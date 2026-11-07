import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let audioTools: [Tool] = [
        Tool("recordaudio", "Record Audio", "mic", .audio,
             "Record your voice in M4A or WAV, then transcribe it on device") { RecordAudioView() },
        Tool("trimaudio", "Trim Audio", "scissors", .audio,
             "Cut a song or recording down to the part you want, with fade in and fade out", accepts: [.audio], fullBleed: true) { TrimView(kind: .audio) },
        Tool("cleanaudio", "Clean Up Audio", "waveform.badge.magnifyingglass", .audio,
             "Reduce background noise, rumble and hiss in recordings and videos, and even out loudness",
             accepts: [.audio, .movie], fullBleed: true) { CleanUpAudioView() },
    ]
}

// MARK: - Clean Up Audio

enum CleanStrength: String, CaseIterable, Identifiable {
    case light = "Light", medium = "Medium", strong = "Strong"
    var id: String { rawValue }
    /// afftdn noise reduction in dB.
    var reduction: Int { switch self { case .light: 8; case .medium: 14; case .strong: 24 } }
}

enum CleanAudioArgs {
    static func filter(strength: CleanStrength, rumbleAndHiss: Bool, loudness: Bool, removeSilences: Bool, sampleRate: Int) -> String {
        var f: [String] = []
        if rumbleAndHiss { f += ["highpass=f=80", "lowpass=f=12000"] }
        f.append("afftdn=nr=\(strength.reduction):nf=-40:tn=1")
        if removeSilences {
            f.append("silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.2:stop_periods=-1:stop_duration=0.8:stop_threshold=-45dB:stop_silence=0.3")
        }
        // loudnorm works at 192 kHz internally; bring the rate back down. On clips under 3 s it hands over the
        // whole file as one frame, which FLAC refuses, so re-cut it into normal-sized frames.
        if loudness { f += ["loudnorm=I=-16:TP=-1.5:LRA=11", "aresample=\(sampleRate)", "asetnsamples=n=4096:p=0"] }
        return f.joined(separator: ",")
    }

    static func args(_ input: URL, _ output: URL, filter: String, video: Bool) -> [String] {
        let ext = output.pathExtension.lowercased()
        var a = VideoEditArgs.head + ["-i", input.path]
        a += video ? ["-map", "0:v:0", "-map", "0:a:0", "-map", "0:s?", "-c:v", "copy", "-c:s", "copy"] : ["-map", "0:a:0", "-vn"]
        a += ["-map_metadata", "0", "-af", filter] + AudioEncoding.forExtension(ext).args
        if ["mp4", "mov", "m4v", "m4a"].contains(ext) { a += ["-movflags", "+faststart"] }
        return a + VideoEditArgs.tail + [output.path]
    }
}

struct CleanUpAudioView: View {
    @AppStorage("clean.strength") private var strength: CleanStrength = .medium
    @AppStorage("clean.rumble") private var rumble = true
    @AppStorage("clean.loudness") private var loudness = false
    @AppStorage("clean.silences") private var silences = false

    var body: some View {
        BatchToolView(toolID: "cleanaudio", folderName: "", types: [.audio, .movie, .video], noun: "File", verb: "Clean Up", concurrency: 2,
                      previewKey: "\(strength.rawValue)|\(rumble)|\(loudness)|\(silences)") {
            Section("Noise reduction") {
                Picker("Strength", selection: $strength) { ForEach(CleanStrength.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Text(strength == .strong ? "For noisy rooms. Voices may sound slightly processed." : strength == .light ? "Gentle; keeps the voice completely natural." : "Good for most recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Cut rumble and hiss", isOn: $rumble)
                Toggle("Even out loudness", isOn: $loudness)
                Toggle("Remove silences", isOn: $silences)
            } footer: {
                Text("In videos only the sound is cleaned and the picture is copied as is. Silences are kept in videos so they stay in sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } process: { [strength, rumble, loudness, silences] url, folder, progress in
            let p = try await MediaProbe.read(url)
            guard p.hasAudio else { throw ToolError("This file has no sound track.") }
            let video = p.video != nil
            let ext = video ? VideoOutput.same.ext(for: url) : AudioEncoding.forExtension(url.pathExtension).ext
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " cleaned", ext: ext)
            let f = CleanAudioArgs.filter(strength: strength, rumbleAndHiss: rumble, loudness: loudness,
                                          removeSilences: silences && !video, sampleRate: p.sampleRate)
            return try await runFFmpeg(CleanAudioArgs.args(url, out, filter: f, video: video), input: url, output: out, progress: progress)
        }
    }
}

// MARK: - Record Audio

enum RecordingFormat: String, CaseIterable, Identifiable {
    case m4a = "M4A (AAC)", wav = "WAV"
    var id: String { rawValue }
    var ext: String { self == .m4a ? "m4a" : "wav" }
}

@MainActor @Observable
final class RecorderModel: NSObject, AVAudioRecorderDelegate {
    static let shared = RecorderModel()

    enum State { case idle, recording, paused }

    struct Recording: Identifiable {
        var id: URL { url }
        let url: URL
        var duration: Double
        var transcript: URL?
        var transcribing: Double?
        var error: String?
    }

    var state: State = .idle
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var recordings: [Recording] = []
    var error: String?
    var playing: URL?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    static func settings(_ format: RecordingFormat, stereo: Bool) -> [String: Any] {
        let channels = stereo ? 2 : 1
        switch format {
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: stereo ? 192_000 : 96_000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        case .wav:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        }
    }

    /// Recordings already in the output folder, newest first.
    func loadExisting() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Output.root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let audio = files.filter { $0.lastPathComponent.hasPrefix("Recording ") && ["m4a", "wav"].contains($0.pathExtension.lowercased()) }
        let known = Set(recordings.map(\.url))
        let fresh = audio.filter { !known.contains($0) }.map { url in
            let txt = url.deletingPathExtension().appendingPathExtension("txt")
            return Recording(url: url, duration: (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0,
                             transcript: FileManager.default.fileExists(atPath: txt.path) ? txt : nil)
        }
        recordings = (recordings + fresh).filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    func start(format: RecordingFormat, stereo: Bool) {
        error = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .audio) { start(format: format, stereo: stereo) }
                else { error = "MyToolbox can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone." }
            }
            return
        default:
            error = "MyToolbox can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            return
        }
        stopPlayback()
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        let url = Output.file(name: "Recording \(stamp)", ext: format.ext)
        do {
            let r = try AVAudioRecorder(url: url, settings: Self.settings(format, stereo: stereo))
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record() else { throw ToolError("The microphone couldn't start. Check the input in System Settings → Sound.") }
            recorder = r
            state = .recording
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        r.updateMeters()
        elapsed = r.currentTime
        // −50 dB…0 dB → 0…1
        level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
    }

    func pauseResume() {
        guard let r = recorder else { return }
        if state == .recording { r.pause(); state = .paused } else if state == .paused { r.record(); state = .recording }
    }

    func stop() {
        guard let r = recorder else { return }
        let duration = r.currentTime
        r.stop()
        timer?.invalidate(); timer = nil
        recorder = nil
        state = .idle
        level = 0
        recordings.insert(Recording(url: r.url, duration: duration), at: 0)
    }

    func play(_ url: URL) {
        if playing == url { stopPlayback(); return }
        stopPlayback()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        playing = player == nil ? nil : url
        let length = player?.duration ?? 0
        Task {
            try? await Task.sleep(for: .seconds(length + 0.2))
            if playing == url && player?.isPlaying != true { playing = nil }
        }
    }

    func stopPlayback() { player?.stop(); player = nil; playing = nil }

    func transcribe(_ url: URL, locale: Locale) {
        guard let i = recordings.firstIndex(where: { $0.url == url }) else { return }
        recordings[i].transcribing = 0
        recordings[i].error = nil
        Task {
            do {
                let segments = try await Transcription.transcribe(url, locale: locale) { [weak self] p, _ in
                    if let i = self?.recordings.firstIndex(where: { $0.url == url }) { self?.recordings[i].transcribing = p }
                }
                guard !segments.isEmpty else { throw ToolError("No speech was recognized. Check the language.") }
                let txt = Output.unique(url.deletingPathExtension().appendingPathExtension("txt"))
                try TranscriptFormat.text.render(segments).write(to: txt, atomically: true, encoding: .utf8)
                update(url) { $0.transcript = txt; $0.transcribing = nil }
            } catch {
                update(url) { $0.error = error.localizedDescription; $0.transcribing = nil }
            }
        }
    }

    private func update(_ url: URL, _ change: (inout Recording) -> Void) {
        if let i = recordings.firstIndex(where: { $0.url == url }) { change(&recordings[i]) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.error = error?.localizedDescription ?? "Recording stopped because of an error."
            self.stop()
        }
    }
}

struct RecordAudioView: View {
    @Bindable private var model = RecorderModel.shared
    @Bindable private var speech = TranscribeModel.shared
    @AppStorage("rec.format") private var format: RecordingFormat = .m4a
    @AppStorage("rec.stereo") private var stereo = false
    @State private var showing: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Picker("Format", selection: $format) { ForEach(RecordingFormat.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                Picker("Channels", selection: $stereo) { Text("Mono").tag(false); Text("Stereo").tag(true) }.fixedSize()
                Spacer()
                Picker("Transcribe in", selection: $speech.localeID) {
                    ForEach(speech.locales, id: \.identifier) { Text(speech.name($0)).tag($0.identifier) }
                }
                .frame(maxWidth: 260)
            }
            .disabled(model.state != .idle)

            HStack(spacing: 20) {
                Button {
                    model.state == .idle ? model.start(format: format, stereo: stereo) : model.stop()
                } label: {
                    ZStack {
                        Circle().fill(.red.opacity(0.15)).frame(width: 72, height: 72)
                        if model.state == .idle {
                            Circle().fill(.red).frame(width: 44, height: 44)
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help(model.state == .idle ? "Start recording (⌘↩)" : "Stop and save (⌘↩)")
                .accessibilityLabel(model.state == .idle ? "Record" : "Stop")

                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.clock(model.elapsed)).font(.system(size: 32, weight: .medium).monospacedDigit())
                    LevelMeter(level: model.level).frame(width: 260, height: 8)
                    Text(model.state == .idle ? "Ready" : model.state == .paused ? "Paused" : "Recording…").foregroundStyle(.secondary)
                }
                if model.state != .idle {
                    Button(model.state == .paused ? "Resume" : "Pause") { model.pauseResume() }.keyboardShortcut("p")
                }
                Spacer()
            }
            if let e = model.error { ErrorText(message: e) }
            Divider()
            if model.recordings.isEmpty {
                ContentUnavailableView("No Recordings Yet", systemImage: "mic",
                                       description: Text("Click the red button to record. Recordings are saved to \(Output.rootDisplay)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.recordings) { r in row(r) }
                    .listStyle(.inset)
            }
            SavesToLine()
        }
        .task { await speech.loadLocales(); model.loadExisting() }
        .sheet(item: $showing) { PreviewSheet(url: $0) }
    }

    /// "0:42.3", or "1:02:05.0" past an hour.
    static func clock(_ t: TimeInterval) -> String {
        let tenths = Int(t * 10) % 10
        return timecode(t) + ".\(tenths)"
    }

    private func row(_ r: RecorderModel.Recording) -> some View {
        HStack(spacing: 12) {
            Button { model.play(r.url) } label: { Image(systemName: model.playing == r.url ? "stop.circle.fill" : "play.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .help(model.playing == r.url ? "Stop" : "Play")
            VStack(alignment: .leading, spacing: 2) {
                Text(r.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("\(timecode(r.duration)) · \(r.url.fileSize.byteString)").font(.caption).foregroundStyle(.secondary)
                if let e = r.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if let p = r.transcribing {
                ProgressView(value: p).frame(width: 80)
            } else if let t = r.transcript {
                Button("Copy Text") { if let s = try? String(contentsOf: t, encoding: .utf8) { Pasteboard.copy(s) } }
                Button("Open Text") { showing = t }
            } else {
                Button("Transcribe") {
                    model.transcribe(r.url, locale: speech.localeID.isEmpty ? Locale.current : Locale(identifier: speech.localeID))
                }
            }
            Button { r.url.reveal() } label: { Image(systemName: "magnifyingglass.circle") }.buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.vertical, 3)
        .draggableFile(r.url)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(r.url) }
            Button("Show in Finder") { r.url.reveal() }
        }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.9 ? Color.red : level > 0.7 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
