import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let docTools: [Tool] = [
        Tool("scan", "Scan Document", "doc.viewfinder", .docs,
             "Scan paper with your iPhone or from photos. Pages are found, straightened and cleaned up into one PDF",
             accepts: [.image], fullBleed: true) { ScanDocumentView() },
        Tool("redactpdf", "Redact PDF", "eye.slash.circle", .docs,
             "Black out names, numbers or whole areas so they're removed for good, not just covered up",
             accepts: [.pdf], fullBleed: true) { RedactPDFView() },
        Tool("fillforms", "Fill & Flatten Forms", "pencil.and.list.clipboard", .docs,
             "Fill in PDF forms, add text where there are no fields, and flatten the answers", accepts: [.pdf], fullBleed: true) { FillFormsView() },
        Tool("searchable", "Make PDF Searchable", "text.magnifyingglass", .docs,
             "Add an invisible text layer to scanned PDFs so you can search, select and copy their text",
             accepts: [.pdf], fullBleed: true) { MakeSearchableView() },
        Tool("pdf2word", "PDF to Word", "doc.richtext", .docs,
             "Turn PDFs into Word documents you can edit, with headings, lists and paragraphs", accepts: [.pdf], fullBleed: true) { PDFToWordView() },
        Tool("signpdf", "Sign PDF", "signature", .docs,
             "Draw or type your signature and place it on a document", accepts: [.pdf], fullBleed: true) { SignPDFView() },
        Tool("merge", "Merge PDFs", "doc.on.doc", .docs,
             "Combine several PDFs and images into one document", accepts: [.pdf, .image], fullBleed: true) { MergePDFView() },
        Tool("split", "Split PDF", "scissors", .docs,
             "Break a PDF into single pages or page ranges", accepts: [.pdf], fullBleed: true) { SplitPDFView() },
        Tool("organize", "Organize PDF", "square.grid.3x3", .docs,
             "Reorder, rotate and remove pages in a PDF", accepts: [.pdf], fullBleed: true) { PageGridView(mode: .organize) },
        Tool("deletepages", "Delete Pages", "trash", .docs,
             "Remove the pages you don't need from a PDF", accepts: [.pdf], fullBleed: true) { PageGridView(mode: .delete) },
        Tool("extractpages", "Extract Pages", "doc.badge.arrow.up", .docs,
             "Save selected pages as a new PDF", accepts: [.pdf], fullBleed: true) { PageGridView(mode: .extract) },
        Tool("img2pdf", "Images to PDF", "photo.on.rectangle", .docs,
             "Turn photos and scans into a single PDF document", accepts: [.image], fullBleed: true) { ImagesToPDFView() },
        Tool("compresspdf", "Compress PDF", "arrow.down.doc", .docs,
             "Make PDFs smaller by recompressing their images", accepts: [.pdf], fullBleed: true) { CompressPDFView() },
        Tool("addpassword", "Add Password", "lock.doc", .docs,
             "Protect PDFs with a password and limit printing or copying", accepts: [.pdf], fullBleed: true) { AddPasswordView() },
        Tool("removepassword", "Remove Password", "lock.open", .docs,
             "Save an unlocked copy of a password-protected PDF you own", accepts: [.pdf], fullBleed: true) { RemovePasswordView() },
        Tool("pdf2images", "PDF to Images", "photo.stack", .docs,
             "Save every page of a PDF as a PNG, JPEG or HEIC image", accepts: [.pdf], fullBleed: true) { PDFToImagesView() },
        Tool("convertdocs", "Convert Documents", "arrow.triangle.2.circlepath.doc.on.clipboard", .docs,
             "Switch documents between Word, OpenDocument, RTF, HTML, plain text and Markdown",
             accepts: DocKit.wordTypes, fullBleed: true) { ConvertDocumentsView() },
        Tool("word2pdf", "Word to PDF", "doc.text", .docs,
             "Turn Word, RTF and text documents into PDFs", accepts: DocKit.wordTypes, fullBleed: true) { WordToPDFView() },
        Tool("ppt2pdf", "PowerPoint to PDF", "rectangle.on.rectangle.angled", .docs,
             "Turn slide decks into PDFs with Keynote or LibreOffice", accepts: DocKit.slideTypes, fullBleed: true) { OfficeToPDFView(kind: .slides) },
        Tool("excel2pdf", "Excel to PDF", "tablecells", .docs,
             "Turn spreadsheets into PDFs with Numbers or LibreOffice", accepts: DocKit.sheetTypes, fullBleed: true) { OfficeToPDFView(kind: .sheets) },
        Tool("webpdf", "Web Page to PDF", "globe", .docs,
             "Save web pages as PDFs, on pages or as one long page") { WebPageToPDFView() },
        Tool("md2pdf", "Markdown to PDF", "text.document", .docs,
             "Typeset Markdown notes and READMEs as clean PDFs", accepts: DocKit.markdownTypes, fullBleed: true) { MarkdownToPDFView() },
    ]
}

// MARK: - Combine layout (many inputs → one PDF)

/// Like BatchToolView, but the inputs are ordered (drag to reorder) and produce a single output.
struct CombineToolView<Options: View, Preview: View>: View {
    let toolID: String
    let types: [UTType]
    let noun: String
    let verb: String
    @ViewBuilder let options: () -> Options
    @ViewBuilder let preview: (URL) -> Preview
    let combine: @MainActor ([URL]) async throws -> URL
    /// Everything that changes the result; set with `previewRender` to show a live preview under the list.
    var previewKey: String?
    var previewRender: (@MainActor ([URL], URL) async throws -> URL)?

    @Bindable private var run: BatchRun
    @State private var working = false
    @State private var result: URL?
    @State private var error: String?
    @State private var targeted = false

    init(toolID: String, types: [UTType], noun: String, verb: String,
         previewKey: String? = nil, previewRender: (@MainActor ([URL], URL) async throws -> URL)? = nil,
         @ViewBuilder options: @escaping () -> Options,
         @ViewBuilder preview: @escaping (URL) -> Preview, combine: @escaping @MainActor ([URL]) async throws -> URL) {
        self.previewKey = previewKey
        self.previewRender = previewRender
        self.toolID = toolID
        self.types = types
        self.noun = noun
        self.verb = verb
        self.options = options
        self.preview = preview
        self.combine = combine
        self.run = AppModel.shared.batch(toolID)
        ToolActions.combine[toolID] = combine
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if run.items.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                        Text("Drop \(noun)s").font(.title3.weight(.semibold))
                        Text("They're combined in the order shown. Drag to reorder.").foregroundStyle(.secondary)
                        Button("Choose \(noun)s…") { run.add(FilePicker.choose(types: types, folders: true), types: types) }.controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $run.selection) {
                        ForEach(Array(run.items.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 10) {
                                Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                                BatchRow(item: item, remove: { run.remove([item.id]) })
                            }
                            .tag(item.id)
                        }
                        .onMove { run.items.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .onDeleteCommand { if let id = run.selection { run.remove([id]) } }
                    .frame(maxHeight: previewKey == nil ? .infinity : min(CGFloat(run.items.count) * 48 + 16, 200))
                    if let previewKey, let previewRender, run.items.count >= 2, let first = run.items.first?.url {
                        let urls = run.items.map(\.url)
                        Divider()
                        LivePreviewPane(id: toolID, source: first, key: previewKey + "|" + urls.map(\.path).joined(separator: "|"),
                                        excerpt: false, enabled: !working) { _, folder in try await previewRender(urls, folder) }
                    }
                    Divider()
                    HStack {
                        Button { run.add(FilePicker.choose(types: types, folders: true), types: types) } label: { Label("Add \(noun)s…", systemImage: "plus") }
                        Spacer()
                        Text("Drag rows to change the order").foregroundStyle(.secondary)
                        Button("Clear") { run.clear(); result = nil }
                    }
                    .buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity)
            .onDrop(of: FileDrop.types, isTargeted: $targeted) { providers in
                FileDrop.load(providers) { run.add($0, types: types); result = nil }
                return true
            }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).padding(6).allowsHitTesting(false) } }
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    if let item = run.selectedItem { preview(item.url).padding([.horizontal, .top], 16) }
                    Form { options() }.formStyle(.grouped).frame(width: 320).scrollDisabled(true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let error { ErrorText(message: error).font(.callout) }
                    if let result {
                        HStack {
                            Thumbnail(url: result, size: 28)
                            Text(result.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(result) }
                        }
                        .contentShape(Rectangle())
                        .draggableFile(result)
                    }
                    Button {
                        Task {
                            working = true; error = nil
                            do { result = try await combine(run.items.map(\.url)) } catch { self.error = error.localizedDescription }
                            working = false
                        }
                    } label: {
                        Group { if working { ProgressView().controlSize(.small) } else { Text("\(verb) \(run.items.count) \(noun)\(run.items.count == 1 ? "" : "s")") } }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(run.items.isEmpty || working)
                    SavesToLine()
                }
                .padding(16)
            }
            .frame(width: 320)
            .clipped()
        }
        .receivesFiles(for: toolID) { run.add($0, types: types); result = nil }
    }
}

extension CombineToolView where Preview == EmptyView {
    init(toolID: String, types: [UTType], noun: String, verb: String,
         previewKey: String? = nil, previewRender: (@MainActor ([URL], URL) async throws -> URL)? = nil,
         @ViewBuilder options: @escaping () -> Options,
         combine: @escaping @MainActor ([URL]) async throws -> URL) {
        self.init(toolID: toolID, types: types, noun: noun, verb: verb, previewKey: previewKey, previewRender: previewRender,
                  options: options, preview: { _ in EmptyView() }, combine: combine)
    }
}

// MARK: - Merge, Images to PDF

struct MergePDFView: View {
    @State private var name = "Merged"

    var body: some View {
        CombineToolView(toolID: "merge", types: [.pdf, .image], noun: "File", verb: "Merge") {
            Section {
                TextField("File name", text: $name)
            } footer: {
                Text("PDFs keep their pages as they are; images become full pages.").font(.caption).foregroundStyle(.secondary)
            }
        } combine: { [name] urls in
            let out = PDFDocument()
            for url in urls {
                if url.pathExtension.lowercased() == "pdf" {
                    let doc = try DocKit.open(url)
                    for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
                } else {
                    let data = try DocKit.pdf(fromImages: [try ImageKit.load(url)], pageSize: nil, margin: 0, ocr: false)
                    if let doc = PDFDocument(data: data), let p = doc.page(at: 0) { out.insert(p, at: out.pageCount) }
                }
            }
            let url = Output.file(name: name.isEmpty ? "Merged" : name, ext: "pdf")
            try DocKit.write(out, to: url)
            return url
        }
    }
}

struct ImagesToPDFView: View {
    @State private var name = "Images"
    @AppStorage("i2p.paper") private var paper = "fit"
    @AppStorage("i2p.margin") private var margin = 0.0
    @AppStorage("i2p.ocr") private var ocr = true

    var body: some View {
        CombineToolView(toolID: "img2pdf", types: [.image], noun: "Image", verb: "Make PDF from") {
            Section {
                TextField("File name", text: $name)
                Picker("Page size", selection: $paper) {
                    Text("Fit each image").tag("fit")
                    Text("A4").tag("a4")
                    Text("US Letter").tag("letter")
                }
                Picker("Margin", selection: $margin) { Text("None").tag(0.0); Text("Small").tag(18.0); Text("Large").tag(42.0) }
                Toggle("Make text searchable", isOn: $ocr)
            }
        } combine: { [name, paper, margin, ocr] urls in
            let images = try urls.map { try ImageKit.load($0, maxPixel: 3000) }
            let size: CGSize? = paper == "a4" ? DocKit.Paper.a4.size : paper == "letter" ? DocKit.Paper.letter.size : nil
            let data = try await offMain { try DocKit.pdf(fromImages: images, pageSize: size, margin: margin, ocr: ocr) }
            let url = Output.file(name: name.isEmpty ? "Images" : name, ext: "pdf")
            try data.write(to: url)
            return url
        }
    }
}

// MARK: - Split

struct SplitPDFView: View {
    @AppStorage("split.mode") private var mode = "each"
    @AppStorage("split.every") private var every = 2
    @State private var ranges = "1-3, 4-"

    var body: some View {
        BatchToolView(toolID: "split", folderName: "", types: [.pdf], noun: "PDF", verb: "Split", concurrency: 2) {
            Section {
                Picker("Split into", selection: $mode) {
                    Text("Single pages").tag("each")
                    Text("Every N pages").tag("every")
                    Text("Page ranges").tag("ranges")
                }
                .pickerStyle(.radioGroup)
                if mode == "every" { Stepper("Every \(every) pages", value: $every, in: 2...500) }
                if mode == "ranges" {
                    TextField("Ranges", text: $ranges, prompt: Text("1-3, 5, 8-"))
                    Text("Each range becomes its own PDF.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } process: { [mode, every, ranges] url, folder, progress in
            let doc = try DocKit.open(url)
            let n = doc.pageCount
            let groups: [[Int]] = switch mode {
            case "every": stride(from: 0, to: n, by: every).map { Array($0..<min($0 + every, n)) }
            case "ranges": try DocKit.ranges(ranges, pageCount: n)
            default: (0..<n).map { [$0] }
            }
            let dir = Output.unique(folder.appendingPathComponent(url.baseName + " split"))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, pages) in groups.enumerated() {
                let label = pages.count == 1 ? "page \(pages[0] + 1)" : "pages \(pages.first! + 1)-\(pages.last! + 1)"
                try DocKit.write(DocKit.subset(doc, pages: pages), to: dir.appendingPathComponent("\(url.baseName) \(label).pdf"))
                progress(Double(i + 1) / Double(groups.count))
            }
            return BatchOutput(files: [dir], note: "\(groups.count) PDFs in “\(dir.lastPathComponent)”")
        }
    }
}

// MARK: - Compress

struct CompressPDFView: View {
    @AppStorage("cpdf.level") private var level: VideoQuality = .balanced

    var body: some View {
        BatchToolView(toolID: "compresspdf", folderName: "", types: [.pdf], noun: "PDF", verb: "Compress", concurrency: 2) {
            Section {
                Picker("Quality", selection: $level) { ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            } header: {
                Text("Quality")
            } footer: {
                Text(level == .small
                     ? "Pages are re-rendered as compact images with a searchable text layer. Smallest, but vector text becomes an image."
                     : "Images are recompressed; text and vectors stay sharp. PDFs that can't get smaller are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } process: { [level] url, folder, progress in
            let doc = try DocKit.open(url)
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " compressed", ext: "pdf")
            switch level {
            case .small:
                let pages = try (0..<doc.pageCount).compactMap { i -> CGImage? in
                    progress(Double(i) / Double(max(1, doc.pageCount)) * 0.6)
                    return try doc.page(at: i).map { try DocKit.render($0, dpi: 110) }
                }
                let data = try await offMain { try DocKit.pdf(fromImages: pages, pageSize: nil, margin: 0, ocr: true, jpegQuality: 0.55, imageDPI: 110) }
                try data.write(to: out)
            default:
                var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
                if level == .balanced { options[.optimizeImagesForScreenOption] = true }
                try DocKit.write(doc, to: out, options: options)
            }
            if out.fileSize >= url.fileSize {
                try? FileManager.default.removeItem(at: out)
                return BatchOutput(note: "Already compact — couldn't make it smaller")
            }
            return BatchOutput(files: [out], note: sizeChange(url.fileSize, out.fileSize))
        }
    }
}

// MARK: - Passwords

struct AddPasswordView: View {
    @State private var password = ""
    @State private var confirm = ""
    @AppStorage("pw.print") private var allowPrinting = true
    @AppStorage("pw.copy") private var allowCopying = false

    var body: some View {
        BatchToolView(toolID: "addpassword", folderName: "", types: [.pdf], noun: "PDF", verb: "Protect", concurrency: 2) {
            Section {
                SecureField("Password", text: $password)
                SecureField("Confirm password", text: $confirm)
                if !confirm.isEmpty && confirm != password { Text("The passwords don't match").font(.caption).foregroundStyle(.red) }
                Toggle("Allow printing", isOn: $allowPrinting)
                Toggle("Allow copying text", isOn: $allowCopying)
            } footer: {
                Text("Uses 256-bit AES encryption. Anyone opening the PDF needs this password.").font(.caption).foregroundStyle(.secondary)
            }
        } process: { [password, confirm, allowPrinting, allowCopying] url, folder, _ in
            guard !password.isEmpty else { throw ToolError("Type a password first") }
            guard password == confirm else { throw ToolError("The passwords don't match") }
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " protected", ext: "pdf")
            if let qpdf = Shell.which("qpdf") {
                let r = try await Shell.run(qpdf, ["--encrypt", password, password + "-owner-" + UUID().uuidString.prefix(8), "256",
                                                   "--print=\(allowPrinting ? "full" : "none")", "--extract=\(allowCopying ? "y" : "n")",
                                                   "--", url.path, out.path])
                if !r.ok && r.status != 3 { throw ToolError(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            } else {
                let doc = try DocKit.open(url)
                // PDFAccessPermissions is a plain enum in Swift, so combine its bits by hand.
                var perms = PDFAccessPermissions.allowsContentAccessibility.rawValue
                if allowPrinting { perms |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue | PDFAccessPermissions.allowsHighQualityPrinting.rawValue }
                if allowCopying { perms |= PDFAccessPermissions.allowsContentCopying.rawValue }
                try DocKit.write(doc, to: out, options: [.userPasswordOption: password, .ownerPasswordOption: UUID().uuidString,
                                                         .accessPermissionsOption: NSNumber(value: perms)])
            }
            guard PDFDocument(url: out)?.isLocked == true else { throw ToolError("Couldn't encrypt this PDF") }
            return BatchOutput(files: [out], note: "Protected")
        }
    }
}

struct RemovePasswordView: View {
    @State private var password = ""

    var body: some View {
        BatchToolView(toolID: "removepassword", folderName: "", types: [.pdf], noun: "PDF", verb: "Unlock", concurrency: 2) {
            Section {
                SecureField("Current password", text: $password)
            } footer: {
                Text("Saves an unlocked copy. PDFs that only restrict printing or copying can be unlocked without a password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } process: { [password] url, folder, _ in
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " unlocked", ext: "pdf")
            if let qpdf = Shell.which("qpdf") {
                var args = ["--decrypt"]
                if !password.isEmpty { args.append("--password=\(password)") }
                let r = try await Shell.run(qpdf, args + ["--", url.path, out.path])
                if !r.ok && r.status != 3 {
                    try? FileManager.default.removeItem(at: out)
                    throw ToolError(r.err.contains("invalid password") ? "Wrong password" : r.err.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                guard let doc = PDFDocument(url: url) else { throw ToolError("Can't open this PDF") }
                if doc.isLocked && !doc.unlock(withPassword: password) { throw ToolError("Wrong password") }
                try DocKit.write(doc, to: out)
            }
            return BatchOutput(files: [out], note: "Unlocked")
        }
    }
}

// MARK: - PDF to Images

struct PDFToImagesView: View {
    @AppStorage("p2i.format") private var format: ImageFormat = .png
    @AppStorage("p2i.dpi") private var dpi = 150.0

    var body: some View {
        BatchToolView(toolID: "pdf2images", folderName: "", types: [.pdf], noun: "PDF", verb: "Export Pages from", concurrency: 1) {
            Section {
                Picker("Format", selection: $format) {
                    Text("PNG").tag(ImageFormat.png); Text("JPEG").tag(ImageFormat.jpeg); Text("HEIC").tag(ImageFormat.heic)
                }
                .pickerStyle(.segmented).labelsHidden()
                Picker("Resolution", selection: $dpi) {
                    Text("72 dpi · screen").tag(72.0); Text("150 dpi · good").tag(150.0); Text("300 dpi · print").tag(300.0)
                }
            } header: { Text("Format") }
        } process: { [format, dpi] url, folder, progress in
            let doc = try DocKit.open(url)
            let dir = Output.unique(folder.appendingPathComponent(url.baseName + " pages"))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let digits = String(doc.pageCount).count
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let image = try DocKit.render(page, dpi: dpi)
                let name = "\(url.baseName) page \(String(format: "%0\(digits)d", i + 1))"
                try ImageKit.save(image, to: dir.appendingPathComponent(name).appendingPathExtension(format.ext), format: format, quality: 0.9)
                progress(Double(i + 1) / Double(doc.pageCount))
            }
            return BatchOutput(files: [dir], note: "\(doc.pageCount) \(format.title) images")
        }
    }
}

// MARK: - Make Searchable, PDF to Word

struct MakeSearchableView: View {
    var body: some View {
        BatchToolView(toolID: "searchable", folderName: "", types: [.pdf], noun: "PDF", verb: "Make Searchable", concurrency: 1) {
            Section {
                Text("Pages that are only images get an invisible text layer, so you can search, select and copy their text. Pages that already have text are left as they are.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } process: { url, folder, progress in
            let doc = try DocKit.open(url)
            let (data, recognized) = try await offMain { try DocKit.searchable(doc) }
            progress(1)
            guard recognized > 0 else { return BatchOutput(note: "Already searchable — every page has text") }
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " searchable", ext: "pdf")
            try data.write(to: out)
            return BatchOutput(files: [out], note: "Text added to \(recognized) page\(recognized == 1 ? "" : "s")")
        }
    }
}

enum PDFToWord {
    /// Rebuilds editable rich text from a PDF: big text becomes headings, wrapped lines rejoin into paragraphs.
    static func attributed(_ doc: PDFDocument) throws -> NSAttributedString {
        let out = NSMutableAttributedString()
        var bodySizes: [CGFloat: Int] = [:]
        var pages: [NSAttributedString] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let a = page.attributedString, a.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                pages.append(a)
            } else {
                pages.append(NSAttributedString(string: (try? OCR.recognize(DocKit.render(page, dpi: 200))) ?? ""))
            }
        }
        for a in pages {
            a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
                if let f = v as? NSFont { bodySizes[f.pointSize.rounded(), default: 0] += r.length }
            }
        }
        let body = bodySizes.max { $0.value < $1.value }?.key ?? 11
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8
        for (index, a) in pages.enumerated() {
            let lines = a.string.components(separatedBy: "\n")
            var location = 0
            var pending = ""
            var pendingFont = NSFont.systemFont(ofSize: 11)
            func flush() {
                guard !pending.trimmingCharacters(in: .whitespaces).isEmpty else { pending = ""; return }
                out.append(NSAttributedString(string: pending.trimmingCharacters(in: .whitespaces) + "\n",
                                              attributes: [.font: pendingFont, .paragraphStyle: paragraph]))
                pending = ""
            }
            for line in lines {
                let length = (line as NSString).length
                defer { location += length + 1 }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { flush(); continue }
                let source = location < a.length ? a.attribute(.font, at: location, effectiveRange: nil) as? NSFont : nil
                let size = source?.pointSize ?? body
                let bold = source?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
                let isHeading = size >= body * 1.2 || (bold && trimmed.count < 80 && !trimmed.hasSuffix("."))
                let isBullet = trimmed.hasPrefix("•") || trimmed.hasPrefix("- ") || trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
                let font: NSFont = isHeading
                    ? .systemFont(ofSize: min(24, max(13, size)), weight: .bold)
                    : NSFontManager.shared.convert(.systemFont(ofSize: 11), toHaveTrait: bold ? .boldFontMask : [])
                if isHeading || isBullet {
                    flush()
                    pending = trimmed
                    pendingFont = font
                    flush()
                } else {
                    if !pending.isEmpty && pendingFont.pointSize != font.pointSize { flush() }
                    if pending.hasSuffix("-") { pending.removeLast(); pending += trimmed } else { pending += (pending.isEmpty ? "" : " ") + trimmed }
                    pendingFont = font
                    if trimmed.hasSuffix(".") || trimmed.hasSuffix(":") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
                        if line.count < 60 { flush() }   // short last line of a paragraph
                    }
                }
            }
            flush()
            if index < pages.count - 1 { out.append(NSAttributedString(string: "\u{0C}")) }   // page break
        }
        return out
    }
}

struct PDFToWordView: View {
    var body: some View {
        BatchToolView(toolID: "pdf2word", folderName: "", types: [.pdf], noun: "PDF", verb: "Convert", concurrency: 2) {
            Section {
                Text("Headings, lists and paragraphs are rebuilt as editable text. Scanned pages are read with text recognition.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } process: { url, folder, _ in
            let doc = try DocKit.open(url)
            let (data, words) = try await offMain {
                let attr = try PDFToWord.attributed(doc)
                let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                return (data, attr.string.split(whereSeparator: \.isWhitespace).count)
            }
            let out = ImageKit.outputURL(for: url, in: folder, ext: "docx")
            try data.write(to: out)
            return BatchOutput(files: [out], note: "\(words) words")
        }
    }
}

// MARK: - Convert Documents

enum DocFormat: String, CaseIterable, Identifiable {
    case docx = "Word (.docx)", odt = "OpenDocument (.odt)", rtf = "RTF", html = "HTML", txt = "Plain Text", md = "Markdown"
    var id: String { rawValue }
    var ext: String {
        switch self {
        case .docx: "docx"
        case .odt: "odt"
        case .rtf: "rtf"
        case .html: "html"
        case .txt: "txt"
        case .md: "md"
        }
    }
    var type: NSAttributedString.DocumentType? {
        switch self {
        case .docx: .officeOpenXML
        case .odt: .openDocument
        case .rtf: .rtf
        case .html: .html
        case .txt: .plain
        case .md: nil
        }
    }
}

enum DocConvert {
    static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }

    static func read(_ url: URL) throws -> NSAttributedString {
        if isMarkdown(url) { return DocKit.attributed(markdown: try String(contentsOf: url, encoding: .utf8)) }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    static func convert(_ url: URL, to format: DocFormat, into folder: URL) async throws -> URL {
        let out = ImageKit.outputURL(for: url, in: folder, suffix: url.pathExtension.lowercased() == format.ext ? " converted" : "", ext: format.ext)
        // pandoc handles Markdown in and out best; NSAttributedString keeps rich formatting otherwise.
        if (format == .md || isMarkdown(url)), let pandoc = Shell.which("pandoc") {
            let to = format == .md ? "gfm" : format == .txt ? "plain" : format.ext == "docx" ? "docx" : format.ext
            let r = try await Shell.run(pandoc, [url.path, "-t", to, "-s", "-o", out.path])
            if r.ok { return out }
        }
        if format == .md {
            let text = try read(url).string
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        let attr = try read(url)
        let data = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: format.type!])
        try data.write(to: out)
        return out
    }
}

struct ConvertDocumentsView: View {
    @AppStorage("docs.format") private var format: DocFormat = .docx

    var body: some View {
        BatchToolView(toolID: "convertdocs", folderName: "", types: DocKit.wordTypes, noun: "Document", verb: "Convert", concurrency: 2) {
            Section {
                Picker("Convert to", selection: $format) { ForEach(DocFormat.allCases) { Text($0.rawValue).tag($0) } }
            } footer: {
                Text("Headings, bold, italics, lists and tables are kept where the format allows.").font(.caption).foregroundStyle(.secondary)
            }
        } process: { [format] url, folder, _ in
            let out = try await DocConvert.convert(url, to: format, into: folder)
            return BatchOutput(files: [out], note: format.rawValue)
        }
    }
}

// MARK: - Word, Markdown, Office → PDF

struct WordToPDFView: View {
    @AppStorage("w2p.paper") private var paper: DocKit.Paper = .a4

    var body: some View {
        BatchToolView(toolID: "word2pdf", folderName: "", types: DocKit.wordTypes, noun: "Document", verb: "Convert", concurrency: 1) {
            Section {
                Picker("Paper", selection: $paper) { ForEach(DocKit.Paper.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            } header: { Text("Paper") } footer: {
                Text(DocKit.libreOffice != nil ? "Uses LibreOffice for Word files, so layouts match closely."
                     : "Complex Word layouts convert best with LibreOffice installed (brew install --cask libreoffice).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } process: { [paper] url, folder, _ in
            let ext = url.pathExtension.lowercased()
            if ["docx", "doc", "odt"].contains(ext), DocKit.libreOffice != nil {
                let out = try await DocKit.libreOfficeConvert(url, to: "pdf", into: folder)
                return BatchOutput(files: [out], note: "LibreOffice")
            }
            let attr = try DocConvert.read(url)
            let data = try DocKit.pdf(from: attr, paper: paper)
            let out = ImageKit.outputURL(for: url, in: folder, ext: "pdf")
            try data.write(to: out)
            return BatchOutput(files: [out], note: "\(PDFDocument(data: data)?.pageCount ?? 0) pages")
        }
    }
}

struct MarkdownToPDFView: View {
    @AppStorage("md.paper") private var paper: DocKit.Paper = .a4

    static let css = """
    body{font:15px/1.6 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;color:#1d1d1f;max-width:760px;margin:0 auto;padding:8px}
    h1,h2{border-bottom:1px solid #e5e5ea;padding-bottom:.3em}h1{font-size:1.9em}h2{font-size:1.45em}h3{font-size:1.2em}
    code{font:13px ui-monospace,Menlo,monospace;background:#f2f2f7;padding:2px 5px;border-radius:5px}
    pre{background:#f2f2f7;padding:12px 14px;border-radius:8px;overflow:auto}pre code{background:none;padding:0}
    blockquote{color:#555;border-left:4px solid #d1d1d6;margin:0;padding:0 1em}table{border-collapse:collapse}
    th,td{border:1px solid #d1d1d6;padding:6px 10px}img{max-width:100%}a{color:#0066cc}
    """

    var body: some View {
        BatchToolView(toolID: "md2pdf", folderName: "", types: DocKit.markdownTypes, noun: "Markdown File", verb: "Typeset", concurrency: 1) {
            Section {
                Picker("Paper", selection: $paper) { ForEach(DocKit.Paper.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            } header: { Text("Paper") } footer: {
                Text("Headings, code blocks, tables, quotes and images (relative paths work) are laid out like a clean README.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } process: { [paper] url, folder, _ in
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let data: Data
            if let pandoc = Shell.which("pandoc") {
                let r = try await Shell.run(pandoc, ["-f", "gfm", "-t", "html"], input: Data(markdown.utf8))
                let html = "<!doctype html><html><head><meta charset='utf-8'><style>\(Self.css)</style></head><body>\(r.out)</body></html>"
                data = try await WebPDF.render(html: html, baseURL: url.deletingLastPathComponent(), longPage: false, paper: paper)
            } else {
                data = try DocKit.pdf(from: DocKit.attributed(markdown: markdown), paper: paper)
            }
            let out = ImageKit.outputURL(for: url, in: folder, ext: "pdf")
            try data.write(to: out)
            return BatchOutput(files: [out], note: "\(PDFDocument(data: data)?.pageCount ?? 0) pages")
        }
    }
}

struct OfficeToPDFView: View {
    enum Kind { case slides, sheets }
    let kind: Kind

    private var iWorkApp: String { kind == .slides ? "Keynote" : "Numbers" }
    private var hasIWork: Bool { DocKit.appInstalled(iWorkApp) }

    var body: some View {
        BatchToolView(toolID: kind == .slides ? "ppt2pdf" : "excel2pdf", folderName: "",
                      types: kind == .slides ? DocKit.slideTypes : DocKit.sheetTypes,
                      noun: kind == .slides ? "Presentation" : "Spreadsheet", verb: "Convert", concurrency: 1) {
            Section {
                if hasIWork {
                    Label("Uses \(iWorkApp). macOS asks once to let MyToolbox control it.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if DocKit.libreOffice != nil {
                    Label("Uses LibreOffice.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Text("Needs \(iWorkApp) (free from Apple) or LibreOffice.").foregroundStyle(.orange)
                    Button("Get \(iWorkApp) from the App Store") {
                        NSWorkspace.shared.open(URL(string: kind == .slides ? "macappstore://apps.apple.com/app/id409183694" : "macappstore://apps.apple.com/app/id409203825")!)
                    }
                    Text("Or in Terminal: brew install --cask libreoffice").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        } process: { url, folder, _ in
            let out = ImageKit.outputURL(for: url, in: folder, ext: "pdf")
            if DocKit.appInstalled(iWorkApp) {
                try await DocKit.iWorkExport(url, app: iWorkApp, to: out)
                return BatchOutput(files: [out], note: "\(PDFDocument(url: out)?.pageCount ?? 0) pages · \(iWorkApp)")
            }
            if DocKit.libreOffice != nil {
                let made = try await DocKit.libreOfficeConvert(url, to: "pdf", into: folder)
                return BatchOutput(files: [made], note: "LibreOffice")
            }
            throw ToolError("Install \(iWorkApp) or LibreOffice to convert this file")
        }
    }
}

// MARK: - Web Page to PDF

struct WebPageToPDFView: View {
    @State private var links = ""
    @AppStorage("web.long") private var longPage = false
    @AppStorage("web.paper") private var paper: DocKit.Paper = .a4
    @State private var working = false
    @State private var status: String?
    @State private var results: [URL] = []
    @State private var errors: [String] = []

    private var urls: [URL] {
        links.components(separatedBy: .whitespacesAndNewlines).compactMap { s in
            let t = s.hasPrefix("http") ? s : (s.contains(".") ? "https://" + s : "")
            return URL(string: t).flatMap { $0.host == nil ? nil : $0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Paste web addresses — one per line", text: $links, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    .onSubmit(save)
                Button("Paste") { links = Pasteboard.string ?? "" }
                Button("Save as PDF", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(urls.isEmpty || working)
            }
            HStack(spacing: 16) {
                Picker("Layout", selection: $longPage) {
                    Text("Pages").tag(false)
                    Text("One long page").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                if !longPage {
                    Picker("Paper", selection: $paper) { ForEach(DocKit.Paper.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                }
                Spacer()
            }
            if working, let status { HStack { ProgressView().controlSize(.small); Text(status).foregroundStyle(.secondary) } }
            ForEach(errors, id: \.self) { ErrorText(message: $0) }
            ResultList(urls: results)
            if results.isEmpty && !working {
                ContentUnavailableView("Save Any Web Page", systemImage: "globe",
                                       description: Text("Paste a link, or drag one from your browser's address bar onto this window."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .receivesFiles(for: "webpdf") { urls in
            links = (links.isEmpty ? "" : links + "\n") + urls.filter { !$0.isFileURL }.map(\.absoluteString).joined(separator: "\n")
        }
    }

    private func save() {
        let targets = urls
        guard !targets.isEmpty else { return }
        working = true
        errors = []
        Task {
            var made: [URL] = []
            for (i, url) in targets.enumerated() {
                status = "Loading \(url.host ?? url.absoluteString) (\(i + 1) of \(targets.count))…"
                do {
                    let data = try await WebPDF.render(url: url, longPage: longPage, paper: paper)
                    let name = (url.host ?? "Web Page").replacingOccurrences(of: "www.", with: "") + (url.path.count > 1 ? " " + url.lastPathComponent : "")
                    let out = Output.file(name: name, ext: "pdf")
                    try data.write(to: out)
                    made.append(out)
                } catch {
                    errors.append("\(url.host ?? url.absoluteString): \(error.localizedDescription)")
                }
            }
            results = made
            working = false
            if errors.isEmpty { links = "" }
        }
    }
}
