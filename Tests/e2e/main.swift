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
