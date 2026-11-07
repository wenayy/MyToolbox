import AVFoundation
import Observation
import PDFKit
import Speech
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension ToolRegistry {
    static let textTools: [Tool] = [
        Tool("transcribe", "Transcribe", "waveform", .text,
             "Turn speech in audio and video into a timestamped transcript or subtitles", accepts: [.audio, .movie]) { TranscribeView() },
        Tool("summarize", "Summarize", "text.append", .text,
             "Summarize text and documents on device with Apple Intelligence", accepts: DocText.types) { SummarizeView() },
        Tool("extracttext", "Extract Text", "text.viewfinder", .text,
             "Recognize text in images, screenshots and scanned PDFs", accepts: [.image, .pdf], fullBleed: true) { ExtractTextView() },
        Tool("capturetext", "Capture Text", "rectangle.and.text.magnifyingglass", .text,
             "Select any area of the screen and copy the text in it (⌃⌥T)") { CaptureTextView() },
        Tool("translate", "Translate", "translate", .text,
             "Translate text, documents and subtitles on device, keeping formatting and timings",
             accepts: DocText.types + DocText.subtitleTypes) { TranslateView() },
        Tool("tts", "Text to Speech", "speaker.wave.2", .text,
             "Read text, documents and PDFs aloud, and save it as audio", accepts: DocText.types) { TextToSpeechView() },
        Tool("askdoc", "Ask a Document", "bubble.left.and.text.bubble.right", .text,
             "Ask questions about a PDF or document and get answers with page references", accepts: DocText.types,
             fullBleed: true) { AskDocumentView() },
        Tool("wordcount", "Word Counter", "list.number", .text,
             "Count words, characters, sentences and paragraphs, with reading time") { WordCounterView() },
        Tool("case", "Case Converter", "textformat", .text,
             "Switch text between UPPERCASE, lowercase, Title Case, camelCase, snake_case and more") { CaseConverterView() },
    ]
}

// MARK: - Reading documents

enum DocText {
    static let types: [UTType] = [.plainText, .pdf, .rtf, .rtfd, .html, UTType("org.openxmlformats.wordprocessingml.document")!,
                                  UTType("com.microsoft.word.doc")!, UTType("org.oasis-open.opendocument.text")!,
                                  UTType(filenameExtension: "md") ?? .plainText]
    static let subtitleTypes: [UTType] = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]

    /// Plain text of a document, PDF or text file.
    static func load(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ToolError("Can't open \(url.lastPathComponent)") }
            let text = doc.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                throw ToolError("This PDF has no text layer. Run it through Extract Text first.")
            }
            return text
        }
        if ["txt", "text", "md", "markdown", "srt", "vtt", "csv", "json", "log"].contains(ext) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        let attr = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        return attr.string
    }
}

// MARK: - OCR

extension VNImageRequestHandler {
    /// Like `perform`, but retries a couple of times: the Neural Engine sometimes refuses a job
    /// while it's busy (an "e5rt" error) and succeeds a moment later.
    /// If the accurate text model still can't run, text requests fall back to the fast model, which doesn't
    /// need that Neural Engine program.
    func performRetrying(_ requests: [VNRequest]) throws {
        var attempt = 0
        while true {
            do { return try perform(requests) } catch {
                attempt += 1
                if attempt >= 3 {
                    let text = requests.compactMap { $0 as? VNRecognizeTextRequest }.filter { $0.recognitionLevel == .accurate }
                    if !text.isEmpty {
                        text.forEach { $0.recognitionLevel = .fast }
                        if (try? perform(requests)) != nil { return }
                    }
                    throw ToolError("Couldn't analyze the image: \(error.localizedDescription)")
                }
                Thread.sleep(forTimeInterval: 0.4 * Double(attempt))
            }
        }
    }
}

enum OCR {
    /// Recognized text in reading order, with blank lines between paragraphs.
    static func recognize(_ image: CGImage, fast: Bool = false) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).performRetrying([request])
        let lines = (request.results ?? []).compactMap { obs -> (CGRect, String)? in
            guard let s = obs.topCandidates(1).first?.string else { return nil }
            return (obs.boundingBox, s)
        }
        .sorted { a, b in
            abs(a.0.midY - b.0.midY) < min(a.0.height, b.0.height) * 0.5 ? a.0.minX < b.0.minX : a.0.midY > b.0.midY
        }
        var out = ""
        var previous: CGRect?
        for (box, text) in lines {
            if let p = previous {
                let sameRow = abs(p.midY - box.midY) < min(p.height, box.height) * 0.5
                if sameRow { out += "  " }
                else { out += (p.minY - box.maxY) > p.height * 1.2 ? "\n\n" : "\n" }
            }
            out += text
            previous = box
        }
        return out
    }

    static func boxes(_ image: CGImage) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).performRetrying([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Text of an image or PDF. PDF pages with a text layer use it; scanned pages are recognized.
    static func text(of url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ToolError("Can't open \(url.lastPathComponent)") }
            var pages: [String] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let layer = page.string ?? ""
                if layer.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
                    pages.append(layer)
                } else {
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = 2200 / max(bounds.width, bounds.height)
                    let thumb = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                    if let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) { pages.append(try recognize(cg)) }
                }
                progress(Double(i + 1) / Double(doc.pageCount))
            }
            return pages.joined(separator: "\n\n")
        }
        return try recognize(ImageKit.load(url, maxPixel: 4096))
    }
}

// MARK: - Extract Text

@MainActor @Observable
final class ExtractTextModel {
    static let shared = ExtractTextModel()

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var text: String?
        var error: String?
        var progress: Double = 0
    }

    var items: [Item] = []
    var selection: Item.ID?
    var saved: [URL] = []

    func add(_ urls: [URL]) {
        let fresh = urls.filter { url in !items.contains { $0.url == url } && BatchRun.matches(url, [.image, .pdf]) }
        let new = fresh.map { Item(url: $0) }
        items.append(contentsOf: new)
        if selection == nil { selection = new.first?.id }
        for item in new { recognize(item.id, item.url) }
    }

    private func recognize(_ id: Item.ID, _ url: URL) {
        Task {
            do {
                let text = try await offMain {
                    try OCR.text(of: url) { p in Task { @MainActor in ExtractTextModel.shared.set(id) { $0.progress = p } } }
                }
                set(id) { $0.text = text.isEmpty ? "" : text; if text.isEmpty { $0.error = "No text found" } }
            } catch {
                set(id) { $0.error = error.localizedDescription }
            }
        }
    }

    func set(_ id: Item.ID, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    func saveAll() {
        let folder = Output.root
        saved = items.compactMap { item in
            guard let text = item.text, !text.isEmpty else { return nil }
            let out = Output.unique(folder.appendingPathComponent(item.url.baseName).appendingPathExtension("txt"))
            return (try? text.write(to: out, atomically: true, encoding: .utf8)) == nil ? nil : out
        }
    }
}

struct ExtractTextView: View {
    @Bindable private var model = ExtractTextModel.shared
    @State private var targeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.viewfinder").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                        Text("Drop Images or PDFs").font(.title3.weight(.semibold))
                        Text("Text is recognized on this Mac as soon as you add them.").foregroundStyle(.secondary)
                        Button("Choose Files…") { model.add(FilePicker.choose(types: [.image, .pdf])) }.controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selection) {
                        ForEach(model.items) { item in
                            HStack(spacing: 10) {
                                Thumbnail(url: item.url, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    if let error = item.error {
                                        Text(error).font(.caption).foregroundStyle(.secondary)
                                    } else if let text = item.text {
                                        Text("\(text.split(whereSeparator: \.isWhitespace).count) words").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        ProgressView(value: item.progress).controlSize(.small)
                                    }
                                }
                            }
                            .tag(item.id)
                            .contextMenu {
                                Button("Show in Finder") { item.url.reveal() }
                                Button("Remove") { model.items.removeAll { $0.id == item.id } }
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Button { model.add(FilePicker.choose(types: [.image, .pdf])) } label: { Label("Add Files…", systemImage: "plus") }
                        Spacer()
                        Button("Clear") { model.items = []; model.selection = nil; model.saved = [] }
                    }
                    .buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            .onDrop(of: FileDrop.types, isTargeted: $targeted) { providers in
                FileDrop.load(providers) { model.add($0) }
                return true
            }

            VStack(alignment: .leading, spacing: 10) {
                if let i = model.items.firstIndex(where: { $0.id == model.selection }) {
                    if let text = model.items[i].text {
                        EditorBox(title: model.items[i].url.lastPathComponent, text: Binding(
                            get: { model.items[i].text ?? "" }, set: { model.items[i].text = $0 }), monospaced: false) {
                            Button("Save as Text") {
                                let out = Output.file(name: model.items[i].url.baseName, ext: "txt")
                                try? text.write(to: out, atomically: true, encoding: .utf8)
                                model.saved = [out]
                            }
                            .controlSize(.small)
                        }
                    } else if let error = model.items[i].error {
                        ContentUnavailableView(error, systemImage: "text.badge.xmark",
                                               description: Text("Try a sharper image, or a PDF page with clearer text."))
                    } else {
                        ProgressView("Recognizing text…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ContentUnavailableView("No File Selected", systemImage: "doc.text.magnifyingglass")
                }
                ResultList(urls: model.saved)
                HStack {
                    SavesToLine()
                    Spacer()
                    Button("Save All as Text", action: model.saveAll)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.items.contains { ($0.text ?? "").isEmpty == false })
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(16)
            .frame(minWidth: 360)
        }
        .receivesFiles(for: "extracttext") { model.add($0) }
    }
}

// MARK: - Capture Text

@MainActor @Observable
final class CaptureTextModel {
    static let shared = CaptureTextModel()
    var history: [String] = []
    var message: String?
}

@MainActor
enum CaptureText {
    /// Lets the person drag over part of the screen, recognizes the text there and copies it.
    static func run(showResult: Bool) {
        let model = CaptureTextModel.shared
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            model.message = "Allow MyToolbox under Screen & System Audio Recording in System Settings, then try again."
            Toast.show("Allow Screen Recording for MyToolbox, then try again", symbol: "lock.shield")
            AppModel.shared.open("capturetext")
            return
        }
        let mainWindow = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
        mainWindow?.orderOut(nil)
        Task {
            let shot = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: shot) }
            _ = try? await Shell.run("/usr/sbin/screencapture", ["-i", "-x", "-r", shot.path])
            if showResult { mainWindow?.makeKeyAndOrderFront(nil) }
            guard FileManager.default.fileExists(atPath: shot.path) else { return }   // Escape pressed
            do {
                let text = try await offMain { try OCR.recognize(ImageKit.load(shot)) }
                guard !text.isEmpty else {
                    Toast.show("No text found in that area", symbol: "text.badge.xmark")
                    return
                }
                Pasteboard.copy(text)
                model.history.insert(text, at: 0)
                model.message = nil
                let words = text.split(whereSeparator: \.isWhitespace).count
                Toast.show("Copied \(words) word\(words == 1 ? "" : "s")", symbol: "doc.on.clipboard")
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }
}

struct CaptureTextView: View {
    @Bindable private var model = CaptureTextModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Button {
                    CaptureText.run(showResult: true)
                } label: {
                    Label("Capture Text", systemImage: "viewfinder").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drag over any part of the screen. The text is copied to the clipboard.")
                    Text("Works from any app with ⌃⌥T. Press Escape to cancel.").foregroundStyle(.secondary)
                }
            }
            if let message = model.message {
                Banner(symbol: "lock.shield", message: message) {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            if model.history.isEmpty {
                ContentUnavailableView("Nothing Captured Yet", systemImage: "text.viewfinder",
                                       description: Text("Captured text appears here so you can copy it again."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Recent Captures").font(.headline)
                List {
                    ForEach(Array(model.history.enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .top) {
                            Text(text).lineLimit(4).textSelection(.enabled)
                            Spacer()
                            CopyButton(text: text, label: "").labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - Transcribe

struct TranscriptSegment: Equatable {
    var start: Double
    var end: Double
    var text: String
}

enum TranscriptFormat: String, CaseIterable, Identifiable {
    case text = "Text", timestamped = "Text with Timestamps", srt = "Subtitles (SRT)", vtt = "Subtitles (WebVTT)"
    var id: String { rawValue }
    var ext: String { self == .srt ? "srt" : self == .vtt ? "vtt" : "txt" }

    func render(_ segments: [TranscriptSegment]) -> String {
        switch self {
        case .text:
            return segments.map(\.text).joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
        case .timestamped:
            return segments.map { "[\(timecode($0.start))] \($0.text)" }.joined(separator: "\n")
        case .srt:
            return segments.enumerated().map { i, s in
                "\(i + 1)\n\(timecode(s.start, millis: true)) --> \(timecode(s.end, millis: true))\n\(s.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + segments.map { s in
                "\(timecode(s.start, millis: true, separator: ".")) --> \(timecode(s.end, millis: true, separator: "."))\n\(s.text)\n"
            }.joined(separator: "\n")
        }
    }
}

enum Transcription {
    /// Splits timed words into subtitle-sized cues: at most ~80 characters or 6 seconds, breaking after sentences.
    static func cues(words: [(String, Double, Double)]) -> [TranscriptSegment] {
        var cues: [TranscriptSegment] = []
        var current: TranscriptSegment?
        for (word, start, end) in words {
            let w = word.trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty else { continue }
            if var c = current {
                let tooLong = c.text.count + w.count + 1 > 80 || end - c.start > 6
                if tooLong {
                    cues.append(c)
                    current = TranscriptSegment(start: start, end: end, text: w)
                } else {
                    c.text += (word.hasPrefix(" ") || !c.text.isEmpty ? " " : "") + w
                    c.end = end
                    current = c
                    if let last = w.last, ".?!".contains(last), c.text.count > 30 {
                        cues.append(c)
                        current = nil
                    }
                }
            } else {
                current = TranscriptSegment(start: start, end: end, text: w)
            }
        }
        if let c = current { cues.append(c) }
        return cues
    }

    /// An audio file AVAudioFile can read; video and odd containers are converted to M4A first.
    static func audioFile(for url: URL) async throws -> (AVAudioFile, URL?) {
        if let file = try? AVAudioFile(forReading: url) { return (file, nil) }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ToolError("Can't read the audio in \(url.lastPathComponent)")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try await export.export(to: temp, as: .m4a)
        return (try AVAudioFile(forReading: temp), temp)
    }
}

@MainActor @Observable
final class TranscribeModel {
    static let shared = TranscribeModel()

    enum State: Equatable {
        case idle, preparing(String), running(Double), done, failed(String)
    }

    var file: URL?
    var localeID = ""
    var locales: [Locale] = []
    var installed: Set<String> = []
    var segments: [TranscriptSegment] = []
    var state: State = .idle
    var saved: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func loadLocales() async {
        guard locales.isEmpty else { return }
        let all = await SpeechTranscriber.supportedLocales
        installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        locales = all.sorted { name($0) < name($1) }
        if localeID.isEmpty {
            localeID = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)?.identifier ?? all.first?.identifier ?? "en_US"
        }
    }

    func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    func start() {
        guard let file else { return }
        segments = []
        saved = []
        state = .preparing("Preparing…")
        let locale = Locale(identifier: localeID)
        task = Task {
            var tempAudio: URL?
            defer { if let tempAudio { try? FileManager.default.removeItem(at: tempAudio) } }
            do {
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                                    attributeOptions: [.audioTimeRange])
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    state = .preparing("Downloading the \(name(locale)) speech model…")
                    try await request.downloadAndInstall()
                    installed.insert(locale.identifier)
                }
                state = .preparing("Reading audio…")
                let (audio, temp) = try await Transcription.audioFile(for: file)
                tempAudio = temp
                let duration = Double(audio.length) / audio.processingFormat.sampleRate
                state = .running(0)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let collector = Task { @MainActor in
                    for try await result in transcriber.results {
                        var words: [(String, Double, Double)] = []
                        for run in result.text.runs {
                            let piece = String(result.text[run.range].characters)
                            if let range = run.audioTimeRange {
                                words.append((piece, range.start.seconds, range.end.seconds))
                            }
                        }
                        let cues = words.isEmpty
                            ? [TranscriptSegment(start: result.range.start.seconds, end: result.range.end.seconds,
                                                 text: String(result.text.characters).trimmingCharacters(in: .whitespaces))]
                            : Transcription.cues(words: words)
                        segments.append(contentsOf: cues.filter { !$0.text.isEmpty })
                        if duration > 0 { state = .running(min(1, result.range.end.seconds / duration)) }
                    }
                }
                if let last = try await analyzer.analyzeSequence(from: audio) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                try await collector.value
                state = segments.isEmpty ? .failed("No speech was recognized. Check the language.") : .done
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }

    func export(_ format: TranscriptFormat) {
        guard let file else { return }
        let out = Output.file(name: file.baseName + (format == .timestamped ? " (timestamps)" : ""), ext: format.ext)
        try? format.render(segments).write(to: out, atomically: true, encoding: .utf8)
        saved = [out]
    }
}

struct TranscribeView: View {
    @Bindable private var model = TranscribeModel.shared
    @State private var files: [URL] = []

    private var running: Bool {
        switch model.state { case .preparing, .running: true; default: false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DropZone(prompt: "Drop an audio or video file", types: [.audio, .movie], multiple: false, urls: $files)
                .disabled(running)
                .onChange(of: files) { model.file = files.first; model.segments = []; model.state = .idle }
            HStack(spacing: 12) {
                Picker("Spoken language", selection: $model.localeID) {
                    ForEach(model.locales, id: \.identifier) { locale in
                        Text(model.name(locale) + (model.installed.contains(locale.identifier) ? "" : " — download needed"))
                            .tag(locale.identifier)
                    }
                }
                .frame(maxWidth: 360)
                .disabled(running)
                Spacer()
                if running {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Transcribe") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.file == nil)
                }
            }
            switch model.state {
            case .preparing(let what): HStack { ProgressView().controlSize(.small); Text(what).foregroundStyle(.secondary) }
            case .running(let p): ProgressView(value: p) { Text("Transcribing… \(Int(p * 100))%").foregroundStyle(.secondary) }
            case .failed(let why): ErrorText(message: why)
            default: EmptyView()
            }
            if model.segments.isEmpty {
                if !running {
                    ContentUnavailableView("No Transcript Yet", systemImage: "waveform",
                                           description: Text("Speech is recognized on this Mac. Nothing is uploaded."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else {
                HStack {
                    Text("\(model.segments.count) segments").font(.headline)
                    Spacer()
                    CopyButton(text: TranscriptFormat.text.render(model.segments), label: "Copy Text")
                    Menu("Export") {
                        ForEach(TranscriptFormat.allCases) { format in
                            Button(format.rawValue) { model.export(format) }
                        }
                    }
                    .fixedSize()
                    .disabled(running)
                }
                ResultList(urls: model.saved)
                List(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(timecode(segment.start)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        Text(segment.text).textSelection(.enabled)
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await model.loadLocales() }
        .onAppear { if let f = model.file, files.isEmpty { files = [f] } }
        .receivesFiles(for: "transcribe") { urls in if let f = urls.first { files = [f] } }
    }
}

// MARK: - Text to Speech

@MainActor @Observable
final class SpeechModel: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechModel()

    var text = ""
    var voiceID = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier ?? ""
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var speaking = false
    var paused = false
    var spokenRange: NSRange?
    var saving = false
    var saved: [URL] = []
    var error: String?

    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private var writer: AVSpeechSynthesizer?
    @ObservationIgnored private var audioFile: AVAudioFile?

    override init() {
        super.init()
        synth.delegate = self
    }

    var voices: [AVSpeechSynthesisVoice] {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode().prefix(2)
        return AVSpeechSynthesisVoice.speechVoices().sorted { a, b in
            let aLocal = a.language.hasPrefix(lang), bLocal = b.language.hasPrefix(lang)
            if aLocal != bLocal { return aLocal }
            if a.language != b.language { return a.language < b.language }
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let quality = v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : ""
        let lang = Locale.current.localizedString(forIdentifier: v.language) ?? v.language
        return "\(v.name)\(quality) — \(lang)"
    }

    private func utterance() -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: voiceID)
        u.rate = rate
        return u
    }

    func playPause() {
        if speaking {
            if paused { synth.continueSpeaking(); paused = false } else { synth.pauseSpeaking(at: .word); paused = true }
        } else {
            guard !text.isEmpty else { return }
            speaking = true
            paused = false
            synth.speak(utterance())
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speaking = false
        paused = false
        spokenRange = nil
    }

    func saveAudio(name: String) {
        guard !text.isEmpty else { return }
        saving = true
        error = nil
        let out = Output.file(name: name, ext: "m4a")
        let writer = AVSpeechSynthesizer()
        self.writer = writer
        audioFile = nil
        writer.write(utterance()) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                self.finishSaving(out)
                return
            }
            do {
                if self.audioFile == nil {
                    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: pcm.format.sampleRate,
                                                   AVNumberOfChannelsKey: pcm.format.channelCount]
                    self.audioFile = try AVAudioFile(forWriting: out, settings: settings, commonFormat: pcm.format.commonFormat,
                                                     interleaved: pcm.format.isInterleaved)
                }
                try self.audioFile?.write(from: pcm)
            } catch {
                self.error = error.localizedDescription
                self.finishSaving(nil)
            }
        }
    }

    private func finishSaving(_ url: URL?) {
        guard saving else { return }
        audioFile = nil   // closes the file
        writer = nil
        saving = false
        if let url, FileManager.default.fileExists(atPath: url.path) { saved = [url] }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.spokenRange = range }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            self.paused = false
            self.spokenRange = nil
        }
    }
}

struct TextToSpeechView: View {
    @Bindable private var model = SpeechModel.shared
    @State private var sourceName = "Speech"
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ControlBar {
                Picker("Voice", selection: $model.voiceID) {
                    ForEach(model.voices, id: \.identifier) { Text(SpeechModel.label($0)).tag($0.identifier) }
                }
                .frame(maxWidth: 380)
                HStack(spacing: 6) {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: $model.rate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate * 0.75)
                        .frame(width: 140)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                .help("Speaking rate")
                Spacer()
                Button("More Voices…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                }
                .help("Download Premium voices in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices")
            }
            if let loadError { ErrorText(message: loadError) }
            if model.speaking, let range = model.spokenRange {
                ScrollView {
                    Text(highlighted(range)).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(10)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                EditorBox(title: "Text", text: $model.text, monospaced: false, placeholder: "Type or paste text, or open a document or PDF…") {
                    Button("Open Document…") {
                        if let url = FilePicker.choose(types: DocText.types, multiple: false).first { load(url) }
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                Button { model.playPause() } label: {
                    Label(model.speaking ? (model.paused ? "Resume" : "Pause") : "Play",
                          systemImage: model.speaking && !model.paused ? "pause.fill" : "play.fill")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.text.isEmpty)
                Button("Stop", action: model.stop).disabled(!model.speaking)
                Spacer()
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
                if model.saving { ProgressView().controlSize(.small) }
                Button("Save as Audio") { model.saveAudio(name: sourceName) }
                    .disabled(model.text.isEmpty || model.saving)
                    .help("Save an M4A file you can play anywhere")
            }
            ResultList(urls: model.saved)
        }
        .receivesFiles(for: "tts") { urls in if let url = urls.first { load(url) } }
    }

    private func load(_ url: URL) {
        do {
            model.text = try DocText.load(url)
            sourceName = url.baseName
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func highlighted(_ range: NSRange) -> AttributedString {
        var a = AttributedString(model.text)
        if let r = Range(range, in: model.text), let lower = AttributedString.Index(r.lowerBound, within: a),
           let upper = AttributedString.Index(r.upperBound, within: a) {
            a[lower..<upper].backgroundColor = .accentColor.opacity(0.35)
        }
        return a
    }
}
