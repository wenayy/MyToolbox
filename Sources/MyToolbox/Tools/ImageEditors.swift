import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Geometry

/// Maps between view points and image pixels (top-left origin) for an aspect-fit image.
struct FitGeometry {
    let imageSize: CGSize
    let frame: CGRect

    init(imageSize: CGSize, in container: CGSize) {
        self.imageSize = imageSize
        let scale = min(container.width / max(imageSize.width, 1), container.height / max(imageSize.height, 1))
        let w = imageSize.width * scale, h = imageSize.height * scale
        frame = CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    var scale: CGFloat { frame.width / max(imageSize.width, 1) }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: ((p.x - frame.minX) / scale).clamped(0, imageSize.width), y: ((p.y - frame.minY) / scale).clamped(0, imageSize.height))
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * scale, y: frame.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * scale, y: frame.minY + p.y * scale) }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}

extension CGRect {
    init(_ a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

// MARK: - Model

/// One thing drawn on the image, in image pixels with a top-left origin.
struct Markup: Identifiable, Equatable {
    enum Kind: Equatable {
        case redact(ObscureStyle)
        case arrow, box, highlight
        case text(String)
        case step(Int)
    }

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: CGColor = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    /// Stroke width in image pixels; also sets text and step size.
    var width: CGFloat = 4

    var rect: CGRect { CGRect(start, end) }
    var isArrow: Bool { kind == .arrow }
    var fontSize: CGFloat { width * 5 }

    var bounds: CGRect {
        switch kind {
        case .arrow: return rect.insetBy(dx: -width * 2, dy: -width * 2)
        case .text(let s):
            let size = NSAttributedString(string: s.isEmpty ? " " : s, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold)]).size()
            return CGRect(origin: start, size: size)
        case .step: let r = width * 4.5; return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        default: return rect
        }
    }

    /// Text and steps are moved, not resized.
    var resizable: Bool {
        switch kind { case .text, .step: false; default: true }
    }

    mutating func offset(by d: CGSize) {
        start.x += d.width; start.y += d.height
        end.x += d.width; end.y += d.height
    }
}

enum MarkupHandle: Equatable {
    case start, end, topLeft, topRight, bottomLeft, bottomRight

    static func handles(for m: Markup) -> [(MarkupHandle, CGPoint)] {
        guard m.resizable else { return [] }
        if m.isArrow { return [(.start, m.start), (.end, m.end)] }
        let r = m.rect
        return [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
    }

    /// Moves this handle to `p`; the opposite corner stays put.
    func apply(_ p: CGPoint, to m: inout Markup) {
        if m.isArrow {
            if self == .start { m.start = p } else { m.end = p }
            return
        }
        let r = m.rect
        let fixed: CGPoint = switch self {
        case .topLeft: CGPoint(x: r.maxX, y: r.maxY)
        case .topRight: CGPoint(x: r.minX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.maxX, y: r.minY)
        default: CGPoint(x: r.minX, y: r.minY)
        }
        let n = CGRect(p, fixed)
        m.start = CGPoint(x: n.minX, y: n.minY)
        m.end = CGPoint(x: n.maxX, y: n.maxY)
    }
}

/// Pre-rendered blurred and pixelated copies of the whole image, so redaction boxes are just clipped
/// draws: instant while dragging, and the preview matches the saved file exactly.
struct ObscureLayers: @unchecked Sendable {
    let blurred: CGImage
    let pixelated: CGImage

    static func make(_ image: CGImage, strength: Double) throws -> ObscureLayers {
        let ci = CIImage(cgImage: image)
        let side = Double(max(image.width, image.height))
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: side * (0.006 + 0.022 * strength)).cropped(to: ci.extent)
        let pix = CIFilter.pixellate()
        pix.inputImage = ci.clampedToExtent()
        pix.center = .zero
        pix.scale = Float(max(4, side * (0.008 + 0.024 * strength)))
        let pixelated = (pix.outputImage ?? ci).cropped(to: ci.extent)
        return ObscureLayers(blurred: try ImageKit.cgImage(blurred), pixelated: try ImageKit.cgImage(pixelated))
    }
}

enum MarkupRenderer {
    /// Draws markups into a context whose origin is top-left (y down), in image pixel units.
    /// `imageRect` is where the base image sits in those units (where effect layers are drawn).
    static func draw(_ items: [Markup], in ctx: CGContext, imageRect: CGRect, layers: ObscureLayers?) {
        for m in items {
            ctx.saveGState()
            switch m.kind {
            case .redact(let style):
                ctx.clip(to: m.rect)
                if style == .black || layers == nil {
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                    ctx.fill(m.rect)
                } else {
                    drawUpright(style == .blur ? layers!.blurred : layers!.pixelated, in: imageRect, ctx: ctx)
                }
            default:
                drawMark(m, in: ctx)
            }
            ctx.restoreGState()
        }
    }

    /// Draws a CGImage upright in a y-down context.
    static func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func drawMark(_ m: Markup, in ctx: CGContext) {
        let w = m.width
        ctx.setShouldAntialias(true)
        ctx.setLineJoin(.round)
        switch m.kind {
        case .arrow:
            let a = m.start, b = m.end
            guard hypot(b.x - a.x, b.y - a.y) > 1 else { return }
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = w * 4.5
            let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            ctx.setStrokeColor(m.color)
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            ctx.move(to: a)
            ctx.addLine(to: base)
            ctx.strokePath()
            ctx.setFillColor(m.color)
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x - cos(angle - .pi / 7) * head, y: b.y - sin(angle - .pi / 7) * head))
            ctx.addLine(to: CGPoint(x: b.x - cos(angle + .pi / 7) * head, y: b.y - sin(angle + .pi / 7) * head))
            ctx.closePath()
            ctx.fillPath()
        case .box:
            let r = m.rect
            ctx.setStrokeColor(m.color)
            ctx.setLineWidth(w)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(w * 1.5, r.width / 2), cornerHeight: min(w * 1.5, r.height / 2), transform: nil))
            ctx.strokePath()
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(m.color.copy(alpha: 0.4) ?? m.color)
            ctx.fill(m.rect)
        case .text(let s):
            withAppKit(ctx) {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = w
                NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: m.fontSize, weight: .bold),
                                                           .foregroundColor: NSColor(cgColor: m.color) ?? .red, .shadow: shadow]).draw(at: m.start)
            }
        case .step(let n):
            let r = w * 4.5
            ctx.setFillColor(m.color)
            ctx.fillEllipse(in: CGRect(x: m.start.x - r, y: m.start.y - r, width: r * 2, height: r * 2))
            withAppKit(ctx) {
                let label = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                                                                           .foregroundColor: NSColor.white])
                let size = label.size()
                label.draw(at: CGPoint(x: m.start.x - size.width / 2, y: m.start.y - size.height / 2))
            }
        case .redact:
            break
        }
    }

    private static func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The finished full-resolution image.
    static func render(_ image: CGImage, items: [Markup], strength: Double) throws -> CGImage {
        let needsLayers = items.contains { if case .redact(let s) = $0.kind { s != .black } else { false } }
        let layers = needsLayers ? try ObscureLayers.make(image, strength: strength) : nil
        let w = image.width, h = image.height
        let ctx = try ImageKit.context(width: w, height: h)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        drawUpright(image, in: rect, ctx: ctx)
        draw(items, in: ctx, imageRect: rect, layers: layers)
        return ctx.makeImage()!
    }
}

/// What Find can cover automatically in Redact.
enum RedactFind: String, CaseIterable, Identifiable {
    case allText = "All Text", emails = "Email Addresses", phones = "Phone Numbers",
         numbers = "Long Numbers (cards, accounts, IDs)", faces = "Faces"
    var id: String { rawValue }
}

enum RedactFinder {
    /// Rects (image px, top-left origin) covering just the matching text, not whole lines.
    static func find(_ what: RedactFind, custom: String? = nil, in image: CGImage) throws -> [CGRect] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func toImage(_ n: CGRect) -> CGRect {
            let pad = max(2, n.height * h * 0.14)
            return CGRect(x: n.minX * w, y: (1 - n.maxY) * h, width: n.width * w, height: n.height * h).insetBy(dx: -pad, dy: -pad)
        }
        if what == .faces {
            return try ImageJobs.faces(in: image).map { CGRect(x: $0.minX, y: h - $0.maxY, width: $0.width, height: $0.height) }
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).performRetrying([request])
        var rects: [CGRect] = []
        for obs in request.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            if what == .allText && (custom ?? "").isEmpty { rects.append(toImage(obs.boundingBox)); continue }
            for range in matches(what, custom: custom, in: candidate.string) {
                if let box = try? candidate.boundingBox(for: range) { rects.append(toImage(box.boundingBox)) }
            }
        }
        return rects
    }

    static func matches(_ what: RedactFind, custom: String?, in text: String) -> [Range<String.Index>] {
        if let custom, !custom.isEmpty {
            var out: [Range<String.Index>] = []
            var from = text.startIndex
            while let r = text.range(of: custom, options: .caseInsensitive, range: from..<text.endIndex) { out.append(r); from = r.upperBound }
            return out
        }
        let pattern: String
        switch what {
        case .emails: pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        case .phones: pattern = #"\+?\d[\d\s().-]{7,}\d"#
        case .numbers: pattern = #"\d[\d\s•*-]{4,}\d|\d{4,}"#
        default: return []
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
}

enum EditorTool: String, CaseIterable, Identifiable {
    case select = "Select", redact = "Cover", arrow = "Arrow", box = "Box", highlight = "Highlight", text = "Text", step = "Step"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .redact: "rectangle.dashed"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .step: "1.circle"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .select: "v"
        case .redact: "c"
        case .arrow: "a"
        case .box: "r"
        case .highlight: "h"
        case .text: "t"
        case .step: "n"
        }
    }
}

@MainActor @Observable
final class MarkupDocument {
    let toolID: String
    let suffix: String
    let tools: [EditorTool]

    var image: CGImage?
    var name = "Image"
    var sourceURL: URL?
    var items: [Markup] = []
    var selection: Markup.ID?
    var tool: EditorTool
    var color: Color = .red
    var size = 1.0
    var redactStyle: ObscureStyle = .pixelate
    var strength = 0.6
    var saved: URL?
    var error: String?
    var busy = false
    var layers: ObscureLayers?
    var canUndo = false
    var canRedo = false
    var editingText = false
    @ObservationIgnored private var undoStack: [[Markup]] = []
    @ObservationIgnored private var redoStack: [[Markup]] = []

    init(toolID: String, suffix: String, tools: [EditorTool]) {
        self.toolID = toolID
        self.suffix = suffix
        self.tools = tools
        self.tool = tools.dropFirst().first ?? .select
    }

    var imageSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    var baseWidth: CGFloat { max(2, max(imageSize.width, imageSize.height) / 260 * size) }
    var nextStep: Int { (items.compactMap { if case .step(let n) = $0.kind { n } else { nil } }.max() ?? 0) + 1 }
    var cgColor: CGColor { NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? NSColor.systemRed.cgColor }

    // MARK: Image

    func open(_ url: URL) {
        do { set(try ImageKit.load(url), name: url.baseName, source: url) } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func paste() -> Bool {
        guard let ns = Pasteboard.image, let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        set(cg, name: "Pasted Image", source: nil)
        return true
    }

    func set(_ image: CGImage, name: String, source: URL?) {
        self.image = image
        self.name = name
        sourceURL = source
        resetMarks()
    }

    func close() {
        image = nil
        layers = nil
        resetMarks()
    }

    private func resetMarks() {
        items = []
        selection = nil
        saved = nil
        error = nil
        undoStack = []
        redoStack = []
        refreshUndo()
    }

    /// Display-size effect layers for the live preview.
    func rebuildLayers(maxSide: CGFloat) async {
        guard let image, tools.contains(.redact), maxSide > 1, toolID != "redactpdf-page" else { layers = nil; return }
        let strength = strength
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        layers = try? await offMain {
            let small = scale < 1 ? try ImageKit.resized(image, width: Int(CGFloat(image.width) * scale), height: Int(CGFloat(image.height) * scale)) : image
            return try ObscureLayers.make(small, strength: strength)
        }
    }

    // MARK: Editing with undo

    func checkpoint() {
        undoStack.append(items)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
        refreshUndo()
    }

    func add(_ m: Markup) {
        checkpoint()
        items.append(m)
        selection = m.id
    }

    func add(_ ms: [Markup]) {
        guard !ms.isEmpty else { return }
        checkpoint()
        items.append(contentsOf: ms)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        selection = nil
        refreshUndo()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        refreshUndo()
    }

    func deleteSelected() {
        guard let id = selection else { return }
        checkpoint()
        items.removeAll { $0.id == id }
        selection = nil
    }

    func clear() {
        guard !items.isEmpty else { return }
        checkpoint()
        items = []
        selection = nil
    }

    private func refreshUndo() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func update(_ id: Markup.ID, _ change: (inout Markup) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    // MARK: Find (Redact)

    func find(_ what: RedactFind, custom: String? = nil) {
        guard let image else { return }
        busy = true
        let style = redactStyle
        Task {
            let rects = (try? await offMain { try RedactFinder.find(what, custom: custom, in: image) }) ?? []
            add(rects.map { Markup(kind: .redact(style), start: $0.origin, end: CGPoint(x: $0.maxX, y: $0.maxY)) })
            busy = false
            Toast.show(rects.isEmpty ? "Nothing found" : "Covered \(rects.count) area\(rects.count == 1 ? "" : "s")",
                       symbol: rects.isEmpty ? "magnifyingglass" : "checkmark.circle.fill")
        }
    }

    // MARK: Output

    func rendered() throws -> CGImage? {
        guard let image else { return nil }
        return try MarkupRenderer.render(image, items: items, strength: strength)
    }

    func save() {
        do {
            guard let result = try rendered() else { return }
            let format = sourceURL.map(ImageJobs.sameFormat) ?? .png
            let out = Output.file(name: "\(name) \(suffix)", ext: format.ext)
            try ImageKit.save(result, to: out, format: format, quality: 0.92)
            saved = out
            Toast.show("Saved \(out.lastPathComponent)", symbol: "checkmark.circle.fill")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copy() {
        guard let result = try? rendered(), let data = ImageKit.pngData(result) else { return }
        Pasteboard.copy(png: data)
        Toast.show("Copied image", symbol: "doc.on.clipboard")
    }
}

// MARK: - Shared editor view

struct MarkupEditor: View {
    @Bindable var doc: MarkupDocument
    let emptyTitle: String

    @State private var customFind = ""
    @State private var showCustomFind = false

    private let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if doc.image == nil { emptyState } else { MarkupCanvas(doc: doc) }
            if let saved = doc.saved { savedBar(saved) }
        }
        .onDrop(of: FileDrop.types, isTargeted: nil) { providers in
            FileDrop.load(providers) { urls in if let url = urls.first(where: { BatchRun.matches($0, [.image]) }) { doc.open(url) } }
            return true
        }
        .onPasteCommand(of: [.image, .png, .tiff]) { _ in doc.paste() }
        .receivesFiles(for: doc.toolID) { urls in if let url = urls.first { doc.open(url) } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ToolbarRow {
            Menu {
                Button("Open Image…") { if let url = FilePicker.choose(types: [.image], multiple: false).first { doc.open(url) } }
                Button("Paste Image") { doc.paste() }.disabled(Pasteboard.image == nil)
            } label: { Label("Open", systemImage: "photo") }
            .fixedSize()
            .help("Open or paste an image. You can also drop one here.")
            if doc.image != nil {
                Button { doc.close() } label: { Image(systemName: "xmark") }
                    .help("Close this image and start over")
            }
            Divider().frame(height: 18)
            Picker("Tool", selection: $doc.tool) {
                ForEach(doc.tools) { t in Label(t.rawValue, systemImage: t.symbol).tag(t) }
            }
            .pickerStyle(.segmented).labelStyle(.iconOnly).labelsHidden().fixedSize()
            .help(doc.tools.map(\.rawValue).joined(separator: ", "))
            if doc.tools.contains(.redact) { redactControls } else { annotateControls }
        } trailing: {
            Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z").help("Undo (⌘Z)").disabled(!doc.canUndo)
            Button { doc.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo (⇧⌘Z)").disabled(!doc.canRedo)
            Button { doc.deleteSelected() } label: { Image(systemName: "trash") }
                .help("Delete the selected mark (Delete)").disabled(doc.selection == nil)
            Button { doc.clear() } label: { Image(systemName: "eraser") }.disabled(doc.items.isEmpty).help("Remove everything you drew")
            Button { doc.copy() } label: { Image(systemName: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .shift]).help("Copy the finished image (⇧⌘C)").disabled(doc.image == nil)
            Button("Save") { doc.save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
                .disabled(doc.image == nil)
        }
    }

    @ViewBuilder private var redactControls: some View {
        Picker("Style", selection: $doc.redactStyle) { ForEach(ObscureStyle.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.menu).fixedSize().labelsHidden()
            .help("How covered areas look")
            .onChange(of: doc.redactStyle) {
                if let id = doc.selection { doc.checkpoint(); doc.update(id) { $0.kind = .redact(doc.redactStyle) } }
            }
        if doc.redactStyle != .black {
            Slider(value: $doc.strength, in: 0...1).frame(width: 60).help("Blur / pixel size")
        }
        Menu {
            ForEach(RedactFind.allCases) { f in Button(f.rawValue) { doc.find(f) } }
            Divider()
            Button("Specific Words…") { showCustomFind = true }
        } label: { Label("Find", systemImage: "text.viewfinder") }
        .fixedSize()
        .disabled(doc.image == nil || doc.busy)
        .help("Cover text, emails, phone numbers, long numbers or faces automatically")
        .popover(isPresented: $showCustomFind) {
            HStack {
                TextField("Word or phrase to cover", text: $customFind).frame(width: 220)
                    .onSubmit { doc.find(.allText, custom: customFind); showCustomFind = false }
                Button("Cover") { doc.find(.allText, custom: customFind); showCustomFind = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        if doc.busy { ProgressView().controlSize(.small) }
    }

    @ViewBuilder private var annotateControls: some View {
        HStack(spacing: 4) {
            ForEach(palette, id: \.self) { c in
                Button {
                    doc.color = c
                    if let id = doc.selection { doc.checkpoint(); doc.update(id) { $0.color = doc.cgColor } }
                } label: {
                    Circle().fill(c).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(doc.color == c ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: doc.color == c ? 2.5 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.description)
            }
        }
        Picker("Size", selection: $doc.size) { Text("S").tag(0.6); Text("M").tag(1.0); Text("L").tag(1.6) }
            .pickerStyle(.segmented).fixedSize().labelsHidden()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(emptyTitle).font(.title3.weight(.semibold))
            Text("Drop an image, choose one, or paste a screenshot (⌘V).").foregroundStyle(.secondary)
            HStack {
                Button("Choose Image…") { if let url = FilePicker.choose(types: [.image], multiple: false).first { doc.open(url) } }
                Button("Paste Image") { doc.paste() }.disabled(Pasteboard.image == nil)
            }
            .controlSize(.large)
            if let error = doc.error { ErrorText(message: error) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func savedBar(_ saved: URL) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Thumbnail(url: saved, size: 22)
                Text(saved.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Drag this row anywhere").font(.caption).foregroundStyle(.secondary)
                Button("Open") { NSWorkspace.shared.open(saved) }
                Button("Show in Finder") { saved.reveal() }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
            .draggableFile(saved)
        }
    }

    // MARK: Canvas
}

/// The drawing surface shared by Redact Image, Annotate and Redact PDF: draw, select, move, resize, delete.
struct MarkupCanvas: View {
    @Bindable var doc: MarkupDocument

    private enum DragMode {
        case create(CGPoint)
        case move(Markup.ID, CGPoint, Markup)
        case resize(Markup.ID, MarkupHandle)
        /// A click or drag on empty canvas with the Select, Text or Step tool.
        case click
    }

    private struct TextEdit {
        var id: Markup.ID?
        var at: CGPoint
        var value: String
    }

    @State private var drag: DragMode?
    @State private var draft: Markup?
    @State private var textEdit: TextEdit? { didSet { doc.editingText = textEdit != nil } }
    @State private var canvasSize: CGSize = .zero
    @FocusState private var textFocused: Bool

    var body: some View {
        canvas
            .onDeleteCommand { doc.deleteSelected() }
            .onExitCommand { if textEdit != nil { textEdit = nil } else { doc.selection = nil } }
            .task(id: "\(doc.image.map { "\(ObjectIdentifier($0))" } ?? "")|\(doc.strength)|\(Int(canvasSize.width))x\(Int(canvasSize.height))") {
                await doc.rebuildLayers(maxSide: max(canvasSize.width, canvasSize.height) * 2)
            }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let area = CGSize(width: max(1, geo.size.width - 40), height: max(1, geo.size.height - 40))
            let fit = FitGeometry(imageSize: doc.imageSize, in: area)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    guard let image = doc.image else { return }
                    context.withCGContext { cg in
                        cg.translateBy(x: fit.frame.minX, y: fit.frame.minY)
                        cg.scaleBy(x: fit.scale, y: fit.scale)
                        cg.interpolationQuality = .high
                        let rect = CGRect(origin: .zero, size: doc.imageSize)
                        MarkupRenderer.drawUpright(image, in: rect, ctx: cg)
                        var items = doc.items
                        if let draft { items.append(draft) }
                        if let id = textEdit?.id { items.removeAll { $0.id == id } }
                        MarkupRenderer.draw(items, in: cg, imageRect: rect, layers: doc.layers)
                    }
                }
                .allowsHitTesting(false)
                selectionOverlay(fit)
                if let edit = textEdit {
                    let v = fit.toView(edit.at)
                    TextField("Type, then Return", text: Binding(get: { textEdit?.value ?? "" }, set: { textEdit?.value = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .focused($textFocused)
                        .offset(x: v.x, y: v.y)
                        .onSubmit(commitText)
                }
            }
            .frame(width: area.width, height: area.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(fit))
            .simultaneousGesture(TapGesture(count: 2).onEnded { editSelectedText() })
            .onContinuousHover { phase in
                switch phase {
                case .active: (doc.tool == .select ? NSCursor.arrow : NSCursor.crosshair).set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .padding(20)
            .onAppear { canvasSize = area }
            .onChange(of: area) { canvasSize = area }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            Text(hint).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule()).padding(8)
                .allowsHitTesting(false)
        }
    }

    private var hint: String {
        if doc.selection != nil { return "Drag to move · drag a corner to resize · Delete removes · Esc deselects" }
        switch doc.tool {
        case .select: return "Click a mark to select it"
        case .redact: return "Drag over anything to cover it, or use Find to cover text, emails or numbers"
        case .text: return "Click where the text should go · double-click a label to edit it"
        case .step: return "Click to place the next numbered step"
        default: return "Drag to draw · click a mark to select it"
        }
    }

    @ViewBuilder private func selectionOverlay(_ fit: FitGeometry) -> some View {
        if let id = doc.selection, let m = doc.items.first(where: { $0.id == id }) {
            let r = fit.toView(m.bounds).insetBy(dx: -3, dy: -3)
            Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
            ForEach(Array(MarkupHandle.handles(for: m).enumerated()), id: \.offset) { _, h in
                let p = fit.toView(h.1)
                Circle().fill(.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 11, height: 11)
                    .offset(x: p.x - 5.5, y: p.y - 5.5)
                    .allowsHitTesting(false)
            }
        }
    }

    private func hitItem(_ p: CGPoint, fit: FitGeometry) -> Markup? {
        let slop = 6 / fit.scale
        return doc.items.last { $0.bounds.insetBy(dx: -slop, dy: -slop).contains(p) }
    }

    private func hitHandle(_ viewPoint: CGPoint, fit: FitGeometry) -> MarkupHandle? {
        guard let id = doc.selection, let m = doc.items.first(where: { $0.id == id }) else { return nil }
        return MarkupHandle.handles(for: m).first { hypot(fit.toView($0.1).x - viewPoint.x, fit.toView($0.1).y - viewPoint.y) < 9 }?.0
    }

    private func dragGesture(_ fit: FitGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let p = fit.toImage(v.location)
                if drag == nil {
                    if textEdit != nil { commitText() }
                    let start = fit.toImage(v.startLocation)
                    if let handle = hitHandle(v.startLocation, fit: fit), let id = doc.selection {
                        doc.checkpoint()
                        drag = .resize(id, handle)
                    } else if let hit = hitItem(start, fit: fit) {
                        doc.selection = hit.id
                        doc.checkpoint()
                        drag = .move(hit.id, start, hit)
                    } else if doc.tool == .select || doc.tool == .text || doc.tool == .step {
                        doc.selection = nil
                        drag = .click
                    } else {
                        doc.selection = nil
                        drag = .create(start)
                    }
                }
                switch drag {
                case .create(let s): draft = makeMarkup(from: s, to: p)
                case .move(let id, let s, let original):
                    doc.update(id) { m in
                        m = original
                        m.offset(by: CGSize(width: p.x - s.x, height: p.y - s.y))
                    }
                case .resize(let id, let handle): doc.update(id) { handle.apply(p, to: &$0) }
                default: break
                }
            }
            .onEnded { v in
                defer { drag = nil; draft = nil }
                let moved = hypot(v.location.x - v.startLocation.x, v.location.y - v.startLocation.y) > 3
                switch drag {
                case .create:
                    if moved, let d = draft, d.isArrow || (d.rect.width > 3 && d.rect.height > 3) { doc.add(d) }
                case .click:
                    let p = fit.toImage(v.location)
                    if !moved && doc.tool == .text { textEdit = TextEdit(id: nil, at: p, value: ""); textFocused = true }
                    if !moved && doc.tool == .step {
                        doc.add(Markup(kind: .step(doc.nextStep), start: p, end: p, color: doc.cgColor, width: doc.baseWidth))
                    }
                default: break
                }
            }
    }

    private func makeMarkup(from a: CGPoint, to b: CGPoint) -> Markup {
        let kind: Markup.Kind = switch doc.tool {
        case .redact: .redact(doc.redactStyle)
        case .arrow: .arrow
        case .highlight: .highlight
        default: .box
        }
        let yellow = CGColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1)
        return Markup(kind: kind, start: a, end: b, color: doc.tool == .highlight && doc.color == .red ? yellow : doc.cgColor,
                      width: doc.baseWidth)
    }

    private func editSelectedText() {
        guard let id = doc.selection, let m = doc.items.first(where: { $0.id == id }), case .text(let s) = m.kind else { return }
        textEdit = TextEdit(id: id, at: m.start, value: s)
        textFocused = true
    }

    private func commitText() {
        guard let edit = textEdit else { return }
        textEdit = nil
        let value = edit.value.trimmingCharacters(in: .whitespaces)
        if let id = edit.id {
            doc.checkpoint()
            if value.isEmpty { doc.items.removeAll { $0.id == id } } else { doc.update(id) { $0.kind = .text(value) } }
        } else if !value.isEmpty {
            doc.add(Markup(kind: .text(value), start: edit.at, end: edit.at, color: doc.cgColor, width: doc.baseWidth))
        }
    }
}

// MARK: - The two tools

@MainActor
enum Editors {
    static let redact = MarkupDocument(toolID: "redact", suffix: "redacted", tools: [.select, .redact])
    static let annotate = MarkupDocument(toolID: "annotate", suffix: "annotated", tools: [.select, .arrow, .box, .highlight, .text, .step])
}

struct RedactView: View {
    var body: some View { MarkupEditor(doc: Editors.redact, emptyTitle: "Redact an Image") }
}

struct AnnotateView: View {
    var body: some View { MarkupEditor(doc: Editors.annotate, emptyTitle: "Annotate a Screenshot") }
}
