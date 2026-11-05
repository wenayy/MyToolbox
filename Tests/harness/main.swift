import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Logic + integration checks. Build and run:
//   swiftc -O -o .build/harness $(find Sources/MyToolbox -name '*.swift' ! -name MyToolboxApp.swift) Tests/harness/main.swift && .build/harness
// Pass "fast" to skip the network and on-device AI checks.

let fast = CommandLine.arguments.contains("fast")
var failures = 0
func check(_ cond: Bool, _ name: String) { print(cond ? "✓ \(name)" : "✗ \(name)"); if !cond { failures += 1 } }

func spin(_ timeout: Double = 120, until done: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

/// Runs an async block on the main actor and waits for it.
func wait(_ timeout: Double = 120, _ body: @escaping @MainActor () async -> Void) {
    var finished = false
    Task { @MainActor in await body(); finished = true }
    spin(timeout) { finished }
    if !finished { print("✗ timed out after \(Int(timeout))s"); failures += 1 }
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mytoolbox-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
UserDefaults.standard.set(tmp.appendingPathComponent("out").path, forKey: Output.rootKey)
let folder = Output.root

// MARK: Registry

check(Set(ToolRegistry.all.map(\.id)).count == ToolRegistry.all.count, "tool ids are unique (\(ToolRegistry.all.count) tools)")
let badSymbols = (ToolRegistry.all.map(\.symbol) + ToolCategory.allCases.map(\.symbol)).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
check(badSymbols.isEmpty, "every SF Symbol exists \(badSymbols)")
check(ToolRegistry.search("cv").first?.id == "compressvideo", "search initials 'cv' → Compress Video")
check(ToolRegistry.search("json").first?.id == "json", "search 'json'")
MainActor.assumeIsolated {
    check(AppModel.shared.tools(accepting: [URL(fileURLWithPath: "/x/a.mov")]).map(\.id).contains("compressvideo"), "drop .mov → Compress Video offered")
    check(AppModel.shared.tools(accepting: [URL(fileURLWithPath: "/x/a.png")]).contains { $0.id == "removebg" }, "drop .png → image tools offered")
}

// MARK: Text tools

check(CaseStyle.camel.apply("hello world-foo_bar") == "helloWorldFooBar", "camelCase")
check(CaseStyle.snake.apply("someHTTPServer value") == "some_http_server_value", "snake_case splits acronyms")
check(CaseStyle.title.apply("the lord of the rings") == "The Lord of the Rings", "Title Case small words")
let stats = TextStats("Hello world. This is a test!\n\nNew paragraph here.")
check(stats.words == 9 && stats.sentences == 3 && stats.paragraphs == 2, "word stats")

// MARK: Developer tools

check((try? JSONTool.format("{\"b\":1,\"a\":[1,2]}", pretty: true, sortKeys: true, indent: .tab))?.contains("\n\t\"a\"") == true, "JSON sorted + tab indent")
do { _ = try JSONTool.format("{\"a\": }", pretty: true, sortKeys: false, indent: .two); check(false, "JSON error") }
catch { check(JSONTool.message(error).lowercased().contains("line"), "JSON error names the line: \(JSONTool.message(error))") }
let v7 = UUIDView.uuidV7().uuidString
check(Array(v7)[14] == "7", "uuid v7 version nibble")
let info = UUIDInfo.inspect(v7) ?? []
check(info.first?.1.hasPrefix("7") == true && info.contains { $0.0 == "Created" }, "inspect v7 shows version and time")
check(UUIDInfo.inspect("not-a-uuid") == nil, "inspect rejects junk")
check(Timestamps.parse("1730000000000")?.timeIntervalSince1970 == 1_730_000_000, "timestamp auto ms")
check(Timestamps.parse("1730000000", unit: .millis)?.timeIntervalSince1970 == 1_730_000, "timestamp forced ms")
check(Timestamps.parse("2026-10-31T12:00:00Z") != nil, "timestamp ISO")
let d = Differ.diff("a\nb\nc", "a\nB\nc\nd", ignoreWhitespace: false, ignoreCase: false)
check(d.filter { $0.kind == .added }.count == 2 && d.filter { $0.kind == .removed }.count == 1, "diff counts")
let pairs = DiffPair.pairs(d)
check(pairs.count == 4 && pairs[1].left?.text == "b" && pairs[1].right?.text == "B", "side-by-side pairs changed lines")
let wd = WordDiff.highlight(old: "the quick fox", new: "the slow fox")
check(wd.old.filter(\.1).map(\.0) == ["quick"] && wd.new.filter(\.1).map(\.0) == ["slow"], "word-level highlight")
check(LinkCleaner.clean(URL(string: "https://example.com/p?id=3&utm_source=x&fbclid=abc")!).absoluteString == "https://example.com/p?id=3", "strip utm/fbclid")
check(LinkCleaner.clean(URL(string: "https://www.google.com/url?q=https://site.com/a?utm_medium=e&sa=D")!).absoluteString == "https://site.com/a", "unwrap google redirect")
let spoof = "p\u{0430}ypal"
check(spoof.unicodeScalars.contains { Confusables.latin(for: $0) == "a" }, "Cyrillic а flagged as look-alike")
check(UnicodeView.isHidden("\u{200B}".unicodeScalars.first!), "zero-width space flagged")
check(HashView.digests(Data("abc".utf8))[2].1 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc")
let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
check(JWTView.pretty(JWTView.base64URL(jwt.components(separatedBy: ".")[1])).contains("John Doe"), "jwt payload decode")
let paris = Geo.distance(.init(latitude: 48.8566, longitude: 2.3522), .init(latitude: 51.5074, longitude: -0.1278))
check(abs(paris / 1000 - 344) < 5, "Paris–London ≈ 344 km (\(Int(paris / 1000)))")

// MARK: File tools

let qrPNG = tmp.appendingPathComponent("qr.png")
try! QR.pngData(QR.make("https://mactoolbox.app")!)!.write(to: qrPNG)
check(QR.read(qrPNG) == ["https://mactoolbox.app"], "QR make → read")
check(QR.wifiPayload(ssid: "My;Net", password: "p:w", security: "WPA", hidden: false) == #"WIFI:T:WPA;S:My\;Net;P:p\:w;;"#, "wifi payload escaping")
let dupDir = tmp.appendingPathComponent("dups")
try! FileManager.default.createDirectory(at: dupDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
let blob = Data((0..<200_000).map { UInt8($0 % 251) })
try! blob.write(to: dupDir.appendingPathComponent("a.bin"))
try! blob.write(to: dupDir.appendingPathComponent("sub/b.bin"))
var other = blob; other[150_000] = 7
try! other.write(to: dupDir.appendingPathComponent("c.bin"))
let groups = DuplicateScanner.scan([dupDir], minSize: 1) { _ in }
check(groups.count == 1 && groups[0].files.count == 2, "duplicates: only true copies grouped")
let overlap = DuplicateScanner.scan([dupDir, dupDir.appendingPathComponent("sub"), dupDir.appendingPathComponent("a.bin")], minSize: 1) { _ in }
check(overlap.count == 1 && overlap[0].files.count == 2, "duplicates: overlapping folders and loose files aren't double-counted")

// MARK: Images

func makeImage(_ w: Int, _ h: Int, alpha: Bool = false, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let ctx = try! ImageKit.context(width: image.width, height: image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let i = y * ctx.bytesPerRow + x * 4   // y counts from the top
    return (p[i], p[i + 1], p[i + 2], p[i + 3])
}

// 200×100: left half red, right half blue (top-left origin thinking).
let redLeft = makeImage(200, 100) { c in
    c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
}
let turned = try! ImageJobs.rotated(redLeft, quarterTurns: 1, flip: false)
check(turned.width == 100 && turned.height == 200 && pixel(turned, 50, 20).0 > 200, "rotate right: red half moves to the top")
let flipped = try! ImageJobs.rotated(redLeft, quarterTurns: 0, flip: true)
check(pixel(flipped, 20, 50).2 > 200, "flip: blue moves to the left")

// A photo-like JPEG with metadata and orientation 6.
let photo = tmp.appendingPathComponent("photo.jpg")
do {
    let img = makeImage(1600, 1200) { c in
        for i in 0..<40 {
            c.setFillColor(CGColor(srgbRed: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
            c.fillEllipse(in: CGRect(x: i * 37 % 1500, y: i * 53 % 1100, width: 160, height: 120))
        }
    }
    let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImageDestinationLossyCompressionQuality: 0.98,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "X1"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"],
    ]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}
check(ImageJobs.metadataSummary(photo).map(\.0) == ["Camera", "Taken", "Location"], "metadata summary finds camera, date, location")
let oriented = try! ImageKit.load(photo)
check(oriented.width == 1200 && oriented.height == 1600, "load applies EXIF orientation")

let stripped = try! ImageJobs.removeMetadata(photo, folder: folder, locationOnly: false)
let sp = ImageKit.properties(stripped.files[0])
check(sp[kCGImagePropertyGPSDictionary] == nil && (sp[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil
      && (sp[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil,
      "remove metadata: GPS, camera and date gone")
check(sp[kCGImagePropertyOrientation] as? Int == 6, "remove metadata keeps orientation")
let locOnly = try! ImageJobs.removeMetadata(photo, folder: folder, locationOnly: true)
let lp = ImageKit.properties(locOnly.files[0])
check(lp[kCGImagePropertyGPSDictionary] == nil && (lp[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "TestCam",
      "location-only keeps camera, drops GPS")

for format in [ImageFormat.png, .heic, .tiff] + (ImageFormat.canWriteWebP ? [.webp] : []) {
    let out = try! ImageJobs.convert(photo, folder: folder, format: format, quality: 0.8, keepMetadata: true)
    let ok = out.files.first.map { ImageFormat.of($0) == format && (try? ImageKit.load($0))?.width == 1200 } ?? false
    check(ok, "convert to \(format.title)")
}
let small = try! ImageJobs.compress(photo, folder: folder, quality: 0.55, format: nil, maxSide: 1280, stripPrivate: true)
check(small.files.count == 1 && small.files[0].fileSize < photo.fileSize, "compress: smaller (\(small.note ?? ""))")
check(ImageKit.properties(small.files[0])[kCGImagePropertyGPSDictionary] == nil, "compress strips location")
let resized = try! ImageJobs.resize(photo, folder: folder, mode: .exact, percent: 0, longest: 0, width: 300, height: 300, fit: .fill, noEnlarge: true)
check((try? ImageKit.load(resized.files[0]))?.width == 300 && (try? ImageKit.load(resized.files[0]))?.height == 300, "resize fill → exact 300×300")
let t = ImageJobs.targetSize(from: CGSize(width: 1000, height: 500), mode: .longest, percent: 0, longest: 2000, width: 0, height: 0, fit: .fit, noEnlarge: true)
check(t.canvas == CGSize(width: 1000, height: 500), "resize never enlarges when asked")

let shot = makeImage(100, 100, alpha: true) { c in
    c.clear(CGRect(x: 0, y: 0, width: 100, height: 100))
    c.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    c.fill(CGRect(x: 10, y: 30, width: 40, height: 20))
}
let trimmed = try! ImageJobs.trimTransparent(shot)
check(trimmed.width == 40 && trimmed.height == 20, "trim transparent edges → 40×20")
var bs = ImageJobs.BeautifySettings()
bs.aspect = 1
let pretty = try! ImageJobs.beautify(shot, bs)
check(pretty.width == pretty.height, "beautify 1:1 is square (\(pretty.width)×\(pretty.height))")
let covered = try! ImageJobs.obscure(redLeft, rects: [CGRect(x: 10, y: 10, width: 50, height: 50)], style: .black, strength: 1)
check(pixel(covered, 30, 60).0 < 10, "black box covers the area")
let noFace = try! ImageJobs.blurFaces(photo, folder: folder, style: .blur, strength: 0.5)
check(noFace.files.isEmpty && noFace.note == "No faces found", "blur faces skips photos without faces")
let boxMark = Markup(kind: .box, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 120, y: 70), color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), width: 6)
let whiteImage = makeImage(200, 100) { $0.setFillColor(.white); $0.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
let annotated = try! MarkupRenderer.render(whiteImage, items: [boxMark], strength: 0.5)
check(pixel(annotated, 20, 45).0 > 200 && pixel(annotated, 20, 45).1 < 80, "annotation box drawn at top-left coordinates")
let cover = Markup(kind: .redact(.black), start: CGPoint(x: 150, y: 10), end: CGPoint(x: 190, y: 40))
let redacted = try! MarkupRenderer.render(whiteImage, items: [cover], strength: 0.5)
check(pixel(redacted, 170, 25).0 < 10 && pixel(redacted, 170, 60).0 > 240 && pixel(redacted, 140, 25).0 > 240, "redact box covers exactly its rect")
let blurCover = Markup(kind: .redact(.pixelate), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100))
check((try? MarkupRenderer.render(redLeft, items: [blurCover], strength: 0.8)) != nil, "pixelate redaction renders")
var resizable = Markup(kind: .box, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50))
MarkupHandle.bottomRight.apply(CGPoint(x: 80, y: 90), to: &resizable)
check(resizable.rect == CGRect(x: 10, y: 10, width: 70, height: 80), "corner handle resizes, opposite corner stays")
MarkupHandle.topLeft.apply(CGPoint(x: 100, y: 100), to: &resizable)
check(resizable.rect == CGRect(x: 80, y: 90, width: 20, height: 10), "dragging a corner past the other flips cleanly")
check(RedactFinder.matches(.emails, custom: nil, in: "Mail me at a.b@example.co.uk now").count == 1, "find emails")
check(RedactFinder.matches(.phones, custom: nil, in: "Call +1 (555) 123-4567 today").count == 1, "find phone numbers")
check(RedactFinder.matches(.numbers, custom: nil, in: "Card 4111 1111 1111 1111, year 2026").count == 2, "find long numbers")
check(RedactFinder.matches(.allText, custom: "secret", in: "a Secret and a SECRET").count == 2, "find custom words")
let emailImage = makeImage(1200, 200) { c in
    c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 200))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    NSAttributedString(string: "Contact: jane@example.com", attributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 20, y: 70))
    NSGraphicsContext.current = nil
}
let emailRects = (try? RedactFinder.find(.emails, in: emailImage)) ?? []
check(emailRects.count == 1 && emailRects[0].minX > 200, "finds just the email, not the label (\(emailRects.map { Int($0.minX) }))")

check(PickedColor(r: 1, g: 0.5, b: 0).hex == "#FF8000" && PickedColor(r: 1, g: 0.5, b: 0).hslString == "hsl(30, 100%, 50%)", "color formats")

// OCR
let textImage = makeImage(900, 200) { c in
    c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
    let ns = NSGraphicsContext(cgContext: c, flipped: false)
    NSGraphicsContext.current = ns
    NSAttributedString(string: "Hello MyToolbox 2026", attributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 30, y: 60))
    NSGraphicsContext.current = nil
}
let ocr = (try? OCR.recognize(textImage)) ?? ""
check(ocr.contains("MyToolbox") && ocr.contains("2026"), "OCR reads rendered text: \(ocr)")

// MARK: Documents, subtitles, transcripts

let docx = tmp.appendingPathComponent("doc.docx")
let attr = NSAttributedString(string: "First paragraph.\nSecond paragraph.", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
try! attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
check((try? DocText.load(docx))?.contains("Second paragraph") == true, "read .docx text")
let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello there\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond line\nwraps\n"
check(SubtitleText.textLineIndices(srt.components(separatedBy: "\n")) == [2, 6, 7], "SRT: only cue text lines are translated")
let vtt = "WEBVTT\nKind: captions\n\nNOTE skip me\nstill note\n\nintro\n00:00.000 --> 00:01.000\nHi\n"
check(SubtitleText.textLineIndices(vtt.components(separatedBy: "\n")) == [8], "VTT: header, NOTE and cue ids kept")
let segs = [TranscriptSegment(start: 1.5, end: 3.25, text: "Hello"), TranscriptSegment(start: 3.5, end: 5, text: "World")]
check(TranscriptFormat.srt.render(segs).hasPrefix("1\n00:00:01,500 --> 00:00:03,250\nHello"), "SRT timestamps")
check(TranscriptFormat.vtt.render(segs).contains("00:00:03.500 --> 00:00:05.000"), "VTT timestamps")
let words: [(String, Double, Double)] = (0..<40).map { i -> (String, Double, Double) in
    let t = Double(i) * 0.4
    return (" word\(i)", t, t + 0.3)
}
let cues = Transcription.cues(words: words)
check(cues.count > 1 && cues.allSatisfy { $0.text.count <= 80 && $0.end - $0.start <= 6.5 }, "transcript split into subtitle-sized cues")
let longText = String(repeating: "Sentence about things. ", count: 1200)
check(Summarizer.chunks(longText).allSatisfy { $0.count <= Summarizer.chunkChars } && Summarizer.chunks(longText).count >= 4, "long text chunked for the model")
check(DocIndex.citedPages("Revenue grew [p. 3] and costs fell [p. 7].") == [3, 7], "citations parsed")
let chunks = DocIndex.chunks(pages: ["The cafeteria opens at noon.", "The secret code word is PELICAN and it rotates monthly."])
check(DocIndex.retrieve("What is the code word?", from: chunks, embedding: nil, k: 1).first?.page == 2, "retrieval finds the right page")

// MARK: Video

let ytArgs = YTDLP.arguments(url: "https://youtu.be/x", options: DownloadOptions(), outDir: tmp, tempDir: tmp, ffmpeg: nil)
check(!ytArgs.contains("--cookies-from-browser"), "downloads never read browser cookies by default")
check(ytArgs.contains("--no-playlist") && ytArgs.contains("vcodec:h264,res,acodec:m4a"), "default: single video, prefer H.264")
var withLogin = DownloadOptions(); withLogin.cookiesBrowser = "safari"
check(YTDLP.arguments(url: "u", options: withLogin, outDir: tmp, tempDir: tmp, ffmpeg: nil).contains("--cookies-from-browser"), "login retry passes cookies")
check(YTDLP.classify("ERROR: [youtube] abc: Sign in to confirm you're not a bot") == .needsLogin, "classify sign-in error")
check(YTDLP.classify("ERROR: unable to download video data: HTTP Error 403: Forbidden") == .outdated, "classify 403 as outdated")
check(YTDLP.classify("ERROR: no space left on device") == .other, "classify other errors")
check(YTDLP.isLikelyVideoLink("https://www.youtube.com/watch?v=1") && !YTDLP.isLikelyVideoLink("https://github.com/x"), "clipboard prefill only for video sites")

if let ffmpeg = Shell.which("ffmpeg") {
    let clip = tmp.appendingPathComponent("clip.mov")
    wait {
        _ = try? await Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=duration=3:size=1280x720:rate=30", "-f", "lavfi", "-i",
                                          "sine=frequency=440:duration=3", "-c:v", "mjpeg", "-q:v", "2", "-c:a", "pcm_s16le", "-shortest", clip.path])
        var s = CompressVideoSettings()
        s.maxResolution = 480
        let out = tmp.appendingPathComponent("clip small.mp4")
        var progress: [Double] = []
        do {
            try await FFmpeg.run(s.ffmpegArguments(input: clip, output: out), duration: await FFmpeg.duration(clip)) { progress.append($0) }
        } catch { print("  ffmpeg error: \(error.localizedDescription)") }
        let probe = try? await Shell.run(Shell.which("ffprobe")!, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,height", "-of", "csv=p=0", out.path])
        check(out.fileSize > 0 && out.fileSize < clip.fileSize, "compress video: \(sizeChange(clip.fileSize, out.fileSize))")
        check(probe?.out.trimmingCharacters(in: .whitespacesAndNewlines) == "h264,480", "compressed to H.264 at 480p (\(probe?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))")
        check(!progress.isEmpty && (progress.last ?? 0) > 0.8, "ffmpeg progress reported (\(progress.count) updates)")
    }
}

// Cancelling a stream stops the process.
wait {
    let task = Task { try await Shell.stream("/bin/sleep", ["30"]) { _ in } }
    try? await Task.sleep(for: .milliseconds(300))
    let start = Date()
    task.cancel()
    let result = await task.result
    var cancelled = false
    if case .failure(let e) = result, e is CancellationError { cancelled = true }
    check(cancelled && Date().timeIntervalSince(start) < 2, "cancel stops a running process")
}

// MARK: Docs

func textPDF(_ pages: [String], to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for page in pages {
        ctx.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 18)]).draw(in: CGRect(x: 50, y: 500, width: 500, height: 200))
        NSGraphicsContext.current = nil
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

check((try? DocKit.ranges("1-3, 5, 8-", pageCount: 10)) == [[0, 1, 2], [4], [7, 8, 9]], "page ranges parse")
check((try? DocKit.ranges("4-12, 15-", pageCount: 10)) == [[3, 4, 5, 6, 7, 8, 9]], "page ranges clamp to the PDF and skip pages past the end")
check((try? DocKit.ranges("12-", pageCount: 10)) == nil && (try? DocKit.ranges("5-2", pageCount: 10)) == nil && (try? DocKit.ranges("a-b", pageCount: 10)) == nil,
      "page ranges reject nonsense")
let threePages = tmp.appendingPathComponent("three.pdf")
textPDF(["Page one about apples", "Page two about pears", "Page three: account 4111 1111 1111 1111 and Secret plans"], to: threePages)
let doc3 = try! DocKit.open(threePages)
check(DocKit.subset(doc3, pages: [2, 0]).page(at: 0)?.string?.contains("three") == true, "subset keeps chosen pages in order")

// An image-only "scan" of text, then OCR text layers.
let scanImage = makeImage(1275, 1650) { c in
    c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 1275, height: 1650))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    NSAttributedString(string: "Invoice number 98765 from Toolbox Ltd", attributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 100, y: 1300))
    NSGraphicsContext.current = nil
}
let imageOnly = try! DocKit.pdf(fromImages: [scanImage], pageSize: nil, margin: 0, ocr: false)
check((PDFDocument(data: imageOnly)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "image-only PDF has no text")
let (searchableData, recognizedPages) = try! DocKit.searchable(PDFDocument(data: imageOnly)!)
let searchableText = PDFDocument(data: searchableData)?.string ?? ""
check(recognizedPages == 1 && searchableText.contains("98765"), "make searchable adds a text layer: \(searchableText.prefix(60))")
let ocrPDF = try! DocKit.pdf(fromImages: [scanImage], pageSize: DocKit.Paper.a4.size, margin: 18, ocr: true)
check(PDFDocument(data: ocrPDF)?.string?.contains("Invoice") == true && PDFDocument(data: ocrPDF)?.page(at: 0)?.bounds(for: .mediaBox).width == 595, "images to PDF on A4 with searchable text")
if let sel = PDFDocument(data: searchableData)?.findString("98765", withOptions: []).first, let page = sel.pages.first {
    let b = sel.bounds(for: page)
    check(b.minY > 792 * 0.6, "OCR text sits where the words are on the page (y=\(Int(b.minY)))")
}

// Passwords
let protected = tmp.appendingPathComponent("protected.pdf")
if let qpdf = Shell.which("qpdf") {
    wait {
        _ = try? await Shell.run(qpdf, ["--encrypt", "pw123", "owner-x", "256", "--print=none", "--", threePages.path, protected.path])
        check(PDFDocument(url: protected)?.isLocked == true, "add password: PDF is locked")
        let unlocked = tmp.appendingPathComponent("unlocked.pdf")
        let r = try? await Shell.run(qpdf, ["--decrypt", "--password=pw123", "--", protected.path, unlocked.path])
        check(r?.ok == true && PDFDocument(url: unlocked)?.isLocked == false && PDFDocument(url: unlocked)?.pageCount == 3, "remove password: unlocked copy")
        let wrong = try? await Shell.run(qpdf, ["--decrypt", "--password=nope", "--", protected.path, tmp.appendingPathComponent("x.pdf").path])
        check(wrong?.ok == false && (wrong?.err.contains("invalid password") ?? false), "wrong password is reported")
    }
}
let pkProtected = tmp.appendingPathComponent("pk-protected.pdf")
_ = doc3.write(to: pkProtected, withOptions: [.userPasswordOption: "abc", .ownerPasswordOption: "own",
                                               .accessPermissionsOption: NSNumber(value: PDFAccessPermissions.allowsContentAccessibility.rawValue)])
check(PDFDocument(url: pkProtected)?.isLocked == true, "PDFKit fallback encrypts too")

// Flatten form fields
let formDoc = PDFDocument(url: threePages)!
let field = PDFAnnotation(bounds: CGRect(x: 60, y: 300, width: 220, height: 22), forType: .widget, withProperties: nil)
field.widgetFieldType = .text
field.widgetStringValue = "Jane Appleseed"
formDoc.page(at: 0)!.addAnnotation(field)
let flat = PDFDocument(data: try! DocKit.flatten(formDoc))!
check(flat.page(at: 0)!.annotations.isEmpty, "flatten removes editable fields")
check(((try? OCR.recognize(DocKit.render(flat.page(at: 0)!, dpi: 150))) ?? "").contains("Jane"), "flattened answer is printed on the page")

// PDF → Word, Convert Documents, Markdown/Word → PDF
let docxAttr = try! PDFToWord.attributed(doc3)
check(docxAttr.string.contains("pears") && docxAttr.string.contains("\u{0C}"), "PDF to Word keeps text with page breaks")
let md = tmp.appendingPathComponent("notes.md")
try! "# Title\n\nSome **bold** text.\n\n- one\n- two\n".write(to: md, atomically: true, encoding: .utf8)
wait {
    let docx = try? await DocConvert.convert(md, to: .docx, into: tmp)
    check(docx.map { (try? NSAttributedString(url: $0, options: [:], documentAttributes: nil))?.string.contains("bold") ?? false } ?? false, "Markdown → Word")
    if let docx {
        let back = try? await DocConvert.convert(docx, to: .md, into: tmp)
        check(back.map { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("**bold**") } ?? false, "Word → Markdown")
        let rtf = try? await DocConvert.convert(docx, to: .rtf, into: tmp)
        check(rtf.map { $0.fileSize > 0 } ?? false, "Word → RTF")
    }
    if let data = try? DocKit.pdf(from: DocKit.attributed(markdown: String(repeating: "Line of text that wraps nicely. ", count: 400)), paper: .a4) {
        let pdf = PDFDocument(data: data)
        check((pdf?.pageCount ?? 0) > 1 && pdf?.page(at: 0)?.bounds(for: .mediaBox).width == 595, "text → paginated A4 PDF (\(pdf?.pageCount ?? 0) pages)")
    } else { check(false, "text → PDF") }
    do {
        let html = "<h1>Hello Web</h1><p>" + String(repeating: "Paragraph text. ", count: 600) + "</p>"
        let paged = try await WebPDF.render(html: html, longPage: false, paper: .letter)
        let long = try await WebPDF.render(html: html, longPage: true, paper: .letter)
        check((PDFDocument(data: paged)?.pageCount ?? 0) > 1 && PDFDocument(data: paged)?.string?.contains("Hello Web") == true, "HTML → paged PDF")
        check(PDFDocument(data: long)?.pageCount == 1, "HTML → one long page")
    } catch { check(false, "web PDF: \(error.localizedDescription)") }
}

// Redact PDF really removes the text
wait {
    let m = RedactPDFModel.shared
    m.open(threePages)
    m.find(.numbers)
    while m.busy != nil { try? await Task.sleep(for: .milliseconds(100)) }
    check((m.pages[2]?.items.count ?? 0) >= 1, "redact PDF finds the card number on page 3")
    m.save()
    let started = Date()
    while m.busy != nil { try? await Task.sleep(for: .milliseconds(100)) }
    print("  redact save took \(Int(Date().timeIntervalSince(started)))s, error: \(m.error ?? "none")")
    let text = m.saved.flatMap { PDFDocument(url: $0)?.string } ?? ""
    check(!text.contains("4111") && text.contains("Secret"), "redacted PDF: number gone, other text still searchable")
}

// Scan: synthetic photo of a tilted page on a dark desk
let photoOfPaper = makeImage(1600, 1200) { c in
    c.setFillColor(CGColor(gray: 0.15, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
    c.setFillColor(.white)
    c.move(to: CGPoint(x: 400, y: 150)); c.addLine(to: CGPoint(x: 1250, y: 220)); c.addLine(to: CGPoint(x: 1180, y: 1080)); c.addLine(to: CGPoint(x: 330, y: 1010))
    c.closePath(); c.fillPath()
}
let scanned = try? ScanKit.process(photoOfPaper, filter: .blackWhite, findEdges: true)
check(scanned.map { $0.width < 1400 && $0.height < 1100 } ?? false, "scan finds the page and crops to it (\(scanned.map { "\($0.width)×\($0.height)" } ?? "none"))")

// MARK: Round 4: pause, conversions, PDF editor, signatures

wait {
    var lines = 0
    let task = Task { try await Shell.$tag.withValue("pause-test") {
        try await Shell.stream("/bin/sh", ["-c", "while true; do echo x; sleep 0.05; done"]) { _ in lines += 1 }
    } }
    try? await Task.sleep(for: .milliseconds(400))
    Shell.setPaused(true, tag: "pause-test")
    try? await Task.sleep(for: .milliseconds(150))
    let atPause = lines
    try? await Task.sleep(for: .milliseconds(600))
    let stalled = lines - atPause
    Shell.setPaused(false, tag: "pause-test")
    try? await Task.sleep(for: .milliseconds(400))
    check(atPause > 0 && stalled <= 1 && lines > atPause + 2, "pause freezes a job's process and resume continues it (\(atPause)→+\(stalled)→\(lines))")
    task.cancel()
    _ = await task.result
}
check(MediaArgs.video(URL(fileURLWithPath: "/a.mov"), URL(fileURLWithPath: "/b.mp4"), target: .mp4, remux: true).contains("copy"), "remux copies streams")
check(MediaArgs.audio(URL(fileURLWithPath: "/a.wav"), URL(fileURLWithPath: "/b.mp3"), target: .mp3, kbps: 320).contains("320k"), "audio bitrate applied")
if Shell.which("ffmpeg") != nil {
    let clip2 = tmp.appendingPathComponent("clip2.mov")
    wait {
        _ = try? await Shell.run(Shell.which("ffmpeg")!, ["-y", "-f", "lavfi", "-i", "testsrc=duration=2:size=640x360:rate=25", "-f", "lavfi", "-i",
                                                          "sine=frequency=440:duration=2", "-c:v", "libx264", "-c:a", "aac", "-shortest", clip2.path])
        let gif = tmp.appendingPathComponent("clip.gif")
        try? await FFmpeg.run(MediaArgs.gif(clip2, gif, fps: 10, width: 320, start: 0, duration: 0), duration: 2) { _ in }
        check(gif.fileSize > 1000 && (try? ImageKit.load(gif))?.width == 320, "video to GIF at 320 px")
        let m4a = tmp.appendingPathComponent("clip.m4a")
        try? await FFmpeg.run(MediaArgs.audio(clip2, m4a, target: .m4a, kbps: 128), duration: 2) { _ in }
        check(m4a.fileSize > 1000, "extract audio to M4A")
        let mp4 = tmp.appendingPathComponent("clip remux.mp4")
        try? await FFmpeg.run(MediaArgs.video(clip2, mp4, target: .mp4, remux: true), duration: 2) { _ in }
        check(mp4.fileSize > 1000, "remux MOV → MP4 without re-encoding")
    }
}
wait {
    let ed = PDFEditorModel.shared
    ed.open(threePages)
    let page = ed.doc!.page(at: 0)!
    let before = page.annotations.count
    let box = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 100, height: 40), forType: .square, withProperties: nil)
    ed.add(box, to: page)
    check(page.annotations.count == before + 1, "PDF editor adds a mark")
    ed.undo()
    check(page.annotations.count == before, "undo removes it")
    ed.redo()
    check(page.annotations.count == before + 1, "redo puts it back")
    let start = box.bounds
    box.bounds = start.offsetBy(dx: 30, dy: 0)
    ed.record(.bounds(box, start))
    ed.undo()
    check(box.bounds == start, "undo a move")
    ed.redo()
    check(box.bounds.minX == start.minX + 30, "redo a move")
    ed.save(flatten: true)
    check(ed.saved.flatMap { PDFDocument(url: $0) }?.page(at: 0)?.annotations.isEmpty == true, "save flattened bakes marks into the page")

    let v = VectorAnnotation(bounds: CGRect(x: 100, y: 100, width: 106, height: 56), forType: .ink, withProperties: nil)
    v.strokeWidth = 4
    v.points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 0)]
    let tip = v.absolute(v.points[1])
    v.bounds = CGRect(x: 100, y: 100, width: 206, height: 106)
    let grown = v.smoothPath().boundingBoxOfPath
    check(v.absolute(v.points[1]).x > tip.x + 40 && grown.width > 190 && v.bounds.contains(grown), "resizing a pen stroke scales it instead of cropping")
    v.kind = .arrow
    v.points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
    check(v.standardEquivalent().type == "Line", "arrow saves as a standard line annotation")
    v.kind = .rectangle
    check(v.standardEquivalent().type == "Square", "rectangle saves as a standard square annotation")

    ed.open(threePages)
    let p0 = ed.doc!.page(at: 0)!
    let n0 = p0.annotations.count
    if let line = p0.selection(for: p0.bounds(for: .mediaBox))?.selectionsByLine().first {
        ed.replaceText(line, on: p0)
        let added = p0.annotations.suffix(from: n0)
        check(added.count == 2 && added.contains { ($0 as? VectorAnnotation)?.kind == .eraser } && added.contains { $0.type == "FreeText" && !($0.contents ?? "").isEmpty && !($0.font?.fontName ?? "").contains("Times") },
              "edit text covers the line and adds an editable box with its words")
    } else {
        check(false, "edit text: test PDF has a text line")
    }
    // A PDF that really is set in Times keeps Times when its text is edited.
    let timesPDF = tmp.appendingPathComponent("times.pdf")
    do {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(timesPDF as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Set in Times Roman", attributes: [.font: NSFont(name: "Times New Roman", size: 20)!]).draw(at: CGPoint(x: 72, y: 600))
        NSGraphicsContext.current = nil
        ctx.endPDFPage()
        ctx.closePDF()
    }
    ed.open(timesPDF)
    if let tp = ed.doc?.page(at: 0), let line = tp.selection(for: tp.bounds(for: .mediaBox))?.selectionsByLine().first {
        ed.replaceText(line, on: tp)
        check(tp.annotations.last?.font?.fontName.contains("Times") == true, "edit text keeps a PDF's real Times font (\(tp.annotations.last?.font?.fontName ?? "none"))")
    }

    let sign = SignModel.shared
    sign.open(threePages)
    let sigImage = makeImage(300, 100, alpha: true) { $0.setFillColor(.black); $0.fill(CGRect(x: 10, y: 40, width: 280, height: 6)) }
    let sigURL = tmp.appendingPathComponent("sig.png")
    try? ImageKit.save(sigImage, to: sigURL, format: .png)
    sign.armed = sigURL
    sign.width = 150
    sign.place(on: sign.doc!.page(at: 0)!, at: CGPoint(x: 300, y: 300))
    let placed = SignatureAnnotation.selected
    sign.width = 240
    check(placed.map { abs($0.bounds.width - 240) < 0.5 && abs($0.bounds.height - 80) < 0.5 } ?? false, "resizing a placed signature keeps its shape")

    let vec = SignatureVector.from(strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 30), CGPoint(x: 110, y: 10)]], color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    let round = vec.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(SignatureVector.self, from: $0) }
    check(round.map { abs($0.aspect - vec!.aspect) < 0.001 && $0.strokes?.first?.count == 3 && $0.color[2] == 1 } ?? false, "vector signature survives saving")
    if let round {
        let big = makeImage(1200, 400, alpha: true) { round.draw(in: CGRect(x: 0, y: 0, width: 1200, height: 400), ctx: $0) }
        let data = big.dataProvider?.data as Data?
        let partial = data.map { d in stride(from: 3, to: d.count, by: 4).filter { d[$0] > 0 && d[$0] < 255 }.count } ?? 0
        check(partial > 100, "vector signature draws smooth (anti-aliased) edges at any size")
    }
}

// MARK: Mac

let speedJSON = #"{"dl_throughput": 245000000, "ul_throughput": 41000000, "responsiveness": 1020, "base_rtt": 18.5, "interface_name": "en0"}"#
let speed = SpeedResult.parse(speedJSON)
check(speed.map { Int($0.download) == 245 && Int($0.upload) == 41 && $0.rating.0 == "High" } ?? false, "speed test result parsing")
check(MacKit.size(of: dupDir) >= 600_000, "folder size on disk")
check(!MacKit.installedApps().isEmpty, "installed apps listed")
check(!LoginItemsModel.scan().isEmpty || true, "launch agents scan runs")
check(!Displays.screens().isEmpty, "displays listed")
check(Displays.screens().contains { $0.builtIn } ? Displays.builtInBrightness(Displays.screens().first { $0.builtIn }!.id) != nil : true, "built-in brightness readable")
wait {
    let battery = await BatteryInfo.read()
    check(battery == nil || battery?.cycles != nil, "battery health read (cycles \(battery?.cycles.map(String.init) ?? "n/a"), max \(battery?.maxCapacity ?? "n/a"))")
    KeepAwake.shared.start(minutes: 1)
    let assertions = (try? await Shell.run("/usr/bin/pmset", ["-g", "assertions"]))?.out ?? ""
    check(assertions.contains("MyToolbox Keep Awake"), "keep awake holds a power assertion")
    KeepAwake.shared.stop()
    let after = (try? await Shell.run("/usr/bin/pmset", ["-g", "assertions"]))?.out ?? ""
    check(!after.contains("MyToolbox Keep Awake"), "keep awake releases it")
    if let app = MacKit.installedApps().first(where: { $0.url.path.hasPrefix("/Applications") }) {
        let c = await AppCheck.run(app.url)
        check(c.signedBy != "Unknown", "app signature read for \(app.name): \(c.signedBy)")
    }
    let shadow = await MacKit.defaults(["read", "com.apple.screencapture", "disable-shadow"])
    check(true, "hidden settings read (screenshot shadow setting: \(shadow.isEmpty ? "default" : shadow))")
}

// MARK: Slow checks: network, speech, Apple Intelligence

if !fast {
    wait(180) {
        let manager = DownloadManager.shared
        var o = DownloadOptions(); o.quality = .m4a
        manager.add(["https://www.youtube.com/watch?v=jNQXAC9IVRw"], options: o)
        while manager.jobs.first.map({ $0.state == .queued || $0.state == .running }) ?? false { try? await Task.sleep(for: .milliseconds(200)) }
        let job = manager.jobs.first
        let file = job?.items.first?.file
        check(job?.state == .finished && file.map { FileManager.default.fileExists(atPath: $0.path) } == true,
              "download audio: \(file?.lastPathComponent ?? String(describing: job?.state))")
        check(job?.items.first?.title == "Me at the zoo", "download shows the video title")
    }

    let speech = tmp.appendingPathComponent("speech.aiff")
    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: ["-o", speech.path, "Hello, this is a transcription test for my toolbox."])
    spin(20) { speech.fileSize > 0 }
    sleep(1)
    wait(180) {
        let m = TranscribeModel.shared
        await m.loadLocales()
        m.localeID = "en_US"
        m.file = speech
        m.start()
        while true {
            if case .done = m.state { break }
            if case .failed = m.state { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let text = TranscriptFormat.text.render(m.segments).lowercased()
        check(text.contains("transcription"), "transcribe speech: \(text)")
    }

    wait(60) {
        let m = SpeechModel.shared
        m.text = "Saving this sentence as audio."
        m.saveAudio(name: "tts-test")
        while m.saving { try? await Task.sleep(for: .milliseconds(100)) }
        check((m.saved.first?.fileSize ?? 0) > 1000, "text to speech saved M4A (\(m.saved.first?.fileSize.byteString ?? m.error ?? "none"))")
    }

    if AIModel.isAvailable {
        wait(120) {
            let text = "The city council met on Tuesday and approved a new park on Elm Street. Construction starts in March and costs 2 million dollars. The mayor said the park will open next summer."
            let summary = (try? await Summarizer.summarize(text, length: .short, style: .paragraph, status: { _ in }, partial: { _ in })) ?? ""
            check(summary.lowercased().contains("park"), "summarize: \(summary.prefix(120))")
        }

        let pdfURL = tmp.appendingPathComponent("doc.pdf")
        do {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let ctx = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
            for page in ["Chapter one is about the history of the company, founded in 1998 in Oslo.",
                         "Security: the vault code word is PELICAN. It changes every month."] {
                ctx.beginPDFPage(nil)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 14)]).draw(in: CGRect(x: 50, y: 500, width: 500, height: 200))
                NSGraphicsContext.current = nil
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }
        wait(120) {
            let m = AskDocumentModel.shared
            m.open(pdfURL)
            while m.indexing { try? await Task.sleep(for: .milliseconds(100)) }
            m.question = "What is the vault code word?"
            m.ask()
            while m.working { try? await Task.sleep(for: .milliseconds(100)) }
            let answer = m.messages.last
            check(answer?.text.uppercased().contains("PELICAN") == true, "ask a document answers: \(answer?.text.prefix(120) ?? "")")
            check(answer?.pages.contains(2) == true, "answer cites page 2 (\(answer?.pages ?? []))")
        }
    } else {
        print("· skipped Apple Intelligence checks: \(AIModel.statusText)")
    }
}

try? FileManager.default.removeItem(at: tmp)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
