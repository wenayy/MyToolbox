import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let cropPDFTools: [Tool] = [
        Tool("croppdf", "Crop PDF", "crop", .docs,
             "Crop PDF pages to a smaller size, like a 4 × 6 in shipping label on a full sheet", accepts: [.pdf], fullBleed: true) { CropPDFView() },
    ]
}

enum PDFCropSize: String, CaseIterable, Identifiable {
    case free = "Freeform", label = "4 × 6 in label", a6 = "A6", a5 = "A5", letter = "US Letter", a4 = "A4"
    var id: String { rawValue }
    /// Portrait size in points.
    var points: CGSize? {
        switch self {
        case .free: nil
        case .label: CGSize(width: 288, height: 432)
        case .a6: CGSize(width: 297.6, height: 419.5)
        case .a5: CGSize(width: 419.5, height: 595.3)
        case .letter: CGSize(width: 612, height: 792)
        case .a4: CGSize(width: 595.3, height: 841.9)
        }
    }
}

enum PDFCropScope: String, CaseIterable, Identifiable {
    case all = "All pages", shown = "Only the page shown", trimEach = "Trim each page's margins"
    var id: String { rawValue }
}

/// Crop maths for PDF pages, in "display" terms: 0…1 of the page as it's shown (rotation applied), origin top left.
enum PDFCrop {
    /// The page box rectangle for a display rectangle, undoing the page's rotation.
    static func boxRect(_ r: CGRect, page: PDFPage) -> CGRect {
        let b = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            switch rotation {
            case 90: CGPoint(x: b.minX + v * b.width, y: b.minY + u * b.height)
            case 180: CGPoint(x: b.maxX - u * b.width, y: b.minY + v * b.height)
            case 270: CGPoint(x: b.maxX - v * b.width, y: b.maxY - u * b.height)
            default: CGPoint(x: b.minX + u * b.width, y: b.maxY - v * b.height)
            }
        }
        let corners = [map(r.minX, r.minY), map(r.maxX, r.minY), map(r.minX, r.maxY), map(r.maxX, r.maxY)]
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Page size as shown, in points.
    static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox).size
        return page.rotation % 180 == 0 ? b : CGSize(width: b.height, height: b.width)
    }

    /// A fixed-size frame (in points), turned to match the page and centred; nil for freeform.
    static func fixedRect(_ size: PDFCropSize, page: PDFPage) -> CGRect? {
        guard var pts = size.points else { return nil }
        let shown = displaySize(page)
        if shown.width > shown.height { pts = CGSize(width: pts.height, height: pts.width) }
        var w = pts.width / shown.width, h = pts.height / shown.height
        if w > 1 || h > 1 { let k = 1 / max(w, h); w *= k; h *= k }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// The area with ink on it (anything not near-white), padded a little.
    static func contentRect(_ page: PDFPage) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let shown = displaySize(page)
        guard shown.width > 0, shown.height > 0 else { return full }
        let scale = min(1, 1400 / max(shown.width, shown.height)) * 2
        let w = Int(shown.width * scale), h = Int(shown.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = page.thumbnail(of: CGSize(width: w, height: h), for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = ctx.data else { return full }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if px[i] < 235 || px[i + 1] < 235 || px[i + 2] < 235 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return full }
        // Bitmap rows run top to bottom in memory, so y here is already from the top.
        let pad = 6 * scale
        let r = CGRect(x: CGFloat(minX) - pad, y: CGFloat(minY) - pad, width: CGFloat(maxX - minX + 1) + 2 * pad, height: CGFloat(maxY - minY + 1) + 2 * pad)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return CGRect(x: r.minX / CGFloat(w), y: r.minY / CGFloat(h), width: r.width / CGFloat(w), height: r.height / CGFloat(h))
    }

    static func apply(_ display: CGRect, to page: PDFPage) {
        // Rounded (not .integral, which grows outward) so a 4 × 6 in label stays exactly 288 × 432 pt.
        let b = boxRect(display, page: page)
        let r = CGRect(x: b.minX.rounded(), y: b.minY.rounded(), width: b.width.rounded(), height: b.height.rounded())
        for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] { page.setBounds(r, for: box) }
    }

    /// Saves a cropped copy of `url`.
    static func crop(_ url: URL, rect: CGRect, scope: PDFCropScope, shownPage: Int, folder: URL = Output.root) throws -> URL {
        let doc = try DocKit.open(url)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            switch scope {
            case .all: apply(rect, to: page)
            case .shown: if i == shownPage { apply(rect, to: page) }
            case .trimEach: apply(contentRect(page), to: page)
            }
        }
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " cropped", ext: "pdf")
        guard doc.write(to: out) else { throw ToolError("Couldn't save \(out.lastPathComponent).") }
        return out
    }
}

@MainActor @Observable
final class CropPDFModel {
    static let shared = CropPDFModel()
    var files: [URL] = []
    var current: URL?
    var doc: PDFDocument?
    var pageIndex = 0
    var image: NSImage?
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var size: PDFCropSize = .free
    var scope: PDFCropScope = .all
    var working = false
    var results: [URL] = []
    var error: String?

    var page: PDFPage? { doc?.page(at: pageIndex) }

    func add(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" && !files.contains($0) }
        files += pdfs
        if current == nil, let first = files.first { show(first) }
    }

    func show(_ url: URL) {
        error = nil
        do {
            doc = try DocKit.open(url)
            current = url
            pageIndex = 0
            render()
            setSize(size)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func go(_ delta: Int) {
        guard let doc else { return }
        pageIndex = min(max(0, pageIndex + delta), doc.pageCount - 1)
        render()
    }

    func render() {
        guard let page else { image = nil; return }
        let shown = PDFCrop.displaySize(page)
        let k = 1200 / max(shown.width, shown.height, 1)
        // Sized in points so the crop frame's shape matches the page.
        let img = page.thumbnail(of: CGSize(width: shown.width * k, height: shown.height * k), for: .cropBox)
        img.size = shown
        image = img
    }

    func setSize(_ s: PDFCropSize) {
        size = s
        if let page, let r = PDFCrop.fixedRect(s, page: page) { rect = r } else if s == .free { rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    func trimMargins() {
        guard let page else { return }
        size = .free
        rect = PDFCrop.contentRect(page)
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        if current == url { current = nil; doc = nil; image = nil; if let f = files.first { show(f) } }
    }

    func cropAll() {
        working = true; error = nil; results = []
        let (rect, scope, shown, files) = (rect, scope, pageIndex, files)
        Task {
            for f in files {
                do {
                    let out = try await offMain { try PDFCrop.crop(f, rect: rect, scope: scope, shownPage: shown) }
                    results.append(out)
                } catch {
                    self.error = "\(f.lastPathComponent): \(error.localizedDescription)"
                }
            }
            working = false
        }
    }
}

struct CropPDFView: View {
    @Bindable private var model = CropPDFModel.shared
    @State private var dropped: [URL] = []

    var body: some View {
        Group {
            if model.files.isEmpty {
                DropZone(prompt: "Drop PDFs to crop", types: [.pdf], multiple: true, urls: $dropped)
                    .padding(20).frame(maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 0) {
                    if model.files.count > 1 { fileList.frame(width: 220); Divider() }
                    VStack(spacing: 10) {
                        if let image = model.image {
                            CropEditor(image: image, rect: $model.rect, aspect: nil, resizable: model.size == .free)
                                .disabled(model.scope == .trimEach)
                                .opacity(model.scope == .trimEach ? 0.6 : 1)
                        } else {
                            Spacer()
                        }
                        if let doc = model.doc, doc.pageCount > 1 {
                            HStack {
                                Button { model.go(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.pageIndex == 0)
                                Text("Page \(model.pageIndex + 1) of \(doc.pageCount)").monospacedDigit()
                                Button { model.go(1) } label: { Image(systemName: "chevron.right") }.disabled(model.pageIndex >= doc.pageCount - 1)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector.frame(width: 300)
                }
            }
        }
        .onChange(of: dropped) { if !dropped.isEmpty { model.add(dropped); dropped = [] } }
        .receivesFiles(for: "croppdf") { model.add($0) }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            List(model.files, id: \.self, selection: Binding(get: { model.current }, set: { if let u = $0 { model.show(u) } })) { url in
                HStack {
                    Thumbnail(url: url, size: 26)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .contextMenu { Button("Remove from List") { model.remove(url) } }
            }
            Divider()
            HStack {
                Button { model.add(FilePicker.choose(types: [.pdf])) } label: { Label("Add PDFs…", systemImage: "plus") }
                Spacer()
                Button("Clear") { model.files = []; model.current = nil; model.doc = nil; model.image = nil; model.results = [] }
            }
            .buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Size", selection: Binding(get: { model.size }, set: { model.setSize($0) })) {
                        ForEach(PDFCropSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Trim Margins") { model.trimMargins() }
                    if let page = model.page {
                        let pts = PDFCrop.boxRect(model.rect, page: page).size
                        LabeledContent("Result", value: String(format: "%.2f × %.2f in", pts.width / 72, pts.height / 72))
                    }
                } footer: {
                    Text(model.size == .free ? "Drag the corners of the frame, or drag inside it to move." : "Drag the frame to place it. The pages come out exactly this size.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Apply to", selection: $model.scope) { ForEach(PDFCropScope.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.radioGroup)
                } footer: {
                    Text(model.scope == .trimEach ? "Every page is cropped to its own content — handy when labels sit in different places."
                         : "The page size changes, so the PDF prints at the cropped size. Originals are never changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(model.working)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let e = model.error { ErrorText(message: e) }
                ResultList(urls: model.results)
                Button {
                    model.cropAll()
                } label: {
                    Group { if model.working { ProgressView().controlSize(.small) } else { Text("Crop \(model.files.count) PDF\(model.files.count == 1 ? "" : "s")") } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.working)
                SavesToLine()
            }
            .padding(16)
        }
    }
}
