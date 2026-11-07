import AVFoundation
import Observation
import ScreenCaptureKit
import SwiftUI

// MARK: - Record Screen

enum CaptureTarget: String, CaseIterable, Identifiable {
    case display = "Display", window = "Window", area = "Area"
    var id: String { rawValue }
}

enum RecordResolution: Int, CaseIterable, Identifiable {
    case native = 0, p1440 = 1440, p1080 = 1080, p720 = 720
    var id: Int { rawValue }
    var title: String { self == .native ? "Native" : "\(rawValue)p" }

    /// Pixel size for a capture of `points` at `scale`, with the shorter side capped and both sides even.
    func size(points: CGSize, scale: CGFloat) -> CGSize {
        var w = points.width * scale, h = points.height * scale
        if rawValue > 0, min(w, h) > CGFloat(rawValue) {
            let k = CGFloat(rawValue) / min(w, h)
            w *= k; h *= k
        }
        return CGSize(width: max(2, Int(w) / 2 * 2), height: max(2, Int(h) / 2 * 2))
    }
}

enum RecordFileType: String, CaseIterable, Identifiable {
    case mov = "MOV", mp4 = "MP4"
    var id: String { rawValue }
    var ext: String { rawValue.lowercased() }
    var avType: AVFileType { self == .mov ? .mov : .mp4 }
}

struct ScreenRecordingOptions: Equatable {
    var target: CaptureTarget = .display
    var systemAudio = false
    var microphone = false
    /// "" = the input chosen in System Settings.
    var micDevice = ""
    var reduceNoise = true
    var showPointer = true
    var highlightClicks = false
    var resolution: RecordResolution = .native
    var fps = 30
    var fileType: RecordFileType = .mov
    /// Seconds to count down before recording starts; 0 = start at once.
    var countdown = 0
}

@MainActor @Observable
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let shared = ScreenRecorder()

    var displays: [SCDisplay] = []
    var windows: [SCWindow] = []
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var windowID: CGWindowID?
    var recording = false
    var starting = false
    var startedAt: Date?
    /// Adding the microphone to the finished video.
    var finishing = false
    var micLevel: Float = 0
    var inputs: [AudioInput] = []
    var error: String?
    var results: [URL] = []
    @ObservationIgnored private var mic: MicRecorder?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var ticker: Timer?

    var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    var usesOwnMicrophone: Bool { mic != nil }

    func refresh() async {
        inputs = AudioInputs.all()
        guard hasAccess else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            displays = content.displays
            let me = Bundle.main.bundleIdentifier
            windows = content.windows.filter { w in
                w.windowLayer == 0 && w.frame.width >= 80 && w.frame.height >= 60
                    && w.owningApplication.map { $0.bundleIdentifier != me && !$0.applicationName.isEmpty } == true
            }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? CGMainDisplayID() }
            if let id = windowID, !windows.contains(where: { $0.windowID == id }) { windowID = nil }
            if windowID == nil { windowID = windows.first?.windowID }
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func windowName(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "Window"
        guard let t = w.title, !t.isEmpty else { return app }
        return "\(app) — \(t)"
    }

    func start(_ o: ScreenRecordingOptions) {
        guard !recording, !starting, !finishing else { return }
        error = nil
        guard hasAccess else {
            CGRequestScreenCaptureAccess()
            error = "Allow MyToolbox under Screen & System Audio Recording in System Settings, then quit and reopen MyToolbox."
            return
        }
        starting = true
        Task {
            defer { starting = false }
            var mic: MicRecorder?
            do {
                if o.microphone, !(await AudioInputs.requestAccess()) {
                    throw ToolError(AudioInputs.deniedMessage + " Or turn Microphone off.")
                }
                await refresh()
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter: SCContentFilter
                var sourceRect: CGRect?
                var screen = NSScreen.main
                switch o.target {
                case .display:
                    guard let d = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw ToolError("No display found.") }
                    filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                    screen = Self.screen(for: d.displayID) ?? screen
                case .window:
                    guard let w = content.windows.first(where: { $0.windowID == windowID }) else { throw ToolError("Choose a window to record. It must be open on screen.") }
                    filter = SCContentFilter(desktopIndependentWindow: w)
                case .area:
                    guard let picked = await AreaPicker.pick() else { return }
                    guard let d = content.displays.first(where: { $0.displayID == picked.0 }) else { throw ToolError("That display isn't available.") }
                    filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                    sourceRect = picked.1
                    screen = Self.screen(for: d.displayID) ?? screen
                }

                // With noise reduction the microphone is recorded here through Apple's voice processing and mixed in
                // afterwards; ScreenCaptureKit's own microphone capture has no noise reduction.
                let ownMic = o.microphone && o.reduceNoise && Shell.which("ffmpeg") != nil
                let config = SCStreamConfiguration()
                let points = sourceRect?.size ?? filter.contentRect.size
                let px = o.resolution.size(points: points, scale: CGFloat(filter.pointPixelScale))
                config.width = Int(px.width)
                config.height = Int(px.height)
                if let sourceRect { config.sourceRect = sourceRect }
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
                config.queueDepth = 6
                config.showsCursor = o.showPointer
                config.showMouseClicks = o.highlightClicks
                config.capturesAudio = o.systemAudio
                config.excludesCurrentProcessAudio = true
                config.captureMicrophone = o.microphone && !ownMic
                if config.captureMicrophone, !o.micDevice.isEmpty { config.microphoneCaptureDeviceID = o.micDevice }

                if ownMic {
                    let micURL = FileManager.default.temporaryDirectory.appendingPathComponent("MyToolbox mic \(UUID().uuidString).caf")
                    let m = try MicRecorder(url: micURL, options: .init(voiceProcessing: true, deviceUID: o.micDevice.isEmpty ? nil : o.micDevice),
                                            writeImmediately: false)
                    m.onLevel = { [weak self] in self?.micLevel = $0 }
                    try m.start()
                    mic = m
                }
                if o.countdown > 0 { await Countdown.run(o.countdown, on: screen) }

                let url = Output.file(name: "Screen Recording \(Output.stamp())", ext: o.fileType.ext)
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = url
                rc.outputFileType = o.fileType.avType
                rc.videoCodecType = .h264
                let out = SCRecordingOutput(configuration: rc, delegate: self)
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                try s.addRecordingOutput(out)
                self.mic = mic
                try await s.startCapture()
                stream = s; output = out; file = url
                recording = true
                startedAt = Date()
                showStatusItem()
                // The delegate starts the microphone file with the first video frame; this is the fallback.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.mic?.beginWriting()
                }
            } catch {
                mic?.stop()
                if let m = mic { try? FileManager.default.removeItem(at: m.url) }
                self.mic = nil
                self.error = error.localizedDescription
                stream = nil; output = nil; file = nil
            }
        }
    }

    func stop() {
        guard recording, let s = stream else { return }
        recording = false
        hideStatusItem()
        Task {
            do { try await s.stopCapture() } catch { self.error = error.localizedDescription }
            if let out = output { try? s.removeRecordingOutput(out) }
            let mic = self.mic
            mic?.stop()
            self.mic = nil
            micLevel = 0
            stream = nil; output = nil
            startedAt = nil
            guard let file else { return }
            if let mic {
                finishing = true
                do {
                    try await Self.mixMicrophone(into: file, mic: mic.url)
                    try? FileManager.default.removeItem(at: mic.url)
                } catch {
                    // Never lose the voice: keep it next to the video.
                    let kept = Output.unique(file.deletingLastPathComponent().appendingPathComponent(file.baseName + " microphone.caf"))
                    try? FileManager.default.moveItem(at: mic.url, to: kept)
                    self.error = "Your voice couldn't be added to the video (\(error.localizedDescription)). It's saved next to it as \(kept.lastPathComponent)."
                }
                finishing = false
            }
            if FileManager.default.fileExists(atPath: file.path), !results.contains(file) { results.insert(file, at: 0) }
            self.file = nil
        }
    }

    static func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
    }

    /// ffmpeg arguments that put the recorded voice under (or, with system audio, mixed into) a screen recording.
    /// The picture is copied as is; the voice is padded with silence so it lasts as long as the video.
    static func mixArgs(video: URL, mic: URL, output: URL, videoHasAudio: Bool) -> [String] {
        let graph = videoHasAudio
            ? "[1:a:0]aresample=48000,apad[m];[0:a:0]aresample=48000[s];[s][m]amix=inputs=2:duration=first:normalize=0[a]"
            : "[1:a:0]aresample=48000,apad[a]"
        var a = VideoEditArgs.head + ["-i", video.path, "-i", mic.path, "-filter_complex", graph,
                                      "-map", "0:v:0", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]
        if !videoHasAudio { a.append("-shortest") }
        if ["mp4", "mov"].contains(output.pathExtension.lowercased()) { a += ["-movflags", "+faststart"] }
        return a + [output.path]
    }

    /// Replaces `video` with a copy that includes the microphone recording.
    static func mixMicrophone(into video: URL, mic: URL) async throws {
        let ffmpeg = try Shell.require("ffmpeg")
        let probe = try await MediaProbe.read(video)
        let temp = video.deletingLastPathComponent().appendingPathComponent(".mixing \(UUID().uuidString).\(video.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let r = try await Shell.run(ffmpeg, mixArgs(video: video, mic: mic, output: temp, videoHasAudio: probe.hasAudio))
        guard r.ok, temp.fileSize > 0 else { throw ToolError(FFmpeg.explain(r.err.components(separatedBy: "\n"))) }
        _ = try FileManager.default.replaceItemAt(video, withItemAt: temp)
    }

    // MARK: Menu bar control, so the recording can be stopped from any app

    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.toolTip = "Stop recording (MyToolbox)"
        statusItem = item
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.startedAt else { return }
                self.statusItem?.button?.title = " " + timecode(Date().timeIntervalSince(start))
            }
        }
    }

    private func hideStatusItem() {
        ticker?.invalidate(); ticker = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func statusItemClicked() {
        stop()
        AppModel.shared.showMainWindow()
        AppModel.shared.open("recordscreen")
    }

    // MARK: Delegates

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.error = "Recording stopped: \(error.localizedDescription)"
            if self.recording { self.stop() }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.error = "The recording couldn't be saved: \(error.localizedDescription)" }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.mic?.beginWriting() }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            if let url = self.file, !self.results.contains(url), FileManager.default.fileExists(atPath: url.path) { self.results.insert(url, at: 0) }
        }
    }
}

struct RecordScreenView: View {
    @Bindable private var model = ScreenRecorder.shared
    @AppStorage("rs.target") private var target: CaptureTarget = .display
    @AppStorage("rs.systemAudio") private var systemAudio = false
    @AppStorage("rs.mic") private var microphone = false
    @AppStorage("rs.pointer") private var showPointer = true
    @AppStorage("rs.clicks") private var highlightClicks = false
    @AppStorage("rs.resolution") private var resolution: RecordResolution = .native
    @AppStorage("rs.fps") private var fps = 30
    @AppStorage("rs.type") private var fileType: RecordFileType = .mov
    @AppStorage("rs.micDevice") private var micDevice = ""
    @AppStorage("rs.reduceNoise") private var reduceNoise = true
    @AppStorage("rs.countdown") private var countdown = 3

    private var options: ScreenRecordingOptions {
        .init(target: target, systemAudio: systemAudio, microphone: microphone, micDevice: micDevice, reduceNoise: reduceNoise,
              showPointer: showPointer, highlightClicks: highlightClicks, resolution: resolution, fps: fps, fileType: fileType, countdown: countdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.hasAccess {
                Banner(symbol: "lock.shield", message: "Record Screen needs Screen & System Audio Recording permission.") {
                    Button("Allow…") { CGRequestScreenCaptureAccess() }
                }
            }
            Form {
                Section("Record") {
                    Picker("Capture", selection: $target) { ForEach(CaptureTarget.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                    switch target {
                    case .display:
                        Picker("Display", selection: $model.displayID) {
                            ForEach(model.displays, id: \.displayID) { d in
                                Text(NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }?.localizedName
                                     ?? "Display \(d.displayID)").tag(d.displayID)
                            }
                        }
                    case .window:
                        Picker("Window", selection: $model.windowID) {
                            Text("Choose…").tag(CGWindowID?.none)
                            ForEach(model.windows, id: \.windowID) { Text(ScreenRecorder.windowName($0)).lineLimit(1).tag(CGWindowID?.some($0.windowID)) }
                        }
                        Button("Refresh Windows") { Task { await model.refresh() } }
                    case .area:
                        Text("After you click Record, drag over the part of the screen to record. Press Esc to cancel.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("System audio", isOn: $systemAudio)
                    Toggle("Microphone", isOn: $microphone)
                    if microphone {
                        MicrophonePicker(selection: $micDevice, inputs: model.inputs)
                        NoiseReductionToggle(isOn: $reduceNoise).disabled(Shell.which("ffmpeg") == nil)
                    }
                } header: {
                    Text("Sound")
                } footer: {
                    if microphone && reduceNoise {
                        Text(Shell.which("ffmpeg") == nil
                             ? "Reducing background noise needs the free ffmpeg helper (Settings → Helpers)."
                             : "Keeps your voice and removes background noise, room echo and the Mac's own sound from the microphone. System audio is still recorded cleanly on its own.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Picture") {
                    Toggle("Show pointer", isOn: $showPointer)
                    Toggle("Highlight clicks", isOn: $highlightClicks)
                    Picker("Resolution", selection: $resolution) { ForEach(RecordResolution.allCases) { Text($0.title).tag($0) } }
                    Picker("Frame rate", selection: $fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                    Picker("Format", selection: $fileType) { ForEach(RecordFileType.allCases) { Text("\($0.rawValue) (H.264)").tag($0) } }
                    Picker("Countdown", selection: $countdown) { Text("Off").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5) }
                }
            }
            .formStyle(.grouped)
            .disabled(model.recording || model.starting || model.finishing)
            .frame(maxWidth: 560)

            HStack(spacing: 14) {
                if model.recording {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(minWidth: 120) }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(timecode(Date().timeIntervalSince(model.startedAt ?? Date()))).font(.title2.monospacedDigit())
                    }
                    if model.usesOwnMicrophone {
                        LevelMeter(level: model.micLevel).frame(width: 120, height: 6).help("Microphone level")
                        MicModeButton()
                    }
                    Text("Stop from the menu bar too.").foregroundStyle(.secondary)
                } else if model.finishing {
                    ProgressView().controlSize(.small)
                    Text("Adding your voice to the video…").foregroundStyle(.secondary)
                } else {
                    Button {
                        model.start(options)
                    } label: { Label("Record", systemImage: "record.circle").frame(minWidth: 120) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.starting || (target == .window && model.windowID == nil))
                    if model.starting { ProgressView().controlSize(.small) }
                }
            }
            if let e = model.error { ErrorText(message: e) }
            ResultList(urls: model.results)
            SavesToLine()
            Spacer()
        }
        .task { await model.refresh() }
    }
}

// MARK: - Countdown before recording

@MainActor
enum Countdown {
    @Observable final class Ticker { var value = 0 }

    /// Shows 3… 2… 1… in the middle of `screen`. MyToolbox's own windows aren't recorded, so it never shows up in the video.
    static func run(_ seconds: Int, on screen: NSScreen?) async {
        guard seconds > 0, let screen = screen ?? NSScreen.main else { return }
        let size = CGSize(width: 180, height: 180)
        let panel = NSPanel(contentRect: CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let ticker = Ticker()
        panel.contentView = NSHostingView(rootView: CountdownBadge(ticker: ticker))
        for n in stride(from: seconds, to: 0, by: -1) {
            ticker.value = n
            panel.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
    }

    private struct CountdownBadge: View {
        let ticker: Ticker
        var body: some View {
            Text("\(ticker.value)")
                .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 180, height: 180)
                .background(.black.opacity(0.65), in: Circle())
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: ticker.value)
        }
    }
}

// MARK: - Choosing an area of the screen

/// Covers every screen with a dimmed layer; the person drags out a rectangle (Esc cancels).
@MainActor
enum AreaPicker {
    private static var windows: [NSWindow] = []
    private static var finish: ((CGDirectDisplayID, CGRect)?) -> Void = { _ in }

    /// The display and the rectangle on it, in points from its top-left corner.
    static func pick() async -> (CGDirectDisplayID, CGRect)? {
        await withCheckedContinuation { cont in
            var done = false
            finish = { result in
                guard !done else { return }
                done = true
                windows.forEach { $0.orderOut(nil) }
                windows = []
                cont.resume(returning: result)
            }
            for screen in NSScreen.screens {
                let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.level = .screenSaver
                w.isOpaque = false
                w.backgroundColor = .clear
                w.isReleasedWhenClosed = false
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
                w.contentView = AreaSelectionView(displayID: id) { finish($0) }
                w.setFrame(screen.frame, display: true)
                w.makeKeyAndOrderFront(nil)
                windows.append(w)
            }
            NSApp.activate()
            NSCursor.crosshair.push()
        }
    }

    static func done() { NSCursor.pop() }
}

/// Borderless windows can't take key focus by default; this one must, to hear Esc.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class AreaSelectionView: NSView {
    let displayID: CGDirectDisplayID
    let onDone: ((CGDirectDisplayID, CGRect)?) -> Void
    private var start: NSPoint?
    private var current: NSPoint?

    init(displayID: CGDirectDisplayID, onDone: @escaping ((CGDirectDisplayID, CGRect)?) -> Void) {
        self.displayID = displayID
        self.onDone = onDone
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let s = selection { path.append(NSBezierPath(rect: s)); path.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.35).setFill()
        path.fill()
        if let s = selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: s.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
            let label = "\(Int(s.width)) × \(Int(s.height))" as NSString
            label.draw(at: NSPoint(x: s.minX + 4, y: max(4, s.minY - 20)),
                       withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        } else {
            let hint = "Drag over the area to record · Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 18, weight: .medium)]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attrs)
        }
    }

    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { current = convert(e.locationInWindow, from: nil); needsDisplay = true }

    override func mouseUp(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        guard let s = selection, s.width >= 20, s.height >= 20 else { start = nil; current = nil; needsDisplay = true; return }
        AreaPicker.done()
        // Flip to top-left origin, as ScreenCaptureKit expects.
        onDone((displayID, CGRect(x: s.minX, y: bounds.height - s.maxY, width: s.width, height: s.height)))
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { AreaPicker.done(); onDone(nil) } else { super.keyDown(with: e) }
    }
}
