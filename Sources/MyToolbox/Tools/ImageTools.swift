import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension ToolRegistry {
    static let imageTools: [Tool] = [
        Tool("blurfaces", "Blur Faces", "person.crop.circle.badge.xmark", .images,
             "Find faces in photos and blur, pixelate or black them out", accepts: [.image], fullBleed: true) { BlurFacesView() },
        Tool("beautify", "Beautify Screenshot", "sparkles.rectangle.stack", .images,
             "Put screenshots on a background with padding, rounded corners and a shadow", accepts: [.image], fullBleed: true) { BeautifyView() },
        Tool("removebg", "Remove Background", "person.and.background.dotted", .images,
             "Lift the subject out of photos and save it with a transparent or solid background", accepts: [.image], fullBleed: true) { RemoveBackgroundView() },
        Tool("convertimages", "Convert Images", "photo.on.rectangle.angled", .images,
             "Save photos as JPEG, PNG, HEIC, TIFF or WebP", accepts: [.image], fullBleed: true) { ConvertImagesView() },
        Tool("compressimages", "Compress Images", "arrow.down.right.and.arrow.up.left", .images,
             "Make photos smaller without visible loss in quality", accepts: [.image], fullBleed: true) { CompressImagesView() },
        Tool("resizeimages", "Resize Images", "arrow.up.left.and.arrow.down.right", .images,
             "Scale photos by percentage, longest side or exact size", accepts: [.image], fullBleed: true) { ResizeImagesView() },
        Tool("rotateimages", "Rotate Images", "rotate.right", .images,
             "Rotate or flip many photos at once", accepts: [.image], fullBleed: true) { RotateImagesView() },
        Tool("removemetadata", "Remove Metadata", "location.slash", .images,
             "Strip location, camera and date info from photos", accepts: [.image], fullBleed: true) { RemoveMetadataView() },
        Tool("colorpicker", "Color Picker", "eyedropper", .images,
             "Pick any color on screen and copy it as HEX, RGB, HSL or code") { ColorPickerView() },
        Tool("redact", "Redact Image", "eye.slash", .images,
             "Blur, pixelate or black out any part of a photo or screenshot", accepts: [.image], fullBleed: true) { RedactView() },
        Tool("annotate", "Annotate Screenshot", "pencil.and.outline", .images,
             "Add arrows, boxes, text and numbered steps to a screenshot", accepts: [.image], fullBleed: true) { AnnotateView() },
    ]
}

// MARK: - Shared image jobs (pure functions, run off the main actor)

enum ObscureStyle: String, CaseIterable, Identifiable {
    case blur = "Blur", pixelate = "Pixelate", black = "Black Box"
    var id: String { rawValue }
}

enum ImageJobs {
    /// Output format for tools that keep the input's format.
    static func sameFormat(_ url: URL) -> ImageFormat {
        let f = ImageFormat.of(url) ?? .png
        if f == .webp && !ImageFormat.canWriteWebP { return .png }
        return f
    }

    static func convert(_ url: URL, folder: URL, format: ImageFormat, quality: Double, keepMetadata: Bool) throws -> BatchOutput {
        let image = try ImageKit.load(url)
        let out = ImageKit.outputURL(for: url, in: folder, suffix: ImageFormat.of(url) == format ? " converted" : "", ext: format.ext)
        try ImageKit.save(image, to: out, format: format, quality: quality, metadata: keepMetadata ? ImageKit.carriedMetadata(url) : [:])
        return BatchOutput(files: [out], note: "\(format.title) · " + sizeChange(url.fileSize, out.fileSize))
    }

    static func compress(_ url: URL, folder: URL, quality: Double, format: ImageFormat?, maxSide: Int, stripPrivate: Bool) throws -> BatchOutput {
        let target = format ?? sameFormat(url)
        let image = try ImageKit.load(url, maxPixel: maxSide > 0 ? maxSide : nil)
        var meta = ImageKit.carriedMetadata(url)
        if stripPrivate {
            meta[kCGImagePropertyGPSDictionary] = nil
            meta[kCGImagePropertyMakerAppleDictionary] = nil
            meta[kCGImagePropertyIPTCDictionary] = nil
        }
        let data = try ImageKit.encode(image, format: target, quality: quality, metadata: meta)
        let before = url.fileSize
        if Int64(data.count) >= before && target == ImageFormat.of(url) {
            return BatchOutput(note: "Already optimized — couldn't make it smaller")
        }
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " compressed", ext: target.ext)
        try data.write(to: out)
        return BatchOutput(files: [out], note: sizeChange(before, Int64(data.count)))
    }

    enum ResizeMode: String, CaseIterable, Identifiable {
        case percent = "Percentage", longest = "Longest Side", exact = "Exact Size"
        var id: String { rawValue }
    }

    enum FitMode: String, CaseIterable, Identifiable {
        case fit = "Fit Inside", fill = "Fill and Crop", stretch = "Stretch"
        var id: String { rawValue }
    }

    static func targetSize(from size: CGSize, mode: ResizeMode, percent: Double, longest: Int, width: Int, height: Int,
                           fit: FitMode, noEnlarge: Bool) -> (canvas: CGSize, draw: CGRect) {
        var scaleX: Double, scaleY: Double
        switch mode {
        case .percent:
            scaleX = percent / 100; scaleY = scaleX
        case .longest:
            scaleX = Double(longest) / max(size.width, size.height); scaleY = scaleX
        case .exact:
            let sx = Double(width) / size.width, sy = Double(height) / size.height
            switch fit {
            case .fit: scaleX = min(sx, sy); scaleY = scaleX
            case .fill: scaleX = max(sx, sy); scaleY = scaleX
            case .stretch: scaleX = sx; scaleY = sy
            }
        }
        if noEnlarge { scaleX = min(scaleX, 1); scaleY = min(scaleY, 1) }
        let drawW = max(1, (size.width * scaleX).rounded()), drawH = max(1, (size.height * scaleY).rounded())
        if mode == .exact && fit == .fill {
            let cw = min(Double(width), drawW), ch = min(Double(height), drawH)
            return (CGSize(width: cw, height: ch), CGRect(x: (cw - drawW) / 2, y: (ch - drawH) / 2, width: drawW, height: drawH))
        }
        return (CGSize(width: drawW, height: drawH), CGRect(x: 0, y: 0, width: drawW, height: drawH))
    }

    static func resize(_ url: URL, folder: URL, mode: ResizeMode, percent: Double, longest: Int, width: Int, height: Int,
                       fit: FitMode, noEnlarge: Bool) throws -> BatchOutput {
        let image = try ImageKit.load(url)
        let (canvas, draw) = targetSize(from: CGSize(width: image.width, height: image.height), mode: mode, percent: percent,
                                        longest: longest, width: width, height: height, fit: fit, noEnlarge: noEnlarge)
        let ctx = try ImageKit.context(width: Int(canvas.width), height: Int(canvas.height))
        ctx.draw(image, in: draw)
        let format = sameFormat(url)
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " resized", ext: format.ext)
        try ImageKit.save(ctx.makeImage()!, to: out, format: format, quality: 0.9, metadata: ImageKit.carriedMetadata(url))
        return BatchOutput(files: [out], note: "\(image.width)×\(image.height) → \(Int(canvas.width))×\(Int(canvas.height))")
    }

    /// Quarter turns clockwise, after an optional horizontal flip.
    static func rotated(_ image: CGImage, quarterTurns: Int, flip: Bool) throws -> CGImage {
        var ci = CIImage(cgImage: image)
        if flip { ci = ci.oriented(.upMirrored) }
        for _ in 0..<((quarterTurns % 4 + 4) % 4) { ci = ci.oriented(.right) }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        return try ImageKit.cgImage(ci)
    }

    static func rotate(_ url: URL, folder: URL, quarterTurns: Int, flip: Bool) throws -> BatchOutput {
        let image = try rotated(ImageKit.load(url), quarterTurns: quarterTurns, flip: flip)
        let format = sameFormat(url)
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " rotated", ext: format.ext)
        try ImageKit.save(image, to: out, format: format, quality: 0.95, metadata: ImageKit.carriedMetadata(url))
        return BatchOutput(files: [out], note: "\(image.width)×\(image.height)")
    }

    /// Copies the image without its metadata. JPEG, PNG, TIFF and HEIC are copied without re-encoding.
    static func removeMetadata(_ url: URL, folder: URL, locationOnly: Bool) throws -> BatchOutput {
        let src = try ImageKit.source(url)
        guard let type = CGImageSourceGetType(src) else { throw ToolError("Unknown image type") }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " clean", ext: url.pathExtension)
        let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil)
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true, kCGImageDestinationMergeMetadata: false]
        if locationOnly {
            if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) { options[kCGImageDestinationMetadata] = meta }
        } else {
            // Empty metadata except the orientation tag, so portrait photos stay upright.
            let meta = CGImageMetadataCreateMutable()
            let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                         orientation as CFNumber)
            options[kCGImageDestinationMetadata] = meta
        }
        var error: Unmanaged<CFError>?
        if dest.map({ !CGImageDestinationCopyImageSource($0, src, options as CFDictionary, &error) }) ?? true {
            // Formats ImageIO can't copy losslessly (or can't write at all, like WebP) get re-encoded
            // with nothing but orientation.
            try? FileManager.default.removeItem(at: out)
            let format = sameFormat(url)
            var keep: [CFString: Any] = [:]
            if locationOnly { keep = ImageKit.carriedMetadata(url); keep[kCGImagePropertyGPSDictionary] = nil }
            let fallback = ImageKit.outputURL(for: url, in: folder, suffix: " clean", ext: format.ext)
            try ImageKit.save(ImageKit.load(url), to: fallback, format: format, quality: 0.95, metadata: keep)
            return BatchOutput(files: [fallback], note: locationOnly ? "Location removed" : "All metadata removed")
        }
        return BatchOutput(files: [out], note: locationOnly ? "Location removed" : "All metadata removed")
    }

    /// The private details a photo carries, for showing before removal.
    static func metadataSummary(_ url: URL) -> [(String, String)] {
        let p = ImageKit.properties(url)
        var rows: [(String, String)] = []
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String].compactMap { $0 }.joined(separator: " ")
        if !camera.isEmpty { rows.append(("Camera", camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { rows.append(("Lens", lens)) }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            rows.append(("Taken", date))
        }
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N", ew = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            rows.append(("Location", String(format: "%.5f° %@, %.5f° %@", lat, ns, lon, ew)))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { rows.append(("Software", software)) }
        if let author = tiff[kCGImagePropertyTIFFArtist] as? String { rows.append(("Author", author)) }
        return rows
    }

    // MARK: Faces & redaction

    /// Face rectangles in Core Image coordinates (origin bottom-left), padded so hair and chin are covered.
    static func faces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).performRetrying([request])
        let w = Double(image.width), h = Double(image.height)
        return (request.results ?? []).map { face in
            let r = VNImageRectForNormalizedRect(face.boundingBox, image.width, image.height)
            return r.insetBy(dx: -r.width * 0.18, dy: -r.height * 0.22).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// Applies blur / pixelate / black to rects given in Core Image coordinates.
    static func obscure(_ image: CGImage, rects: [CGRect], style: ObscureStyle, strength: Double) throws -> CGImage {
        let original = CIImage(cgImage: image)
        var result = original
        for r in rects where r.width > 1 && r.height > 1 {
            let size = max(r.width, r.height)
            let patch: CIImage
            switch style {
            case .blur:
                patch = original.clampedToExtent().applyingGaussianBlur(sigma: max(6, size * (0.04 + 0.12 * strength)))
            case .pixelate:
                let f = CIFilter.pixellate()
                f.inputImage = original.clampedToExtent()
                f.center = r.origin
                f.scale = Float(max(6, size * (0.05 + 0.15 * strength)))
                patch = f.outputImage ?? original
            case .black:
                patch = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            }
            result = patch.cropped(to: r).composited(over: result)
        }
        return try ImageKit.cgImage(result.cropped(to: original.extent))
    }

    static func blurFaces(_ url: URL, folder: URL, style: ObscureStyle, strength: Double) throws -> BatchOutput {
        let image = try ImageKit.load(url)
        let found = try faces(in: image)
        guard !found.isEmpty else { return BatchOutput(note: "No faces found") }
        let result = try obscure(image, rects: found, style: style, strength: strength)
        let format = sameFormat(url)
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " blurred", ext: format.ext)
        try ImageKit.save(result, to: out, format: format, quality: 0.92, metadata: ImageKit.carriedMetadata(url))
        return BatchOutput(files: [out], note: "\(found.count) face\(found.count == 1 ? "" : "s") \(style == .black ? "covered" : style == .blur ? "blurred" : "pixelated")")
    }

    // MARK: Background removal

    enum Backdrop: Equatable {
        case transparent, white, color(CGColor)
    }

    static func cutout(_ image: CGImage, crop: Bool, backdrop: Backdrop) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.performRetrying([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: crop)
        var ci = CIImage(cvPixelBuffer: buffer)
        switch backdrop {
        case .transparent: break
        case .white: ci = ci.composited(over: CIImage(color: .white).cropped(to: ci.extent))
        case .color(let c): ci = ci.composited(over: CIImage(color: CIColor(cgColor: c)).cropped(to: ci.extent))
        }
        return try ImageKit.cgImage(ci)
    }

    static func removeBackground(_ url: URL, folder: URL, crop: Bool, backdrop: Backdrop) throws -> BatchOutput {
        guard let result = try cutout(ImageKit.load(url, maxPixel: 4096), crop: crop, backdrop: backdrop) else {
            return BatchOutput(note: "No subject found in this photo")
        }
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " cutout", ext: "png")
        try ImageKit.save(result, to: out, format: .png)
        return BatchOutput(files: [out], note: "\(result.width)×\(result.height) PNG")
    }

    // MARK: Beautify

    struct Gradient: Identifiable, Equatable {
        let id: String
        let from: CGColor
        let to: CGColor

        static func hex(_ v: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }

        static let presets: [Gradient] = [
            Gradient(id: "Soft Light", from: hex(0xE9ECF2), to: hex(0xF9F9FB)),
            Gradient(id: "Graphite", from: hex(0x3B3F47), to: hex(0x17181C)),
            Gradient(id: "Accent Blue", from: hex(0x3A7BFF), to: hex(0x7FB6FF)),
            Gradient(id: "Sunset", from: hex(0xFF7E5F), to: hex(0xFEB47B)),
            Gradient(id: "Ocean", from: hex(0x1C92D2), to: hex(0x7BE0D6)),
            Gradient(id: "Lavender", from: hex(0x8E7CF0), to: hex(0xE0A6F2)),
            Gradient(id: "Mint", from: hex(0x56CCA0), to: hex(0xD4F5B0)),
            Gradient(id: "Peach", from: hex(0xFFB199), to: hex(0xFFE3B3)),
        ]
    }

    enum BeautifyBackground: Equatable {
        case gradient(Gradient), solid(CGColor), image(URL), transparent
    }

    struct BeautifySettings: Equatable {
        var background: BeautifyBackground = .gradient(Gradient.presets[2])
        var padding = 0.08        // fraction of the longest side
        var cornerRadius = 0.025  // fraction of the shortest side
        var shadow = 0.6
        var aspect: Double? = nil // width / height
        var trim = true

        var key: String { "\(background)|\(padding)|\(cornerRadius)|\(shadow)|\(aspect ?? 0)|\(trim)" }
    }

    /// Crops away fully transparent edges (window screenshots carry a transparent shadow margin).
    static func trimTransparent(_ image: CGImage) throws -> CGImage {
        guard ImageKit.hasAlpha(image) else { return image }
        let w = image.width, h = image.height
        let ctx = try ImageKit.context(width: w, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        let row = ctx.bytesPerRow
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[y * row + x * 4 + 3] > 12 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // Context rows run top to bottom in memory, matching CGImage cropping coordinates.
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) ?? image
    }

    static func beautify(_ input: CGImage, _ s: BeautifySettings) throws -> CGImage {
        let shot = s.trim ? try trimTransparent(input) : input
        let w = Double(shot.width), h = Double(shot.height)
        let pad = max(w, h) * s.padding
        var cw = w + pad * 2, ch = h + pad * 2
        if let r = s.aspect {
            if cw / ch < r { cw = ch * r } else { ch = cw / r }
        }
        let ctx = try ImageKit.context(width: Int(cw.rounded()), height: Int(ch.rounded()))
        let canvas = CGRect(x: 0, y: 0, width: cw.rounded(), height: ch.rounded())
        switch s.background {
        case .gradient(let g):
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [g.from, g.to] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        case .solid(let c):
            ctx.setFillColor(c)
            ctx.fill(canvas)
        case .image(let url):
            if let bg = try? ImageKit.load(url, maxPixel: Int(max(cw, ch))) {
                let scale = max(cw / Double(bg.width), ch / Double(bg.height))
                let bw = Double(bg.width) * scale, bh = Double(bg.height) * scale
                ctx.draw(bg, in: CGRect(x: (cw - bw) / 2, y: (ch - bh) / 2, width: bw, height: bh))
            }
        case .transparent:
            break
        }
        let frame = CGRect(x: ((cw - w) / 2).rounded(), y: ((ch - h) / 2).rounded(), width: w, height: h)
        let radius = min(w, h) * s.cornerRadius
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if s.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -max(w, h) * 0.012 * s.shadow), blur: max(w, h) * 0.05 * s.shadow,
                          color: CGColor(gray: 0, alpha: 0.25 + 0.3 * s.shadow))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(shot, in: frame)
        ctx.restoreGState()
        return ctx.makeImage()!
    }
}

// MARK: - Convert

struct ConvertImagesView: View {
    @AppStorage("convert.format") private var format: ImageFormat = .jpeg
    @AppStorage("convert.quality") private var quality = 0.85
    @AppStorage("convert.metadata") private var keepMetadata = true

    var body: some View {
        BatchToolView(toolID: "convertimages", folderName: "Convert Images", types: [.image], noun: "Photo", verb: "Convert",
                      concurrency: 4) {
            Section {
                Picker("Format", selection: $format) {
                    ForEach(ImageFormat.allCases) { f in
                        Text(f.title).tag(f).disabled(f == .webp && !ImageFormat.canWriteWebP)
                    }
                }
                if format == .webp && !ImageFormat.canWriteWebP {
                    Text("WebP needs cwebp. Install it with: brew install webp").font(.caption).foregroundStyle(.orange)
                }
                if format.lossy { QualitySlider(quality: $quality) }
                Toggle("Keep camera and location info", isOn: $keepMetadata)
            } footer: {
                Text(formatHint).font(.caption).foregroundStyle(.secondary)
            }
        } process: { [format, quality, keepMetadata] url, folder, _ in
            try await offMain { try ImageJobs.convert(url, folder: folder, format: format, quality: quality, keepMetadata: keepMetadata) }
        }
    }

    private var formatHint: String {
        switch format {
        case .jpeg: "Opens everywhere. No transparency — transparent areas turn white."
        case .png: "Lossless, keeps transparency. Larger files for photos."
        case .heic: "About half the size of JPEG at the same quality. Best on Apple devices."
        case .tiff: "Lossless, for print and editing. Large files."
        case .webp: "Small files for the web, keeps transparency."
        }
    }
}

struct QualitySlider: View {
    @Binding var quality: Double
    var body: some View {
        LabeledContent("Quality") {
            HStack {
                Slider(value: $quality, in: 0.3...1, step: 0.05)
                Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - Compress

struct CompressImagesView: View {
    @AppStorage("cimg.quality") private var level: VideoQuality = .balanced
    @AppStorage("cimg.format") private var formatRaw = ""
    @AppStorage("cimg.maxSide") private var maxSide = 0
    @AppStorage("cimg.strip") private var stripPrivate = true

    var body: some View {
        BatchToolView(toolID: "compressimages", folderName: "Compress Images", types: [.image], noun: "Photo", verb: "Compress",
                      concurrency: 4) {
            Section("Quality") {
                Picker("Quality", selection: $level) { ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Text(level == .high ? "No visible difference." : level == .balanced ? "Smaller files, still sharp. Best for most photos." : "Smallest files, for sharing and the web.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Save as", selection: $formatRaw) {
                    Text("Same as original").tag("")
                    Text("JPEG").tag(ImageFormat.jpeg.rawValue)
                    Text("HEIC (smallest)").tag(ImageFormat.heic.rawValue)
                    if ImageFormat.canWriteWebP { Text("WebP").tag(ImageFormat.webp.rawValue) }
                }
                Picker("Max size", selection: $maxSide) {
                    Text("Original").tag(0)
                    Text("4K (3840 px)").tag(3840)
                    Text("2560 px").tag(2560)
                    Text("1920 px").tag(1920)
                    Text("1280 px").tag(1280)
                }
                Toggle("Remove location and camera info", isOn: $stripPrivate)
            } footer: {
                Text("If a photo can't get smaller, it's skipped and left as it is.").font(.caption).foregroundStyle(.secondary)
            }
        } process: { [level, formatRaw, maxSide, stripPrivate] url, folder, _ in
            let q = level == .high ? 0.82 : level == .balanced ? 0.7 : 0.55
            return try await offMain {
                try ImageJobs.compress(url, folder: folder, quality: q, format: ImageFormat(rawValue: formatRaw), maxSide: maxSide, stripPrivate: stripPrivate)
            }
        }
    }
}

// MARK: - Resize

struct ResizeImagesView: View {
    @AppStorage("resize.mode") private var mode: ImageJobs.ResizeMode = .longest
    @AppStorage("resize.percent") private var percent = 50.0
    @AppStorage("resize.longest") private var longest = 1920
    @AppStorage("resize.width") private var width = 1200
    @AppStorage("resize.height") private var height = 800
    @AppStorage("resize.fit") private var fit: ImageJobs.FitMode = .fit
    @AppStorage("resize.noEnlarge") private var noEnlarge = true

    var body: some View {
        BatchToolView(toolID: "resizeimages", folderName: "Resize Images", types: [.image], noun: "Photo", verb: "Resize",
                      concurrency: 4) {
            Section {
                Picker("Resize by", selection: $mode) { ForEach(ImageJobs.ResizeMode.allCases) { Text($0.rawValue).tag($0) } }
                switch mode {
                case .percent:
                    LabeledContent("Scale") {
                        HStack {
                            Slider(value: $percent, in: 5...200, step: 5)
                            Text("\(Int(percent))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                case .longest:
                    TextField("Longest side (px)", value: $longest, format: .number)
                case .exact:
                    TextField("Width (px)", value: $width, format: .number)
                    TextField("Height (px)", value: $height, format: .number)
                    Picker("Fit", selection: $fit) { ForEach(ImageJobs.FitMode.allCases) { Text($0.rawValue).tag($0) } }
                }
                Toggle("Don't make photos larger", isOn: $noEnlarge)
            }
        } preview: { url in
            ResizeSizePreview(url: url, mode: mode, percent: percent, longest: longest, width: width, height: height, fit: fit, noEnlarge: noEnlarge)
        } process: { [mode, percent, longest, width, height, fit, noEnlarge] url, folder, _ in
            try await offMain {
                try ImageJobs.resize(url, folder: folder, mode: mode, percent: percent, longest: longest, width: width, height: height,
                                     fit: fit, noEnlarge: noEnlarge)
            }
        }
    }
}

private struct ResizeSizePreview: View {
    let url: URL
    let mode: ImageJobs.ResizeMode
    let percent: Double, longest: Int, width: Int, height: Int
    let fit: ImageJobs.FitMode
    let noEnlarge: Bool

    var body: some View {
        if let src = try? ImageKit.source(url) {
            let size = ImageKit.pixelSize(src)
            let target = ImageJobs.targetSize(from: size, mode: mode, percent: percent, longest: longest, width: width, height: height,
                                              fit: fit, noEnlarge: noEnlarge).canvas
            HStack {
                Thumbnail(url: url, size: 44)
                VStack(alignment: .leading) {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text("\(Int(size.width))×\(Int(size.height)) → \(Int(target.width))×\(Int(target.height))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Rotate

struct RotateImagesView: View {
    @State private var turns = 1
    @State private var flip = false

    var body: some View {
        BatchToolView(toolID: "rotateimages", folderName: "Rotate Images", types: [.image], noun: "Photo", verb: "Rotate",
                      concurrency: 4) {
            Section {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Button { turns = (turns + 3) % 4 } label: { Label("Rotate Left", systemImage: "rotate.left").frame(maxWidth: .infinity) }
                        Button { turns = (turns + 1) % 4 } label: { Label("Rotate Right", systemImage: "rotate.right").frame(maxWidth: .infinity) }
                    }
                    GridRow {
                        Button { flip.toggle() } label: {
                            Label("Flip Across", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right").frame(maxWidth: .infinity)
                        }
                        Button { flip.toggle(); turns = (turns + 2) % 4 } label: {
                            Label("Flip Down", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down").frame(maxWidth: .infinity)
                        }
                    }
                }
                .lineLimit(1)
                .buttonStyle(.bordered)
                LabeledContent("Result", value: [turns == 0 ? nil : "\(turns * 90)° clockwise", flip ? "mirrored" : nil].compactMap { $0 }.joined(separator: ", ").isEmpty
                               ? "No change" : [turns == 0 ? nil : "\(turns * 90)° clockwise", flip ? "mirrored" : nil].compactMap { $0 }.joined(separator: ", "))
                Button("Reset") { turns = 0; flip = false }
            }
        } preview: { url in
            RenderedPreview(url: url, key: "\(turns)\(flip)") { [turns, flip] image in
                try ImageJobs.rotated(image, quarterTurns: turns, flip: flip)
            }
        } process: { [turns, flip] url, folder, _ in
            if turns == 0 && !flip { return BatchOutput(note: "No rotation chosen") }
            return try await offMain { try ImageJobs.rotate(url, folder: folder, quarterTurns: turns, flip: flip) }
        }
    }
}

// MARK: - Remove Metadata

struct RemoveMetadataView: View {
    @AppStorage("meta.locationOnly") private var locationOnly = false

    var body: some View {
        BatchToolView(toolID: "removemetadata", folderName: "Remove Metadata", types: [.image], noun: "Photo", verb: "Remove Metadata from",
                      concurrency: 4) {
            Section {
                Picker("Remove", selection: $locationOnly) {
                    Text("Everything").tag(false)
                    Text("Location only").tag(true)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("JPEG, PNG, HEIC and TIFF are copied without recompressing, so quality doesn't change. Rotation is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } preview: { url in
            MetadataPreview(url: url)
        } process: { [locationOnly] url, folder, _ in
            try await offMain { try ImageJobs.removeMetadata(url, folder: folder, locationOnly: locationOnly) }
        }
    }
}

private struct MetadataPreview: View {
    let url: URL
    var body: some View {
        let rows = ImageJobs.metadataSummary(url)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Thumbnail(url: url, size: 44)
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            if rows.isEmpty {
                Label("No camera, date or location info found", systemImage: "checkmark.shield").foregroundStyle(.secondary)
            } else {
                Text("This photo reveals").font(.caption).foregroundStyle(.secondary)
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline) {
                        Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text(value).textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Blur Faces

struct BlurFacesView: View {
    @AppStorage("faces.style") private var style: ObscureStyle = .blur
    @AppStorage("faces.strength") private var strength = 0.6

    var body: some View {
        BatchToolView(toolID: "blurfaces", folderName: "Blur Faces", types: [.image], noun: "Photo", verb: "Blur Faces in",
                      concurrency: 3) {
            Section {
                Picker("Style", selection: $style) { ForEach(ObscureStyle.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                if style != .black {
                    LabeledContent("Strength") { Slider(value: $strength, in: 0...1) }
                }
            } header: {
                Text("Style")
            } footer: {
                Text("Faces are found on this Mac. Photos without faces are skipped.").font(.caption).foregroundStyle(.secondary)
            }
        } preview: { url in
            RenderedPreview(url: url, key: "\(style)\(strength)") { [style, strength] image in
                let found = try ImageJobs.faces(in: image)
                if found.isEmpty { throw ToolError("No faces found in this photo") }
                return try ImageJobs.obscure(image, rects: found, style: style, strength: strength)
            }
        } process: { [style, strength] url, folder, _ in
            try await offMain { try ImageJobs.blurFaces(url, folder: folder, style: style, strength: strength) }
        }
    }
}

// MARK: - Remove Background

struct RemoveBackgroundView: View {
    @AppStorage("bg.mode") private var mode = 0   // 0 transparent, 1 white, 2 color
    @AppStorage("bg.crop") private var crop = false
    @State private var color = Color.blue

    private var backdrop: ImageJobs.Backdrop {
        switch mode {
        case 1: .white
        case 2: .color(NSColor(color).cgColor)
        default: .transparent
        }
    }

    var body: some View {
        BatchToolView(toolID: "removebg", folderName: "Remove Background", types: [.image], noun: "Photo", verb: "Remove Background from",
                      concurrency: 2) {
            Section {
                Picker("Background", selection: $mode) {
                    Text("Transparent").tag(0)
                    Text("White").tag(1)
                    Text("Color").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                if mode == 2 { ColorPicker("Color", selection: $color, supportsOpacity: false) }
                Toggle("Crop to subject", isOn: $crop)
            } header: {
                Text("Background")
            } footer: {
                Text("Saved as PNG so transparency is kept. Runs on this Mac with Apple's Vision.").font(.caption).foregroundStyle(.secondary)
            }
        } preview: { url in
            RenderedPreview(url: url, key: "\(mode)\(crop)\(color.description)") { [crop, backdrop] image in
                guard let out = try ImageJobs.cutout(image, crop: crop, backdrop: backdrop) else { throw ToolError("No subject found in this photo") }
                return out
            }
            .background(CheckerboardBackground().clipShape(RoundedRectangle(cornerRadius: 10)))
        } process: { [crop, backdrop] url, folder, _ in
            try await offMain { try ImageJobs.removeBackground(url, folder: folder, crop: crop, backdrop: backdrop) }
        }
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

// MARK: - Beautify

struct BeautifyView: View {
    @State private var settings = ImageJobs.BeautifySettings()
    @State private var solid = Color.white
    @State private var kind = 0   // 0 gradient, 1 solid, 2 image, 3 transparent
    @State private var gradient = ImageJobs.Gradient.presets[2]
    @State private var backgroundImage: URL?
    @State private var copied = false

    private var current: ImageJobs.BeautifySettings {
        var s = settings
        switch kind {
        case 1: s.background = .solid(NSColor(solid).cgColor)
        case 2: s.background = backgroundImage.map { .image($0) } ?? .gradient(gradient)
        case 3: s.background = .transparent
        default: s.background = .gradient(gradient)
        }
        return s
    }

    var body: some View {
        BatchToolView(toolID: "beautify", folderName: "Beautify Screenshot", types: [.image], noun: "Screenshot", verb: "Beautify",
                      concurrency: 3) {
            Section("Background") {
                Picker("Background", selection: $kind) {
                    Text("Gradient").tag(0); Text("Color").tag(1); Text("Image").tag(2); Text("None").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch kind {
                case 0:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 6)], spacing: 8) {
                        ForEach(ImageJobs.Gradient.presets) { g in
                            Button { gradient = g } label: {
                                LinearGradient(colors: [Color(cgColor: g.from), Color(cgColor: g.to)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    .frame(width: 26, height: 26)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(gradient == g ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(g.id)
                        }
                    }
                case 1:
                    ColorPicker("Color", selection: $solid, supportsOpacity: false)
                case 2:
                    Button(backgroundImage?.lastPathComponent ?? "Choose Image…") {
                        backgroundImage = FilePicker.choose(types: [.image], multiple: false).first
                    }
                default:
                    Text("Transparent PNG with just the shadow.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Frame") {
                LabeledContent("Padding") { Slider(value: $settings.padding, in: 0...0.25) }
                LabeledContent("Corners") { Slider(value: $settings.cornerRadius, in: 0...0.08) }
                LabeledContent("Shadow") { Slider(value: $settings.shadow, in: 0...1) }
                Picker("Size", selection: $settings.aspect) {
                    Text("Auto").tag(Double?.none)
                    Text("16:9 · X").tag(Double?.some(16.0 / 9))
                    Text("1:1 · Square").tag(Double?.some(1))
                    Text("4:5 · Instagram").tag(Double?.some(4.0 / 5))
                    Text("9:16 · Stories").tag(Double?.some(9.0 / 16))
                }
                Toggle("Trim transparent edges", isOn: $settings.trim)
            }
        } preview: { url in
            VStack(spacing: 8) {
                RenderedPreview(url: url, key: current.key) { [current] image in try ImageJobs.beautify(image, current) }
                    .background(CheckerboardBackground().clipShape(RoundedRectangle(cornerRadius: 10)))
                Button(copied ? "Copied" : "Copy Image") {
                    let s = current
                    Task {
                        if let data = try? await offMain({ ImageKit.pngData(try ImageJobs.beautify(ImageKit.load(url), s)) }) ?? nil {
                            Pasteboard.copy(png: data)
                            copied = true
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    }
                }
                .controlSize(.small)
            }
        } process: { [current] url, folder, _ in
            try await offMain {
                let out = ImageKit.outputURL(for: url, in: folder, suffix: " beautified", ext: "png")
                let result = try ImageJobs.beautify(ImageKit.load(url), current)
                try ImageKit.save(result, to: out, format: .png)
                return BatchOutput(files: [out], note: "\(result.width)×\(result.height) PNG")
            }
        }
    }
}

// MARK: - Color Picker

struct PickedColor: Codable, Equatable {
    var r: Double, g: Double, b: Double

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var hex: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    var rgb: String { "rgb(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())))" }

    var hsl: (h: Double, s: Double, l: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b), l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        switch maxV {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        return (h * 360, s, l)
    }

    var hslString: String {
        let v = hsl
        return "hsl(\(Int(v.h.rounded())), \(Int((v.s * 100).rounded()))%, \(Int((v.l * 100).rounded()))%)"
    }

    var formats: [(String, String)] {
        [("HEX", hex), ("RGB", rgb), ("HSL", hslString),
         ("SwiftUI", String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)),
         ("NSColor", String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: 1)", r, g, b)),
         ("UIColor", String(format: "UIColor(red: %.3f, green: %.3f, blue: %.3f, alpha: 1)", r, g, b)),
         ("CSS variable", "--color: \(hex.lowercased());")]
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }
}

struct ColorPickerView: View {
    @AppStorage("colors.history") private var historyData = Data()
    @State private var current: PickedColor?
    @State private var autoCopy = true

    private var history: [PickedColor] { (try? JSONDecoder().decode([PickedColor].self, from: historyData)) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Button(action: pick) { Label("Pick Color", systemImage: "eyedropper").padding(.horizontal, 4) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Click anywhere on screen to pick a color. Escape cancels.")
                    Toggle("Copy HEX automatically", isOn: $autoCopy).controlSize(.small)
                }
                Spacer()
            }
            if let c = current {
                HStack(alignment: .top, spacing: 18) {
                    RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: c.nsColor))
                        .frame(width: 120, height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(c.formats, id: \.0) { ValueRow(label: $0.0, value: $0.1) }
                    }
                }
            } else {
                ContentUnavailableView("No Color Picked", systemImage: "eyedropper",
                                       description: Text("Pick a color from anywhere on your screen, including other apps."))
                    .frame(maxHeight: 200)
            }
            if !history.isEmpty {
                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    Button("Clear") { historyData = Data() }.controlSize(.small)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, c in
                        Button { current = c } label: {
                            RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: c.nsColor)).frame(width: 34, height: 34)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(current == c ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: current == c ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(c.hex)
                        .contextMenu { Button("Copy \(c.hex)") { Pasteboard.copy(c.hex) } }
                    }
                }
            }
            Spacer()
        }
        .onAppear { if current == nil { current = history.first } }
    }

    private func pick() {
        NSColorSampler().show { color in
            guard let color, let c = PickedColor(color) else { return }
            current = c
            var h = history.filter { $0 != c }
            h.insert(c, at: 0)
            historyData = (try? JSONEncoder().encode(Array(h.prefix(32)))) ?? Data()
            if autoCopy {
                Pasteboard.copy(c.hex)
                Toast.show("Copied \(c.hex)", symbol: "eyedropper")
            }
        }
    }
}
