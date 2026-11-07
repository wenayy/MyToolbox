import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let conversionTools: [Tool] = [
        Tool("convertvideo", "Convert Video", "film.stack", .video,
             "Turn videos into MP4, MOV, WebM, MKV or ProRes — instantly when no re-encoding is needed",
             accepts: [.movie], fullBleed: true) { ConvertVideoView() },
        Tool("gif", "Video to GIF", "photo.badge.arrow.down", .video,
             "Make a looping GIF from a clip, with sharp colours and a size you choose", accepts: [.movie], fullBleed: true) { VideoToGIFView() },
        Tool("extractaudio", "Extract Audio", "waveform.badge.plus", .audio,
             "Save the soundtrack of a video as M4A, MP3 or WAV", accepts: [.movie], fullBleed: true) { ExtractAudioView() },
        Tool("convertaudio", "Convert Audio", "music.note.list", .audio,
             "Switch audio between MP3, M4A, WAV, FLAC, Opus and OGG", accepts: [.audio], fullBleed: true) { ConvertAudioView() },
    ]
}

/// ffmpeg arguments for the conversion tools (pure, so they're testable).
enum MediaArgs {
    enum VideoTarget: String, CaseIterable, Identifiable {
        case mp4 = "MP4 (H.264)", mov = "MOV (H.264)", hevc = "MP4 (HEVC)", webm = "WebM (VP9)", mkv = "MKV", prores = "MOV (ProRes)"
        var id: String { rawValue }
        var ext: String {
            switch self {
            case .mp4, .hevc: "mp4"
            case .mov, .prores: "mov"
            case .webm: "webm"
            case .mkv: "mkv"
            }
        }
        /// Containers that can usually take the original streams as they are.
        var canRemux: Bool { self == .mp4 || self == .mov || self == .mkv }
    }

    static func video(_ input: URL, _ output: URL, target: VideoTarget, remux: Bool) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0"]
        if remux {
            a += ["-c", "copy"]
        } else {
            switch target {
            case .mp4, .mov: a += ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]
            case .hevc: a += ["-c:v", "libx265", "-preset", "medium", "-crf", "23", "-tag:v", "hvc1", "-x265-params", "log-level=error", "-c:a", "aac", "-b:a", "160k"]
            case .webm: a += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
            case .mkv: a += ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "160k"]
            case .prores: a += ["-c:v", "prores_videotoolbox", "-profile:v", "2", "-c:a", "pcm_s16le"]
            }
        }
        if target.ext == "mp4" || target.ext == "mov" { a += ["-movflags", "+faststart"] }
        return a + ["-progress", "pipe:1", "-nostats", output.path]
    }

    static func gif(_ input: URL, _ output: URL, fps: Int, width: Int, start: Double, duration: Double) -> [String] {
        let scale = width > 0 ? "scale='min(\(width),iw)':-2:flags=lanczos" : "scale=iw:-2:flags=lanczos"
        var a = ["-hide_banner", "-nostdin", "-y"]
        if start > 0 { a += ["-ss", String(start)] }
        if duration > 0 { a += ["-t", String(duration)] }
        // Two-step palette so colours stay clean instead of dithered mush.
        return a + ["-i", input.path, "-vf", "fps=\(fps),\(scale),split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
                    "-loop", "0", "-progress", "pipe:1", "-nostats", output.path]
    }

    enum AudioTarget: String, CaseIterable, Identifiable {
        case mp3 = "MP3", m4a = "M4A (AAC)", wav = "WAV", flac = "FLAC", opus = "Opus", ogg = "OGG (Vorbis)"
        var id: String { rawValue }
        var ext: String {
            switch self {
            case .mp3: "mp3"
            case .m4a: "m4a"
            case .wav: "wav"
            case .flac: "flac"
            case .opus: "opus"
            case .ogg: "ogg"
            }
        }
        var lossless: Bool { self == .wav || self == .flac }
    }

    static func audio(_ input: URL, _ output: URL, target: AudioTarget, kbps: Int) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-vn", "-map_metadata", "0"]
        switch target {
        case .mp3: a += ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
        case .m4a: a += ["-c:a", "aac", "-b:a", "\(kbps)k"]
        case .wav: a += ["-c:a", "pcm_s16le"]
        case .flac: a += ["-c:a", "flac"]
        case .opus: a += ["-c:a", "libopus", "-b:a", "\(min(kbps, 256))k"]
        // Vorbis refuses fixed bitrates its encoder can't hit (e.g. 192k on a mono voice memo); quality mode always works.
        case .ogg: a += ["-c:a", "libvorbis", "-q:a", kbps >= 320 ? "9" : kbps >= 256 ? "8" : kbps >= 192 ? "6" : "4"]
        }
        return a + ["-progress", "pipe:1", "-nostats", output.path]
    }
}

struct ConvertVideoView: View {
    @AppStorage("cv.target") private var target: MediaArgs.VideoTarget = .mp4
    @AppStorage("cv.remux") private var preferRemux = true

    var body: some View {
        BatchToolView(toolID: "convertvideo", folderName: "", types: [.movie, .video], noun: "Video", verb: "Convert", concurrency: 1,
                      previewKey: "\(target.rawValue)|\(preferRemux)") {
            Section {
                Picker("Convert to", selection: $target) { ForEach(MediaArgs.VideoTarget.allCases) { Text($0.rawValue).tag($0) } }
                if target.canRemux { Toggle("Skip re-encoding when possible (instant, no quality loss)", isOn: $preferRemux) }
            } footer: {
                Text(target == .webm ? "WebM is for the web; VP9 encoding is slow." : target == .prores ? "ProRes is for editing — files are very large." : "Plays in QuickTime, Photos and on iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } process: { [target, preferRemux] url, folder, progress in
            let out = ImageKit.outputURL(for: url, in: folder, suffix: url.pathExtension.lowercased() == target.ext ? " converted" : "", ext: target.ext)
            if preferRemux && target.canRemux {
                // Try copying the streams first; fall back to re-encoding if the container won't take them.
                if let done = try? await runFFmpeg(MediaArgs.video(url, out, target: target, remux: true), input: url, output: out, progress: progress) {
                    return BatchOutput(files: done.files, note: "Remuxed · " + (done.note ?? ""))
                }
            }
            return try await runFFmpeg(MediaArgs.video(url, out, target: target, remux: false), input: url, output: out, progress: progress)
        }
    }
}

struct VideoToGIFView: View {
    @AppStorage("gif.fps") private var fps = 15
    @AppStorage("gif.width") private var width = 480
    @State private var start = 0.0
    @State private var duration = 6.0

    var body: some View {
        BatchToolView(toolID: "gif", folderName: "", types: [.movie, .video], noun: "Video", verb: "Make GIF from", concurrency: 1,
                      previewKey: "\(fps)|\(width)|\(start)|\(duration)", previewStart: { [start] _ in start }) {
            Section {
                Picker("Width", selection: $width) { Text("320 px").tag(320); Text("480 px").tag(480); Text("640 px").tag(640); Text("800 px").tag(800); Text("Original").tag(0) }
                Picker("Frames per second", selection: $fps) { Text("10").tag(10); Text("15").tag(15); Text("20").tag(20); Text("25").tag(25) }
                TextField("Start at (seconds)", value: $start, format: .number)
                TextField("Length (seconds, 0 = whole video)", value: $duration, format: .number)
            } footer: {
                Text("GIFs get big fast — keep clips short and narrow.").font(.caption).foregroundStyle(.secondary)
            }
        } process: { [fps, width, start, duration] url, folder, progress in
            let out = ImageKit.outputURL(for: url, in: folder, ext: "gif")
            // A preview is handed a piece that already begins at the chosen start.
            let preview = Previewing.current
            let (s, d) = preview.map { (0, duration > 0 ? min(duration, $0.length) : 0) } ?? (start, duration)
            let r = try await runFFmpeg(MediaArgs.gif(url, out, fps: fps, width: width, start: s, duration: d), input: url, output: out, progress: progress)
            return BatchOutput(files: r.files, note: out.fileSize.byteString)
        }
    }
}

struct ExtractAudioView: View {
    @AppStorage("ea.target") private var target: MediaArgs.AudioTarget = .m4a

    var body: some View {
        BatchToolView(toolID: "extractaudio", folderName: "", types: [.movie, .video], noun: "Video", verb: "Extract Audio from", concurrency: 2,
                      previewKey: target.rawValue) {
            Section {
                Picker("Save as", selection: $target) {
                    ForEach([MediaArgs.AudioTarget.m4a, .mp3, .wav, .flac]) { Text($0.rawValue).tag($0) }
                }
            }
        } process: { [target] url, folder, progress in
            let out = ImageKit.outputURL(for: url, in: folder, ext: target.ext)
            let r = try await runFFmpeg(MediaArgs.audio(url, out, target: target, kbps: 192), input: url, output: out, needsAudio: true, progress: progress)
            return BatchOutput(files: r.files, note: "\(target.rawValue) · \(out.fileSize.byteString)")
        }
    }
}

struct ConvertAudioView: View {
    @AppStorage("ca.target") private var target: MediaArgs.AudioTarget = .mp3
    @AppStorage("ca.kbps") private var kbps = 192

    var body: some View {
        BatchToolView(toolID: "convertaudio", folderName: "", types: [.audio], noun: "Audio File", verb: "Convert", concurrency: 3,
                      previewKey: "\(target.rawValue)|\(kbps)") {
            Section {
                Picker("Convert to", selection: $target) { ForEach(MediaArgs.AudioTarget.allCases) { Text($0.rawValue).tag($0) } }
                if !target.lossless {
                    Picker("Quality", selection: $kbps) { Text("128 kbps").tag(128); Text("192 kbps").tag(192); Text("256 kbps").tag(256); Text("320 kbps").tag(320) }
                }
            } footer: {
                Text(target.lossless ? "Lossless — bigger files, perfect quality." : "Higher bitrates sound better and make bigger files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } process: { [target, kbps] url, folder, progress in
            let out = ImageKit.outputURL(for: url, in: folder, suffix: url.pathExtension.lowercased() == target.ext ? " converted" : "", ext: target.ext)
            return try await runFFmpeg(MediaArgs.audio(url, out, target: target, kbps: kbps), input: url, output: out, needsAudio: true, progress: progress)
        }
    }
}
