import AVFoundation
import AVKit
import SwiftUI

// MARK: - What's in a media file

/// ffprobe's view of a file: container, streams and tags. Read once, used by every video and audio tool.
struct MediaProbe {
    let format: [String: Any]
    let streams: [[String: Any]]
    /// ffprobe's JSON as it came, for Media Info's export.
    let json: Data

    static func read(_ url: URL) async throws -> MediaProbe {
        let probe = try Shell.require("ffprobe")
        let r = try await Shell.run(probe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path])
        guard r.ok, let data = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("This file isn't a video or audio file that can be read — it may be damaged or a different kind of file.")
        }
        return MediaProbe(format: obj["format"] as? [String: Any] ?? [:], streams: obj["streams"] as? [[String: Any]] ?? [], json: data)
    }

    var duration: Double { Double(format["duration"] as? String ?? "") ?? Double(video?["duration"] as? String ?? "") ?? 0 }
    /// The first real picture stream (cover art in audio files doesn't count).
    var video: [String: Any]? {
        streams.first { $0["codec_type"] as? String == "video" && ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 }
    }
    var audio: [String: Any]? { streams.first { $0["codec_type"] as? String == "audio" } }
    var hasAudio: Bool { audio != nil }
    var sampleRate: Int { Int(audio?["sample_rate"] as? String ?? "") ?? 48_000 }

    /// Rotation phones store instead of turning the pixels (ffmpeg applies it when encoding).
    var rotation: Int {
        let side = (video?["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Int }.first
        let tag = Int((video?["tags"] as? [String: Any])?["rotate"] as? String ?? "")
        return ((side ?? tag ?? 0) % 360 + 360) % 360
    }

    /// Picture size as players show it, after rotation.
    var displaySize: CGSize {
        let w = video?["width"] as? Int ?? 0, h = video?["height"] as? Int ?? 0
        return rotation == 90 || rotation == 270 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    var frameRate: Double? {
        guard let s = video?["avg_frame_rate"] as? String ?? video?["r_frame_rate"] as? String else { return nil }
        let p = s.split(separator: "/").compactMap { Double($0) }
        return p.count == 2 && p[1] > 0 && p[0] > 0 ? p[0] / p[1] : nil
    }
}

// MARK: - ffmpeg plumbing shared by the media tools

/// Runs ffmpeg for one file with progress, deleting a half-written result if it fails.
func runFFmpeg(_ args: [String], input: URL, output: URL, needsAudio: Bool = false, cwd: URL? = nil,
               progress: @escaping @MainActor (Double) -> Void) async throws -> BatchOutput {
    if Shell.which("ffmpeg") == nil { throw ShellError.missing("ffmpeg") }
    if needsAudio, await FFmpeg.hasAudio(input) == false { throw ToolError("This file has no sound track.") }
    do {
        try await FFmpeg.run(args, duration: await FFmpeg.duration(input), cwd: cwd, progress: progress)
    } catch {
        try? FileManager.default.removeItem(at: output)
        throw error
    }
    return BatchOutput(files: [output], note: sizeChange(input.fileSize, output.fileSize))
}

/// Audio encoders that suit each container, so a file can keep its format after editing.
enum AudioEncoding {
    /// The extension the result keeps (unknown containers become M4A) and the ffmpeg arguments to encode it.
    static func forExtension(_ ext: String, kbps: Int = 192) -> (ext: String, args: [String]) {
        switch ext.lowercased() {
        case "mp3": ("mp3", ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"])
        case "wav": ("wav", ["-c:a", "pcm_s16le"])
        case "aif", "aiff", "aifc": (ext.lowercased(), ["-c:a", "pcm_s16be"])
        case "flac": ("flac", ["-c:a", "flac"])
        case "ogg", "oga": ("ogg", ["-c:a", "libvorbis", "-q:a", "6"])
        case "opus": ("opus", ["-c:a", "libopus", "-b:a", "\(min(kbps, 256))k"])
        case "webm": ("webm", ["-c:a", "libopus", "-b:a", "\(min(kbps, 256))k"])
        case "m4a", "m4b", "aac", "mp4", "m4v", "mov", "mkv", "caf": (ext.lowercased() == "aac" ? "m4a" : ext.lowercased(), ["-c:a", "aac", "-b:a", "\(kbps)k"])
        default: ("m4a", ["-c:a", "aac", "-b:a", "\(kbps)k"])
        }
    }
}

/// Where a re-encoded video goes: its own format, or MP4 / MOV.
enum VideoOutput: String, CaseIterable, Identifiable {
    case same = "Same as original", mp4 = "MP4", mov = "MOV"
    var id: String { rawValue }

    /// Containers kept as they are; anything else (AVI, WMV, FLV…) becomes MP4.
    private static let keepable = ["mp4", "m4v", "mov", "mkv", "webm"]

    func ext(for input: URL) -> String {
        switch self {
        case .mp4: "mp4"
        case .mov: "mov"
        case .same: Self.keepable.contains(input.pathExtension.lowercased()) ? input.pathExtension.lowercased() : "mp4"
        }
    }

    /// Video and audio encoder arguments for a container.
    static func encode(ext: String, audio: Bool = true) -> [String] {
        var a: [String]
        if ext == "webm" {
            a = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
        } else {
            a = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
        }
        a += audio ? AudioEncoding.forExtension(ext, kbps: 160).args : ["-an"]
        if ext == "mp4" || ext == "mov" || ext == "m4v" { a += ["-movflags", "+faststart"] }
        return a
    }
}

enum VideoFrame {
    /// One still from a video, as players show it (rotation applied), at most `maxSize` pixels on its long side.
    static func grab(_ url: URL, at seconds: Double, maxSize: Int = 1280) async throws -> CGImage {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        if let ffmpeg = Shell.which("ffmpeg") {
            let scale = "scale='if(gte(iw,ih),min(\(maxSize),iw),-2)':'if(gte(iw,ih),-2,min(\(maxSize),ih))'"
            for t in [seconds, 0] {
                _ = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-ss", String(max(0, t)), "-i", url.path,
                                                 "-frames:v", "1", "-vf", scale, temp.path])
                if let image = try? ImageKit.load(temp) { return image }
            }
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        do {
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        } catch {
            throw ToolError("Can't show a picture from \(url.lastPathComponent).")
        }
    }
}

// MARK: - Picking part of a clip

/// A clip being trimmed: the player, its length and the chosen start and end.
@MainActor @Observable
final class MediaClip {
    let url: URL
    let player: AVPlayer
    var duration: Double = 0
    var current: Double = 0
    var start: Double = 0
    var end: Double = 0
    /// False for files AVFoundation can't play (MKV, WebM…): times can still be typed.
    var playable = true
    var loading = true
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var stopAt: Double?

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds.isFinite ? time.seconds : 0
                if let stop = self.stopAt, self.current >= stop { self.player.pause(); self.stopAt = nil }
            }
        }
        Task { await load() }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        playable = (try? await asset.load(.isPlayable)) ?? false
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        if duration == 0 || !playable, let probe = try? await MediaProbe.read(url) { duration = probe.duration }
        end = duration
        loading = false
    }

    var length: Double { max(0, end - start) }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = t
    }

    func playSelection() {
        seek(start)
        stopAt = end
        player.play()
    }

    func setStartToPlayhead() { start = min(current, max(0, end - 0.1)) }
    func setEndToPlayhead() { end = max(current, min(duration, start + 0.1)) }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var audioOnly = false

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = audioOnly ? .inline : .floating
        v.showsFullScreenToggleButton = !audioOnly
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// Timeline with start and end handles, the playhead, and buttons to set and play the selection.
struct RangeTimeline: View {
    @Bindable var clip: MediaClip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width, d = max(clip.duration, 0.001)
                let x = { (t: Double) in CGFloat(t / d) * w }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    Rectangle().fill(Color.accentColor.opacity(0.25))
                        .frame(width: max(0, x(clip.end) - x(clip.start))).offset(x: x(clip.start))
                    Rectangle().fill(.primary).frame(width: 2).offset(x: x(clip.current) - 1).allowsHitTesting(false)
                    handle.offset(x: x(clip.start) - 6)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            clip.start = min(max(0, Double(g.location.x / w) * d), clip.end - 0.1)
                            clip.seek(clip.start)
                        })
                        .accessibilityLabel("Start")
                    handle.offset(x: x(clip.end) - 6)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            clip.end = max(min(d, Double(g.location.x / w) * d), clip.start + 0.1)
                            clip.seek(clip.end)
                        })
                        .accessibilityLabel("End")
                }
                .coordinateSpace(name: "timeline")
                .contentShape(Rectangle())
                .onTapGesture { p in clip.seek(min(max(0, Double(p.x / w) * d), d)) }
            }
            .frame(height: 36)
            .disabled(clip.duration == 0)

            HStack(spacing: 12) {
                TimecodeField(label: "Start", seconds: $clip.start, range: 0...max(0, clip.end - 0.1))
                TimecodeField(label: "End", seconds: $clip.end, range: min(clip.start + 0.1, clip.duration)...max(clip.duration, 0.1))
                Text("Length \(TimecodeField.format(clip.length))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button("Set Start to Playhead") { clip.setStartToPlayhead() }
                Button("Set End to Playhead") { clip.setEndToPlayhead() }
                Button { clip.playSelection() } label: { Label("Play Selection", systemImage: "play.fill") }
                    .keyboardShortcut(.space, modifiers: [])
            }
            .disabled(!clip.playable)
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
            .frame(width: 12, height: 36)
            .overlay(Capsule().fill(.white.opacity(0.8)).frame(width: 2, height: 14))
    }
}

/// "1:23.5" or "83.5" ⇄ seconds.
struct TimecodeField: View {
    let label: String
    @Binding var seconds: Double
    var range: ClosedRange<Double>
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: $text)
                .labelsHidden().frame(width: 96).monospacedDigit()
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
        }
        .onAppear { text = Self.format(seconds) }
        .onChange(of: seconds) { if !focused { text = Self.format(seconds) } }
    }

    private func commit() {
        if let t = Self.parse(text) { seconds = min(max(t, range.lowerBound), range.upperBound) }
        text = Self.format(seconds)
    }

    /// "1:23.500", or "1:02:03.500" past an hour.
    static func format(_ s: Double) -> String {
        let t = max(0, s), ms = Int(((t - t.rounded(.down)) * 1000).rounded()) % 1000
        return timecode(t) + String(format: ".%03d", ms)
    }

    static func parse(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

// MARK: - Picking part of a picture

/// Aspect ratios offered when cropping.
enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Freeform", original = "Original", square = "1:1", wide = "16:9", vertical = "9:16", classic = "4:3", portrait = "4:5"
    var id: String { rawValue }
    /// Width ÷ height in pixels; nil for freeform.
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: original.height > 0 ? original.width / original.height : nil
        case .square: 1
        case .wide: 16.0 / 9
        case .vertical: 9.0 / 16
        case .classic: 4.0 / 3
        case .portrait: 4.0 / 5
        }
    }
}

/// A picture with a crop frame on top: drag the corners to resize, drag inside to move.
/// `rect` is in 0…1 of the picture, origin at the top left.
struct CropEditor: View {
    let image: NSImage
    @Binding var rect: CGRect
    /// Width ÷ height in pixels to keep, or nil.
    var aspect: CGFloat?
    /// False for a fixed size (like a 4 × 6 in label): the frame can only be moved.
    var resizable = true
    @State private var startRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let size = fitted(image.size, in: geo.size)
            let frame = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(frame)
                }
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                // Accent frame so it shows on white pages as well as on video.
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.white.opacity(0.001))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .gesture(drag(size) { r, t in
                        r.origin.x = min(max(0, r.minX + t.width), 1 - r.width)
                        r.origin.y = min(max(0, r.minY + t.height), 1 - r.height)
                    })
                    .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
                ForEach(resizable ? 0..<4 : 0..<0, id: \.self) { corner in
                    let px = corner % 2 == 0 ? frame.minX : frame.maxX, py = corner < 2 ? frame.minY : frame.maxY
                    Circle().fill(.white).overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: 14, height: 14).shadow(radius: 1)
                        .offset(x: px - 7, y: py - 7)
                        .gesture(drag(size) { r, t in resize(&r, corner: corner, by: t, picture: size) })
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fitted(_ s: CGSize, in box: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return box }
        let k = min(box.width / s.width, box.height / s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }

    private func drag(_ size: CGSize, _ apply: @escaping (inout CGRect, CGSize) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                let base = startRect ?? rect
                if startRect == nil { startRect = rect }
                var r = base
                apply(&r, CGSize(width: g.translation.width / size.width, height: g.translation.height / size.height))
                rect = r
            }
            .onEnded { _ in startRect = nil }
    }

    /// Moves one corner while the opposite one stays put, keeping the aspect ratio if there is one.
    private func resize(_ r: inout CGRect, corner: Int, by t: CGSize, picture: CGSize) {
        let left = corner % 2 == 0, top = corner < 2
        let anchorX = left ? r.maxX : r.minX, anchorY = top ? r.maxY : r.minY
        var x = (left ? r.minX : r.maxX) + t.width, y = (top ? r.minY : r.maxY) + t.height
        x = min(max(0, x), 1); y = min(max(0, y), 1)
        var w = max(0.03, abs(anchorX - x)), h = max(0.03, abs(anchorY - y))
        if let aspect, picture.height > 0 {
            // Aspect in 0…1 units of this picture.
            let k = aspect * picture.height / picture.width
            if w / h > k { w = h * k } else { h = w / k }
            let maxW = left ? anchorX : 1 - anchorX, maxH = top ? anchorY : 1 - anchorY
            if w > maxW { w = maxW; h = w / k }
            if h > maxH { h = maxH; w = h * k }
        }
        r = CGRect(x: left ? anchorX - w : anchorX, y: top ? anchorY - h : anchorY, width: w, height: h)
    }

    /// The biggest centred frame of `aspect` (width ÷ height in pixels) on a picture of `size`.
    static func centered(aspect: CGFloat?, picture size: CGSize) -> CGRect {
        guard let aspect, size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let k = aspect * size.height / size.width
        let w = k >= 1 ? 1 : k, h = k >= 1 ? 1 / k : 1
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}
