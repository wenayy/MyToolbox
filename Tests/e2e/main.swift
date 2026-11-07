import AppKit
import AVFoundation
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// End-to-end: runs every file tool's *real* processing code (pulled out of its view, exactly what the
// Run button calls) on media generated from scratch, then checks each result really opens.
//   swiftc -O -swift-version 5 -o .build/e2e $(find Sources/MyToolbox -name '*.swift' ! -name MyToolboxApp.swift) Tests/e2e/main.swift && .build/e2e

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0, passes = 0
func check(_ cond: Bool, _ name: String) {
    print(cond ? "✓ \(name)" : "✗ \(name)")
    if cond { passes += 1 } else { failures += 1 }
}
func spin(_ timeout: Double, until done: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}
func wait(_ timeout: Double = 300, _ body: @escaping @MainActor () async -> Void) {
    var finished = false
    Task { @MainActor in await body(); finished = true }
    spin(timeout) { finished }
    if !finished { print("✗ timed out after \(Int(timeout))s"); failures += 1 }
}
@discardableResult func sh(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("mytoolbox-e2e-\(UUID().uuidString.prefix(6))")
let inputs = root.appendingPathComponent("in put — ünïcode")
let out = root.appendingPathComponent("out")
try! FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
UserDefaults.standard.set(out.path, forKey: Output.rootKey)
let defaults = UserDefaults.standard
func url(_ name: String) -> URL { inputs.appendingPathComponent(name) }

// MARK: - Inputs, made from scratch

let ff = "/opt/homebrew/bin/ffmpeg"
func makeVideo(_ name: String, _ args: [String]) -> URL {
    let u = url(name)
    let r = sh(ff, ["-hide_banner", "-loglevel", "error", "-y"] + args + [u.path])
    if r.0 != 0 { print("could not make \(name): \(r.1)") }
    return u
}
let clip = makeVideo("Holiday clip — été 2026.mp4", ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                                                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
let silent = makeVideo("no audio.mov", ["-f", "lavfi", "-i", "testsrc=size=640x360:rate=25:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p"])
let vertical = makeVideo("vertical phone.mkv", ["-f", "lavfi", "-i", "smptebars=size=720x1280:rate=30:duration=2", "-f", "lavfi", "-i", "anoisesrc=d=2:a=0.1",
                                                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "libopus", "-shortest"])
let webm = makeVideo("web.webm", ["-f", "lavfi", "-i", "mandelbrot=size=320x240:rate=15", "-t", "2", "-c:v", "libvpx-vp9", "-b:v", "300k"])
let hevc = makeVideo("iphone hevc.mov", ["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=2", "-f", "lavfi", "-i", "sine=duration=2",
                                         "-c:v", "libx265", "-tag:v", "hvc1", "-x265-params", "log-level=error", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
let videos = [clip, silent, vertical, webm, hevc]

let speech = url("voice memo.aiff")
sh("/usr/bin/say", ["-o", speech.path, "Hello, this is a test of the toolbox audio tools."])
let mp3 = makeVideo("song.mp3", ["-f", "lavfi", "-i", "sine=frequency=330:duration=3", "-c:a", "libmp3lame", "-b:a", "192k"])
let flac = makeVideo("lossless.flac", ["-f", "lavfi", "-i", "sine=frequency=550:duration=2", "-c:a", "flac"])
let audios = [speech, mp3, flac]

func draw(_ w: Int, _ h: Int, alpha: Bool = false, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
    body(ctx)
    return ctx.makeImage()!
}
func text(_ s: String, _ size: CGFloat, at p: CGPoint, in c: CGContext, color: NSColor = .black) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color]).draw(at: p)
    NSGraphicsContext.restoreGraphicsState()
}
let photoImage = draw(3024, 4032) { c in
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1), CGColor(srgbRed: 1, green: 0.6, blue: 0.2, alpha: 1)] as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 3024, y: 4032), options: [])
    c.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1)); c.fillEllipse(in: CGRect(x: 600, y: 900, width: 1800, height: 1800))
}
// A "camera photo" with GPS, camera and date, written as JPEG with EXIF orientation 6.
let photo = url("IMG_0001.JPG")
do {
    let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, photoImage, [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:06:01 10:00:00"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"],
    ] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
let screenshot = url("Screenshot 2026-11-05 at 10.00.00.png")
try! ImageKit.save(draw(1440, 900) { c in
    c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 1440, height: 900))
    c.setFillColor(CGColor(gray: 0.93, alpha: 1)); c.fill(CGRect(x: 0, y: 820, width: 1440, height: 80))
    text("Account settings", 40, at: CGPoint(x: 60, y: 720), in: c)
    text("Email: someone@example.com", 28, at: CGPoint(x: 60, y: 620), in: c)
    text("Phone: +1 415 555 0134", 28, at: CGPoint(x: 60, y: 560), in: c)
    text("Card: 4242 4242 4242 4242", 28, at: CGPoint(x: 60, y: 500), in: c)
}, to: screenshot, format: .png)
let logo = url("logo transparent.png")
try! ImageKit.save(draw(800, 600, alpha: true) { c in
    c.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.3, alpha: 1)); c.fillEllipse(in: CGRect(x: 200, y: 100, width: 400, height: 400))
}, to: logo, format: .png)
let huge = url("huge panorama.png")
try! ImageKit.save(draw(9000, 3000) { c in c.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 9000, height: 3000)) }, to: huge, format: .png)
let pixel = url("1px.png")
try! ImageKit.save(draw(1, 1) { c in c.setFillColor(.black); c.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }, to: pixel, format: .png)
let heic = url("live.heic")
try! ImageKit.save(photoImage, to: heic, format: .heic)
let tiff = url("scan.tiff")
try! ImageKit.save(draw(1200, 800) { c in c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 800)) }, to: tiff, format: .tiff)
let gifImg = url("anim.gif")
sh(ff, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=200x150:rate=5:duration=1", gifImg.path])
let webp = url("sticker.webp")
try! ImageKit.save(draw(300, 300, alpha: true) { c in c.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 1)); c.fillEllipse(in: CGRect(x: 20, y: 20, width: 260, height: 260)) }, to: webp, format: .webp)
let paper = url("receipt photo.jpg")
try! ImageKit.save(draw(2000, 2600) { c in
    c.setFillColor(CGColor(gray: 0.25, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 2000, height: 2600))
    c.setFillColor(CGColor(gray: 0.97, alpha: 1)); c.fill(CGRect(x: 300, y: 300, width: 1400, height: 1950))
    text("RECEIPT 12345", 90, at: CGPoint(x: 420, y: 1900), in: c)
    text("Coffee 4.50", 70, at: CGPoint(x: 420, y: 1700), in: c)
}, to: paper, format: .jpeg)
let images = [photo, screenshot, logo, huge, pixel, heic, tiff, gifImg, webp, paper]

// PDFs: a 3-page text PDF, an image-only scan, and one with a picture to compress.
func makePDF(_ name: String, pages: [String], image: CGImage? = nil) -> URL {
    let u = url(name)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(u as CFURL, mediaBox: &box, nil)!
    for p in pages {
        ctx.beginPDFPage(nil)
        if let image { ctx.draw(image, in: CGRect(x: 56, y: 300, width: 500, height: 440)) }
        text(p, 22, at: CGPoint(x: 56, y: 200), in: ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return u
}
let report = makePDF("Quarterly report.pdf", pages: ["Page one: revenue grew.", "Page two: costs fell.", "Page three: outlook."])
let brochure = makePDF("brochure with photos.pdf", pages: ["Photo page A", "Photo page B"], image: photoImage)
let scanned = url("scanned letter.pdf")
try! DocKit.pdf(fromImages: [draw(1275, 1650) { c in
    c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 1275, height: 1650))
    text("Dear customer, invoice 98765 is due.", 40, at: CGPoint(x: 100, y: 1300), in: c)
}], pageSize: nil, margin: 0, ocr: false).write(to: scanned)
let pdfs = [report, brochure, scanned]

// Documents
let markdown = url("README notes.md")
try! "# Title\n\nSome **bold** text and a list:\n\n- one\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nprint(\"hi\")\n```\n".write(to: markdown, atomically: true, encoding: .utf8)
let plain = url("plain.txt")
try! String(repeating: "Line of plain text for paging.\n", count: 200).write(to: plain, atomically: true, encoding: .utf8)
let html = url("page.html")
try! "<html><body><h1>Hello</h1><p>A web page with <b>bold</b>.</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
let rtf = url("letter.rtf")
try! NSAttributedString(string: "A rich text letter.\n\nSincerely,").rtf(from: NSRange(location: 0, length: 27), documentAttributes: [:])!.write(to: rtf)
let docx = url("contract.docx")
sh("/usr/bin/textutil", ["-convert", "docx", "-output", docx.path, rtf.path])
let csv = url("budget.csv")
try! "Item,Cost\nRent,1200\nFood,400\n".write(to: csv, atomically: true, encoding: .utf8)
let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
sh(soffice, ["--headless", "--convert-to", "xlsx", "--outdir", inputs.path, csv.path])
let xlsx = url("budget.xlsx")
sh(soffice, ["--headless", "--infilter=impress_pdf_import", "--convert-to", "pptx", "--outdir", inputs.path, report.path])
let pptx = url("Quarterly report.pptx")
print("· inputs ready in \(inputs.path)")

// MARK: - Pull each tool's real processing closure out of its view

/// Builds the tool's view the way SwiftUI would (evaluating bodies down to the shared batch layout),
/// so the layout records the tool's Run action for the current options.
func expand<V: View>(_ v: V) -> Any? { V.Body.self == Never.self ? nil : v.body }
func build(_ value: Any, depth: Int = 0) {
    guard depth < 14 else { return }
    let mirror = Mirror(reflecting: value)
    let name = String(describing: type(of: value))
    if mirror.displayStyle == .class && !name.contains("AnyView") { return }
    if name.hasPrefix("BatchToolView<") || name.hasPrefix("CombineToolView<") { return }
    for c in mirror.children { build(c.value, depth: depth + 1) }
    if let v = value as? any View, let b = expand(v) { build(b, depth: depth + 1) }
}
@MainActor func process(_ id: String) -> BatchProcess? {
    guard let tool = ToolRegistry.all.first(where: { $0.id == id }) else { return nil }
    ToolActions.process[id] = nil
    build(tool.view())
    return ToolActions.process[id]
}
@MainActor func combine(_ id: String) -> (@MainActor ([URL]) async throws -> URL)? {
    guard let tool = ToolRegistry.all.first(where: { $0.id == id }) else { return nil }
    build(tool.view())
    return ToolActions.combine[id]
}

// MARK: - Validation

func probe(_ u: URL) -> (duration: Double, video: String?, audio: String?, width: Int, height: Int) {
    let r = sh("/opt/homebrew/bin/ffprobe", ["-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,width,height", "-of", "json", u.path])
    guard let json = try? JSONSerialization.jsonObject(with: Data(r.1.utf8)) as? [String: Any] else { return (0, nil, nil, 0, 0) }
    let streams = json["streams"] as? [[String: Any]] ?? []
    let v = streams.first { $0["codec_type"] as? String == "video" }
    let a = streams.first { $0["codec_type"] as? String == "audio" }
    let d = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
    return (d, v?["codec_name"] as? String, a?["codec_name"] as? String, v?["width"] as? Int ?? 0, v?["height"] as? Int ?? 0)
}
func opens(_ u: URL) -> String? {
    guard FileManager.default.fileExists(atPath: u.path) else { return "missing" }
    if u.isDirectory {
        let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
        if items.isEmpty { return "empty folder" }
        for i in items { if let e = opens(i) { return "\(i.lastPathComponent): \(e)" } }
        return nil
    }
    guard u.fileSize > 0 else { return "empty file" }
    let type = UTType(filenameExtension: u.pathExtension) ?? .data
    if type.conforms(to: .pdf) { return (PDFDocument(url: u)?.pageCount ?? 0) > 0 ? nil : "PDF won't open" }
    if type.conforms(to: .image) && u.pathExtension.lowercased() != "webp" { return (try? ImageKit.load(u)) == nil ? "image won't open" : nil }
    if type.conforms(to: .audiovisualContent) || ["webm", "mkv", "opus", "ogg", "flac", "webp"].contains(u.pathExtension.lowercased()) {
        let p = probe(u)
        return p.video == nil && p.audio == nil ? "no streams" : nil
    }
    if ["docx", "rtf", "odt", "html", "txt", "md"].contains(u.pathExtension.lowercased()) {
        return ((try? NSAttributedString(url: u, options: [:], documentAttributes: nil))?.length ?? 0) > 0 || u.fileSize > 20 ? nil : "unreadable"
    }
    return nil
}

/// Runs one tool on one file and checks the result. Returns the output (or nil when it errored).
@MainActor @discardableResult
func run(_ id: String, _ input: URL, _ label: String = "", expectError: Bool = false,
         validate: ((BatchOutput) -> String?)? = nil) async -> BatchOutput? {
    guard let p = process(id) else { check(false, "\(id): processing code found"); return nil }
    let name = "\(id) \(label.isEmpty ? "" : "[\(label)] ")← \(input.lastPathComponent)"
    var lastProgress = -1.0
    let started = Date()
    do {
        let r = try await p(input, out) { lastProgress = $0 }
        _ = lastProgress
        if expectError { check(false, "\(name): should have refused"); return r }
        if r.files.isEmpty {
            check(r.note != nil, "\(name): no file, says why — \(r.note ?? "nothing")")
            return r
        }
        let problem = r.files.compactMap(opens).first ?? validate?(r)
        check(problem == nil, "\(name) → \(r.files.map(\.lastPathComponent).joined(separator: ", ")) \(r.note ?? "") \(problem ?? "") (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
        return r
    } catch {
        let msg = error.localizedDescription
        check(expectError && !msg.isEmpty && !msg.contains("error 1.") && !msg.contains("Operation"), "\(name): \(expectError ? "refused clearly" : "FAILED") — \(msg.prefix(200))")
        return nil
    }
}

// MARK: - Video & audio

wait(1800) {
    for v in videos { await run("compressvideo", v) }
    for target in MediaArgs.VideoTarget.allCases {
        defaults.set(target.rawValue, forKey: "cv.target")
        for remux in [true, false] {
            defaults.set(remux, forKey: "cv.remux")
            for v in (remux ? videos : [clip, vertical]) {
                await run("convertvideo", v, "\(target.rawValue)\(remux ? "" : ", re-encode")") { r in
                    let p = probe(r.files[0])
                    return p.video == nil ? "no video stream" : p.duration < 1 ? "too short (\(p.duration)s)" : nil
                }
            }
        }
    }
    for v in videos { await run("gif", v) }
    for v in videos {
        await run("extractaudio", v, expectError: v == silent || v == webm)
    }
    for target in MediaArgs.AudioTarget.allCases {
        defaults.set(target.rawValue, forKey: "ca.target")
        for a in audios + [clip] { await run("convertaudio", a, target.rawValue) { r in probe(r.files[0]).audio == nil ? "no audio stream" : nil } }
    }
}

// MARK: - Images

wait(1800) {
    for format in ImageFormat.allCases {
        defaults.set(format.rawValue, forKey: "convert.format")
        for i in images { await run("convertimages", i, format.rawValue) }
    }
    for level in VideoQuality.allCases {
        defaults.set(level.rawValue, forKey: "cimg.quality")
        for i in images { await run("compressimages", i, level.rawValue) }
    }
    for mode in ImageJobs.ResizeMode.allCases {
        defaults.set(mode.rawValue, forKey: "resize.mode")
        for i in images { await run("resizeimages", i, mode.rawValue) }
    }
    for i in images { await run("rotateimages", i) }
    for i in images {
        await run("removemetadata", i) { r in
            let left = ImageJobs.metadataSummary(r.files[0]).map(\.0).joined(separator: ",")
            return left.contains("Location") || left.contains("GPS") ? "GPS still there: \(left)" : nil
        }
    }
    for i in images { await run("blurfaces", i) }
    for mode in 0...2 {
        defaults.set(mode, forKey: "bg.mode")
        for i in [photo, logo, screenshot, pixel] { await run("removebg", i, "mode \(mode)") }
    }
    for i in images { await run("beautify", i) }
    for f in ScanFilter.allCases {
        defaults.set(f.rawValue, forKey: "scan.filter")
        if let scan = combine("scan") {
            do {
                let u = try await scan([paper, screenshot])
                check(PDFDocument(url: u)?.pageCount == 2 && (PDFDocument(url: u)?.string ?? "").contains("RECEIPT"), "scan [\(f.rawValue)] → 2-page searchable PDF")
            } catch { check(false, "scan [\(f.rawValue)]: \(error.localizedDescription)") }
        } else { check(false, "scan: code found") }
    }
}

// MARK: - Documents

wait(1800) {
    for mode in ["each", "every", "ranges"] {
        defaults.set(mode, forKey: "split.mode")
        for p in pdfs { await run("split", p, mode) }
    }
    for level in VideoQuality.allCases {
        defaults.set(level.rawValue, forKey: "cpdf.level")
        for p in pdfs { await run("compresspdf", p, level.rawValue) }
    }
    for f in [ImageFormat.png, .jpeg, .heic, .tiff] {
        defaults.set(f.rawValue, forKey: "p2i.format")
        await run("pdf2images", report, f.rawValue)
    }
    for p in pdfs { await run("searchable", p) { r in (PDFDocument(url: r.files[0])?.string ?? "").isEmpty ? "no text layer" : nil } }
    for p in pdfs { await run("pdf2word", p) }
    for f in DocFormat.allCases {
        defaults.set(f.rawValue, forKey: "docs.format")
        for d in [markdown, plain, html, rtf, docx] { await run("convertdocs", d, f.rawValue) }
    }
    for d in [docx, rtf, plain, html] { await run("word2pdf", d) }
    await run("md2pdf", markdown)
    await run("ppt2pdf", pptx)
    await run("excel2pdf", xlsx)
    // Wrong kinds of file are refused with a message, not a crash.
    await run("compresspdf", photo, "not a PDF", expectError: true)
    await run("convertvideo", report, "not a video", expectError: true)
    await run("resizeimages", markdown, "not an image", expectError: true)

    if let merge = combine("merge") {
        do {
            let u = try await merge([report, photo, scanned, logo])
            check(PDFDocument(url: u)?.pageCount == 3 + 1 + 1 + 1, "merge PDFs + images → \(PDFDocument(url: u)?.pageCount ?? 0) pages")
        } catch { check(false, "merge: \(error.localizedDescription)") }
    } else { check(false, "merge: code found") }
    if let i2p = combine("img2pdf") {
        do {
            let u = try await i2p(images.filter { $0.pathExtension != "webp" || true })
            check(PDFDocument(url: u)?.pageCount == images.count, "images to PDF → \(PDFDocument(url: u)?.pageCount ?? 0) pages of \(images.count)")
        } catch { check(false, "images to PDF: \(error.localizedDescription)") }
    } else { check(false, "img2pdf: code found") }
}

// MARK: - Video & audio editing (1.1)

func near(_ a: Double, _ b: Double, _ tol: Double = 0.35) -> Bool { abs(a - b) <= tol }

wait(2400) {
    // Batch tools, driven through their real Run closures.
    for (preset, fit, expect) in [(ResizePreset.fhd, VideoEditArgs.Fit.fit, (1920, 1080)), (.vertical, .pad, (1080, 1920)),
                                  (.square, .fill, (1080, 1080)), (.hd, .fit, (1280, 720))] {
        defaults.set(preset.rawValue, forKey: "rv.preset"); defaults.set(fit.rawValue, forKey: "rv.fit"); defaults.set(true, forKey: "rv.keep")
        for v in [clip, vertical] {
            await run("resizevideo", v, "\(preset.rawValue), \(fit.rawValue)") { r in
                let p = probe(r.files[0])
                switch fit {
                case .pad, .fill: return p.width == expect.0 && p.height == expect.1 ? nil : "got \(p.width)×\(p.height)"
                case .fit: return p.width <= expect.0 && p.height <= expect.1 && p.width % 2 == 0 && p.height % 2 == 0 ? nil : "got \(p.width)×\(p.height)"
                }
            }
        }
    }
    defaults.set(ResizePreset.custom.rawValue, forKey: "rv.preset"); defaults.set(641, forKey: "rv.width"); defaults.set(361, forKey: "rv.height")
    defaults.set(false, forKey: "rv.keep")
    await run("resizevideo", webm, "custom odd 641×361 stretched") { r in let p = probe(r.files[0]); return p.width == 640 && p.height == 360 ? nil : "got \(p.width)×\(p.height)" }
    defaults.set(true, forKey: "rv.keep")

    for (speed, pitch) in [(2.0, true), (0.5, true), (4.0, false), (0.25, true)] {
        defaults.set(speed, forKey: "speed.value"); defaults.set(pitch, forKey: "speed.pitch"); defaults.set(false, forKey: "speed.mute")
        await run("speed", clip, "\(speed)× pitch \(pitch)") { r in
            let p = probe(r.files[0])
            return near(p.duration, 4 / speed, 0.25 + 0.1 / speed) && p.audio != nil ? nil : "length \(p.duration), audio \(p.audio ?? "none")"
        }
    }
    defaults.set(1.5, forKey: "speed.value"); defaults.set(true, forKey: "speed.mute")
    await run("speed", vertical, "1.5× muted") { r in probe(r.files[0]).audio == nil ? nil : "still has sound" }
    defaults.set(2.0, forKey: "speed.value"); defaults.set(false, forKey: "speed.mute")
    await run("speed", silent, "2× no sound track")
    await run("speed", webm, "2× webm")

    for (mode, format) in [(FrameMode.every, ImageFormat.png), (.evenly, .jpeg), (.single, .heic)] {
        defaults.set(mode.rawValue, forKey: "frames.mode"); defaults.set(format.rawValue, forKey: "frames.format")
        defaults.set(1.0, forKey: "frames.interval"); defaults.set(5, forKey: "frames.count"); defaults.set(1.5, forKey: "frames.at"); defaults.set(720, forKey: "frames.size")
        await run("frames", clip, "\(mode.rawValue) \(format.rawValue)") { r in
            let files = r.files[0].isDirectory ? (try? FileManager.default.contentsOfDirectory(at: r.files[0], includingPropertiesForKeys: nil)) ?? [] : r.files
            let expected = mode == .every ? 4...5 : mode == .evenly ? 5...5 : 1...1
            guard expected.contains(files.count) else { return "\(files.count) frames, expected \(expected)" }
            guard let img = try? ImageKit.load(files[0]), min(img.width, img.height) == 720 else { return "frame isn't 720p" }
            return files.allSatisfy { $0.pathExtension == format.ext } ? nil : "wrong format"
        }
    }
    defaults.set(0.5, forKey: "frames.interval"); defaults.set(FrameMode.every.rawValue, forKey: "frames.mode"); defaults.set(0, forKey: "frames.size")
    await run("frames", vertical, "every 0.5 s, original size")

    for v in [clip, vertical, hevc] {
        await run("mutevideo", v) { r in let p = probe(r.files[0]); return p.audio == nil && p.video != nil ? nil : "audio left or video lost" }
    }
    await run("mutevideo", silent, "already silent")

    defaults.set(mp3.path, forKey: "ra.audio")
    for (fit, vol) in [(AudioFit.loop, 0.0), (.once, 0.4)] {
        defaults.set(fit.rawValue, forKey: "ra.fit"); defaults.set(vol, forKey: "ra.original")
        for v in [clip, silent, vertical] {
            await run("replaceaudio", v, "\(fit.rawValue), original \(vol)") { r in
                let p = probe(r.files[0]), src = probe(v)
                return p.audio != nil && near(p.duration, src.duration) ? nil : "audio \(p.audio ?? "none"), \(p.duration)s vs \(src.duration)s"
            }
        }
    }
    defaults.set(speech.path, forKey: "ra.audio")
    await run("replaceaudio", hevc, "speech under HEVC")
    defaults.set(clip.path, forKey: "ra.audio")
    await run("replaceaudio", clip, "same file", expectError: true)

    // Burn subtitles from the matching .srt next to the video, in every style.
    try? "1\n00:00:00,500 --> 00:00:03,000\nHello, this is été ünïcode\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond line\n"
        .write(to: clip.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
    try? "WEBVTT\n\n00:00.200 --> 00:01.800\nVertical caption\n".write(to: url("vertical phone.en.vtt"), atomically: true, encoding: .utf8)
    defaults.set(SubtitleSource.file.rawValue, forKey: "subs.source")
    for look in VideoEditArgs.SubtitleStyle.Look.allCases {
        defaults.set(look.rawValue, forKey: "subs.look")
        await run("burnsubs", clip, look.rawValue) { r in probe(r.files[0]).duration > 3 ? nil : "too short" }
    }
    defaults.set(VideoEditArgs.SubtitleStyle.Position.top.rawValue, forKey: "subs.position"); defaults.set("Large", forKey: "subs.size")
    await run("burnsubs", vertical, "VTT, top, large")
    await run("burnsubs", hevc, "no subtitle file", expectError: true)
    if !CommandLine.arguments.contains("fast") {
        let talking = makeVideo("talking head.mp4", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25", "-i", speech.path, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
        defaults.set(SubtitleSource.transcribe.rawValue, forKey: "subs.source"); defaults.set(true, forKey: "subs.saveSRT")
        TranscribeModel.shared.localeID = "en_US"
        await run("burnsubs", talking, "transcribed") { r in
            r.files.count == 2 && (try? String(contentsOf: r.files[1], encoding: .utf8))?.lowercased().contains("test") == true ? nil : "no transcript saved: \(r.files.map(\.lastPathComponent))"
        }
        defaults.set(SubtitleSource.file.rawValue, forKey: "subs.source")
    }

    for strength in CleanStrength.allCases {
        defaults.set(strength.rawValue, forKey: "clean.strength")
        defaults.set(true, forKey: "clean.rumble"); defaults.set(strength == .strong, forKey: "clean.loudness"); defaults.set(strength != .light, forKey: "clean.silences")
        for f in [speech, mp3, flac, clip, vertical] {
            await run("cleanaudio", f, strength.rawValue) { r in
                let p = probe(r.files[0]), isVideo = probe(f).video != nil
                if p.audio == nil { return "no audio" }
                if isVideo && (p.video == nil || !near(p.duration, probe(f).duration, 0.2)) { return "video lost or out of sync" }
                return nil
            }
        }
    }
    await run("cleanaudio", silent, "no sound", expectError: true)

    // Single-file editors, through the same functions their buttons call.
    func edit(_ name: String, _ body: () async throws -> URL, validate: (URL) -> String?) async {
        do {
            let u = try await body()
            let problem = opens(u) ?? validate(u)
            check(problem == nil, "\(name) → \(u.lastPathComponent) \(problem ?? "")")
        } catch { check(false, "\(name): \(error.localizedDescription)") }
    }
    for v in [clip, vertical, webm, hevc] {
        for exact in [false, true] {
            await edit("trim \(v.lastPathComponent) 0.5–1.8 exact \(exact)", { try await MediaEdits.trimVideo(v, start: 0.5, end: 1.8, exact: exact) { _ in } }) { u in
                let d = probe(u).duration
                return d > 0.9 && d < 2.6 ? nil : "length \(d)"
            }
        }
    }
    do { _ = try await MediaEdits.trimVideo(clip, start: 1, end: 1.01, exact: false) { _ in }; check(false, "trim refuses an empty selection") }
    catch { check(true, "trim refuses an empty selection — \(error.localizedDescription)") }
    for a in audios {
        await edit("trim audio \(a.lastPathComponent) with fades", { try await MediaEdits.trimAudio(a, start: 0.2, end: 1.7, fadeIn: 0.5, fadeOut: 0.5) { _ in } }) { u in
            let p = probe(u)
            return near(p.duration, 1.5, 0.12) && u.pathExtension == AudioEncoding.forExtension(a.pathExtension).ext ? nil : "\(p.duration)s .\(u.pathExtension)"
        }
    }
    for (rect, turns, fh, fv, expect) in [(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), 0, false, false, (640, 360)),
                                          (CGRect(x: 0, y: 0, width: 1, height: 1), 1, false, false, (720, 1280)),
                                          (CGRect(x: 0.1, y: 0, width: 0.5625 * 0.8, height: 0.8), 2, true, true, (576, 576)),
                                          (CGRect(x: 0, y: 0, width: 1, height: 1), 0, true, false, (1280, 720))] {
        await edit("crop \(rect) turns \(turns) flip \(fh)/\(fv)", {
            try await MediaEdits.crop(clip, rect: rect, source: CGSize(width: 1280, height: 720), quarterTurns: turns, flipH: fh, flipV: fv, format: .same) { _ in }
        }) { u in
            let p = probe(u)
            return abs(p.width - expect.0) <= 2 && abs(p.height - expect.1) <= 2 ? nil : "got \(p.width)×\(p.height), expected \(expect.0)×\(expect.1)"
        }
    }
    do {
        _ = try await MediaEdits.crop(clip, rect: CGRect(x: 0, y: 0, width: 1, height: 1), source: CGSize(width: 1280, height: 720), quarterTurns: 4, flipH: false, flipV: false, format: .same) { _ in }
        check(false, "crop refuses when nothing changes")
    } catch { check(true, "crop refuses when nothing changes — \(error.localizedDescription)") }
    for size in MediaEdits.MergeSize.allCases where size != .uhd {
        await edit("merge 4 mixed clips at \(size.rawValue)", { try await MediaEdits.merge([clip, vertical, silent, webm], size: size, name: "Merged \(size.rawValue)") }) { u in
            let p = probe(u)
            let want = size == .sd ? (1280, 720) : size == .hd ? (1920, 1080) : (1280, 720)
            return near(p.duration, 10, 0.5) && p.audio != nil && p.width == want.0 && p.height == want.1 ? nil : "\(p.duration)s \(p.width)×\(p.height) audio \(p.audio ?? "none")"
        }
    }
    await edit("merge vertical first → vertical frame", { try await MediaEdits.merge([vertical, clip], size: .hd, name: "Merged vertical") }) { u in
        let p = probe(u); return p.width == 1080 && p.height == 1920 ? nil : "\(p.width)×\(p.height)"
    }

    // Media Info
    for f in videos + audios {
        do {
            let p = try await MediaProbe.read(f)
            let text = MediaReport.text(f, p)
            check(text.contains("Duration") && (p.video == nil || text.contains("Resolution")) && (p.audio == nil || text.contains("Sample rate")),
                  "media info \(f.lastPathComponent): \(MediaReport.sections(f, p).count) sections")
        } catch { check(false, "media info \(f.lastPathComponent): \(error.localizedDescription)") }
    }
    let located = url("located.mov")
    sh(ff, ["-hide_banner", "-loglevel", "error", "-y", "-i", clip.path, "-c", "copy", "-movflags", "use_metadata_tags",
            "-metadata", "com.apple.quicktime.location.ISO6709=+48.8584+002.2945+035.000/", "-metadata", "com.apple.quicktime.make=Apple", located.path])
    if let p = try? await MediaProbe.read(located), let loc = MediaReport.location(p) {
        check(near(loc.lat, 48.8584, 0.001) && near(loc.lon, 2.2945, 0.001), "media info reads the recording location")
    } else { check(false, "media info reads the recording location") }
}

// MARK: - Crop PDF, Organize Downloads, units (1.1)

wait(600) {
    for (size, scope) in [(PDFCropSize.label, PDFCropScope.all), (.free, .trimEach), (.a6, .shown)] {
        do {
            let doc = try DocKit.open(report)
            let page = doc.page(at: 0)!
            let rect = PDFCrop.fixedRect(size, page: page) ?? CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
            let out = try PDFCrop.crop(report, rect: rect, scope: scope, shownPage: 1)
            let cropped = PDFDocument(url: out)!
            let b0 = cropped.page(at: 0)!.bounds(for: .mediaBox), b1 = cropped.page(at: 1)!.bounds(for: .mediaBox)
            let ok: Bool
            switch scope {
            case .all: ok = b0.width == 288 && b0.height == 432 && b0 == b1
            case .trimEach: ok = b0.width < 612 && b0.height < 792 && b0.width > 50 && cropped.pageCount == 3
            case .shown: ok = b0.width == 612 && b1.width < 612
            }
            check(ok, "crop PDF \(size.rawValue), \(scope.rawValue) → page 1 \(Int(b0.width))×\(Int(b0.height)), page 2 \(Int(b1.width))×\(Int(b1.height))")
        } catch { check(false, "crop PDF \(size.rawValue): \(error.localizedDescription)") }
    }
    // A rotated page maps back to the right part of the unrotated page.
    if let doc = PDFDocument(url: report), let page = doc.page(at: 0) {
        page.rotation = 90
        let r = PDFCrop.boxRect(CGRect(x: 0, y: 0, width: 0.5, height: 1), page: page)
        check(r == CGRect(x: 0, y: 0, width: 612, height: 396), "crop PDF maps a rotated page: \(r)")
    }

    // Where-from metadata → sources.
    let dl = root.appendingPathComponent("downloads")
    try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
    func download(_ name: String, from: [String]) {
        let f = dl.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: logo, to: f)
        if !from.isEmpty, let data = try? PropertyListSerialization.data(fromPropertyList: from, format: .binary, options: 0) {
            _ = data.withUnsafeBytes { setxattr(f.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, data.count, 0, 0) }
        }
    }
    download("tweet.png", from: ["https://pbs.twimg.com/media/abc.png", "https://x.com/someone/status/1"])
    download("pin.png", from: ["https://i.pinimg.com/originals/x.png"])
    download("blog.png", from: ["https://cdn.example.org/a.png", "https://www.example.com/post"])
    download("mystery.png", from: [])
    let rules = DownloadSources.defaults
    let src = { (n: String) in DownloadSources.source(DownloadSources.whereFroms(dl.appendingPathComponent(n)), rules: rules) }
    check(src("tweet.png") == "X" && src("pin.png") == "Pinterest" && src("blog.png") == "example.com" && src("mystery.png") == nil,
          "organize downloads reads Where From: \(src("tweet.png") ?? "-"), \(src("pin.png") ?? "-"), \(src("blog.png") ?? "-"), \(src("mystery.png") ?? "none")")
    do {
        let found = try OrganizeModel.items(in: dl, rules: rules)
        let plan = found.compactMap { i in Organizer.destination(i, by: .site, includeRest: true).map { (i.url, $0) } }
        _ = try Organizer.move(plan, into: dl)
    } catch { check(false, "organize downloads: \(error.localizedDescription)") }
    let made = Set(((try? FileManager.default.contentsOfDirectory(atPath: dl.path)) ?? []))
    check(made.isSuperset(of: ["X", "Pinterest", "example.com", "Unknown"]) && !made.contains("tweet.png"), "organize downloads moves into folders: \(made.sorted())")

    // Small pure pieces.
    check(VideoEditArgs.atempoChain(4) == "atempo=2,atempo=2.0000" && VideoEditArgs.atempoChain(0.25) == "atempo=0.5,atempo=0.5000", "atempo chains: \(VideoEditArgs.atempoChain(0.25))")
    check(TimecodeField.parse("1:02.5") == 62.5 && TimecodeField.parse("83") == 83 && TimecodeField.parse("1:00:00") == 3600 && TimecodeField.parse("x") == nil
          && TimecodeField.format(62.5) == "1:02.500" && TimecodeField.format(3723.25) == "1:02:03.250"
          && TimecodeField.parse(TimecodeField.format(83.125)) == 83.125, "timecode fields parse and format: \(TimecodeField.format(62.5))")
    check(RecordResolution.p1080.size(points: CGSize(width: 1512, height: 982), scale: 2) == CGSize(width: 1662, height: 1080)
          && RecordResolution.native.size(points: CGSize(width: 1512, height: 982), scale: 2) == CGSize(width: 3024, height: 1964), "screen recording sizes")
    check(AudioEncoding.forExtension("AIFF").ext == "aiff" && AudioEncoding.forExtension("wma").ext == "m4a", "audio keeps its format, unknown → M4A")
    check(CropEditor.centered(aspect: 1, picture: CGSize(width: 1920, height: 1080)).width - 0.5625 < 0.001, "square crop on 16:9 is centred")
}

// MARK: - Live previews (1.1)

/// Runs a tool's live preview the way the pane does and returns what it would show.
@MainActor func livePreview(_ id: String, _ file: URL, start: ((URL) async -> Double?)? = nil) async -> LivePreviewModel? {
    guard let p = process(id) else { check(false, "\(id): processing code found"); return nil }
    let model = LivePreviewModel.for("e2e-\(id)-\(UUID().uuidString.prefix(4))")
    let render: @MainActor (URL, URL) async throws -> URL = { input, folder in try LivePreview.showable(try await p(input, folder) { _ in }) }
    await model.run(source: file, excerpt: true, preferredStart: start, render: render)
    if model.phase == .idle { await model.run(source: file, excerpt: true, preferredStart: start, render: render) }   // start moved: run again
    return model
}

func meanBottomDifference(_ a: CGImage, _ b: CGImage) -> Double {
    let w = 160, h = 90
    func pixels(_ i: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }
    let pa = pixels(a), pb = pixels(b)
    var sum = 0.0
    for y in (h * 3 / 4)..<h { for x in 0..<w { let i = (y * w + x) * 4; sum += Double(abs(Int(pa[i]) - Int(pb[i]))) } }
    return sum / Double(w * h / 4)
}

wait(900) {
    @MainActor func ready(_ m: LivePreviewModel?, _ name: String, _ validate: (URL) -> String? = { _ in nil }) {
        guard let m else { return }
        guard m.phase == .ready, let after = m.after, let before = m.before else { check(false, "preview \(name): \(m.phase)"); return }
        let problem = opens(after) ?? validate(after)
        check(problem == nil, "preview \(name) → \(after.lastPathComponent) (before \(before.lastPathComponent)) \(problem ?? "")")
    }
    defaults.set(2.0, forKey: "speed.value"); defaults.set(true, forKey: "speed.pitch"); defaults.set(false, forKey: "speed.mute")
    ready(await livePreview("speed", clip), "speed 2×") { near(probe($0).duration, 2, 0.3) ? nil : "length \(probe($0).duration)" }
    defaults.set(1.0, forKey: "speed.value")
    if let m = await livePreview("speed", clip) { check(m.phase == .note("Speed is 1× — nothing to change"), "preview explains when nothing would change: \(m.phase)") }
    defaults.set(2.0, forKey: "speed.value")
    defaults.set(ResizePreset.vertical.rawValue, forKey: "rv.preset"); defaults.set(VideoEditArgs.Fit.pad.rawValue, forKey: "rv.fit"); defaults.set(true, forKey: "rv.keep")
    ready(await livePreview("resizevideo", clip), "resize vertical bars") { let p = probe($0); return p.width == 1080 && p.height == 1920 ? nil : "\(p.width)×\(p.height)" }
    defaults.set(VideoQuality.small.rawValue, forKey: "cv.quality")
    ready(await livePreview("compressvideo", hevc), "compress")
    defaults.set(MediaArgs.VideoTarget.webm.rawValue, forKey: "cv.target"); defaults.set(false, forKey: "cv.remux")
    ready(await livePreview("convertvideo", clip), "convert to WebM, played as MP4") { $0.pathExtension == "mp4" ? nil : "not converted for playback" }
    ready(await livePreview("gif", vertical), "GIF") { $0.pathExtension == "gif" ? nil : "not a GIF" }
    defaults.set(MediaArgs.AudioTarget.ogg.rawValue, forKey: "ca.target")
    ready(await livePreview("convertaudio", flac), "OGG, playable here") { u in
        let a = AVURLAsset(url: u)
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        Task.detached { ok = (try? await a.load(.isPlayable)) == true; sem.signal() }
        sem.wait()
        return ok ? nil : "not playable"
    }
    defaults.set(MediaArgs.AudioTarget.mp3.rawValue, forKey: "ea.target")
    ready(await livePreview("extractaudio", clip), "extract audio") { probe($0).video == nil ? nil : "still has picture" }
    defaults.set(CleanStrength.strong.rawValue, forKey: "clean.strength"); defaults.set(true, forKey: "clean.loudness")
    ready(await livePreview("cleanaudio", speech), "clean up voice")
    ready(await livePreview("cleanaudio", clip), "clean up video sound") { probe($0).video != nil ? nil : "picture lost" }
    defaults.set(mp3.path, forKey: "ra.audio"); defaults.set(0.3, forKey: "ra.original")
    ready(await livePreview("replaceaudio", vertical), "replace audio")

    // Subtitles from the file next to the video, previewed from later in the video, stay lined up.
    defaults.set(SubtitleSource.file.rawValue, forKey: "subs.source"); defaults.set(VideoEditArgs.SubtitleStyle.Position.bottom.rawValue, forKey: "subs.position")
    defaults.set(VideoEditArgs.SubtitleStyle.Look.box.rawValue, forKey: "subs.look")
    let srt = clip.deletingPathExtension().appendingPathExtension("srt")
    check(SubtitleFiles.firstCue(srt) == 0.5, "preview starts at the first subtitle: \(SubtitleFiles.firstCue(srt) ?? -1)")
    let subsModel = await livePreview("burnsubs", clip) { _ in 1.0 }
    ready(subsModel, "burn subtitles from 0:01")
    if let m = subsModel, let a = m.after, let b = m.before,
       let fa = try? await VideoFrame.grab(a, at: 0.5, maxSize: 640), let fb = try? await VideoFrame.grab(b, at: 0.5, maxSize: 640) {
        let d = meanBottomDifference(fa, fb)
        check(m.start == 1.0 && d > 8, "preview draws the caption due at 0:01.5 (bottom changed by \(Int(d)))")
    } else { check(false, "preview subtitle frames") }

    // Crop and merge previews go through the same functions as their Export / Merge buttons.
    let cropModel = LivePreviewModel.for("e2e-crop")
    await cropModel.run(source: clip, excerpt: true, preferredStart: nil) { input, folder in
        let p = try await MediaProbe.read(input)
        return try await MediaEdits.crop(input, rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1), source: p.displaySize, quarterTurns: 1,
                                         flipH: false, flipV: false, format: .same, folder: folder) { _ in }
    }
    ready(cropModel, "crop half, turned") { let p = probe($0); return p.width == 720 && p.height == 640 ? nil : "\(p.width)×\(p.height)" }
    if let render = combine("mergevideos") {
        _ = render
        let mergeModel = LivePreviewModel.for("e2e-merge")
        await mergeModel.run(source: clip, excerpt: false, preferredStart: nil) { _, folder in
            var pieces: [URL] = []
            for u in [clip, vertical, silent] { pieces.append(try await LivePreview.excerpt(u, start: 0, length: 3, video: true)) }
            return try await MediaEdits.merge(pieces, size: .sd, name: "Merged Video", folder: folder)
        }
        ready(mergeModel, "merge 3 clips") { near(probe($0).duration, 7, 0.5) ? nil : "length \(probe($0).duration)" }
    }
    // Trim Audio's "Hear Result" renders the same file Trim saves, into the preview folder.
    if let u = try? await MediaEdits.trimAudio(mp3, start: 0.2, end: 2, fadeIn: 0.5, fadeOut: 0.5, folder: LivePreview.newFolder()) { _ in } {
        check(u.path.hasPrefix(LivePreview.dir.path) && near(probe(u).duration, 1.8, 0.1), "hear trimmed audio before saving")
    } else { check(false, "hear trimmed audio before saving") }
    let opus = url("voice.opus"); try? Data().write(to: opus)
    check(ToolRegistry.tool("gif")!.accepts(vertical) && BatchRun.matches(vertical, [.movie, .video]) && BatchRun.matches(opus, [.audio])
          && ToolRegistry.tool("cleanaudio")!.accepts(opus), "MKV and Opus files are taken by video and audio tools")
    check(FrameExtractor.times(mode: .every, duration: 4, interval: 1, count: 0, at: 0) == [0, 1, 2, 3]
          && FrameExtractor.times(mode: .evenly, duration: 4, interval: 0, count: 2, at: 0) == [1, 3], "frame tiles show the right moments")
}

// MARK: - Organize by kind, automatic sorting, Keep Awake, recording (1.2)

@MainActor func until(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    return cond()
}
func setPlistXattr(_ url: URL, _ name: String, _ value: Any) {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return }
    _ = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
}

wait(600) {
    // Kinds.
    let kinds = root.appendingPathComponent("kinds")
    try? FileManager.default.createDirectory(at: kinds, withIntermediateDirectories: true)
    func touch(_ name: String, bytes: Int = 10) -> URL {
        let u = kinds.appendingPathComponent(name)
        try? Data(repeating: 65, count: bytes).write(to: u)
        return u
    }
    let marked = touch("IMG_2044.png")
    setPlistXattr(marked, "com.apple.metadata:kMDItemIsScreenCapture", true)
    let expect: [(String, FileKind)] = [
        ("Screenshot 2026-11-07 at 10.00.00.png", .screenshots), ("IMG_2044.png", .screenshots), ("holiday.jpg", .images), ("live.heic", .images),
        ("clip.mp4", .videos), ("show.mkv", .videos), ("Screen Recording 2026-11-07.mov", .videos), ("song.mp3", .audio), ("voice.opus", .audio),
        ("invoice.pdf", .pdfs), ("letter.docx", .documents), ("notes.txt", .documents), ("essay.pages", .documents), ("budget.xlsx", .spreadsheets),
        ("data.csv", .spreadsheets), ("deck.pptx", .presentations), ("talk.key", .presentations), ("photos.zip", .archives), ("src.tar.gz", .archives),
        ("bundle.7z", .archives), ("App.dmg", .installers), ("Setup.pkg", .installers), ("thing.xyz", .other),
    ]
    let wrong = expect.filter { name, kind in
        let u = name == "IMG_2044.png" ? marked : touch(name)
        return FileKind.of(u) != kind
    }
    // Files whose names don't say what they are are recognised by their contents.
    func copyAs(_ src: URL, _ name: String) -> URL { let u = kinds.appendingPathComponent(name); try? FileManager.default.copyItem(at: src, to: u); return u }
    let sniffed: [(URL, FileKind)] = [(copyAs(photo, "1ab329ee-fc5b-4f00"), .images), (copyAs(logo, "3bGWo_19.jpg_small"), .images),
                                      (copyAs(clip, "download"), .videos), (copyAs(vertical, "vid-noext"), .videos), (copyAs(mp3, "track"), .audio),
                                      (copyAs(flac, "lossless-noext"), .audio), (copyAs(report, "statement"), .pdfs), (copyAs(docx, "contract-noext"), .archives),
                                      (copyAs(heic, "IMG_9"), .images), (touch("mystery-noext"), .other)]
    let missed = sniffed.filter { FileKind.of($0.0) != $0.1 }.map { "\($0.0.lastPathComponent)→\(FileKind.of($0.0).rawValue)" }
    check(missed.isEmpty, "files without a telling name are sorted by their contents \(missed)")
    check(wrong.isEmpty, "organize sorts \(expect.count) kinds of file correctly \(wrong.map { "\($0.0)→\(FileKind.of(kinds.appendingPathComponent($0.0)).rawValue)" })")

    // What counts as a finished file.
    let dl = root.appendingPathComponent("dl2")
    try? FileManager.default.createDirectory(at: dl.appendingPathComponent("Old folder"), withIntermediateDirectories: true)
    func put(_ name: String, bytes: Int = 10) { try? Data(repeating: 66, count: bytes).write(to: dl.appendingPathComponent(name)) }
    put("done.pdf"); put("half.mp4.crdownload"); put("film.mkv", bytes: 0); put("film.mkv.part"); put(".hidden.png"); put("empty.txt", bytes: 0)
    put("Report.pdf")
    try? FileManager.default.createDirectory(at: dl.appendingPathComponent("Safari.zip.download"), withIntermediateDirectories: true)
    let names = (try? Organizer.candidates(in: dl).map(\.lastPathComponent)) ?? []
    check(names == ["done.pdf", "Report.pdf"], "only finished, visible files are sorted: \(names)")
    check(((try? Organizer.candidates(in: dl, settle: 60)) ?? [dl]).isEmpty, "files written moments ago wait until they settle")

    // Move, collisions and Undo.
    try? FileManager.default.createDirectory(at: dl.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
    try? Data("old".utf8).write(to: dl.appendingPathComponent("PDFs/done.pdf"))
    let items = (try? OrganizeModel.items(in: dl, rules: DownloadSources.defaults)) ?? []
    let plan = items.compactMap { i in Organizer.destination(i, by: .kind, includeRest: false).map { (i.url, $0) } }
    let moves = (try? Organizer.move(plan, into: dl)) ?? []
    let fm = FileManager.default
    check(moves.count == 2 && fm.fileExists(atPath: dl.appendingPathComponent("PDFs/done 2.pdf").path)
          && (try? String(contentsOf: dl.appendingPathComponent("PDFs/done.pdf"), encoding: .utf8)) == "old",
          "organize never overwrites: \(moves.map(\.to.lastPathComponent))")
    check(Organizer.undo(moves) == 2 && fm.fileExists(atPath: dl.appendingPathComponent("done.pdf").path)
          && fm.fileExists(atPath: dl.appendingPathComponent("Report.pdf").path), "Undo puts files back")

    // Automatic sorting on a live folder.
    let watched = root.appendingPathComponent("watched")
    try? fm.createDirectory(at: watched, withIntermediateDirectories: true)
    defaults.set(OrganizeBy.kind.rawValue, forKey: "organize.by"); defaults.set(false, forKey: "organize.unknown")
    let watcher = DownloadsWatcher.shared
    watcher.settle = 0.5
    watcher.start(watched)
    try? Data(repeating: 1, count: 100).write(to: watched.appendingPathComponent("invoice.pdf"))
    let pdfMoved = await until(10) { fm.fileExists(atPath: watched.appendingPathComponent("PDFs/invoice.pdf").path) }
    check(pdfMoved, "a new download is sorted automatically (invoice.pdf → PDFs)")
    try? Data(repeating: 1, count: 100).write(to: watched.appendingPathComponent("movie.mp4.crdownload"))
    try? Data(repeating: 1, count: 100).write(to: watched.appendingPathComponent("thing.xyz"))
    try? await Task.sleep(for: .seconds(3))
    check(fm.fileExists(atPath: watched.appendingPathComponent("movie.mp4.crdownload").path) && fm.fileExists(atPath: watched.appendingPathComponent("thing.xyz").path),
          "downloads in progress and unknown files are left alone")
    try? fm.moveItem(at: watched.appendingPathComponent("movie.mp4.crdownload"), to: watched.appendingPathComponent("movie.mp4"))
    let movieMoved = await until(10) { fm.fileExists(atPath: watched.appendingPathComponent("Videos/movie.mp4").path) }
    check(movieMoved, "a finished download is sorted once its name is final (movie.mp4 → Videos)")
    let shot = watched.appendingPathComponent("Screenshot 2026-11-07 at 22.00.00.png")
    try! ImageKit.save(draw(40, 30) { c in c.setFillColor(.black); c.fill(CGRect(x: 0, y: 0, width: 40, height: 30)) }, to: shot, format: .png)
    let shotMoved = await until(10) { fm.fileExists(atPath: watched.appendingPathComponent("Screenshots/Screenshot 2026-11-07 at 22.00.00.png").path) }
    check(shotMoved, "screenshots go to Screenshots")
    watcher.stop()
    watcher.settle = 3

    // Keep Awake.
    let k = KeepAwake.shared
    check(KeepAwake.shouldEnd(.forTime(60), deadline: Date().addingTimeInterval(10), idle: 0, appRunning: true, now: Date()) == false
          && KeepAwake.shouldEnd(.forTime(60), deadline: Date().addingTimeInterval(-1), idle: 0, appRunning: true, now: Date())
          && KeepAwake.shouldEnd(.untilAway(900), deadline: nil, idle: 899, appRunning: true, now: Date()) == false
          && KeepAwake.shouldEnd(.untilAway(900), deadline: nil, idle: 900, appRunning: true, now: Date())
          && KeepAwake.shouldEnd(.whileAppOpen(bundleID: "x", name: "X"), deadline: nil, idle: 0, appRunning: false, now: Date())
          && KeepAwake.shouldEnd(.indefinitely, deadline: nil, idle: 99_999, appRunning: false, now: Date()) == false,
          "Keep Awake ends only when its condition is met")
    func assertionHeld() -> Bool { sh("/usr/bin/pmset", ["-g", "assertions"]).1.contains(KeepAwake.assertionName) }
    k.start(.forTime(3))
    check(k.active && assertionHeld(), "Keep Awake holds a power assertion while on")
    k.extend(by: 2)
    let deadlineLeft = k.deadline.map { $0.timeIntervalSinceNow } ?? 0
    check(deadlineLeft > 3.5 && deadlineLeft < 5.5, "+15-style extension moves the end (\(String(format: "%.1f", deadlineLeft)) s left)")
    let ended = await until(10) { !k.active }
    check(ended && !assertionHeld(), "a timed session ends by itself and lets the Mac sleep normally again")
    var fakeIdle = 0.0
    k.idleSeconds = { fakeIdle }
    k.start(.untilAway(60))
    k.check()
    check(k.active, "until-away keeps going while the Mac is in use")
    fakeIdle = 61
    k.check()
    check(!k.active && !assertionHeld(), "until-away ends once nobody has used the Mac for the chosen time")
    var appOpen = true
    k.appIsRunning = { _ in appOpen }
    k.start(.whileAppOpen(bundleID: "com.example.render", name: "Render"))
    k.check()
    let stillOn = k.active
    appOpen = false
    k.check()
    check(stillOn && !k.active, "while-app-open ends when the app quits")
    k.idleSeconds = KeepAwake.systemIdleSeconds
    k.appIsRunning = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    check(KeepAwake.systemIdleSeconds() >= 0, "reads how long the Mac has been idle")

    // Recording plumbing (the microphone itself needs a person and permission).
    // Voice processing hands over several channels with a layout, as here.
    let fmt3 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!)
    let src = AVAudioPCMBuffer(pcmFormat: fmt3, frameCapacity: 4)!
    src.frameLength = 4
    for ch in 0..<3 { for i in 0..<4 { src.floatChannelData![ch][i] = Float(ch + 1) } }
    let stereo = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!, frameCapacity: 4)!
    MicRecorder.copyChannels(from: src, to: stereo, voiceOnly: true)
    let voiceBoth = stereo.floatChannelData![0][0] == 1 && stereo.floatChannelData![1][0] == 1
    MicRecorder.copyChannels(from: src, to: stereo, voiceOnly: false)
    check(voiceBoth && stereo.floatChannelData![0][0] == 1 && stereo.floatChannelData![1][0] == 2, "microphone channels are routed right (voice on both sides with noise reduction)")
    check(MicRecorder.level(src) == 1, "level meter reads full scale")
    check((MicRecorder.settings(for: "m4a", sampleRate: 96_000, channels: 1)[AVSampleRateKey] as? Double) == 48_000, "AAC recordings stay at 48 kHz with 96 kHz mics")
    check(AudioInputs.deviceID(forUID: "no-such-microphone") == nil, "an unplugged microphone is reported as missing")
    _ = AudioInputs.all()

    // Real microphone recordings, only when this Mac already allows it (never prompts). Deleted right after.
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
        for (vp, ext, stereo, delayed) in [(false, "m4a", false, false), (true, "m4a", false, false), (true, "wav", true, false), (true, "caf", false, true)] {
            let u = root.appendingPathComponent("mic test \(vp) \(stereo).\(ext)")
            do {
                let r = try MicRecorder(url: u, options: .init(voiceProcessing: vp, stereo: stereo), writeImmediately: !delayed)
                var levels = 0
                r.onLevel = { _ in levels += 1 }
                try r.start()
                if delayed { try? await Task.sleep(for: .seconds(0.5)); r.beginWriting() }
                try? await Task.sleep(for: .seconds(1.5))
                let d = r.stop()
                let p = probe(u)
                check(d > 1.2 && d < 1.8 && near(p.duration, d, 0.15) && levels > 5,
                      "records the microphone (\(vp ? "noise reduction" : "plain"), \(ext)\(stereo ? ", stereo" : "")\(delayed ? ", started with the video" : "")): \(String(format: "%.2f", d)) s, \(p.audio ?? "no audio")")
            } catch { check(false, "microphone recording (\(vp)): \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: u)
        }
    } else {
        print("· microphone not allowed for this process — live recording not tested")
    }

    let micFile = root.appendingPathComponent("mic.caf")
    sh(ff, ["-hide_banner", "-loglevel", "error", "-y", "-i", speech.path, "-c:a", "pcm_f32le", micFile.path])
    for (name, source) in [("with system audio", clip), ("silent screen", silent)] {
        let screen = root.appendingPathComponent("Screen Recording \(name).mov")
        try? fm.removeItem(at: screen)
        try? fm.copyItem(at: source, to: screen)
        do {
            try await ScreenRecorder.mixMicrophone(into: screen, mic: micFile)
            let p = probe(screen), q = probe(source)
            check(p.audio == "aac" && p.video == q.video && near(p.duration, q.duration, 0.15),
                  "voice is mixed into the screen recording (\(name)): \(p.video ?? "-")/\(p.audio ?? "-") \(String(format: "%.2f", p.duration)) s")
        } catch { check(false, "voice mix (\(name)): \(error.localizedDescription)") }
    }
}

// MARK: - Every tool opens

wait(120) {
    for tool in ToolRegistry.all {
        let v = NSHostingView(rootView: tool.view().frame(width: 1000, height: 700))
        v.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        v.layoutSubtreeIfNeeded()
        check(v.fittingSize.width > 0, "\(tool.id) builds its view")
    }
}

print("\n\(passes) passed, \(failures) failed — inputs and results in \(root.path)")
exit(failures == 0 ? 0 : 1)
