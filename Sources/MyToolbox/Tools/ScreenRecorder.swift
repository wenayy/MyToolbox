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
    var error: String?
    var results: [URL] = []
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var ticker: Timer?

    var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    func refresh() async {
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

    func start(target: CaptureTarget, systemAudio: Bool, microphone: Bool, showPointer: Bool, highlightClicks: Bool,
               resolution: RecordResolution, fps: Int, fileType: RecordFileType) {
        guard !recording, !starting else { return }
        error = nil
        guard hasAccess else {
            CGRequestScreenCaptureAccess()
            error = "Allow MyToolbox under Screen & System Audio Recording in System Settings, then quit and reopen MyToolbox."
            return
        }
        starting = true
        Task {
            defer { starting = false }
            do {
                if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                    throw ToolError("MyToolbox can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone, or turn Microphone off.")
                }
                await refresh()
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter: SCContentFilter
                var sourceRect: CGRect?
                switch target {
                case .display:
                    guard let d = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw ToolError("No display found.") }
                    filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                case .window:
                    guard let w = content.windows.first(where: { $0.windowID == windowID }) else { throw ToolError("Choose a window to record. It must be open on screen.") }
                    filter = SCContentFilter(desktopIndependentWindow: w)
                case .area:
                    guard let picked = await AreaPicker.pick() else { return }
                    guard let d = content.displays.first(where: { $0.displayID == picked.0 }) else { throw ToolError("That display isn't available.") }
                    filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                    sourceRect = picked.1
                }

                let config = SCStreamConfiguration()
                let points = sourceRect?.size ?? filter.contentRect.size
                let px = resolution.size(points: points, scale: CGFloat(filter.pointPixelScale))
                config.width = Int(px.width)
                config.height = Int(px.height)
                if let sourceRect { config.sourceRect = sourceRect }
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                config.queueDepth = 6
                config.showsCursor = showPointer
                config.showMouseClicks = highlightClicks
                config.capturesAudio = systemAudio
                config.excludesCurrentProcessAudio = true
                config.captureMicrophone = microphone

                let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                                       timeZone: .current, calendar: .current))
                let url = Output.file(name: "Screen Recording \(stamp)", ext: fileType.ext)
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = url
                rc.outputFileType = fileType.avType
                rc.videoCodecType = .h264
                let out = SCRecordingOutput(configuration: rc, delegate: self)
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                try s.addRecordingOutput(out)
                try await s.startCapture()
                stream = s; output = out; file = url
                recording = true
                startedAt = Date()
                showStatusItem()
            } catch {
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
            stream = nil; output = nil
            // The file is finished by the time stopCapture returns; the delegate confirms it.
            if let file, FileManager.default.fileExists(atPath: file.path), !results.contains(file) { results.insert(file, at: 0) }
            file = nil
            startedAt = nil
        }
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
                Section("Sound") {
                    Toggle("System audio", isOn: $systemAudio)
                    Toggle("Microphone", isOn: $microphone)
                }
                Section("Picture") {
                    Toggle("Show pointer", isOn: $showPointer)
                    Toggle("Highlight clicks", isOn: $highlightClicks)
                    Picker("Resolution", selection: $resolution) { ForEach(RecordResolution.allCases) { Text($0.title).tag($0) } }
                    Picker("Frame rate", selection: $fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                    Picker("Format", selection: $fileType) { ForEach(RecordFileType.allCases) { Text("\($0.rawValue) (H.264)").tag($0) } }
                }
            }
            .formStyle(.grouped)
            .disabled(model.recording || model.starting)
            .frame(maxWidth: 560)

            HStack(spacing: 14) {
                if model.recording {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(minWidth: 120) }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(timecode(Date().timeIntervalSince(model.startedAt ?? Date()))).font(.title2.monospacedDigit())
                    }
                    Text("Stop from the menu bar too.").foregroundStyle(.secondary)
                } else {
                    Button {
                        model.start(target: target, systemAudio: systemAudio, microphone: microphone, showPointer: showPointer,
                                    highlightClicks: highlightClicks, resolution: resolution, fps: fps, fileType: fileType)
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
