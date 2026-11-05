import AppKit
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let editorTools: [Tool] = [
        Tool("pdfeditor", "PDF Editor", "pencil.and.scribble", .docs,
             "Mark up, draw, add text, notes, images and signatures, edit text, and rearrange pages — all in one place",
             accepts: [.pdf], fullBleed: true) { PDFEditorView() },
    ]
}

enum PDFTool: String, CaseIterable, Identifiable {
    case select = "Select", editText = "Edit Text", pen = "Pen", rectangle = "Rectangle", ellipse = "Ellipse", line = "Line", arrow = "Arrow",
         text = "Text Box", note = "Note", whiteout = "Eraser", image = "Image"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .editText: "character.cursor.ibeam"
        case .pen: "scribble"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "character.textbox"
        case .note: "note.text"
        case .whiteout: "eraser"
        case .image: "photo"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .select: "v"
        case .editText: "e"
        case .pen: "p"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .note: "n"
        case .whiteout: "w"
        case .image: "i"
        }
    }
}

/// Stamped image (picture or signature) that draws itself and can be moved and resized.
final class ImageStampAnnotation: PDFAnnotation {
    var image: CGImage?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

/// Pen strokes and shapes drawn by the app as smooth, anti-aliased vectors. Points are stored relative to
/// the box, so resizing scales the drawing instead of cropping it.
final class VectorAnnotation: PDFAnnotation {
    enum Kind { case ink, rectangle, ellipse, line, arrow, eraser }

    var kind: Kind = .ink
    /// Normalized (0…1) inside the inner box; ink = the stroke, line/arrow = [start, end].
    var points: [CGPoint] = []
    var strokeColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 2

    /// Room around the drawing for the line width and arrow heads (in points, not scaled).
    var pad: CGFloat { kind == .arrow ? strokeWidth * 4 + 2 : strokeWidth / 2 + 1 }
    var inner: CGRect { bounds.insetBy(dx: min(pad, bounds.width / 3), dy: min(pad, bounds.height / 3)) }

    func absolute(_ p: CGPoint) -> CGPoint {
        let r = inner
        return CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
    }

    /// Smooth curve through the stroke points (midpoint quadratic smoothing).
    func smoothPath() -> CGPath {
        let path = CGMutablePath()
        let pts = points.map(absolute)
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 { pts.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts.last!)
        return path
    }

    override func draw(with box: PDFDisplayBox, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(strokeWidth)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setFillColor(strokeColor.cgColor)
        switch kind {
        case .ink:
            ctx.addPath(smoothPath())
            ctx.strokePath()
        case .rectangle:
            ctx.stroke(inner)
        case .ellipse:
            ctx.strokeEllipse(in: inner)
        case .eraser:
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(bounds)
        case .line, .arrow:
            guard points.count == 2 else { break }
            let a = absolute(points[0]), b = absolute(points[1])
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = strokeWidth * 4 + 4
            let end = kind == .arrow ? CGPoint(x: b.x - cos(angle) * head * 0.7, y: b.y - sin(angle) * head * 0.7) : b
            ctx.move(to: a); ctx.addLine(to: end); ctx.strokePath()
            if kind == .arrow {
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(angle - .pi / 7) * head, y: b.y - sin(angle - .pi / 7) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(angle + .pi / 7) * head, y: b.y - sin(angle + .pi / 7) * head))
                ctx.closePath(); ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }

    /// A standard PDF annotation with the same look, so other apps can show and edit it after saving.
    func standardEquivalent() -> PDFAnnotation {
        let border = PDFBorder()
        border.lineWidth = strokeWidth
        let a: PDFAnnotation
        switch kind {
        case .ink:
            a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            let path = NSBezierPath()
            path.append(NSBezierPath(cgPath: smoothPath()))
            path.transform(using: AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY))
            a.add(path)
        case .rectangle, .eraser:
            a = PDFAnnotation(bounds: kind == .eraser ? bounds : inner, forType: .square, withProperties: nil)
            if kind == .eraser { a.interiorColor = .white }
        case .ellipse:
            a = PDFAnnotation(bounds: inner, forType: .circle, withProperties: nil)
        case .line, .arrow:
            a = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            let s = absolute(points.first ?? .zero), e = absolute(points.last ?? .zero)
            a.startPoint = CGPoint(x: s.x - bounds.minX, y: s.y - bounds.minY)
            a.endPoint = CGPoint(x: e.x - bounds.minX, y: e.y - bounds.minY)
            a.endLineStyle = kind == .arrow ? .closedArrow : .none
            a.interiorColor = strokeColor
        }
        a.color = kind == .eraser ? .white : strokeColor
        a.border = kind == .eraser ? nil : border
        return a
    }
}

@MainActor @Observable
final class PDFEditorModel {
    static let shared = PDFEditorModel()

    var url: URL?
    var doc: PDFDocument?
    var tool: PDFTool = .select
    var color: Color = .red
    var lineWidth: CGFloat = 2
    var fontSize: CGFloat = 14
    var selected: PDFAnnotation?
    var editing: PDFAnnotation?
    var pendingImage: CGImage?
    var search = ""
    var results: [PDFSelection] = []
    var resultIndex = 0
    var dirty = false
    var saved: URL?
    var error: String?
    var revision = 0
    @ObservationIgnored weak var view: EditorPDFView?

    enum Change { case added(PDFAnnotation, PDFPage), removed(PDFAnnotation, PDFPage), bounds(PDFAnnotation, CGRect) }
    @ObservationIgnored private var undoStack: [Change] = []
    @ObservationIgnored private var redoStack: [Change] = []
    var canUndo = false
    var canRedo = false

    var nsColor: NSColor { NSColor(color).usingColorSpace(.sRGB) ?? .systemRed }

    func open(_ url: URL) {
        do {
            doc = try DocKit.open(url)
            self.url = url
            selected = nil
            saved = nil
            error = nil
            dirty = false
            undoStack = []; redoStack = []; refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func close() { doc = nil; url = nil; selected = nil; saved = nil }

    // MARK: Undo

    func record(_ change: Change) {
        undoStack.append(change)
        redoStack = []
        dirty = true
        refresh()
    }

    /// Applies a change (or its opposite) and returns what to store for going the other way.
    private func apply(_ c: Change, reverse: Bool) -> Change {
        switch c {
        case .added(let a, let p):
            if reverse { p.removeAnnotation(a) } else { p.addAnnotation(a) }
            return c
        case .removed(let a, let p):
            if reverse { p.addAnnotation(a) } else { p.removeAnnotation(a) }
            return c
        case .bounds(let a, let r):
            let current = a.bounds
            a.bounds = r
            return .bounds(a, current)
        }
    }

    func undo() {
        guard let c = undoStack.popLast() else { return }
        redoStack.append(apply(c, reverse: true))
        selected = nil
        refresh()
    }

    func redo() {
        guard let c = redoStack.popLast() else { return }
        undoStack.append(apply(c, reverse: false))
        refresh()
    }

    private func refresh() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        revision += 1
        view?.refreshOverlay()
    }

    // MARK: Editing

    func add(_ a: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(a)
        record(.added(a, page))
        selected = a
    }

    func deleteSelected() {
        guard let a = selected, let page = a.page else { return }
        page.removeAnnotation(a)
        record(.removed(a, page))
        selected = nil
    }

    /// Highlight, underline or strike out the text currently selected in the page.
    func markup(_ type: PDFAnnotationSubtype) {
        guard let selection = view?.currentSelection else { error = "Select some text first (with the Select tool)"; return }
        let color: NSColor = type == .highlight ? (nsColor == .systemRed ? .systemYellow : nsColor).withAlphaComponent(0.45) : nsColor
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0 else { continue }
                let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                a.color = color
                a.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: b.height)), NSValue(point: CGPoint(x: b.width, y: b.height)),
                                         NSValue(point: .zero), NSValue(point: CGPoint(x: b.width, y: 0))]
                add(a, to: page)
            }
        }
        view?.clearSelection()
    }

    /// Covers the selected text with white and puts an editable text box with the same words on top.
    func editSelectedText() {
        guard let selection = view?.currentSelection, let text = selection.string, !text.isEmpty else {
            error = "Select the text you want to change first, or use the Edit Text tool and click a line"
            return
        }
        for line in selection.selectionsByLine() {
            if let page = line.pages.first { replaceText(line, on: page) }
        }
        view?.clearSelection()
    }

    /// The BaseFont names in a page's resources (subset prefixes like "ABCDEF+" removed).
    static func fontNames(on page: PDFPage) -> [String] {
        guard let dict = page.pageRef?.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { return [] }
        var names: [String] = []
        CGPDFDictionaryApplyBlock(fonts, { _, object, _ in
            var font: CGPDFDictionaryRef?, base: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object, .dictionary, &font), let font, CGPDFDictionaryGetName(font, "BaseFont", &base), let base {
                let name = String(cString: base)
                names.append(name.count > 7 && name.dropFirst(6).first == "+" ? String(name.dropFirst(7)) : name)
            }
            return true
        }, nil)
        return names
    }

    /// Erases one line of the PDF's own text (white cover) and puts an editable box with the same words,
    /// in a matching font and size, on top — then opens it for typing.
    func replaceText(_ line: PDFSelection, on page: PDFPage) {
        let b = line.bounds(for: page)
        guard b.width > 0 else { return }
        let source = line.attributedString.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }
        let size = source?.pointSize ?? max(6, b.height * 0.8)
        // Apple's system font has a private name (".SFNS…") that other PDF apps can't resolve (and looking it
        // up by name gives Times), so text in it gets the closest public face instead.
        let font: NSFont = {
            guard let source else { return NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size) }
            // PDFKit reports Times for embedded fonts it can't resolve; only trust it if the page really uses Times.
            let fallback = source.fontName.hasPrefix(".")
                || (source.fontName.hasPrefix("Times") && !Self.fontNames(on: page).contains { $0.contains("Times") })
            if !fallback { return source.withSize(size) }
            let bold = source.fontDescriptor.symbolicTraits.contains(.bold)
            return NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size) ?? source.withSize(size)
        }()
        let cover = VectorAnnotation(bounds: b.insetBy(dx: -1.5, dy: -1.5), forType: .square, withProperties: nil)
        cover.kind = .eraser
        add(cover, to: page)
        let box = PDFAnnotation(bounds: CGRect(x: b.minX - 2, y: b.minY - size * 0.25, width: max(b.width + 40, 60), height: size * 1.45),
                                forType: .freeText, withProperties: nil)
        box.contents = line.string ?? ""
        box.font = font
        box.fontColor = .black
        box.color = .clear
        add(box, to: page)
        editing = box
    }

    // MARK: Pages

    var currentPage: PDFPage? { view?.currentPage }

    func rotateCurrent(_ degrees: Int) {
        guard let p = currentPage else { return }
        p.rotation = (p.rotation + degrees + 360) % 360
        dirty = true
        refresh()
    }

    func deleteCurrentPage() {
        guard let doc, let p = currentPage, doc.pageCount > 1 else { return }
        doc.removePage(at: doc.index(for: p))
        dirty = true
        refresh()
    }

    func insertBlankPage() {
        guard let doc else { return }
        let size = currentPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let page = PDFPage()
        page.setBounds(size, for: .mediaBox)
        let at = currentPage.map { doc.index(for: $0) + 1 } ?? doc.pageCount
        doc.insert(page, at: at)
        view?.go(to: page)
        dirty = true
        refresh()
    }

    func insertFiles(_ urls: [URL]) {
        guard let doc else { return }
        var at = currentPage.map { doc.index(for: $0) + 1 } ?? doc.pageCount
        for url in urls {
            if url.pathExtension.lowercased() == "pdf", let other = try? DocKit.open(url) {
                for i in 0..<other.pageCount { if let p = other.page(at: i)?.copy() as? PDFPage { doc.insert(p, at: at); at += 1 } }
            } else if let img = try? ImageKit.load(url, maxPixel: 3000),
                      let data = try? DocKit.pdf(fromImages: [img], pageSize: DocKit.Paper.a4.size, margin: 24, ocr: false),
                      let p = PDFDocument(data: data)?.page(at: 0) {
                doc.insert(p, at: at); at += 1
            }
        }
        dirty = true
        refresh()
    }

    // MARK: Search

    func runSearch() {
        guard let doc, !search.isEmpty else { results = []; view?.highlightedSelections = nil; return }
        results = doc.findString(search, withOptions: [.caseInsensitive])
        results.forEach { $0.color = .systemYellow }
        view?.highlightedSelections = results
        resultIndex = 0
        showResult()
    }

    func nextResult(_ d: Int) {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex + d + results.count) % results.count
        showResult()
    }

    private func showResult() {
        guard results.indices.contains(resultIndex) else { return }
        view?.setCurrentSelection(results[resultIndex], animate: true)
        view?.scrollSelectionToVisible(nil)
    }

    // MARK: Saving

    /// Image stamps are drawn by this app, so pages that have them are flattened to keep the pictures in the file.
    func save(flatten: Bool) {
        guard let doc, let url else { return }
        selected = nil
        do {
            let out = Output.file(name: url.baseName + (flatten ? " flattened" : " edited"), ext: "pdf")
            if flatten {
                try DocKit.flatten(doc).write(to: out)
            } else {
                // Swap the app-drawn marks for standard PDF annotations while writing, then put them back.
                var swapped: [(PDFPage, VectorAnnotation, PDFAnnotation)] = []
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    for case let v as VectorAnnotation in page.annotations {
                        let std = v.standardEquivalent()
                        page.removeAnnotation(v)
                        page.addAnnotation(std)
                        swapped.append((page, v, std))
                    }
                }
                defer { for (page, v, std) in swapped { page.removeAnnotation(std); page.addAnnotation(v) } }
                guard let copy = doc.dataRepresentation().flatMap(PDFDocument.init(data:)) else { throw ToolError("Couldn't copy the document") }
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i), page.annotations.contains(where: { $0 is ImageStampAnnotation }) else { continue }
                    let single = PDFDocument()
                    single.insert(page.copy() as! PDFPage, at: 0)
                    for a in page.annotations where a is ImageStampAnnotation {
                        let s = ImageStampAnnotation(bounds: a.bounds, forType: .stamp, withProperties: nil)
                        s.image = (a as? ImageStampAnnotation)?.image
                        single.page(at: 0)?.addAnnotation(s)
                    }
                    if let flat = PDFDocument(data: try DocKit.flatten(single))?.page(at: 0) {
                        copy.removePage(at: i)
                        copy.insert(flat, at: i)
                    }
                }
                try DocKit.write(copy, to: out)
            }
            saved = out
            dirty = false
            Toast.show("Saved \(out.lastPathComponent)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func print() {
        guard let doc, let window = view?.window else { return }
        doc.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true)?
            .runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

/// PDFView that knows the editor's tools: draws shapes and ink, places text, notes and images,
/// and moves, resizes and deletes annotations.
final class EditorPDFView: PDFView {
    weak var model: PDFEditorModel?
    private var dragStart: (PDFPage, CGPoint)?
    private var temp: PDFAnnotation?
    private var inkPoints: [CGPoint] = []
    private var moving: (PDFAnnotation, CGPoint, CGRect)?
    private var resizing: (PDFAnnotation, CGRect)?
    private let overlay = SelectionOverlay()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(overlay)
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: .PDFViewScaleChanged, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: .PDFViewPageChanged, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clip = documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func viewChanged() { refreshOverlay() }

    func refreshOverlay() {
        overlay.removeFromSuperview()
        addSubview(overlay)
        if let a = model?.selected, let page = a.page {
            overlay.frame = convert(a.bounds, from: page).insetBy(dx: -5, dy: -5)
            overlay.isHidden = false
        } else {
            overlay.isHidden = true
        }
        overlay.needsDisplay = true
        setNeedsDisplay(bounds)
    }

    private var tool: PDFTool { model?.tool ?? .select }

    private func isEditable(_ a: PDFAnnotation) -> Bool {
        a.type != "Widget" && a.type != "Link" && a.type != "Popup"
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: false) else { return super.mouseDown(with: event) }
        let point = convert(p, to: page)

        // Resize handle (bottom-right) of the selected annotation.
        if let sel = model.selected, sel.page == page {
            let corner = convert(CGPoint(x: sel.bounds.maxX, y: sel.bounds.minY), from: page)
            if hypot(corner.x - p.x, corner.y - p.y) < 9 {
                resizing = (sel, sel.bounds)
                return
            }
        }
        // The eraser removes a mark you click on; dragging on empty page whites out what's printed there.
        if tool == .whiteout, let hit = page.annotation(at: point), isEditable(hit), !(hit is VectorAnnotation && (hit as! VectorAnnotation).kind == .eraser) {
            model.selected = hit
            model.deleteSelected()
            refreshOverlay()
            return
        }
        // Clicking an existing markup selects it, in any tool.
        if let hit = page.annotation(at: point), isEditable(hit) {
            model.selected = hit
            if event.clickCount == 2, hit.type == "FreeText" || hit.type == "Text" { model.editing = hit }
            moving = (hit, point, hit.bounds)
            refreshOverlay()
            return
        }
        model.selected = nil
        refreshOverlay()

        switch tool {
        case .select:
            super.mouseDown(with: event)   // text selection
        case .editText:
            // Click a line of the document's own text to erase it and type your own in its place.
            if let line = page.selectionForLine(at: point), let text = line.string, !text.trimmingCharacters(in: .whitespaces).isEmpty,
               line.bounds(for: page).insetBy(dx: -4, dy: -4).contains(point) {
                model.replaceText(line, on: page)
            } else {
                model.error = "Click directly on a line of text to change it"
            }
        case .text:
            let a = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - model.fontSize * 1.6, width: 220, height: model.fontSize * 1.8),
                                  forType: .freeText, withProperties: nil)
            a.contents = "Text"
            a.font = .systemFont(ofSize: model.fontSize)
            a.fontColor = model.nsColor
            a.color = .clear
            model.add(a, to: page)
            model.editing = a
        case .note:
            let a = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 20, width: 20, height: 20), forType: .text, withProperties: nil)
            a.color = .systemYellow
            a.contents = ""
            a.iconType = .note
            model.add(a, to: page)
            model.editing = a
        case .image:
            guard let image = model.pendingImage else { return }
            let w: CGFloat = 180, h = w * CGFloat(image.height) / CGFloat(image.width)
            let a = ImageStampAnnotation(bounds: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), forType: .stamp, withProperties: nil)
            a.image = image
            model.add(a, to: page)
            model.tool = .select
        default:
            dragStart = (page, point)
            inkPoints = [point]
        }
        refreshOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return super.mouseDragged(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        if let (a, start) = resizing, let page = a.page {
            let q = convert(p, to: page)
            let keepAspect = a is ImageStampAnnotation
            let w = max(8, q.x - start.minX)
            let h = keepAspect ? w * start.height / start.width : max(8, start.maxY - q.y)
            a.bounds = CGRect(x: start.minX, y: start.maxY - h, width: w, height: h)
            refreshOverlay()
            return
        }
        if let (a, startPoint, startBounds) = moving, let page = a.page {
            let q = convert(p, to: page)
            a.bounds = startBounds.offsetBy(dx: q.x - startPoint.x, dy: q.y - startPoint.y)
            refreshOverlay()
            return
        }
        guard let (page, start) = dragStart else { return super.mouseDragged(with: event) }
        let q = convert(p, to: page)
        inkPoints.append(q)
        if let temp { page.removeAnnotation(temp) }
        temp = makeShape(from: start, to: q)
        if let temp { page.addAnnotation(temp) }
        _ = model
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return super.mouseUp(with: event) }
        if let (a, start) = resizing {
            resizing = nil
            if a.bounds != start { model.record(.bounds(a, start)) }
            return
        }
        if let (a, _, start) = moving {
            moving = nil
            if a.bounds != start { model.record(.bounds(a, start)) }
            return
        }
        if let (page, _) = dragStart {
            if let temp {
                page.removeAnnotation(temp)
                if temp.bounds.width > 3 || temp.bounds.height > 3 { model.add(temp, to: page) }
            }
            temp = nil
            dragStart = nil
            inkPoints = []
            refreshOverlay()
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), model?.selected != nil {
            model?.deleteSelected()
            refreshOverlay()
            return
        }
        super.keyDown(with: event)
    }

    private func makeShape(from a: CGPoint, to b: CGPoint) -> PDFAnnotation? {
        guard let model else { return nil }
        let kind: VectorAnnotation.Kind
        switch tool {
        case .pen: kind = .ink
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .line: kind = .line
        case .arrow: kind = .arrow
        case .whiteout: kind = .eraser
        default: return nil
        }
        let ann = VectorAnnotation(bounds: .zero, forType: .square, withProperties: nil)
        ann.kind = kind
        ann.strokeColor = model.nsColor
        ann.strokeWidth = model.lineWidth
        let raw = kind == .ink ? inkPoints : [a, b]
        guard raw.count > 1 else { return nil }
        let xs = raw.map(\.x), ys = raw.map(\.y)
        var content = CGRect(x: xs.min()!, y: ys.min()!, width: max(1, xs.max()! - xs.min()!), height: max(1, ys.max()! - ys.min()!))
        if kind == .rectangle || kind == .ellipse || kind == .eraser { content = CGRect(a, b) }
        ann.bounds = content.insetBy(dx: -ann.pad, dy: -ann.pad)
        let inner = ann.inner
        ann.points = raw.map { CGPoint(x: ($0.x - inner.minX) / max(inner.width, 1), y: ($0.y - inner.minY) / max(inner.height, 1)) }
        return ann
    }
}

/// Dashed outline with a resize dot, drawn above the page for the selected annotation.
final class SelectionOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(rect: r)
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: r.maxX - 5, y: (isFlipped ? r.maxY : r.minY) - 5, width: 10, height: 10))
        NSColor.white.setFill()
        dot.fill()
        NSColor.controlAccentColor.setStroke()
        dot.lineWidth = 2
        dot.stroke()
    }
}

struct EditorPDFRepresentable: NSViewRepresentable {
    @Bindable var model: PDFEditorModel
    let document: PDFDocument

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let pdf = EditorPDFView()
        pdf.model = model
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.backgroundColor = .underPageBackgroundColor
        pdf.document = document
        model.view = pdf
        let thumbs = PDFThumbnailView()
        thumbs.pdfView = pdf
        thumbs.thumbnailSize = NSSize(width: 90, height: 120)
        thumbs.allowsDragging = true
        thumbs.allowsMultipleSelection = false
        thumbs.backgroundColor = .windowBackgroundColor
        for v in [thumbs, pdf] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        NSLayoutConstraint.activate([
            thumbs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbs.topAnchor.constraint(equalTo: container.topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            thumbs.widthAnchor.constraint(equalToConstant: 130),
            pdf.leadingAnchor.constraint(equalTo: thumbs.trailingAnchor),
            pdf.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdf.topAnchor.constraint(equalTo: container.topAnchor),
            pdf.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let pdf = model.view else { return }
        if pdf.document !== document { pdf.document = document }
        _ = model.revision
        pdf.refreshOverlay()
        pdf.layoutDocumentView()
    }
}

struct PDFEditorView: View {
    @Bindable private var model = PDFEditorModel.shared
    @State private var editText = ""
    @State private var editSize: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let doc = model.doc {
                EditorPDFRepresentable(model: model, document: doc)
            } else {
                PDFDropPlaceholder(title: "Edit a PDF",
                                   detail: "Highlight and mark up text, draw, add text boxes, notes, pictures and signatures, change existing text, and rearrange pages.") { model.open($0) }
            }
            if let saved = model.saved { SavedFileBar(url: saved) }
        }
        .onDrop(of: FileDrop.types, isTargeted: nil) { providers in
            FileDrop.load(providers) { urls in
                if model.doc == nil, let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) { model.open(pdf) }
                else if model.doc != nil { model.insertFiles(urls) }
            }
            return true
        }
        .receivesFiles(for: "pdfeditor") { if let url = $0.first { model.open(url) } }
        .sheet(item: Binding(get: { model.editing.map(AnnotationBox.init) }, set: { if $0 == nil { model.editing = nil } })) { box in
            VStack(alignment: .leading, spacing: 12) {
                Text(box.annotation.type == "Text" ? "Note" : "Text").font(.headline)
                TextEditor(text: $editText).font(.system(size: 14)).frame(width: 420, height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                if box.annotation.type == "FreeText" {
                    Stepper("Size \(Int(editSize)) pt", value: $editSize, in: 6...96)
                }
                HStack {
                    Button("Delete", role: .destructive) { model.selected = box.annotation; model.deleteSelected(); model.editing = nil }
                    Spacer()
                    Button("Cancel") { model.editing = nil }.keyboardShortcut(.cancelAction)
                    Button("Done") {
                        let a = box.annotation
                        a.contents = editText
                        if a.type == "FreeText" {
                            a.font = .systemFont(ofSize: editSize)
                            let lines = max(1, editText.components(separatedBy: "\n").count)
                            let width = max(a.bounds.width, CGFloat(editText.components(separatedBy: "\n").map(\.count).max() ?? 4) * editSize * 0.55)
                            let height = CGFloat(lines) * editSize * 1.35 + 4
                            a.bounds = CGRect(x: a.bounds.minX, y: a.bounds.maxY - height, width: width, height: height)
                        }
                        model.editing = nil
                        model.dirty = true
                        model.view?.refreshOverlay()
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .onAppear {
                editText = box.annotation.contents ?? ""
                editSize = box.annotation.font?.pointSize ?? model.fontSize
            }
        }
    }

    private var toolbar: some View {
        ToolbarRow {
            Menu {
                Button("Open PDF…") { if let url = FilePicker.choose(types: [.pdf], multiple: false).first { model.open(url) } }
                if model.doc != nil {
                    Divider()
                    Button("Insert Pages from Files…") { model.insertFiles(FilePicker.choose(types: [.pdf, .image])) }
                    Button("Insert Blank Page") { model.insertBlankPage() }
                    Divider()
                    Button("Rotate Page Left") { model.rotateCurrent(-90) }
                    Button("Rotate Page Right") { model.rotateCurrent(90) }
                    Button("Delete Page") { model.deleteCurrentPage() }
                    Divider()
                    Button("Print…") { model.print() }
                    Button("Close") { model.close() }
                }
            } label: { Label("File", systemImage: "doc") }
            .fixedSize()
            if model.doc != nil {
                Picker("Tool", selection: $model.tool) {
                    ForEach(PDFTool.allCases) { t in Label(t.rawValue, systemImage: t.symbol).tag(t) }
                }
                .pickerStyle(.segmented).labelStyle(.iconOnly).labelsHidden().fixedSize()
                .help(PDFTool.allCases.map(\.rawValue).joined(separator: ", "))
                .onChange(of: model.tool) {
                    if model.tool == .image, let url = FilePicker.choose(types: [.image] , multiple: false).first {
                        model.pendingImage = try? ImageKit.load(url, maxPixel: 2000)
                    } else if model.tool == .image {
                        model.tool = .select
                    }
                }
                Menu {
                    Button("Highlight") { model.markup(.highlight) }
                    Button("Underline") { model.markup(.underline) }
                    Button("Strikethrough") { model.markup(.strikeOut) }
                    Divider()
                    Button("Edit Selected Text…") { model.editSelectedText() }
                } label: { Label("Text", systemImage: "highlighter") }
                .fixedSize()
                .help("Select text with the Select tool, then highlight, underline, strike out or change it")
                ColorPicker("", selection: $model.color, supportsOpacity: false).labelsHidden().help("Colour for new marks")
                Picker("Width", selection: $model.lineWidth) { Text("Thin").tag(CGFloat(1)); Text("Medium").tag(CGFloat(2)); Text("Thick").tag(CGFloat(4)) }
                    .fixedSize().labelsHidden().help("Line width")
                TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 140)
                    .onSubmit(model.runSearch)
                if !model.results.isEmpty {
                    Text("\(model.resultIndex + 1)/\(model.results.count)").monospacedDigit().foregroundStyle(.secondary)
                    Button { model.nextResult(-1) } label: { Image(systemName: "chevron.up") }
                    Button { model.nextResult(1) } label: { Image(systemName: "chevron.down") }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).lineLimit(1).onTapGesture { model.error = nil } }
        } trailing: {
            if model.doc != nil {
                Button { model.view?.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out (⌘-)")
                Button { model.view?.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in (⌘+)")
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.keyboardShortcut("z").disabled(!model.canUndo).help("Undo (⌘Z)")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo).help("Redo")
                Button { model.deleteSelected() } label: { Image(systemName: "trash") }.disabled(model.selected == nil).help("Delete the selected mark (Delete)")
                Menu {
                    Button("Save (marks stay editable)") { model.save(flatten: false) }
                    Button("Save Flattened (marks become part of the page)") { model.save(flatten: true) }
                } label: { Text("Save") } primaryAction: { model.save(flatten: false) }
                .fixedSize()
                .keyboardShortcut("s")
            }
        }
    }
}

struct AnnotationBox: Identifiable {
    let annotation: PDFAnnotation
    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
}
