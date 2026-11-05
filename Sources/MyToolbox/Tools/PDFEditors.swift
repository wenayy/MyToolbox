import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Page grid: Organize, Delete Pages, Extract Pages

@MainActor @Observable
final class PageGridModel {
    enum Mode { case organize, delete, extract }

    struct PageItem: Identifiable {
        let id = UUID()
        let index: Int
        var rotation = 0
        var thumbnail: NSImage?
    }

    static var models: [Mode: PageGridModel] = [:]
    static func model(_ mode: Mode) -> PageGridModel {
        if let m = models[mode] { return m }
        let m = PageGridModel()
        models[mode] = m
        return m
    }

    var url: URL?
    var doc: PDFDocument?
    var pages: [PageItem] = []
    var selection = Set<PageItem.ID>()
    var saved: URL?
    var error: String?

    func open(_ url: URL) {
        do {
            let doc = try DocKit.open(url)
            self.url = url
            self.doc = doc
            selection = []
            saved = nil
            error = nil
            pages = (0..<doc.pageCount).map { PageItem(index: $0) }
            for i in pages.indices {
                pages[i].thumbnail = doc.page(at: pages[i].index)?.thumbnail(of: NSSize(width: 240, height: 300), for: .mediaBox)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func close() { url = nil; doc = nil; pages = []; selection = []; saved = nil }

    func rotate(_ degrees: Int) {
        for i in pages.indices where selection.contains(pages[i].id) { pages[i].rotation = (pages[i].rotation + degrees + 360) % 360 }
    }

    func removeSelected() {
        pages.removeAll { selection.contains($0.id) }
        selection = []
    }

    func move(_ id: PageItem.ID, before target: PageItem.ID) {
        guard id != target, let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let item = pages.remove(at: from)
        let to = pages.firstIndex(where: { $0.id == target }) ?? pages.count
        pages.insert(item, at: to)
    }

    func save(_ mode: Mode) {
        guard let doc, let url else { return }
        let chosen: [PageItem]
        let suffix: String
        switch mode {
        case .organize: chosen = pages; suffix = " organized"
        case .delete: chosen = pages.filter { !selection.contains($0.id) }; suffix = " edited"
        case .extract: chosen = pages.filter { selection.contains($0.id) }; suffix = " extract"
        }
        guard !chosen.isEmpty else { error = "Nothing would be left in the PDF"; return }
        let out = PDFDocument()
        for (i, item) in chosen.enumerated() {
            guard let page = doc.page(at: item.index)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + item.rotation) % 360
            out.insert(page, at: i)
        }
        do {
            let dest = Output.file(name: url.baseName + suffix, ext: "pdf")
            try DocKit.write(out, to: dest)
            saved = dest
            Toast.show("Saved \(dest.lastPathComponent)")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PageGridView: View {
    let mode: PageGridModel.Mode
    @Bindable private var model: PageGridModel

    init(mode: PageGridModel.Mode) {
        self.mode = mode
        self.model = PageGridModel.model(mode)
    }

    private var toolID: String { mode == .organize ? "organize" : mode == .delete ? "deletepages" : "extractpages" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.doc == nil {
                PDFDropPlaceholder(title: "Open a PDF", detail: detail) { model.open($0) }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 18) {
                        ForEach(Array(model.pages.enumerated()), id: \.element.id) { position, item in
                            pageCell(item, position: position)
                        }
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            }
            if let saved = model.saved { SavedFileBar(url: saved) }
        }
        .onDrop(of: FileDrop.types, isTargeted: nil) { providers in
            FileDrop.load(providers) { if let pdf = $0.first(where: { $0.pathExtension.lowercased() == "pdf" }) { model.open(pdf) } }
            return true
        }
        .onDeleteCommand { if mode == .organize { model.removeSelected() } }
        .receivesFiles(for: toolID) { if let url = $0.first { model.open(url) } }
    }

    private var detail: String {
        switch mode {
        case .organize: "Drag pages to reorder them, rotate or remove pages, then save."
        case .delete: "Click the pages you don't need, then save without them."
        case .extract: "Click the pages you want to keep, then save them as a new PDF."
        }
    }

    private var toolbar: some View {
        ToolbarRow {
            Button { if let url = FilePicker.choose(types: [.pdf], multiple: false).first { model.open(url) } } label: { Label("Open", systemImage: "doc") }
            if model.doc != nil {
                Button { model.close() } label: { Label("Close", systemImage: "xmark") }
                Text(model.url?.lastPathComponent ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } trailing: {
            if model.doc != nil {
                Button("Select All") { model.selection = Set(model.pages.map(\.id)) }
                Button("Select None") { model.selection = [] }.disabled(model.selection.isEmpty)
                if mode == .organize {
                    Button { model.rotate(-90) } label: { Image(systemName: "rotate.left") }.help("Rotate selected pages left").disabled(model.selection.isEmpty)
                    Button { model.rotate(90) } label: { Image(systemName: "rotate.right") }.help("Rotate selected pages right").disabled(model.selection.isEmpty)
                    Button { model.removeSelected() } label: { Image(systemName: "trash") }.help("Remove selected pages (Delete)").disabled(model.selection.isEmpty)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
                Button(actionTitle) { model.save(mode) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
                    .disabled(mode != .organize && model.selection.isEmpty)
            }
        }
    }

    private var actionTitle: String {
        let n = model.selection.count
        switch mode {
        case .organize: return "Save PDF"
        case .delete: return n == 0 ? "Delete Pages" : "Delete \(n) Page\(n == 1 ? "" : "s")"
        case .extract: return n == 0 ? "Extract Pages" : "Extract \(n) Page\(n == 1 ? "" : "s")"
        }
    }

    private func pageCell(_ item: PageGridModel.PageItem, position: Int) -> some View {
        let selected = model.selection.contains(item.id)
        let tint: Color = mode == .delete ? .red : .accentColor
        return VStack(spacing: 6) {
            ZStack {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(item.rotation)))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .opacity(mode == .delete && selected ? 0.35 : 1)
                }
                if mode == .delete && selected {
                    Image(systemName: "trash.circle.fill").font(.system(size: 34)).foregroundStyle(.white, .red)
                }
            }
            .frame(height: 170)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? tint : .clear, lineWidth: 3))
            Text("\(item.index + 1)").font(.caption.monospacedDigit()).foregroundStyle(selected ? tint : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if selected { model.selection.remove(item.id) } else { model.selection.insert(item.id) } }
        .draggable(item.id.uuidString) { Image(nsImage: item.thumbnail ?? NSImage()).resizable().frame(width: 60, height: 80) }
        .dropDestination(for: String.self) { ids, _ in
            guard mode == .organize, let s = ids.first, let id = UUID(uuidString: s) else { return false }
            withAnimation(.snappy) { model.move(id, before: item.id) }
            return true
        }
        .accessibilityLabel("Page \(item.index + 1)\(selected ? ", selected" : "")")
    }
}

/// Empty state for single-PDF tools.
struct PDFDropPlaceholder: View {
    let title: String
    let detail: String
    let open: (URL) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose PDF…") { if let url = FilePicker.choose(types: [.pdf], multiple: false).first { open(url) } }.controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Saved <file> · Open · Show in Finder", draggable.
struct SavedFileBar: View {
    let url: URL
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Thumbnail(url: url, size: 22)
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Drag this row anywhere").font(.caption).foregroundStyle(.secondary)
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { url.reveal() }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
            .draggableFile(url)
        }
    }
}

// MARK: - Scan Document

enum ScanFilter: String, CaseIterable, Identifiable {
    case color = "Color", grayscale = "Grayscale", blackWhite = "Black & White", original = "Original"
    var id: String { rawValue }
}

enum ScanKit {
    /// Finds the paper in a photo, straightens it and cleans it up.
    static func process(_ image: CGImage, filter: ScanFilter, findEdges: Bool) throws -> CGImage {
        var ci = CIImage(cgImage: image)
        if findEdges, let quad = try detect(image) {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            func p(_ n: CGPoint) -> CIVector { CIVector(x: n.x * w, y: n.y * h) }
            let f = CIFilter.perspectiveCorrection()
            f.inputImage = ci
            f.topLeft = p(quad.topLeft).cgPointValue
            f.topRight = p(quad.topRight).cgPointValue
            f.bottomLeft = p(quad.bottomLeft).cgPointValue
            f.bottomRight = p(quad.bottomRight).cgPointValue
            if let out = f.outputImage { ci = out }
        }
        switch filter {
        case .original: break
        case .color:
            let e = CIFilter.documentEnhancer(); e.inputImage = ci; e.amount = 1
            ci = e.outputImage ?? ci
        case .grayscale:
            let e = CIFilter.documentEnhancer(); e.inputImage = ci; e.amount = 1
            ci = (e.outputImage ?? ci).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .blackWhite:
            let e = CIFilter.documentEnhancer(); e.inputImage = ci; e.amount = 1.5
            ci = (e.outputImage ?? ci).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.9, kCIInputBrightnessKey: 0.08])
        }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        return try ImageKit.cgImage(ci)
    }

    /// The document's corners, normalized (origin bottom-left), if one is found.
    static func detect(_ image: CGImage) throws -> VNRectangleObservation? {
        let doc = VNDetectDocumentSegmentationRequest()
        try VNImageRequestHandler(cgImage: image).performRetrying([doc])
        if let r = doc.results?.first, r.confidence > 0.6, r.boundingBox.width * r.boundingBox.height > 0.15 { return r }
        let rect = VNDetectRectanglesRequest()
        rect.minimumSize = 0.3
        rect.minimumConfidence = 0.6
        rect.maximumObservations = 1
        try VNImageRequestHandler(cgImage: image).performRetrying([rect])
        return rect.results?.first
    }
}

/// A button that offers "Take Photo / Scan Documents" from a nearby iPhone (Continuity Camera).
struct ContinuityCameraButton: NSViewRepresentable {
    let onImages: ([NSImage]) -> Void

    func makeNSView(context: Context) -> ContinuityImportButton {
        let b = ContinuityImportButton(title: "Scan with iPhone…", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.onImages = onImages
        b.target = b
        b.action = #selector(ContinuityImportButton.showMenu)
        return b
    }

    func updateNSView(_ view: ContinuityImportButton, context: Context) { view.onImages = onImages }
}

final class ContinuityImportButton: NSButton, NSServicesMenuRequestor {
    var onImages: ([NSImage]) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    @objc func showMenu() {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) || returnType == .pdf { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            onImages(images)
            return true
        }
        if let data = pasteboard.data(forType: .pdf), let doc = PDFDocument(data: data) {
            onImages((0..<doc.pageCount).compactMap { doc.page(at: $0)?.thumbnail(of: NSSize(width: 2400, height: 3200), for: .mediaBox) })
            return true
        }
        return false
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}

struct ScanDocumentView: View {
    @AppStorage("scan.filter") private var filter: ScanFilter = .color
    @AppStorage("scan.edges") private var findEdges = true
    @AppStorage("scan.paper") private var paper = "fit"
    @AppStorage("scan.ocr") private var ocr = true
    @State private var name = "Scan"

    var body: some View {
        CombineToolView(toolID: "scan", types: [.image], noun: "Page", verb: "Make PDF from") {
            Section {
                ContinuityCameraButton { images in
                    let urls = images.compactMap { image -> URL? in
                        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let data = try? ImageKit.encode(cg, format: .jpeg, quality: 0.92) else { return nil }
                        let url = Output.unique(FileDrop.inbox.appendingPathComponent("iPhone Scan").appendingPathExtension("jpg"))
                        return (try? data.write(to: url)) == nil ? nil : url
                    }
                    AppModel.shared.batch("scan").add(urls, types: [.image])
                }
                Text("Or drop photos of paper. Pages are found, straightened and cleaned up.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("File name", text: $name)
                Picker("Look", selection: $filter) { ForEach(ScanFilter.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Find and straighten the page", isOn: $findEdges)
                Picker("Page size", selection: $paper) { Text("Fit each page").tag("fit"); Text("A4").tag("a4"); Text("US Letter").tag("letter") }
                Toggle("Make text searchable", isOn: $ocr)
            }
        } preview: { url in
            RenderedPreview(url: url, key: "\(filter)\(findEdges)", maxPixel: 1200) { [filter, findEdges] image in
                try ScanKit.process(image, filter: filter, findEdges: findEdges)
            }
        } combine: { [filter, findEdges, paper, ocr, name] urls in
            let images = try await offMain { try urls.map { try ScanKit.process(ImageKit.load($0, maxPixel: 3000), filter: filter, findEdges: findEdges) } }
            let size: CGSize? = paper == "a4" ? DocKit.Paper.a4.size : paper == "letter" ? DocKit.Paper.letter.size : nil
            let data = try await offMain { try DocKit.pdf(fromImages: images, pageSize: size, margin: 0, ocr: ocr, jpegQuality: 0.8, imageDPI: 250) }
            let out = Output.file(name: name.isEmpty ? "Scan" : name, ext: "pdf")
            try data.write(to: out)
            return out
        }
    }
}

// MARK: - Redact PDF

@MainActor @Observable
final class RedactPDFModel {
    static let shared = RedactPDFModel()
    /// Pages are edited as images at this resolution; boxes are stored in these pixels.
    static let editDPI: CGFloat = 144

    var url: URL?
    var doc: PDFDocument?
    var page = 0
    var pages: [Int: MarkupDocument] = [:]
    var saved: URL?
    var error: String?
    var busy: String?

    var total: Int { pages.values.reduce(0) { $0 + $1.items.count } }
    var current: MarkupDocument? { pages[page] }

    func open(_ url: URL) {
        do {
            doc = try DocKit.open(url)
            self.url = url
            pages = [:]
            saved = nil
            error = nil
            show(0)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func close() { url = nil; doc = nil; pages = [:]; saved = nil }

    /// The editable image of a page, made on first use.
    func pageDoc(_ index: Int) -> MarkupDocument? {
        if let d = pages[index] { return d }
        guard let doc, let page = doc.page(at: index), let image = try? DocKit.render(page, dpi: Self.editDPI) else { return nil }
        let d = MarkupDocument(toolID: "redactpdf-page", suffix: "", tools: [.select, .redact])
        d.redactStyle = .black
        d.set(image, name: "Page \(index + 1)", source: nil)
        pages[index] = d
        return d
    }

    func show(_ index: Int) {
        page = index
        _ = pageDoc(index)
    }

    /// Covers matches on every page, using text recognition on the page image so boxes match what you see.
    func find(_ what: RedactFind, custom: String? = nil) {
        guard let doc else { return }
        busy = "Searching…"
        Task {
            var found = 0
            for i in 0..<doc.pageCount {
                guard let d = pageDoc(i), let image = d.image else { continue }
                let rects = (try? await offMain { try RedactFinder.find(what, custom: custom, in: image) }) ?? []
                d.add(rects.map { Markup(kind: .redact(.black), start: $0.origin, end: CGPoint(x: $0.maxX, y: $0.maxY)) })
                found += rects.count
            }
            busy = nil
            Toast.show(found == 0 ? "Nothing found" : "Covered \(found) match\(found == 1 ? "" : "es")",
                       symbol: found == 0 ? "magnifyingglass" : "checkmark.circle.fill")
        }
    }

    /// Pages are flattened to images with the boxes burned in, so the hidden text is truly gone,
    /// then a fresh text layer is added so the rest stays searchable.
    func save() {
        guard let doc, let url else { return }
        busy = "Redacting…"
        let boxes = pages.mapValues { $0.items.map(\.rect) }
        Task {
            do {
                var images: [CGImage] = []
                let scale = 200 / Self.editDPI
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let image = try DocKit.render(page, dpi: 200)
                    let rects = boxes[i] ?? []
                    if rects.isEmpty { images.append(image); continue }
                    let ctx = try ImageKit.context(width: image.width, height: image.height)
                    let h = CGFloat(image.height)
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                    for r in rects {
                        ctx.fill(CGRect(x: r.minX * scale, y: h - r.maxY * scale, width: r.width * scale, height: r.height * scale))
                    }
                    images.append(ctx.makeImage()!)
                }
                let pagesToWrite = images
                let data = try await offMain { try DocKit.pdf(fromImages: pagesToWrite, pageSize: nil, margin: 0, ocr: true, jpegQuality: 0.9, imageDPI: 200) }
                let out = Output.file(name: url.baseName + " redacted", ext: "pdf")
                try data.write(to: out)
                saved = out
                Toast.show("Saved \(out.lastPathComponent)")
            } catch {
                self.error = error.localizedDescription
            }
            busy = nil
        }
    }
}

struct RedactPDFView: View {
    @Bindable private var model = RedactPDFModel.shared
    @State private var showCustom = false
    @State private var custom = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let doc = model.doc {
                HStack(spacing: 0) {
                    List(0..<doc.pageCount, id: \.self, selection: Binding(get: { model.page }, set: { if let p = $0 { model.show(p) } })) { i in
                        HStack {
                            if let thumb = doc.page(at: i)?.thumbnail(of: NSSize(width: 90, height: 120), for: .mediaBox) {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).frame(height: 70)
                            }
                            VStack(alignment: .leading) {
                                Text("Page \(i + 1)")
                                if let n = model.pages[i]?.items.count, n > 0 { Text("\(n) hidden").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        .tag(i)
                    }
                    .frame(width: 170)
                    Divider()
                    if let page = model.current {
                        MarkupCanvas(doc: page).id(model.page)
                    }
                }
            } else {
                PDFDropPlaceholder(title: "Redact a PDF", detail: "Drag over anything to black it out, or find emails, phone numbers and other text automatically. Redacted text is removed, not just covered.") { model.open($0) }
            }
            if let saved = model.saved { SavedFileBar(url: saved) }
        }
        .onDrop(of: FileDrop.types, isTargeted: nil) { providers in
            FileDrop.load(providers) { if let pdf = $0.first(where: { $0.pathExtension.lowercased() == "pdf" }) { model.open(pdf) } }
            return true
        }
        .receivesFiles(for: "redactpdf") { if let url = $0.first { model.open(url) } }
    }

    private var toolbar: some View {
        ToolbarRow {
            Button { if let url = FilePicker.choose(types: [.pdf], multiple: false).first { model.open(url) } } label: { Label("Open", systemImage: "doc") }
            if model.doc != nil {
                Button { model.close() } label: { Image(systemName: "xmark") }.help("Close this PDF")
                Menu {
                    ForEach(RedactFind.allCases.filter { $0 != .faces }) { f in Button(f.rawValue) { model.find(f) } }
                    Divider()
                    Button("Specific Words…") { showCustom = true }
                } label: { Label("Find", systemImage: "text.viewfinder") }
                .fixedSize()
                .help("Cover emails, phone numbers, long numbers or any words on every page")
                .popover(isPresented: $showCustom) {
                    HStack {
                        TextField("Word or phrase", text: $custom).frame(width: 220).onSubmit { model.find(.allText, custom: custom); showCustom = false }
                        Button("Cover") { model.find(.allText, custom: custom); showCustom = false }.keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
            }
            if let busy = model.busy { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).lineLimit(1) }
        } trailing: {
            if let page = model.current {
                Button { page.undo() } label: { Image(systemName: "arrow.uturn.backward") }.keyboardShortcut("z").disabled(!page.canUndo).help("Undo (⌘Z)")
                Button { page.redo() } label: { Image(systemName: "arrow.uturn.forward") }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!page.canRedo).help("Redo")
                Button { page.deleteSelected() } label: { Image(systemName: "trash") }.disabled(page.selection == nil).help("Remove the selected box (Delete)")
                Button { page.clear() } label: { Image(systemName: "eraser") }.disabled(page.items.isEmpty).help("Clear this page")
                Button("Save Redacted (\(model.total))") { model.save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s").disabled(model.total == 0 || model.busy != nil)
            }
        }
    }
}

// MARK: - Fill & Flatten, Sign: a PDFView that can place things

final class PlacingPDFView: PDFView {
    /// Called with the page and the click point in page space when placing is on.
    var onPlace: ((PDFPage, CGPoint) -> Void)?
    var onSelect: ((SignatureAnnotation?) -> Void)?
    var placing = false
    private var dragged: (PDFAnnotation, CGPoint)?
    private var resizing: (PDFAnnotation, CGRect)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: false) else { return super.mouseDown(with: event) }
        let point = convert(p, to: page)
        // The bottom-right corner of a selected signature resizes it.
        if let sel = SignatureAnnotation.selected, sel.page == page {
            let corner = CGPoint(x: sel.bounds.maxX, y: sel.bounds.minY)
            if hypot(point.x - corner.x, point.y - corner.y) < 10 / scaleFactor {
                resizing = (sel, sel.bounds)
                return
            }
        }
        if let ann = page.annotation(at: point) as? SignatureAnnotation {
            dragged = (ann, CGPoint(x: point.x - ann.bounds.minX, y: point.y - ann.bounds.minY))
            SignatureAnnotation.selected = ann
            onSelect?(ann)
            setNeedsDisplay(bounds)
            return
        }
        if SignatureAnnotation.selected != nil {
            SignatureAnnotation.selected = nil
            onSelect?(nil)
            setNeedsDisplay(bounds)
        }
        if placing, let onPlace {
            onPlace(page, point)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let (ann, start) = resizing, let page = ann.page {
            // Keep the top-left corner and the signature's proportions.
            let p = convert(convert(event.locationInWindow, from: nil), to: page)
            let width = max(30, p.x - start.minX)
            let height = width * start.height / start.width
            ann.bounds = CGRect(x: start.minX, y: start.maxY - height, width: width, height: height)
            setNeedsDisplay(bounds)
            return
        }
        guard let (ann, offset) = dragged, let page = ann.page else { return super.mouseDragged(with: event) }
        let p = convert(convert(event.locationInWindow, from: nil), to: page)
        ann.bounds.origin = CGPoint(x: p.x - offset.x, y: p.y - offset.y)
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        if resizing != nil { resizing = nil; onSelect?(SignatureAnnotation.selected); return }
        if dragged != nil { dragged = nil; return }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, let sel = SignatureAnnotation.selected, let page = sel.page {   // Delete
            page.removeAnnotation(sel)
            SignatureAnnotation.selected = nil
            onSelect?(nil)
            return
        }
        super.keyDown(with: event)
    }
}

struct PDFPlacingView: NSViewRepresentable {
    let document: PDFDocument
    var placing: Bool
    var onPlace: (PDFPage, CGPoint) -> Void
    var onSelect: (SignatureAnnotation?) -> Void = { _ in }
    var refresh = 0

    func makeNSView(context: Context) -> PlacingPDFView {
        let v = PlacingPDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .underPageBackgroundColor
        v.document = document
        return v
    }

    func updateNSView(_ v: PlacingPDFView, context: Context) {
        if v.document !== document { v.document = document }
        v.placing = placing
        v.onPlace = onPlace
        v.onSelect = onSelect
        v.setNeedsDisplay(v.bounds)
    }
}

/// An image stamped onto a page that draws itself, so flattening keeps it.
final class SignatureAnnotation: PDFAnnotation {
    nonisolated(unsafe) static weak var selected: SignatureAnnotation?
    var image: CGImage?
    var vector: SignatureVector?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        if let vector { vector.draw(in: bounds, ctx: context) } else if let image { context.draw(image, in: bounds) }
        if SignatureAnnotation.selected === self {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.stroke(bounds.insetBy(dx: -2, dy: -2))
            // Resize handle, bottom-right.
            context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(NSColor.white.cgColor)
            let h = CGRect(x: bounds.maxX - 5, y: bounds.minY - 5, width: 10, height: 10)
            context.fillEllipse(in: h)
            context.strokeEllipse(in: h)
        }
        context.restoreGState()
    }
}

@MainActor @Observable
final class FormFillModel {
    static let shared = FormFillModel()
    var url: URL?
    var doc: PDFDocument?
    var addingText = false
    var saved: URL?
    var error: String?

    var fieldCount: Int {
        guard let doc else { return 0 }
        return (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.filter { $0.type == "Widget" }.count ?? 0) }
    }

    func open(_ url: URL) {
        do { doc = try DocKit.open(url); self.url = url; saved = nil; error = nil } catch { self.error = error.localizedDescription }
    }

    func addField(on page: PDFPage, at p: CGPoint) {
        let field = PDFAnnotation(bounds: CGRect(x: p.x, y: p.y - 9, width: 220, height: 20), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.font = .systemFont(ofSize: 12)
        field.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15)
        field.fieldName = "Added \(UUID().uuidString.prefix(6))"
        page.addAnnotation(field)
        addingText = false
    }

    func save(flatten: Bool) {
        guard let doc, let url else { return }
        do {
            let out = Output.file(name: url.baseName + (flatten ? " flattened" : " filled"), ext: "pdf")
            if flatten { try DocKit.flatten(doc).write(to: out) } else { try DocKit.write(doc, to: out) }
            saved = out
            Toast.show("Saved \(out.lastPathComponent)")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FillFormsView: View {
    @Bindable private var model = FormFillModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolbarRow {
                Button { if let url = FilePicker.choose(types: [.pdf], multiple: false).first { model.open(url) } } label: { Label("Open", systemImage: "doc") }
                if model.doc != nil {
                    Button { model.doc = nil; model.url = nil; model.saved = nil } label: { Label("Close", systemImage: "xmark") }
                    Toggle(isOn: $model.addingText) { Label("Add Text", systemImage: "character.textbox") }
                        .toggleStyle(.button)
                        .help("Click anywhere on a page to add a text box, even where the form has no field")
                    Text(model.fieldCount == 0 ? "No form fields — use Add Text" : "\(model.fieldCount) fields · click a field to type")
                        .foregroundStyle(.secondary).font(.callout)
                }
            } trailing: {
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).lineLimit(2).frame(maxWidth: 240).help(error) }
                if model.doc != nil {
                    Button("Save") { model.save(flatten: false) }.help("Answers stay editable")
                    Button("Save Flattened") { model.save(flatten: true) }
                        .buttonStyle(.borderedProminent).keyboardShortcut("s")
                        .help("Answers become part of the page, so they print and can't be changed")
                }
            }
            Divider()
            if let doc = model.doc {
                PDFPlacingView(document: doc, placing: model.addingText) { page, p in model.addField(on: page, at: p) }
            } else {
                PDFDropPlaceholder(title: "Fill a PDF Form", detail: "Type into form fields, add text anywhere, then flatten so the answers can't be changed.") { model.open($0) }
            }
            if let saved = model.saved { SavedFileBar(url: saved) }
        }
        .onDrop(of: FileDrop.types, isTargeted: nil) { providers in
            FileDrop.load(providers) { if let pdf = $0.first(where: { $0.pathExtension.lowercased() == "pdf" }) { model.open(pdf) } }
            return true
        }
        .receivesFiles(for: "fillforms") { if let url = $0.first { model.open(url) } }
    }
}

// MARK: - Sign PDF

/// A signature kept as vectors (strokes or typed text), so it's sharp at any size and zoom.
struct SignatureVector: Codable {
    var strokes: [[CGPoint]]?   // normalized 0…1, y down
    var text: String?
    var font: String?
    var color: [CGFloat]        // r, g, b
    var aspect: CGFloat         // width / height
    var relativeWidth: CGFloat = 0.03   // stroke width as a fraction of the height

    var cgColor: CGColor { CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 1) }

    /// Draws into `rect` in PDF space (y up).
    func draw(in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        if let strokes {
            ctx.setStrokeColor(cgColor)
            ctx.setLineWidth(max(0.6, rect.height * relativeWidth))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in strokes where stroke.count > 1 {
                let pts = stroke.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.maxY - $0.y * rect.height) }
                ctx.move(to: pts[0])
                for i in 1..<pts.count {
                    let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                    ctx.addQuadCurve(to: mid, control: pts[i - 1])
                }
                ctx.addLine(to: pts.last!)
                ctx.strokePath()
            }
        } else if let text {
            let base = NSFont(name: font ?? "", size: 100) ?? .systemFont(ofSize: 100)
            let probe = NSAttributedString(string: text, attributes: [.font: base]).size()
            let size = 100 * min(rect.width / max(probe.width, 1), rect.height / max(probe.height, 1))
            let a = NSAttributedString(string: text, attributes: [.font: base.withSize(size),
                                                                  .foregroundColor: NSColor(cgColor: cgColor) ?? .black])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let s = a.size()
            a.draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }

    static func from(strokes: [[CGPoint]], color: CGColor) -> SignatureVector? {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return nil }
        let pad: CGFloat = 4
        let w = max(1, maxX - minX + pad * 2), h = max(1, maxY - minY + pad * 2)
        let c = color.components ?? [0, 0, 0]
        return SignatureVector(strokes: strokes.map { $0.map { CGPoint(x: ($0.x - minX + pad) / w, y: ($0.y - minY + pad) / h) } },
                               color: [c[0], c.count > 2 ? c[1] : c[0], c.count > 2 ? c[2] : c[0]], aspect: w / h, relativeWidth: 3 / h)
    }
}

enum SignatureStore {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyToolbox/Signatures")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func all() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func save(_ image: CGImage, vector: SignatureVector? = nil) throws -> URL {
        let url = folder.appendingPathComponent("signature-\(Int(Date().timeIntervalSince1970)).png")
        try ImageKit.save(ImageJobs.trimTransparent(image), to: url, format: .png)
        if let vector { try JSONEncoder().encode(vector).write(to: url.deletingPathExtension().appendingPathExtension("json")) }
        return url
    }

    static func vector(for png: URL) -> SignatureVector? {
        (try? Data(contentsOf: png.deletingPathExtension().appendingPathExtension("json"))).flatMap { try? JSONDecoder().decode(SignatureVector.self, from: $0) }
    }

    /// Renders strokes (points in a 600×200 canvas, y down) as a transparent PNG.
    static func render(strokes: [[CGPoint]], color: CGColor) throws -> CGImage {
        let ctx = try ImageKit.context(width: 1200, height: 400)
        ctx.translateBy(x: 0, y: 400)
        ctx.scaleBy(x: 2, y: -2)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where stroke.count > 1 {
            ctx.move(to: stroke[0])
            for i in 1..<stroke.count {
                let mid = CGPoint(x: (stroke[i - 1].x + stroke[i].x) / 2, y: (stroke[i - 1].y + stroke[i].y) / 2)
                ctx.addQuadCurve(to: mid, control: stroke[i - 1])
            }
            ctx.addLine(to: stroke.last!)
            ctx.strokePath()
        }
        return ctx.makeImage()!
    }

    static func render(typed text: String, font: String, color: CGColor) throws -> CGImage {
        let f = NSFont(name: font, size: 120) ?? .systemFont(ofSize: 120)
        let a = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor(cgColor: color) ?? .black])
        let size = a.size()
        let ctx = try ImageKit.context(width: Int(size.width) + 40, height: Int(size.height) + 40)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        a.draw(at: CGPoint(x: 20, y: 20))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static let scriptFonts = ["Snell Roundhand", "Zapfino", "Bradley Hand", "Savoye LET", "Apple Chancery", "Noteworthy"]
        .filter { NSFont(name: $0, size: 12) != nil }
}

@MainActor @Observable
final class SignModel {
    static let shared = SignModel()
    var url: URL?
    var doc: PDFDocument?
    var signatures: [URL] = SignatureStore.all()
    var armed: URL?
    var width: CGFloat = 160 {
        didSet {
            // The size slider also resizes the signature you selected on the page.
            guard let sel = SignatureAnnotation.selected, abs(sel.bounds.width - width) > 0.5 else { return }
            let h = width * sel.bounds.height / sel.bounds.width
            sel.bounds = CGRect(x: sel.bounds.midX - width / 2, y: sel.bounds.midY - h / 2, width: width, height: h)
            refresh += 1
        }
    }
    var refresh = 0
    var hasSelection = false
    var saved: URL?
    var error: String?
    var creating = false

    func open(_ url: URL) {
        do { doc = try DocKit.open(url); self.url = url; saved = nil; error = nil } catch { self.error = error.localizedDescription }
    }

    func place(on page: PDFPage, at p: CGPoint) {
        guard let signature = armed, let image = try? ImageKit.load(signature) else { return }
        let vector = SignatureStore.vector(for: signature)
        let aspect = vector?.aspect ?? CGFloat(image.width) / CGFloat(image.height)
        let h = width / aspect
        let ann = SignatureAnnotation(bounds: CGRect(x: p.x - width / 2, y: p.y - h / 2, width: width, height: h), forType: .stamp, withProperties: nil)
        ann.image = image
        ann.vector = vector
        page.addAnnotation(ann)
        SignatureAnnotation.selected = ann
        hasSelection = true
        armed = nil   // placed — now it can be moved and resized; pick the signature again to place another
    }

    func save() {
        guard let doc, let url else { return }
        SignatureAnnotation.selected = nil
        do {
            let out = Output.file(name: url.baseName + " signed", ext: "pdf")
            try DocKit.flatten(doc).write(to: out)
            saved = out
            Toast.show("Saved \(out.lastPathComponent)")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SignPDFView: View {
    @Bindable private var model = SignModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolbarRow {
                Button { if let url = FilePicker.choose(types: [.pdf], multiple: false).first { model.open(url) } } label: { Label("Open", systemImage: "doc") }
                if model.doc != nil { Button { model.doc = nil; model.url = nil; model.saved = nil } label: { Label("Close", systemImage: "xmark") } }
                Divider().frame(height: 18)
                ForEach(model.signatures, id: \.self) { sig in
                    Button { model.armed = model.armed == sig ? nil : sig } label: {
                        Image(nsImage: NSImage(contentsOf: sig) ?? NSImage()).resizable().aspectRatio(contentMode: .fit).frame(width: 80, height: 26)
                            .padding(3)
                            .background(model.armed == sig ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Click, then click on the page to place it")
                    .contextMenu { Button("Delete Signature") {
                        try? FileManager.default.removeItem(at: sig)
                        try? FileManager.default.removeItem(at: sig.deletingPathExtension().appendingPathExtension("json"))
                        model.signatures = SignatureStore.all()
                    } }
                }
                Button { model.creating = true } label: { Label("New Signature", systemImage: "plus") }
                if model.armed != nil || model.hasSelection {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: $model.width, in: 40...400).frame(width: 110).help("Signature size — changes the selected signature too")
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                }
            } trailing: {
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).lineLimit(2).frame(maxWidth: 240).help(error) }
                if model.doc != nil {
                    Button("Save Signed PDF") { model.save() }.buttonStyle(.borderedProminent).keyboardShortcut("s")
                }
            }
            Divider()
            if let doc = model.doc {
                PDFPlacingView(document: doc, placing: model.armed != nil, onPlace: { page, p in model.place(on: page, at: p) },
                               onSelect: { sel in
                                   model.hasSelection = sel != nil
                                   if let sel { model.width = sel.bounds.width }
                               }, refresh: model.refresh)
                    .overlay(alignment: .bottom) {
                        Text(model.armed != nil ? "Click on the page to place the signature"
                             : model.hasSelection ? "Drag to move · drag the corner dot or use the slider to resize · Delete removes it"
                             : "Pick a signature above, then click on the page · click a placed signature to move or resize it")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule()).padding(8)
                    }
            } else {
                PDFDropPlaceholder(title: "Sign a PDF", detail: "Draw or type your signature once, then place it on any document.") { model.open($0) }
            }
            if let saved = model.saved { SavedFileBar(url: saved) }
        }
        .sheet(isPresented: $model.creating) {
            SignatureCreator { image, vector in
                if let url = try? SignatureStore.save(image, vector: vector) { model.signatures = SignatureStore.all(); model.armed = url }
            }
        }
        .onDrop(of: FileDrop.types, isTargeted: nil) { providers in
            FileDrop.load(providers) { if let pdf = $0.first(where: { $0.pathExtension.lowercased() == "pdf" }) { model.open(pdf) } }
            return true
        }
        .receivesFiles(for: "signpdf") { if let url = $0.first { model.open(url) } }
    }
}

struct SignatureCreator: View {
    let onSave: (CGImage, SignatureVector?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = false
    @State private var strokes: [[CGPoint]] = []
    @State private var text = NSFullUserName()
    @State private var font = SignatureStore.scriptFonts.first ?? "Snell Roundhand"
    @State private var blue = false

    private var color: CGColor { blue ? CGColor(srgbRed: 0.05, green: 0.2, blue: 0.65, alpha: 1) : CGColor(gray: 0.05, alpha: 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Signature").font(.title3.weight(.semibold))
            Picker("", selection: $typed) { Text("Draw").tag(false); Text("Type").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.white)
                if typed {
                    Text(text).font(.custom(font, size: 54)).foregroundStyle(Color(cgColor: color)).lineLimit(1).minimumScaleFactor(0.3).padding()
                } else {
                    Canvas { ctx, _ in
                        for s in strokes where s.count > 1 {
                            var path = Path()
                            path.addLines(s)
                            ctx.stroke(path, with: .color(Color(cgColor: color)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if v.translation == .zero || strokes.isEmpty || v.startLocation != (strokes.last?.first ?? .zero) { strokes.append([v.startLocation]) }
                            strokes[strokes.count - 1].append(v.location)
                        })
                    if strokes.isEmpty { Text("Sign here with your trackpad or mouse").foregroundStyle(.gray) }
                }
                Rectangle().fill(.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 30).offset(y: 50)
            }
            .frame(width: 600, height: 200)
            if typed {
                HStack {
                    TextField("Your name", text: $text).textFieldStyle(.roundedBorder)
                    Picker("Style", selection: $font) { ForEach(SignatureStore.scriptFonts, id: \.self) { Text($0).font(.custom($0, size: 14)).tag($0) } }.frame(width: 200)
                }
            }
            HStack {
                Toggle("Blue ink", isOn: $blue)
                if !typed { Button("Clear") { strokes = [] }.disabled(strokes.isEmpty) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Signature") {
                    if let image = try? (typed ? SignatureStore.render(typed: text, font: font, color: color) : SignatureStore.render(strokes: strokes, color: color)) {
                        let c = color.components ?? [0, 0, 0]
                        let rgb = [c[0], c.count > 2 ? c[1] : c[0], c.count > 2 ? c[2] : c[0]]
                        let vector = typed
                            ? SignatureVector(text: text, font: font, color: rgb, aspect: CGFloat(image.width) / CGFloat(image.height))
                            : SignatureVector.from(strokes: strokes, color: color)
                        onSave(image, vector)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(typed ? text.isEmpty : strokes.isEmpty)
            }
        }
        .padding(20)
    }
}
