import AVFoundation
import AVKit
import Observation
import SwiftUI

// Live preview: a short piece of the file is run through the tool's *own* processing code into a temporary
// folder and played back, so what you see and hear is exactly what the Run button will make.

/// Set while a tool's processing code is making a preview from an excerpt rather than the real file.
struct PreviewContext: Sendable {
    /// The file the person chose; the code is being given an excerpt of it.
    let original: URL
    /// Where the excerpt starts in the original, in seconds.
    let start: Double
    let length: Double
}

enum Previewing {
    @TaskLocal static var current: PreviewContext?
}

/// Shown instead of a preview when the tool would make nothing ("Already silent", "Speed is 1×").
struct PreviewNote: Error { let message: String }

enum LivePreview {
    static let videoLength = 6.0
    static let audioLength = 10.0

    /// Scratch space for excerpts and previews, emptied the first time it's used in each launch.
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("MyToolbox Preview", isDirectory: true)
        try? FileManager.default.removeItem(at: d)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func newFolder() -> URL {
        let f = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// A short piece of `url` from `start`: H.264 with uncompressed sound in a MOV (at most 720p, quick to process)
    /// for videos, WAV for audio. Lossless sound keeps audio comparisons honest.
    static func excerpt(_ url: URL, start: Double, length: Double, video: Bool) async throws -> URL {
        let ffmpeg = try Shell.require("ffmpeg")
        let out = dir.appendingPathComponent("excerpt-\(UUID().uuidString).\(video ? "mov" : "wav")")
        var a = VideoEditArgs.head + ["-ss", VideoEditArgs.seconds(start), "-t", VideoEditArgs.seconds(length), "-i", url.path]
        if video {
            a += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "\(VideoEditArgs.shortSide(720)),format=yuv420p",
                  "-c:v", "libx264", "-preset", "ultrafast", "-crf", "16", "-c:a", "pcm_s16le"]
        } else {
            a += ["-map", "0:a:0", "-vn", "-c:a", "pcm_s16le"]
        }
        let r = try await Shell.run(ffmpeg, a + [out.path])
        guard r.ok, out.fileSize > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw ToolError(FFmpeg.explain(r.err.components(separatedBy: "\n")))
        }
        return out
    }

    /// A copy AVFoundation can play (WebM, MKV, Opus, OGG… → MP4 or M4A); the file itself if it already plays.
    static func playable(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.isPlayable)) == true, ((try? await asset.load(.tracks)) ?? []).isEmpty == false { return url }
        let ffmpeg = try Shell.require("ffmpeg")
        let video = (try? await MediaProbe.read(url))?.video != nil
        let out = url.deletingPathExtension().appendingPathExtension("playback.\(video ? "mp4" : "m4a")")
        let enc = video ? ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "14", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k"]
                        : ["-vn", "-c:a", "aac", "-b:a", "256k"]
        let r = try await Shell.run(ffmpeg, VideoEditArgs.head + ["-i", url.path] + enc + [out.path])
        guard r.ok else { throw ToolError("This result can't be played here, but it will be saved fine.") }
        return out
    }

    /// The file in a tool's result worth showing: a video, a sound, a GIF or a picture.
    static func showable(_ output: BatchOutput) throws -> URL {
        guard let file = output.files.first(where: { !$0.isDirectory }) ?? output.files.first.flatMap(firstImage) else {
            throw PreviewNote(message: output.note ?? "Nothing would change")
        }
        return file
    }

    private static func firstImage(in folder: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }.first
    }

    static func isImage(_ url: URL) -> Bool { ["gif", "png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(url.pathExtension.lowercased()) }
}

/// One tool's preview: the excerpt (Before), the result (After), and a player that can switch between them.
@MainActor @Observable
final class LivePreviewModel {
    private static var models: [String: LivePreviewModel] = [:]
    static func `for`(_ id: String) -> LivePreviewModel {
        if let m = models[id] { return m }
        let m = LivePreviewModel()
        models[id] = m
        return m
    }

    enum Phase: Equatable { case idle, rendering, ready, note(String), failed(String) }

    var phase: Phase = .idle
    var before: URL?
    var after: URL?
    var showAfter = true { didSet { if showAfter != oldValue { load(keepTime: true) } } }
    /// Where the preview starts in the original, chosen by the person or the tool.
    var start: Double = 0
    var duration: Double = 0
    var sourceIsVideo = true
    let player = AVPlayer()
    @ObservationIgnored private var source: URL?
    @ObservationIgnored private var excerpts: [String: URL] = [:]
    @ObservationIgnored private var lastFolder: URL?
    @ObservationIgnored private var loop: Any?

    var shown: URL? { showAfter ? after : before }

    init() {
        loop = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
    }

    var length: Double { sourceIsVideo ? LivePreview.videoLength : LivePreview.audioLength }

    /// Makes a fresh preview after a short pause (typing and slider drags restart it), then shows it.
    func run(source url: URL, excerpt: Bool, preferredStart: ((URL) async -> Double?)?,
             render: @escaping @MainActor (URL, URL) async throws -> URL) async {
        if url != source {
            source = url
            excerpts = [:]
            before = nil; after = nil
            player.replaceCurrentItem(with: nil)
            let p = try? await MediaProbe.read(url)
            duration = p?.duration ?? 0
            sourceIsVideo = p?.video != nil
            let preferred = await preferredStart?(url)
            // Changing `start` restarts this task through the view's task id; that run does the work.
            let s = max(0, min(preferred ?? (duration > 30 ? duration * 0.15 : 0), max(0, duration - 1)))
            if s != start { start = s; return }
        }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        phase = .rendering
        do {
            let length = min(length, max(0.5, duration - start))
            var input = url
            if excerpt {
                let key = "\(start)|\(length)"
                if let cached = excerpts[key], FileManager.default.fileExists(atPath: cached.path) {
                    input = cached
                } else {
                    input = try await LivePreview.excerpt(url, start: start, length: length, video: sourceIsVideo)
                    excerpts[key] = input
                }
            }
            let folder = LivePreview.newFolder()
            let made = try await Previewing.$current.withValue(PreviewContext(original: url, start: excerpt ? start : 0, length: length)) {
                try await render(input, folder)
            }
            let shown = LivePreview.isImage(made) ? made : try await LivePreview.playable(made)
            if Task.isCancelled { try? FileManager.default.removeItem(at: folder); return }
            if let old = lastFolder { try? FileManager.default.removeItem(at: old) }
            lastFolder = folder
            before = input == url ? (LivePreview.isImage(url) ? url : try? await LivePreview.playable(url)) : input
            after = shown
            phase = .ready
            load(keepTime: false)
        } catch is CancellationError {
        } catch let note as PreviewNote {
            if !Task.isCancelled { phase = .note(note.message); after = nil; load(keepTime: false) }
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription); after = nil; load(keepTime: false) }
        }
    }

    /// Puts Before or After in the player, keeping the position and play state so the two can be compared.
    private func load(keepTime: Bool) {
        let wasPlaying = player.rate > 0
        let time = player.currentTime()
        guard let url = shown, !LivePreview.isImage(url) else { player.replaceCurrentItem(with: nil); return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if keepTime { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        if wasPlaying { player.play() }
    }

    func stop() { player.pause() }
}

/// The preview area: the result playing, a Before / After switch, and where in the file to preview from.
struct LivePreviewPane: View {
    let id: String
    let source: URL
    /// Everything that changes the result; a new value makes a new preview.
    let key: String
    var excerpt = true
    var enabled = true
    var preferredStart: ((URL) async -> Double?)?
    let render: @MainActor (URL, URL) async throws -> URL
    @Bindable private var model: LivePreviewModel

    init(id: String, source: URL, key: String, excerpt: Bool = true, enabled: Bool = true,
         preferredStart: ((URL) async -> Double?)? = nil, render: @escaping @MainActor (URL, URL) async throws -> URL) {
        self.id = id
        self.source = source
        self.key = key
        self.excerpt = excerpt
        self.enabled = enabled
        self.preferredStart = preferredStart
        self.render = render
        model = LivePreviewModel.for(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Preview", systemImage: "eye").font(.headline)
                status
                Spacer()
                Picker("Show", selection: $model.showAfter) {
                    Text("Before").tag(false)
                    Text("After").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Switch between the original and the result. Playback keeps its place, so you can compare.")
                .disabled(model.after == nil)
            }
            stage
                .frame(maxWidth: .infinity, maxHeight: model.sourceIsVideo || showsImage ? .infinity : 64)
                .background(.black.opacity(model.sourceIsVideo ? 0.9 : 0.06), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if excerpt && model.duration > model.length + 1 {
                HStack(spacing: 10) {
                    Text("Preview from").foregroundStyle(.secondary)
                    Slider(value: $model.start, in: 0...max(0.1, model.duration - model.length)).controlSize(.small)
                    Text(timecode(model.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
                .font(.callout)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
            if !model.sourceIsVideo && !showsImage { Spacer(minLength: 0) }
        }
        .padding(16)
        .task(id: enabled ? "\(source.path)|\(key)|\(model.start)" : "off") {
            guard enabled else { model.stop(); return }
            await model.run(source: source, excerpt: excerpt, preferredStart: preferredStart, render: render)
        }
        .onDisappear { model.stop() }
    }

    private var showsImage: Bool { model.shown.map(LivePreview.isImage) ?? false }

    private var caption: String {
        let seconds = Int(min(model.length, max(1, model.duration)).rounded())
        let what = model.sourceIsVideo ? "Watch" : "Listen to"
        return excerpt
            ? "\(what) a \(seconds)-second piece made with your settings; switch Before / After to compare. Nothing is saved until you run the tool."
            : "Made with your settings. Nothing is saved until you run the tool."
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .rendering: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating…").foregroundStyle(.secondary) }.font(.callout)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Up to date with your settings")
        default: EmptyView()
        }
    }

    @ViewBuilder private var stage: some View {
        switch model.phase {
        case .note(let text) where model.showAfter:
            ContentUnavailableView(text, systemImage: "info.circle")
        case .failed(let text) where model.showAfter:
            ContentUnavailableView { Label("No Preview", systemImage: "exclamationmark.triangle") } description: { Text(text) }
        default:
            if let url = model.shown, LivePreview.isImage(url) {
                AnimatedImageView(url: url)
            } else if model.shown != nil {
                PlayerView(player: model.player, audioOnly: !model.sourceIsVideo)
            } else {
                ProgressView()
            }
        }
    }
}

/// Shows a picture; GIFs animate.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.image = NSImage(contentsOf: url)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image?.name() != url.path { v.image = NSImage(contentsOf: url); v.image?.setName(url.path) }
    }
}
