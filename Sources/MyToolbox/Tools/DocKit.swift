import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers
import Vision
import WebKit

/// Shared PDF and document plumbing for the Docs tools.
enum DocKit {
    static let wordTypes: [UTType] = [UTType("org.openxmlformats.wordprocessingml.document")!, UTType("com.microsoft.word.doc")!,
                                      UTType("org.oasis-open.opendocument.text")!, .rtf, .rtfd, .plainText, .html,
                                      UTType(filenameExtension: "md") ?? .plainText]
    static let slideTypes: [UTType] = [UTType(filenameExtension: "pptx") ?? .data, UTType(filenameExtension: "ppt") ?? .data,
                                       UTType(filenameExtension: "key") ?? .data, UTType(filenameExtension: "odp") ?? .data]
    static let sheetTypes: [UTType] = [UTType(filenameExtension: "xlsx") ?? .data, UTType(filenameExtension: "xls") ?? .data,
                                       UTType(filenameExtension: "numbers") ?? .data, UTType(filenameExtension: "ods") ?? .data,
                                       .commaSeparatedText]
    static let markdownTypes: [UTType] = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, .plainText]

    // MARK: Opening PDFs

    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolError("Can't open \(url.lastPathComponent) as a PDF") }
        if doc.isLocked {
            guard let password, !password.isEmpty, doc.unlock(withPassword: password) else {
                throw ToolError("\(url.lastPathComponent) is password-protected. Remove the password first.")
            }
        }
        return doc
    }

    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard doc.write(to: url, withOptions: options) else { throw ToolError("Couldn't save \(url.lastPathComponent)") }
    }

    /// "1-3, 5, 8-" → [[0,1,2],[4],[7…last]] (zero-based page indices, one array per range).
    static func ranges(_ spec: String, pageCount: Int) throws -> [[Int]] {
        var out: [[Int]] = []
        for part in spec.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            let bounds = p.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard bounds.count <= 2, let lo = bounds[0].isEmpty ? 1 : Int(bounds[0]),
                  let hi = bounds.count > 1 ? (bounds[1].isEmpty ? Int.max : Int(bounds[1])) : lo, lo >= 1, hi >= lo else {
                throw ToolError("“\(p)” isn't a page range — type them like 1-3, 5, 8-")
            }
            // The same ranges are applied to every PDF in a batch, so pages past the end are simply skipped.
            guard lo <= pageCount else { continue }
            out.append(Array((lo - 1)...(min(hi, pageCount) - 1)))
        }
        if out.isEmpty {
            throw ToolError(spec.trimmingCharacters(in: .whitespaces).isEmpty ? "Type page ranges like 1-3, 5, 8-" : "None of those pages exist — this PDF has \(pageCount) page\(pageCount == 1 ? "" : "s")")
        }
        return out
    }

    static func subset(_ doc: PDFDocument, pages: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for (i, index) in pages.enumerated() {
            if let page = doc.page(at: index)?.copy() as? PDFPage { out.insert(page, at: i) }
        }
        return out
    }

    /// Renders a page at the given resolution (72 = 1 pixel per point).
    static func render(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let w = (rotated ? box.height : box.width) * dpi / 72, h = (rotated ? box.width : box.height) * dpi / 72
        let ctx = try ImageKit.context(width: Int(w.rounded()), height: Int(h.rounded()))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: dpi / 72, y: dpi / 72)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()!
    }

    // MARK: Text layer (Make Searchable, Scan, Redact PDF)

    /// Recognized lines with boxes normalized to the page (origin bottom-left).
    static func recognizeLines(_ image: CGImage) throws -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).performRetrying([request])
        return (request.results ?? []).compactMap { obs in obs.topCandidates(1).first.map { ($0.string, obs.boundingBox) } }
    }

    /// Writes invisible, selectable text over a page drawn in `ctx` (PDF coordinates, origin bottom-left).
    static func drawInvisibleText(_ lines: [(String, CGRect)], in box: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for (text, n) in lines {
            let r = CGRect(x: box.minX + n.minX * box.width, y: box.minY + n.minY * box.height, width: n.width * box.width, height: n.height * box.height)
            guard r.height > 1, r.width > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, r.height * 0.85, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard width > 0 else { continue }
            // Stretch the line to the recognized width so selections line up with the visible words.
            ctx.textMatrix = CGAffineTransform(scaleX: r.width / width, y: 1)
            ctx.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.18)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    /// A new PDF where pages without text get an OCR text layer. Pages that already have text are copied as they are.
    static func searchable(_ doc: PDFDocument, progress: (Double) -> Void = { _ in }) throws -> (Data, Int) {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ToolError("Couldn't create the PDF")
        }
        var recognized = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            page.draw(with: .mediaBox, to: ctx)
            let hasText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count > 10
            if !hasText {
                let lines = try recognizeLines(render(page, dpi: 200))
                // Vision boxes are relative to the rendered (rotated) page; draw them in the media box.
                drawInvisibleText(lines, in: box, ctx: ctx)
                if !lines.isEmpty { recognized += 1 }
            }
            ctx.endPDFPage()
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        ctx.closePDF()
        return (data as Data, recognized)
    }

    /// Makes a PDF from page images, optionally adding an OCR text layer.
    /// With no `pageSize`, each page is the image's size at `imageDPI`.
    static func pdf(fromImages images: [CGImage], pageSize: CGSize?, margin: CGFloat, ocr: Bool, jpegQuality: Double = 0.85,
                    imageDPI: CGFloat = 150) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ToolError("Couldn't create the PDF")
        }
        for image in images {
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            var page: CGRect
            if var size = pageSize {
                if (iw > ih) != (size.width > size.height) { size = CGSize(width: size.height, height: size.width) }   // follow the image's orientation
                page = CGRect(origin: .zero, size: size)
            } else {
                // At 150 dpi a phone photo becomes a sensibly sized page.
                page = CGRect(x: 0, y: 0, width: iw * 72 / imageDPI + margin * 2, height: ih * 72 / imageDPI + margin * 2)
            }
            let area = page.insetBy(dx: margin, dy: margin)
            let scale = min(area.width / iw, area.height / ih)
            let drawn = CGRect(x: area.midX - iw * scale / 2, y: area.midY - ih * scale / 2, width: iw * scale, height: ih * scale)
            var box = page
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            // JPEG-encode photos so the PDF stays small.
            let encoded = (try? ImageKit.encode(image, format: .jpeg, quality: jpegQuality))
                .flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } ?? image
            ctx.draw(encoded, in: drawn)
            // Searchable text is a bonus: a page that can't be read (or is a few pixels big) still goes in.
            if ocr, min(image.width, image.height) >= 16, let lines = try? recognizeLines(image) {
                drawInvisibleText(lines, in: drawn, ctx: ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Draws every page (with its annotations, form values and signatures) into a new PDF,
    /// so nothing stays editable.
    static func flatten(_ doc: PDFDocument) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ToolError("Couldn't create the PDF")
        }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            page.draw(with: .mediaBox, to: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: Documents → PDF

    enum Paper: String, CaseIterable, Identifiable {
        case a4 = "A4", letter = "US Letter"
        var id: String { rawValue }
        var size: CGSize { self == .a4 ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792) }
    }

    /// Paginates rich text into a PDF with NSPrintOperation (must run on the main thread).
    @MainActor
    static func pdf(from attr: NSAttributedString, paper: Paper, margin: CGFloat = 54) throws -> Data {
        let info = NSPrintInfo()
        info.paperSize = paper.size
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mytoolbox-\(UUID().uuidString).pdf")
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp
        let width = paper.size.width - margin * 2
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.appearance = NSAppearance(named: .aqua)
        tv.backgroundColor = .white
        tv.drawsBackground = true
        tv.textContainerInset = .zero
        tv.textStorage?.setAttributedString(attr)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            tv.setFrameSize(NSSize(width: width, height: max(lm.usedRect(for: tc).height, 20)))
        }
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), let data = try? Data(contentsOf: tmp) else { throw ToolError("Couldn't lay out the document") }
        try? FileManager.default.removeItem(at: tmp)
        return data
    }

    /// Text with headings and lists from plain text or Markdown, using the system font.
    static func attributed(markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11.5)
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.lineHeightMultiple = 1.15
        for line in markdown.components(separatedBy: "\n") {
            var text = line
            var font = body
            if let m = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                let level = m.1.count
                font = NSFont.systemFont(ofSize: [22, 18, 15, 13, 12, 12][level - 1], weight: .bold)
                text = String(m.2)
            } else if let m = line.firstMatch(of: #/^\s*[-*+]\s+(.*)$/#) {
                text = "•  " + m.1
            }
            let inline = (try? NSAttributedString(markdown: Data(text.utf8), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? NSAttributedString(string: text)
            let piece = NSMutableAttributedString(attributedString: inline)
            piece.enumerateAttribute(.font, in: NSRange(location: 0, length: piece.length)) { value, range, _ in
                let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                var f = font
                if traits.contains(.bold) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if traits.contains(.italic) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if traits.contains(.monoSpace) { f = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular) }
                piece.addAttribute(.font, value: f, range: range)
            }
            piece.addAttributes([.paragraphStyle: para, .foregroundColor: NSColor.black], range: NSRange(location: 0, length: piece.length))
            out.append(piece)
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }

    // MARK: Helper apps

    static var libreOffice: String? {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func appInstalled(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/\(name).app")
    }

    /// Converts with LibreOffice in the background. Returns the produced file.
    static func libreOfficeConvert(_ url: URL, to ext: String, into folder: URL) async throws -> URL {
        guard let soffice = libreOffice else { throw ToolError("LibreOffice isn't installed") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let r = try await Shell.run(soffice, ["--headless", "--convert-to", ext, "--outdir", temp.path, url.path])
        guard let made = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).first else {
            throw ToolError(r.err.isEmpty ? "LibreOffice couldn't convert \(url.lastPathComponent)" : r.err)
        }
        let out = ImageKit.outputURL(for: url, in: folder, ext: made.pathExtension)
        try FileManager.default.moveItem(at: made, to: out)
        return out
    }

    /// Opens a file in Keynote, Numbers or Pages and exports it as PDF via AppleScript.
    static func iWorkExport(_ url: URL, app: String, to out: URL) async throws {
        let script = """
        tell application "\(app)"
            set d to open POSIX file "\(url.path.replacingOccurrences(of: "\"", with: "\\\""))"
            export d to POSIX file "\(out.path.replacingOccurrences(of: "\"", with: "\\\""))" as PDF
            close d saving no
        end tell
        """
        let r = try await Shell.run("/usr/bin/osascript", ["-e", script])
        guard r.ok, FileManager.default.fileExists(atPath: out.path) else {
            if r.err.contains("-1743") { throw ToolError("Allow MyToolbox to control \(app) in System Settings › Privacy & Security › Automation.") }
            throw ToolError(r.err.isEmpty ? "\(app) couldn't export \(url.lastPathComponent)" : r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - Web pages and HTML → PDF

@MainActor
final class WebPDF: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loaded: CheckedContinuation<Void, Error>?

    /// Loads a URL (or HTML string) offscreen and makes a PDF: paginated on paper, or one long page.
    static func render(url: URL? = nil, html: String? = nil, baseURL: URL? = nil, longPage: Bool, paper: DocKit.Paper) async throws -> Data {
        let renderer = WebPDF()
        return try await renderer.run(url: url, html: html, baseURL: baseURL, longPage: longPage, paper: paper)
    }

    private func run(url: URL?, html: String?, baseURL: URL?, longPage: Bool, paper: DocKit.Paper) async throws -> Data {
        let width: CGFloat = longPage ? 1200 : paper.size.width
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        self.webView = view
        self.window = window
        defer { window.orderOut(nil); self.window = nil }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loaded = cont
            if let html { view.loadHTMLString(html, baseURL: baseURL) } else if let url { view.load(URLRequest(url: url, timeoutInterval: 30)) }
        }
        try await Task.sleep(for: .milliseconds(600))   // let late images and fonts settle
        if longPage {
            let height = (try? await view.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") as? Double) ?? 2000
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: width, height: min(height, 14_000))
            return try await view.pdf(configuration: config)
        }
        let info = NSPrintInfo()
        info.paperSize = paper.size
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString).pdf")
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp
        let op = view.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = view.bounds
        return try await withCheckedThrowingContinuation { cont in
            op.runModal(for: window, delegate: PrintDone.shared, didRun: #selector(PrintDone.done(_:success:contextInfo:)),
                        contextInfo: Unmanaged.passRetained(PrintDone.Box { ok in
                            if ok, let data = try? Data(contentsOf: tmp) {
                                try? FileManager.default.removeItem(at: tmp)
                                cont.resume(returning: data)
                            } else {
                                cont.resume(throwing: ToolError("Couldn't print the page to PDF"))
                            }
                        }).toOpaque())
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
}

/// Bridges NSPrintOperation's Objective-C completion callback to a closure.
final class PrintDone: NSObject {
    static let shared = PrintDone()
    final class Box {
        let call: (Bool) -> Void
        init(_ call: @escaping (Bool) -> Void) { self.call = call }
    }

    @objc func done(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        Unmanaged<Box>.fromOpaque(contextInfo).takeRetainedValue().call(success)
    }
}
