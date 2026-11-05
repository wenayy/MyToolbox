import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, tiff, webp
    var id: String { rawValue }

    var title: String { rawValue == "jpeg" ? "JPEG" : rawValue.uppercased() }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var lossy: Bool { self == .jpeg || self == .heic || self == .webp }
    var supportsAlpha: Bool { self != .jpeg }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .webp: .webP
        }
    }

    static func of(_ url: URL) -> ImageFormat? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return allCases.first { type.conforms(to: $0.utType) }
    }

    /// WebP output needs Google's cwebp (brew install webp); ImageIO can read WebP but not write it.
    static var canWriteWebP: Bool { Shell.which("cwebp") != nil }
}

enum ImageKit {
    static let ci = CIContext(options: [.cacheIntermediates: false])
    static let readableTypes: [UTType] = [.image]

    static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ToolError("Can't open \(url.lastPathComponent) as an image")
        }
        return src
    }

    /// Loads with EXIF orientation applied, optionally downscaled so the longest side ≤ maxPixel.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        let src = try source(url)
        let size = pixelSize(src)
        let longest = Int(max(size.width, size.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixel ?? longest, longest)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ToolError("Can't read the pixels in \(url.lastPathComponent)")
        }
        return image
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let src = try? source(url) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    }

    /// Displayed size (after orientation).
    static func pixelSize(_ src: CGImageSource) -> CGSize {
        let p = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let o = p[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Source metadata minus anything that would be wrong after re-encoding (size, orientation).
    static func carriedMetadata(_ url: URL) -> [CFString: Any] {
        var p = properties(url)
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation,
                    kCGImagePropertyDepth, kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            p[key] = nil
        }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            p[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            p[kCGImagePropertyExifDictionary] = exif
        }
        return p
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        guard let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError("Not enough memory for a \(width)×\(height) image")
        }
        ctx.interpolationQuality = .high
        return ctx
    }

    static func flattened(_ image: CGImage, on color: CGColor = CGColor(gray: 1, alpha: 1)) throws -> CGImage {
        let ctx = try context(width: image.width, height: image.height)
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        if width == image.width && height == image.height { return image }
        let ctx = try context(width: width, height: height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func cgImage(_ image: CIImage) throws -> CGImage {
        guard let cg = ci.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ToolError("Couldn't render the image")
        }
        return cg
    }

    static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.9, metadata: [CFString: Any] = [:]) throws -> Data {
        var image = image
        if format == .jpeg && hasAlpha(image) { image = try flattened(image) }
        if format == .webp { return try encodeWebP(image, quality: quality) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ToolError("This Mac can't write \(format.title) files")
        }
        var props = metadata
        props[kCGImagePropertyOrientation] = 1
        if format.lossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Couldn't save the \(format.title) file") }
        return data as Data
    }

    static func save(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double = 0.9, metadata: [CFString: Any] = [:]) throws {
        try encode(image, format: format, quality: quality, metadata: metadata).write(to: url, options: .atomic)
    }

    private static func encodeWebP(_ image: CGImage, quality: Double) throws -> Data {
        let cwebp = try Shell.require("cwebp")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"), out = dir.appendingPathComponent("out.webp")
        try encode(image, format: .png).write(to: png)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cwebp)
        p.arguments = ["-quiet", "-metadata", "none", "-q", String(Int(quality * 100)), png.path, "-o", out.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let data = try? Data(contentsOf: out) else { throw ToolError("cwebp couldn't write the WebP file") }
        return data
    }

    /// `photo.jpg` → `<folder>/photo<suffix>.<ext>`, never overwriting.
    static func outputURL(for input: URL, in folder: URL, suffix: String = "", ext: String) -> URL {
        Output.unique(folder.appendingPathComponent(input.baseName + suffix).appendingPathExtension(ext))
    }

    static func pngData(_ image: CGImage) -> Data? { try? encode(image, format: .png) }

    static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
