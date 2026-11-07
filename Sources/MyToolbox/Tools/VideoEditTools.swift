import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let videoEditTools: [Tool] = [
        Tool("trimvideo", "Trim Video", "timeline.selection", .video,
             "Cut the start and end of a clip without re-encoding", accepts: [.movie], fullBleed: true) { TrimView(kind: .video) },
        Tool("mergevideos", "Merge Videos", "rectangle.stack.badge.plus", .video,
             "Join several clips into one video, in the order you choose", accepts: [.movie], fullBleed: true) { MergeVideosView() },
        Tool("cropvideo", "Crop & Rotate Video", "crop.rotate", .video,
             "Crop, rotate and flip a video, to any shape or a square or vertical frame", accepts: [.movie], fullBleed: true) { CropVideoView() },
        Tool("resizevideo", "Resize Video", "aspectratio", .video,
             "Change the size of videos to 4K, 1080p, 720p, square, vertical or an exact size", accepts: [.movie], fullBleed: true) { ResizeVideoView() },
        Tool("speed", "Change Speed", "gauge.with.dots.needle.67percent", .video,
             "Speed up or slow down videos from 0.25× to 4×, without chipmunk voices", accepts: [.movie], fullBleed: true) { ChangeSpeedView() },
        Tool("burnsubs", "Burn In Subtitles", "captions.bubble", .video,
             "Draw captions into a video from an SRT file or an automatic transcription", accepts: [.movie], fullBleed: true) { BurnSubtitlesView() },
        Tool("replaceaudio", "Replace Audio", "music.note.tv", .video,
             "Put new music or narration under a video, or mix it with the original sound", accepts: [.movie], fullBleed: true) { ReplaceAudioView() },
        Tool("mutevideo", "Mute Video", "speaker.slash", .video,
             "Remove the sound from videos without re-encoding", accepts: [.movie], fullBleed: true) { MuteVideoView() },
        Tool("frames", "Extract Frames", "photo.stack", .video,
             "Save stills from a video as PNG, JPEG or HEIC — every few seconds, evenly spaced or one moment", accepts: [.movie], fullBleed: true) { ExtractFramesView() },
        Tool("mediainfo", "Media Info", "info.circle", .video,
             "See the codec, resolution, frame rate, bitrate and metadata of videos and audio", accepts: [.movie, .audio], fullBleed: true) { MediaInfoView() },
        Tool("recordscreen", "Record Screen", "record.circle", .video,
             "Record a display, a window or an area, with system sound and your microphone") { RecordScreenView() },
    ]
}

// MARK: - ffmpeg arguments (pure, so they're testable)

enum VideoEditArgs {
    static let head = ["-hide_banner", "-nostdin", "-y"]
    static let tail = ["-progress", "pipe:1", "-nostats"]

    static func seconds(_ s: Double) -> String { String(format: "%.3f", max(0, s)) }

    private static func faststart(_ ext: String) -> [String] { ["mp4", "mov", "m4v"].contains(ext) ? ["-movflags", "+faststart"] : [] }

    /// Keeps the part between `start` and `end`. Without `exact` the streams are copied (instant, cuts on keyframes).
    static func trim(_ input: URL, _ output: URL, start: Double, end: Double, exact: Bool) -> [String] {
        let ext = output.pathExtension.lowercased()
        var a = head + ["-ss", seconds(start), "-t", seconds(end - start), "-i", input.path]
        if exact {
            a += ["-map", "0:v?", "-map", "0:a?", "-map_metadata", "0"] + VideoOutput.encode(ext: ext)
        } else {
            a += ["-map", "0", "-dn", "-map_metadata", "0", "-c", "copy", "-avoid_negative_ts", "make_zero"] + faststart(ext)
        }
        return a + tail + [output.path]
    }

    /// Trims an audio file, re-encoding in its own format, with optional fades (seconds; 0 = none).
    static func trimAudio(_ input: URL, _ output: URL, start: Double, end: Double, fadeIn: Double, fadeOut: Double) -> [String] {
        let length = end - start
        var filters: [String] = []
        if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(seconds(min(fadeIn, length)))") }
        if fadeOut > 0 { filters.append("afade=t=out:st=\(seconds(max(0, length - fadeOut))):d=\(seconds(min(fadeOut, length)))") }
        var a = head + ["-ss", seconds(start), "-t", seconds(length), "-i", input.path, "-map", "0:a:0", "-vn", "-map_metadata", "0"]
        if !filters.isEmpty { a += ["-af", filters.joined(separator: ",")] }
        return a + AudioEncoding.forExtension(output.pathExtension).args + tail + [output.path]
    }

    /// `atempo` only takes 0.5…2 per step in older ffmpeg, so bigger changes are chained.
    static func atempoChain(_ speed: Double) -> String {
        var r = speed, parts: [String] = []
        while r > 2.0001 { parts.append("atempo=2"); r /= 2 }
        while r < 0.4999 { parts.append("atempo=0.5"); r /= 0.5 }
        parts.append("atempo=" + String(format: "%.4f", r))
        return parts.joined(separator: ",")
    }

    static func speed(_ input: URL, _ output: URL, speed: Double, keepPitch: Bool, audio: Bool, sampleRate: Int) -> [String] {
        let ext = output.pathExtension.lowercased()
        var a = head + ["-i", input.path, "-map", "0:v:0", "-filter:v", "setpts=PTS/\(String(format: "%.4f", speed))"]
        if audio {
            let af = keepPitch ? atempoChain(speed) : "asetrate=\(Int(Double(sampleRate) * speed)),aresample=\(sampleRate)"
            a += ["-map", "0:a:0", "-filter:a", af]
        }
        return a + VideoOutput.encode(ext: ext, audio: audio) + tail + [output.path]
    }

    /// Scale so the shorter side is at most `n` pixels (0 = keep), with even dimensions.
    static func shortSide(_ n: Int) -> String {
        n > 0 ? "scale='if(gte(iw,ih),-2,min(\(n),iw))':'if(gte(iw,ih),min(\(n),ih),-2)'" : "scale='trunc(iw/2)*2':'trunc(ih/2)*2'"
    }

    /// One frame every `interval` seconds into numbered PNGs (`pattern` like /tmp/x/%05d.png).
    static func framesEvery(_ input: URL, pattern: String, interval: Double, shortSide n: Int) -> [String] {
        head + ["-i", input.path, "-vf", "fps=1/\(String(format: "%.4f", interval)),\(shortSide(n))", "-fps_mode", "passthrough"] + tail + [pattern]
    }

    static func frame(_ input: URL, at t: Double, to output: URL, shortSide n: Int) -> [String] {
        head + ["-ss", seconds(t), "-i", input.path, "-frames:v", "1", "-vf", shortSide(n), output.path]
    }

    enum Fit: String, CaseIterable, Identifiable {
        case fit = "Fit within size", pad = "Add black bars", fill = "Crop to fill"
        var id: String { rawValue }
    }

    /// Encoders need even sizes: odd ones are rounded down.
    static func even(_ n: Int) -> Int { max(2, n / 2 * 2) }

    static func resizeFilter(width: Int, height: Int, keepAspect: Bool, fit: Fit) -> String {
        let w = even(width), h = even(height)
        guard keepAspect else { return "scale=\(w):\(h),setsar=1" }
        switch fit {
        case .fit: return "scale=\(w):\(h):force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1"
        case .pad: return "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,setsar=1"
        case .fill: return "scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),setsar=1"
        }
    }

    static func filtered(_ input: URL, _ output: URL, video filter: String) -> [String] {
        head + ["-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-vf", filter]
            + VideoOutput.encode(ext: output.pathExtension.lowercased()) + tail + [output.path]
    }

    /// Crop (`rect` in 0…1 of the picture as shown), then turn by quarter turns clockwise, then flip.
    /// Returns nil when nothing would change.
    static func cropFilter(rect: CGRect, source: CGSize, quarterTurns: Int, flipH: Bool, flipV: Bool) -> String? {
        var parts: [String] = []
        let full = rect.minX <= 0.001 && rect.minY <= 0.001 && rect.width >= 0.999 && rect.height >= 0.999
        if !full {
            let w = even(Int((rect.width * source.width).rounded())), h = even(Int((rect.height * source.height).rounded()))
            let x = min(Int((rect.minX * source.width).rounded()), Int(source.width) - w)
            let y = min(Int((rect.minY * source.height).rounded()), Int(source.height) - h)
            parts.append("crop=\(w):\(h):\(max(0, x)):\(max(0, y))")
        }
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: parts.append("transpose=1")
        case 2: parts.append("hflip,vflip")
        case 3: parts.append("transpose=2")
        default: break
        }
        if flipH { parts.append("hflip") }
        if flipV { parts.append("vflip") }
        guard !parts.isEmpty else { return nil }
        return (parts + ["scale='trunc(iw/2)*2':'trunc(ih/2)*2'", "setsar=1"]).joined(separator: ",")
    }

    static func mute(_ input: URL, _ output: URL) -> [String] {
        head + ["-i", input.path, "-map", "0", "-map", "-0:a", "-dn", "-map_metadata", "0", "-c", "copy"]
            + faststart(output.pathExtension.lowercased()) + tail + [output.path]
    }

    /// New sound under a video: looped or played once, optionally mixed with the original at `originalVolume` (0…1).
    static func replaceAudio(video: URL, audio: URL, output: URL, duration: Double, loop: Bool,
                             originalVolume: Double, videoHasAudio: Bool) -> [String] {
        var a = head + ["-i", video.path] + (loop ? ["-stream_loop", "-1"] : []) + ["-i", audio.path]
        let new = "[1:a:0]aresample=48000,aformat=channel_layouts=stereo\(loop ? "" : ",apad")"
        let graph = originalVolume > 0 && videoHasAudio
            ? "\(new)[n];[0:a:0]aresample=48000,aformat=channel_layouts=stereo,volume=\(String(format: "%.2f", originalVolume))[o];[n][o]amix=inputs=2:duration=first:normalize=0[a]"
            : "\(new)[a]"
        let ext = output.pathExtension.lowercased()
        a += ["-filter_complex", graph, "-map", "0:v:0", "-map", "[a]", "-map_metadata", "0", "-c:v", "copy"]
            + AudioEncoding.forExtension(ext).args + ["-t", seconds(duration)] + faststart(ext)
        return a + tail + [output.path]
    }

    struct SubtitleStyle: Equatable {
        enum Size: String, CaseIterable, Identifiable { case small = "Small", medium = "Medium", large = "Large"; var id: String { rawValue } }
        enum Position: String, CaseIterable, Identifiable { case bottom = "Bottom", top = "Top"; var id: String { rawValue } }
        enum Look: String, CaseIterable, Identifiable { case shadow = "White with shadow", box = "White on black box"; var id: String { rawValue } }
        var size: Size = .medium
        var position: Position = .bottom
        var look: Look = .shadow

        /// libass font size on its 288-line canvas.
        var fontSize: Int { switch size { case .small: 15; case .medium: 19; case .large: 25 } }

        var forceStyle: String {
            var s = ["FontName=Helvetica Neue", "FontSize=\(fontSize)", "PrimaryColour=&H00FFFFFF", "Bold=1",
                     "Alignment=\(position == .bottom ? 2 : 8)", "MarginV=\(position == .bottom ? 18 : 14)"]
            switch look {
            case .shadow: s += ["BorderStyle=1", "Outline=1", "Shadow=1", "OutlineColour=&H00000000", "BackColour=&H80000000"]
            case .box: s += ["BorderStyle=3", "Outline=2", "Shadow=0", "OutlineColour=&H60000000", "BackColour=&H60000000"]
            }
            return s.joined(separator: ",")
        }
    }

    /// Draws `subtitles` (a file name in ffmpeg's working folder, to avoid escaping paths) into the picture.
    /// `shift`: the input starts this many seconds into the video the subtitles were timed for.
    static func burn(_ input: URL, _ output: URL, subtitles: String, style: SubtitleStyle, shift: Double = 0) -> [String] {
        let draw = "subtitles=\(subtitles):force_style='\(style.forceStyle)'"
        let vf = shift > 0 ? "setpts=PTS+\(seconds(shift))/TB,\(draw),setpts=PTS-STARTPTS" : draw
        return head + ["-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-vf", vf]
            + VideoOutput.encode(ext: output.pathExtension.lowercased()) + tail + [output.path]
    }

    struct Clip {
        let url: URL
        let duration: Double
        let hasAudio: Bool
    }

    /// Joins clips into one H.264 MP4 of `size`, fitting each into the frame with black bars.
    static func merge(_ clips: [Clip], output: URL, size: CGSize, fps: Int = 30) -> [String] {
        let w = even(Int(size.width)), h = even(Int(size.height))
        var a = head
        for c in clips { a += ["-i", c.url.path] }
        var silent = clips.count
        var graph = "", joined = ""
        for (i, c) in clips.enumerated() {
            graph += "[\(i):v:0]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=\(fps),format=yuv420p[v\(i)];"
            if c.hasAudio {
                graph += "[\(i):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(i)];"
            } else {
                a += ["-f", "lavfi", "-t", seconds(c.duration), "-i", "anullsrc=r=48000:cl=stereo"]
                graph += "[\(silent):a]aformat=sample_fmts=fltp:channel_layouts=stereo[a\(i)];"
                silent += 1
            }
            joined += "[v\(i)][a\(i)]"
        }
        graph += "\(joined)concat=n=\(clips.count):v=1:a=1[v][a]"
        return a + ["-filter_complex", graph, "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"] + tail + [output.path]
    }
}

// MARK: - Edits used by the single-file tools (and the tests)

enum MediaEdits {
    static func trimVideo(_ url: URL, start: Double, end: Double, exact: Bool, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard end - start >= 0.05 else { throw ToolError("Choose a longer part of the clip.") }
        let ext = VideoOutput.same.ext(for: url)
        let out = ImageKit.outputURL(for: url, in: Output.root, suffix: " trimmed", ext: ext)
        if !exact, ext == url.pathExtension.lowercased(),
           (try? await runFFmpeg(VideoEditArgs.trim(url, out, start: start, end: end, exact: false), input: url, output: out, progress: progress)) != nil {
            return out
        }
        // Copying can fail for odd streams; re-encoding always works.
        _ = try await runFFmpeg(VideoEditArgs.trim(url, out, start: start, end: end, exact: true), input: url, output: out, progress: progress)
        return out
    }

    /// Trims audio keeping its format. Without ffmpeg, saves M4A through AVFoundation.
    static func trimAudio(_ url: URL, start: Double, end: Double, fadeIn: Double, fadeOut: Double, folder: URL = Output.root,
                          progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard end - start >= 0.05 else { throw ToolError("Choose a longer part of the recording.") }
        if Shell.which("ffmpeg") != nil {
            let enc = AudioEncoding.forExtension(url.pathExtension)
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " trimmed", ext: enc.ext)
            _ = try await runFFmpeg(VideoEditArgs.trimAudio(url, out, start: start, end: end, fadeIn: fadeIn, fadeOut: fadeOut),
                                    input: url, output: out, progress: progress)
            return out
        }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A),
              let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ToolError("Can't read the audio in \(url.lastPathComponent).") }
        let s = CMTime(seconds: start, preferredTimescale: 600), e = CMTime(seconds: end, preferredTimescale: 600)
        export.timeRange = CMTimeRange(start: s, end: e)
        let params = AVMutableAudioMixInputParameters(track: track)
        if fadeIn > 0 { params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: s, duration: CMTime(seconds: fadeIn, preferredTimescale: 600))) }
        if fadeOut > 0 { params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: e - CMTime(seconds: fadeOut, preferredTimescale: 600), end: e)) }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        export.audioMix = mix
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " trimmed", ext: "m4a")
        try await export.export(to: out, as: .m4a)
        await progress(1)
        return out
    }

    static func crop(_ url: URL, rect: CGRect, source: CGSize, quarterTurns: Int, flipH: Bool, flipV: Bool, format: VideoOutput,
                     folder: URL = Output.root, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let filter = VideoEditArgs.cropFilter(rect: rect, source: source, quarterTurns: quarterTurns, flipH: flipH, flipV: flipV) else {
            throw ToolError("Nothing to change — move the crop frame, rotate or flip first.")
        }
        let out = ImageKit.outputURL(for: url, in: folder, suffix: " cropped", ext: format.ext(for: url))
        _ = try await runFFmpeg(VideoEditArgs.filtered(url, out, video: filter), input: url, output: out, progress: progress)
        return out
    }

    enum MergeSize: String, CaseIterable, Identifiable {
        case first = "Same as first clip", uhd = "4K", hd = "1080p", sd = "720p"
        var id: String { rawValue }
    }

    static func merge(_ urls: [URL], size: MergeSize, name: String, folder: URL = Output.root,
                      progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        guard urls.count >= 2 else { throw ToolError("Add at least two clips to merge.") }
        var clips: [VideoEditArgs.Clip] = []
        var first = CGSize.zero
        for url in urls {
            let p = try await MediaProbe.read(url)
            guard p.video != nil else { throw ToolError("\(url.lastPathComponent) has no picture.") }
            if clips.isEmpty { first = p.displaySize }
            clips.append(.init(url: url, duration: p.duration, hasAudio: p.hasAudio))
        }
        let short: CGFloat = switch size { case .first: min(first.width, first.height); case .uhd: 2160; case .hd: 1080; case .sd: 720 }
        let landscape = first.width >= first.height
        let ratio = size == .first ? max(first.width, first.height) / max(1, min(first.width, first.height)) : 16.0 / 9
        let long = (short * ratio).rounded()
        let target = landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        let out = Output.unique(folder.appendingPathComponent(name.isEmpty ? "Merged Video" : name).appendingPathExtension("mp4"))
        do {
            try await FFmpeg.run(VideoEditArgs.merge(clips, output: out, size: target), duration: clips.reduce(0) { $0 + $1.duration }, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}

// MARK: - Trim Video / Trim Audio

@MainActor @Observable
final class TrimModel {
    static let video = TrimModel(), audio = TrimModel()
    var clip: MediaClip?
    var working = false
    var progress = 0.0
    var result: URL?
    var error: String?

    func open(_ url: URL) {
        clip?.stop()
        clip = MediaClip(url: url)
        result = nil
        error = nil
    }

    func close() { stopHearing(); clip?.stop(); clip = nil; result = nil; error = nil }

    // "Hear Result" for Trim Audio: the rendered piece, fades and all.
    var hearing = false
    @ObservationIgnored private var listener: AVAudioPlayer?
    @ObservationIgnored private var listenTask: Task<Void, Never>?

    func play(_ url: URL) {
        listener = try? AVAudioPlayer(contentsOf: url)
        guard let l = listener, l.play() else { hearing = false; return }
        listenTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(l.duration + 0.1))
            if !Task.isCancelled { self?.hearing = false }
        }
    }

    func stopHearing() { listener?.stop(); listener = nil; listenTask?.cancel(); hearing = false }
}

struct TrimView: View {
    enum Kind { case video, audio }
    let kind: Kind
    @AppStorage("trim.exact") private var exact = false
    @AppStorage("trimaudio.fadeIn") private var fadeIn = false
    @AppStorage("trimaudio.fadeOut") private var fadeOut = false
    @AppStorage("trimaudio.fadeInLength") private var fadeInLength = 2.0
    @AppStorage("trimaudio.fadeOutLength") private var fadeOutLength = 3.0
    @State private var dropped: [URL] = []

    private var model: TrimModel { kind == .video ? .video : .audio }
    private var types: [UTType] { kind == .video ? [.movie, .video] : [.audio] }
    private var toolID: String { kind == .video ? "trimvideo" : "trimaudio" }

    var body: some View {
        Group {
            if let clip = model.clip {
                editor(clip)
            } else {
                DropZone(prompt: kind == .video ? "Drop a video to trim" : "Drop an audio file to trim", types: types, multiple: false, urls: $dropped)
                    .padding(20)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .onChange(of: dropped) { if let u = dropped.first { model.open(u); dropped = [] } }
        .receivesFiles(for: toolID) { if let u = $0.first { model.open(u) } }
    }

    @ViewBuilder private func editor(_ clip: MediaClip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Thumbnail(url: clip.url, size: 22)
                Text(clip.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Another…") { if let u = FilePicker.choose(types: types, multiple: false).first { model.open(u) } }
                Button("Close") { model.close() }
            }
            Group {
                if clip.playable {
                    PlayerView(player: clip.player, audioOnly: kind == .audio)
                } else {
                    ContentUnavailableView("No Preview", systemImage: "eye.slash",
                                           description: Text("macOS can't play this format. Type the start and end times instead."))
                }
            }
            .frame(minHeight: kind == .video ? 220 : 60, maxHeight: kind == .video ? .infinity : 80)
            .background(.black.opacity(kind == .video ? 1 : 0), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if clip.loading { ProgressView().controlSize(.small) } else { RangeTimeline(clip: clip) }
            Divider()
            HStack(alignment: .center, spacing: 16) {
                if kind == .video {
                    Toggle("Exact cut (re-encodes)", isOn: $exact)
                        .help("Off: instant and lossless, but cuts land on the nearest keyframe. On: cuts exactly where you set them.")
                } else {
                    Toggle("Fade in", isOn: $fadeIn)
                    if fadeIn { Stepper("\(fadeInLength, specifier: "%.1f") s", value: $fadeInLength, in: 0.5...10, step: 0.5).fixedSize() }
                    Toggle("Fade out", isOn: $fadeOut)
                    if fadeOut { Stepper("\(fadeOutLength, specifier: "%.1f") s", value: $fadeOutLength, in: 0.5...10, step: 0.5).fixedSize() }
                }
                Spacer()
                if kind == .audio {
                    Button { hear(clip) } label: {
                        Label(model.hearing ? "Stop" : "Hear Result", systemImage: model.hearing ? "stop.fill" : "headphones")
                    }
                    .help("Plays the trimmed part with its fades, exactly as it will be saved")
                    .disabled(model.working || clip.length < 0.05)
                }
                if model.working { ProgressView(value: model.progress).frame(width: 120) }
                Button("Trim") { trim(clip) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.working || clip.length < 0.05)
            }
            if let e = model.error { ErrorText(message: e) }
            if let r = model.result { ResultList(urls: [r]) }
            SavesToLine()
        }
        .padding(20)
    }

    private func hear(_ clip: MediaClip) {
        let m = model
        if m.hearing { m.stopHearing(); return }
        clip.player.pause()
        let (s, e) = (clip.start, clip.end)
        let (fi, fo) = (fadeIn ? fadeInLength : 0, fadeOut ? fadeOutLength : 0)
        m.hearing = true
        Task {
            do {
                let file = try await MediaEdits.trimAudio(clip.url, start: s, end: e, fadeIn: fi, fadeOut: fo, folder: LivePreview.newFolder()) { _ in }
                m.play(try await LivePreview.playable(file))
            } catch {
                m.error = error.localizedDescription
                m.hearing = false
            }
        }
    }

    private func trim(_ clip: MediaClip) {
        clip.player.pause()
        let m = model
        m.working = true; m.progress = 0; m.error = nil; m.result = nil
        let (s, e) = (clip.start, clip.end)
        Task {
            do {
                m.result = kind == .video
                    ? try await MediaEdits.trimVideo(clip.url, start: s, end: e, exact: exact) { m.progress = $0 }
                    : try await MediaEdits.trimAudio(clip.url, start: s, end: e, fadeIn: fadeIn ? fadeInLength : 0,
                                                     fadeOut: fadeOut ? fadeOutLength : 0) { m.progress = $0 }
            } catch {
                m.error = error.localizedDescription
            }
            m.working = false
        }
    }
}

// MARK: - Merge Videos

struct MergeVideosView: View {
    @AppStorage("merge.size") private var size: MediaEdits.MergeSize = .hd
    @State private var name = "Merged Video"

    var body: some View {
        CombineToolView(toolID: "mergevideos", types: [.movie, .video], noun: "Clip", verb: "Merge", previewKey: size.rawValue,
                        previewRender: { [size] urls, folder in
                            // The first 3 seconds of each clip, joined exactly as the real merge joins them.
                            var pieces: [URL] = []
                            for u in urls { pieces.append(try await LivePreview.excerpt(u, start: 0, length: 3, video: true)) }
                            return try await MediaEdits.merge(pieces, size: size, name: "Merged Video", folder: folder)
                        }) {
            Section {
                Picker("Resolution", selection: $size) { ForEach(MediaEdits.MergeSize.allCases) { Text($0.rawValue).tag($0) } }
                TextField("File name", text: $name)
            } footer: {
                Text("Clips are joined into one H.264 MP4. Clips of a different shape get black bars, so nothing is stretched or cut off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } combine: { [size, name] urls in
            try await MediaEdits.merge(urls, size: size, name: name)
        }
    }
}

// MARK: - Crop & Rotate

@MainActor @Observable
final class CropVideoModel {
    static let shared = CropVideoModel()
    var url: URL?
    var source = CGSize.zero
    var duration = 0.0
    var frameTime = 0.0
    var frame: NSImage?
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var aspect: CropAspect = .free
    var quarterTurns = 0
    var flipH = false
    var flipV = false
    var working = false
    var progress = 0.0
    var result: URL?
    var error: String?

    func open(_ url: URL) {
        self.url = url
        frame = nil; result = nil; error = nil
        rect = CGRect(x: 0, y: 0, width: 1, height: 1); aspect = .free; quarterTurns = 0; flipH = false; flipV = false
        Task {
            do {
                let p = try await MediaProbe.read(url)
                guard p.video != nil else { throw ToolError("\(url.lastPathComponent) has no picture.") }
                source = p.displaySize
                duration = p.duration
                frameTime = p.duration / 3
                await loadFrame()
            } catch { self.error = error.localizedDescription }
        }
    }

    func loadFrame() async {
        guard let url else { return }
        if let cg = try? await VideoFrame.grab(url, at: frameTime) {
            // Shown at the video's own size so the crop frame maps 1:1.
            frame = NSImage(cgImage: cg, size: source == .zero ? CGSize(width: cg.width, height: cg.height) : source)
        }
    }

    func setAspect(_ a: CropAspect) {
        aspect = a
        rect = CropEditor.centered(aspect: a.ratio(original: source), picture: source)
    }

    func close() { url = nil; frame = nil; result = nil; error = nil }
}

struct CropVideoView: View {
    @Bindable private var model = CropVideoModel.shared
    @AppStorage("crop.format") private var format: VideoOutput = .same
    @State private var dropped: [URL] = []
    @State private var previewing = false

    var body: some View {
        Group {
            if let url = model.url {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Picker("View", selection: $previewing) {
                            Text("Edit").tag(false)
                            Text("Preview").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 14)
                        if previewing {
                            LivePreviewPane(id: "cropvideo", source: url,
                                            key: "\(model.rect)|\(model.quarterTurns)|\(model.flipH)|\(model.flipV)|\(format.rawValue)",
                                            enabled: !model.working) { [model, format] input, folder in
                                let p = try await MediaProbe.read(input)
                                do {
                                    return try await MediaEdits.crop(input, rect: model.rect, source: p.displaySize, quarterTurns: model.quarterTurns,
                                                                     flipH: model.flipH, flipV: model.flipV, format: format, folder: folder) { _ in }
                                } catch let e as ToolError { throw PreviewNote(message: e.message) }
                            }
                        } else {
                            canvas.padding(20)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector(url).frame(width: 300)
                }
            } else {
                DropZone(prompt: "Drop a video to crop or rotate", types: [.movie, .video], multiple: false, urls: $dropped)
                    .padding(20).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .onChange(of: dropped) { if let u = dropped.first { model.open(u); dropped = [] } }
        .receivesFiles(for: "cropvideo") { if let u = $0.first { model.open(u) } }
    }

    @ViewBuilder private var canvas: some View {
        if let frame = model.frame {
            GeometryReader { geo in
                let turned = model.quarterTurns % 2 != 0
                // A sideways picture has to fit the box with its sides swapped.
                let box = turned ? CGSize(width: geo.size.height, height: geo.size.width) : geo.size
                CropEditor(image: frame, rect: $model.rect, aspect: model.aspect.ratio(original: model.source))
                    .frame(width: box.width, height: box.height)
                    .rotationEffect(.degrees(Double(model.quarterTurns) * 90))
                    .scaleEffect(x: model.flipH ? -1 : 1, y: model.flipV ? -1 : 1)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else if let e = model.error {
            ErrorText(message: e)
        } else {
            ProgressView()
        }
    }

    private func inspector(_ url: URL) -> some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    if model.source != .zero {
                        LabeledContent("Size", value: "\(Int(model.source.width)) × \(Int(model.source.height))")
                        LabeledContent("Result", value: resultSize)
                    }
                }
                Section("Crop") {
                    Picker("Aspect ratio", selection: Binding(get: { model.aspect }, set: { model.setAspect($0) })) {
                        ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Reset Crop") { model.setAspect(.free) }
                }
                Section("Rotate & Flip") {
                    HStack {
                        Button { model.quarterTurns = (model.quarterTurns + 3) % 4 } label: { Label("Left", systemImage: "rotate.left") }
                        Button { model.quarterTurns = (model.quarterTurns + 1) % 4 } label: { Label("Right", systemImage: "rotate.right") }
                    }
                    Toggle("Flip horizontally", isOn: $model.flipH)
                    Toggle("Flip vertically", isOn: $model.flipV)
                }
                Section("Preview frame") {
                    Slider(value: $model.frameTime, in: 0...max(model.duration, 0.1)) { Text("Time") } onEditingChanged: { editing in
                        if !editing { Task { await model.loadFrame() } }
                    }
                }
                Section {
                    Picker("Format", selection: $format) { ForEach(VideoOutput.allCases) { Text($0.rawValue).tag($0) } }
                }
            }
            .formStyle(.grouped)
            .disabled(model.working)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let e = model.error, model.frame != nil { ErrorText(message: e) }
                if let r = model.result { ResultList(urls: [r]) }
                if model.working { ProgressView(value: model.progress) }
                HStack {
                    Button("Close") { model.close() }
                    Button { export(url) } label: { Text("Export").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.working || model.frame == nil)
                }
                .controlSize(.large)
                SavesToLine()
            }
            .padding(16)
        }
    }

    private var resultSize: String {
        let w = VideoEditArgs.even(Int(model.rect.width * model.source.width)), h = VideoEditArgs.even(Int(model.rect.height * model.source.height))
        return model.quarterTurns % 2 == 0 ? "\(w) × \(h)" : "\(h) × \(w)"
    }

    private func export(_ url: URL) {
        let m = model
        m.working = true; m.progress = 0; m.error = nil; m.result = nil
        Task {
            do {
                m.result = try await MediaEdits.crop(url, rect: m.rect, source: m.source, quarterTurns: m.quarterTurns,
                                                     flipH: m.flipH, flipV: m.flipV, format: format) { m.progress = $0 }
            } catch { m.error = error.localizedDescription }
            m.working = false
        }
    }
}

// MARK: - Resize Video

enum ResizePreset: String, CaseIterable, Identifiable {
    case uhd = "4K (3840 × 2160)", fhd = "1080p (1920 × 1080)", hd = "720p (1280 × 720)", sd = "480p (854 × 480)"
    case square = "Square (1080 × 1080)", vertical = "Vertical (1080 × 1920)", custom = "Custom"
    var id: String { rawValue }
    var size: (Int, Int)? {
        switch self {
        case .uhd: (3840, 2160)
        case .fhd: (1920, 1080)
        case .hd: (1280, 720)
        case .sd: (854, 480)
        case .square: (1080, 1080)
        case .vertical: (1080, 1920)
        case .custom: nil
        }
    }
}

struct ResizeVideoView: View {
    @AppStorage("rv.preset") private var preset: ResizePreset = .fhd
    @AppStorage("rv.width") private var width = 1280
    @AppStorage("rv.height") private var height = 720
    @AppStorage("rv.keep") private var keepAspect = true
    @AppStorage("rv.fit") private var fit: VideoEditArgs.Fit = .fit
    @AppStorage("rv.format") private var format: VideoOutput = .same

    var body: some View {
        BatchToolView(toolID: "resizevideo", folderName: "", types: [.movie, .video], noun: "Video", verb: "Resize", concurrency: 1,
                      previewKey: "\(preset.rawValue)|\(width)|\(height)|\(keepAspect)|\(fit.rawValue)|\(format.rawValue)") {
            Section {
                Picker("Size", selection: $preset) { ForEach(ResizePreset.allCases) { Text($0.rawValue).tag($0) } }
                if preset == .custom {
                    TextField("Width", value: $width, format: .number)
                    TextField("Height", value: $height, format: .number)
                }
                Toggle("Keep aspect ratio", isOn: $keepAspect)
                if keepAspect {
                    Picker("Fit", selection: $fit) { ForEach(VideoEditArgs.Fit.allCases) { Text($0.rawValue).tag($0) } }
                }
                Picker("Format", selection: $format) { ForEach(VideoOutput.allCases) { Text($0.rawValue).tag($0) } }
            } footer: {
                Text(keepAspect ? fitHint : "The picture is stretched to the exact size.").font(.caption).foregroundStyle(.secondary)
            }
        } process: { [preset, width, height, keepAspect, fit, format] url, folder, progress in
            let (w, h) = preset.size ?? (width, height)
            guard w >= 2, h >= 2, w <= 8192, h <= 8192 else { throw ToolError("Choose a width and height between 2 and 8192.") }
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " \(VideoEditArgs.even(w))x\(VideoEditArgs.even(h))", ext: format.ext(for: url))
            let filter = VideoEditArgs.resizeFilter(width: w, height: h, keepAspect: keepAspect, fit: fit)
            return try await runFFmpeg(VideoEditArgs.filtered(url, out, video: filter), input: url, output: out, progress: progress)
        }
    }

    private var fitHint: String {
        switch fit {
        case .fit: "The whole picture fits inside the size, keeping its shape."
        case .pad: "The video is exactly this size; empty space becomes black bars."
        case .fill: "The video is exactly this size; edges that don't fit are cut off."
        }
    }
}

// MARK: - Change Speed

struct ChangeSpeedView: View {
    @AppStorage("speed.value") private var speed = 2.0
    @AppStorage("speed.pitch") private var keepPitch = true
    @AppStorage("speed.mute") private var mute = false
    @AppStorage("speed.format") private var format: VideoOutput = .same

    var body: some View {
        BatchToolView(toolID: "speed", folderName: "", types: [.movie, .video], noun: "Video", verb: "Change Speed of", concurrency: 1,
                      previewKey: "\(speed)|\(keepPitch)|\(mute)|\(format.rawValue)") {
            Section {
                LabeledContent("Speed") { Text(Self.label(speed)).monospacedDigit().font(.title3.weight(.semibold)) }
                Slider(value: $speed, in: 0.25...4, step: 0.05) { Text("Speed") } minimumValueLabel: { Text("0.25×") } maximumValueLabel: { Text("4×") }
                    .labelsHidden()
                HStack {
                    ForEach([0.25, 0.5, 1.5, 2, 4], id: \.self) { v in
                        Button(Self.label(v)) { speed = v }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Section {
                Toggle("Keep original pitch", isOn: $keepPitch).disabled(mute)
                Toggle("Mute audio", isOn: $mute)
                Picker("Format", selection: $format) { ForEach(VideoOutput.allCases) { Text($0.rawValue).tag($0) } }
            } footer: {
                Text(keepPitch ? "Voices and music keep their natural pitch at any speed." : "Faster sounds higher, slower sounds deeper — like a tape.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } preview: { url in
            NewLengthLine(url: url, speed: speed)
        } process: { [speed, keepPitch, mute, format] url, folder, progress in
            guard abs(speed - 1) > 0.001 else { return BatchOutput(note: "Speed is 1× — nothing to change") }
            let probe = try await MediaProbe.read(url)
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " \(Self.label(speed))", ext: format.ext(for: url))
            let args = VideoEditArgs.speed(url, out, speed: speed, keepPitch: keepPitch, audio: probe.hasAudio && !mute, sampleRate: probe.sampleRate)
            do {
                try await FFmpeg.run(args, duration: probe.duration / speed, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
            return BatchOutput(files: [out], note: "\(timecode(probe.duration)) → \(timecode(probe.duration / speed))")
        }
    }

    static func label(_ v: Double) -> String {
        (v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", (v * 100).rounded() / 100)) + "×"
    }
}

private struct NewLengthLine: View {
    let url: URL
    let speed: Double
    @State private var duration: Double?

    var body: some View {
        HStack {
            Image(systemName: "clock")
            if let d = duration {
                Text("\(timecode(d)) → \(timecode(d / speed))").monospacedDigit()
            } else {
                Text("Reading length…")
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .task(id: url) { duration = (try? await MediaProbe.read(url))?.duration }
    }
}

// MARK: - Burn In Subtitles

enum SubtitleSource: String, CaseIterable, Identifiable {
    case file = "Subtitle file", transcribe = "Transcribe automatically"
    var id: String { rawValue }
}

enum SubtitleFiles {
    static let types: [UTType] = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]

    /// When the first caption appears, so a preview can start there.
    static func firstCue(_ file: URL) -> Double? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let m = text.firstMatch(of: #/(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->/#) else { return nil }
        let (h, mi, s, ms) = (Double(m.1) ?? 0, Double(m.2) ?? 0, Double(m.3) ?? 0, Double(m.4) ?? 0)
        return h * 3600 + mi * 60 + s + ms / 1000
    }

    /// "Holiday.srt" or "Holiday.en.vtt" next to "Holiday.mp4".
    static func matching(_ video: URL) -> URL? {
        let dir = video.deletingLastPathComponent(), base = video.baseName
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["srt", "vtt"].contains($0.pathExtension.lowercased()) }
            .filter { $0.baseName == base || $0.baseName.hasPrefix(base + ".") }
            .sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
            .first
    }
}

struct BurnSubtitlesView: View {
    @AppStorage("subs.source") private var source: SubtitleSource = .file
    @AppStorage("subs.size") private var size: VideoEditArgs.SubtitleStyle.Size = .medium
    @AppStorage("subs.position") private var position: VideoEditArgs.SubtitleStyle.Position = .bottom
    @AppStorage("subs.look") private var look: VideoEditArgs.SubtitleStyle.Look = .shadow
    @AppStorage("subs.saveSRT") private var saveSRT = true
    @AppStorage("subs.format") private var format: VideoOutput = .same
    @State private var subtitleFile: [URL] = []
    @Bindable private var speech = TranscribeModel.shared

    private var style: VideoEditArgs.SubtitleStyle { .init(size: size, position: position, look: look) }

    var body: some View {
        BatchToolView(toolID: "burnsubs", folderName: "", types: [.movie, .video], noun: "Video", verb: "Burn Subtitles into", concurrency: 1,
                      previewKey: "\(source.rawValue)|\(size.rawValue)|\(position.rawValue)|\(look.rawValue)|\(format.rawValue)|\(subtitleFile.first?.path ?? "")|\(speech.localeID)",
                      previewStart: { [source, subtitleFile] url in
                          guard source == .file, let f = subtitleFile.first ?? SubtitleFiles.matching(url) else { return nil }
                          return SubtitleFiles.firstCue(f)
                      }) {
            Section {
                Picker("Captions from", selection: $source) { ForEach(SubtitleSource.allCases) { Text($0.rawValue).tag($0) } }
                if source == .file {
                    DropZone(prompt: "SRT or WebVTT file", types: SubtitleFiles.types, multiple: false, urls: $subtitleFile)
                    Text("Leave empty to use the subtitle file with the same name next to each video.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Spoken language", selection: $speech.localeID) {
                        ForEach(speech.locales, id: \.identifier) { Text(speech.name($0)).tag($0.identifier) }
                    }
                    Toggle("Also save the subtitle file", isOn: $saveSRT)
                }
            }
            Section("Style") {
                Picker("Size", selection: $size) { ForEach(VideoEditArgs.SubtitleStyle.Size.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                Picker("Position", selection: $position) { ForEach(VideoEditArgs.SubtitleStyle.Position.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                Picker("Look", selection: $look) { ForEach(VideoEditArgs.SubtitleStyle.Look.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Format", selection: $format) { ForEach(VideoOutput.allCases) { Text($0.rawValue).tag($0) } }
            }
        } preview: { url in
            SubtitlePreview(url: url, style: style)
        } process: { [source, style, saveSRT, format, subtitleFile, localeID = speech.localeID] url, folder, progress in
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("subs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            var saved: [URL] = []
            let subName: String
            switch source {
            case .file:
                let video = Previewing.current?.original ?? url
                guard let file = subtitleFile.first ?? SubtitleFiles.matching(video) else {
                    throw ToolError("No subtitle file. Choose one, or put \(video.baseName).srt next to the video.")
                }
                subName = "subs." + file.pathExtension.lowercased()
                try FileManager.default.copyItem(at: file, to: temp.appendingPathComponent(subName))
            case .transcribe:
                let locale = localeID.isEmpty ? await Transcription.defaultLocale() : Locale(identifier: localeID)
                let segments = try await Transcription.transcribeCached(url, locale: locale) { p, _ in progress(p * 0.4) }
                guard !segments.isEmpty else { throw ToolError("No speech was recognized. Check the spoken language.") }
                let srt = TranscriptFormat.srt.render(segments)
                subName = "subs.srt"
                try srt.write(to: temp.appendingPathComponent(subName), atomically: true, encoding: .utf8)
                if saveSRT {
                    let s = ImageKit.outputURL(for: url, in: folder, ext: "srt")
                    try srt.write(to: s, atomically: true, encoding: .utf8)
                    saved.append(s)
                }
            }
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " subtitled", ext: format.ext(for: url))
            let share = source == .transcribe ? 0.4 : 0
            // A preview from the subtitle file is a piece from later in the video; line the cues up with it.
            let shift = source == .file ? Previewing.current?.start ?? 0 : 0
            let r = try await runFFmpeg(VideoEditArgs.burn(url, out, subtitles: subName, style: style, shift: shift), input: url, output: out, cwd: temp) {
                progress(share + $0 * (1 - share))
            }
            return BatchOutput(files: r.files + saved, note: r.note)
        }
        .task { await speech.loadLocales() }
    }
}

/// A frame of the video with a sample caption in the chosen style.
private struct SubtitlePreview: View {
    let url: URL
    let style: VideoEditArgs.SubtitleStyle
    @State private var frame: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.black)
            if let frame {
                GeometryReader { geo in
                    let size = fitted(frame.size, geo.size)
                    ZStack(alignment: style.position == .bottom ? .bottom : .top) {
                        Image(nsImage: frame).resizable().frame(width: size.width, height: size.height)
                        caption(height: size.height)
                            .padding(style.position == .bottom ? .bottom : .top, size.height * CGFloat(style.position == .bottom ? 18 : 14) / 288)
                    }
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 180)
        .task(id: url) {
            let d = (try? await MediaProbe.read(url))?.duration ?? 0
            frame = (try? await VideoFrame.grab(url, at: d / 3, maxSize: 640)).map(ImageKit.nsImage)
        }
    }

    private func caption(height: CGFloat) -> some View {
        let text = Text("Captions look like this").font(.system(size: max(7, height * CGFloat(style.fontSize) / 288 * 0.8), weight: .bold))
            .foregroundStyle(.white)
        return Group {
            if style.look == .box {
                text.padding(.horizontal, 4).padding(.vertical, 1).background(.black.opacity(0.62))
            } else {
                text.shadow(color: .black, radius: 1, x: 1, y: 1)
            }
        }
    }

    private func fitted(_ s: CGSize, _ box: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return box }
        let k = min(box.width / s.width, box.height / s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }
}

// MARK: - Replace Audio, Mute

enum AudioFit: String, CaseIterable, Identifiable {
    case loop = "Loop to fit the video", once = "Play once, then silence"
    var id: String { rawValue }
}

struct ReplaceAudioView: View {
    /// The chosen sound, remembered so the same music can go under the next video too.
    @AppStorage("ra.audio") private var audioPath = ""
    @AppStorage("ra.fit") private var fit: AudioFit = .loop
    @AppStorage("ra.original") private var original = 0.0

    private var audio: [URL] {
        audioPath.isEmpty || !FileManager.default.fileExists(atPath: audioPath) ? [] : [URL(fileURLWithPath: audioPath)]
    }

    var body: some View {
        BatchToolView(toolID: "replaceaudio", folderName: "", types: [.movie, .video], noun: "Video", verb: "Replace Audio in", concurrency: 1,
                      previewKey: "\(audioPath)|\(fit.rawValue)|\(original)") {
            Section {
                DropZone(prompt: "New sound: an audio file, or a video to take its sound", types: [.audio, .movie], multiple: false,
                         urls: Binding(get: { audio }, set: { audioPath = $0.first?.path ?? "" }))
                Picker("If it's shorter", selection: $fit) { ForEach(AudioFit.allCases) { Text($0.rawValue).tag($0) } }
                LabeledContent("Original audio") { Text("\(Int(original * 100))%").monospacedDigit() }
                Slider(value: $original, in: 0...1, step: 0.05) { Text("Original audio") }.labelsHidden()
            } footer: {
                Text(original == 0 ? "Only the new sound is kept." : "The new sound plays over the original, which is turned down to \(Int(original * 100))%.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } process: { [audio, fit, original] url, folder, progress in
            guard let sound = audio.first else { throw ToolError("Choose the new audio first.") }
            guard sound != url else { throw ToolError("Choose a different file for the new sound.") }
            let p = try await MediaProbe.read(url)
            guard p.video != nil else { throw ToolError("\(url.lastPathComponent) has no picture.") }
            guard await FFmpeg.hasAudio(sound) != false else { throw ToolError("\(sound.lastPathComponent) has no sound track.") }
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " new audio", ext: VideoOutput.same.ext(for: url))
            let args = VideoEditArgs.replaceAudio(video: url, audio: sound, output: out, duration: p.duration, loop: fit == .loop,
                                                  originalVolume: original, videoHasAudio: p.hasAudio)
            return try await runFFmpeg(args, input: url, output: out, progress: progress)
        }
    }
}

struct MuteVideoView: View {
    var body: some View {
        BatchToolView(toolID: "mutevideo", folderName: "", types: [.movie, .video], noun: "Video", verb: "Mute", concurrency: 2) {
            Section {
                Label("The picture is copied as is, so quality doesn't change and it takes seconds.", systemImage: "bolt")
                    .font(.callout).foregroundStyle(.secondary)
            } footer: {
                Text("Your original keeps its sound.").font(.caption).foregroundStyle(.secondary)
            }
        } process: { url, folder, progress in
            let p = try await MediaProbe.read(url)
            guard p.video != nil else { throw ToolError("\(url.lastPathComponent) has no picture.") }
            guard p.hasAudio else { return BatchOutput(note: "Already silent") }
            let out = ImageKit.outputURL(for: url, in: folder, suffix: " muted", ext: url.pathExtension.lowercased())
            return try await runFFmpeg(VideoEditArgs.mute(url, out), input: url, output: out, progress: progress)
        }
    }
}

// MARK: - Extract Frames

enum FrameMode: String, CaseIterable, Identifiable {
    case every = "Every few seconds", evenly = "Evenly spaced", single = "One frame"
    var id: String { rawValue }
}

struct ExtractFramesView: View {
    @AppStorage("frames.mode") private var mode: FrameMode = .every
    @AppStorage("frames.interval") private var interval = 1.0
    @AppStorage("frames.count") private var count = 10
    @AppStorage("frames.at") private var at = 0.0
    @AppStorage("frames.format") private var format: ImageFormat = .png
    @AppStorage("frames.size") private var size = 0

    var body: some View {
        BatchToolView(toolID: "frames", folderName: "", types: [.movie, .video], noun: "Video", verb: "Extract Frames from", concurrency: 1) {
            Section {
                Picker("Frames", selection: $mode) { ForEach(FrameMode.allCases) { Text($0.rawValue).tag($0) } }
                switch mode {
                case .every: TextField("Every (seconds)", value: $interval, format: .number)
                case .evenly: Stepper("\(count) frames", value: $count, in: 2...500)
                case .single: TextField("At (seconds)", value: $at, format: .number)
                }
            }
            Section {
                Picker("Format", selection: $format) { ForEach([ImageFormat.png, .jpeg, .heic]) { Text($0.title).tag($0) } }
                Picker("Size", selection: $size) { Text("Original").tag(0); Text("1080p").tag(1080); Text("720p").tag(720) }
            } footer: {
                Text(format == .png ? "PNG keeps every detail." : format == .jpeg ? "JPEG files are small and open anywhere." : "HEIC files are compact, for Apple devices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } preview: { url in
            FramesPreview(url: url, mode: mode, interval: interval, count: count, at: at)
        } process: { [mode, interval, count, at, format, size] url, folder, progress in
            try await FrameExtractor.extract(url, folder: folder, mode: mode, interval: interval, count: count, at: at,
                                             format: format, shortSide: size, progress: progress)
        }
    }
}

/// Thumbnails of the first frames that will be saved, with their times.
private struct FramesPreview: View {
    let url: URL
    let mode: FrameMode
    let interval: Double
    let count: Int
    let at: Double
    @State private var tiles: [(Double, NSImage)] = []
    @State private var total = 0
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tiles.isEmpty {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)).frame(height: 120)
                    .overlay { if failed { Text("No preview for this format. Frames are still extracted.").font(.caption).foregroundStyle(.secondary).padding() } else { ProgressView().controlSize(.small) } }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                        Image(nsImage: tile.1).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(alignment: .bottomTrailing) {
                                Text(FrameExtractor.stamp(tile.0)).font(.system(size: 9).monospacedDigit())
                                    .padding(.horizontal, 3).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(.white).padding(2)
                            }
                    }
                }
                Text(total > tiles.count ? "First \(tiles.count) of \(total) frames" : "\(total) frame\(total == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(url.path)|\(mode.rawValue)|\(interval)|\(count)|\(at)") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let d = (try? await MediaProbe.read(url))?.duration, d > 0 else { failed = true; return }
            let times = FrameExtractor.times(mode: mode, duration: d, interval: interval, count: count, at: at)
            total = times.count
            var made: [(Double, NSImage)] = []
            for t in times.prefix(6) {
                guard !Task.isCancelled else { return }
                if let cg = try? await VideoFrame.grab(url, at: t, maxSize: 240) { made.append((t, ImageKit.nsImage(cg))); tiles = made }
            }
            failed = made.isEmpty
        }
    }
}

enum FrameExtractor {
    /// When the frames are taken, in seconds.
    static func times(mode: FrameMode, duration d: Double, interval: Double, count: Int, at: Double) -> [Double] {
        switch mode {
        case .every:
            guard interval >= 0.01 else { return [] }
            return stride(from: 0, to: d, by: interval).prefix(20_000).map { $0 }
        case .evenly: return (0..<max(1, count)).map { (Double($0) + 0.5) * d / Double(max(1, count)) }
        case .single: return [min(max(0, at), max(0, d - 0.05))]
        }
    }

    static func stamp(_ t: Double) -> String {
        let m = Int(t) / 60
        return String(format: "%dm%05.2fs", m, t - Double(m * 60))
    }

    static func extract(_ url: URL, folder: URL, mode: FrameMode, interval: Double, count: Int, at: Double, format: ImageFormat,
                        shortSide: Int, progress: @escaping @MainActor (Double) -> Void) async throws -> BatchOutput {
        let ffmpeg = try Shell.require("ffmpeg")
        let p = try await MediaProbe.read(url)
        guard p.video != nil else { throw ToolError("\(url.lastPathComponent) has no picture.") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // (png in temp, name for the result)
        var frames: [(URL, String)] = []
        switch mode {
        case .every:
            guard interval >= 0.01 else { throw ToolError("Choose an interval of at least 0.01 seconds.") }
            guard p.duration / interval <= 20_000 else { throw ToolError("That would make more than 20,000 pictures. Choose a longer interval.") }
            try await FFmpeg.run(VideoEditArgs.framesEvery(url, pattern: temp.appendingPathComponent("%05d.png").path, interval: interval, shortSide: shortSide),
                                 duration: p.duration) { progress($0 * 0.8) }
            let made = ((try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            frames = made.enumerated().map { i, f in (f, "\(url.baseName) \(stamp(Double(i) * interval))") }
        case .evenly, .single:
            let times = times(mode: mode, duration: p.duration, interval: interval, count: count, at: at)
            for (i, t) in times.enumerated() {
                try Task.checkCancellation()
                let f = temp.appendingPathComponent(String(format: "%05d.png", i))
                let r = try await Shell.run(ffmpeg, VideoEditArgs.frame(url, at: t, to: f, shortSide: shortSide))
                if r.ok, FileManager.default.fileExists(atPath: f.path) { frames.append((f, "\(url.baseName) \(stamp(t))")) }
                await progress(Double(i + 1) / Double(times.count) * 0.8)
            }
        }
        guard !frames.isEmpty else { throw ToolError("No frames could be read from this video.") }

        // One picture goes straight into the output folder; many get a folder of their own.
        let dest = frames.count == 1 ? folder : Output.unique(folder.appendingPathComponent("\(url.baseName) frames"))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for (i, (png, name)) in frames.enumerated() {
            let target = Output.unique(dest.appendingPathComponent(name).appendingPathExtension(format.ext))
            if format == .png {
                try FileManager.default.moveItem(at: png, to: target)
            } else {
                try await offMain { try ImageKit.save(ImageKit.load(png), to: target, format: format, quality: 0.9) }
            }
            if frames.count == 1 { return BatchOutput(files: [target], note: "1 frame") }
            await progress(0.8 + 0.2 * Double(i + 1) / Double(frames.count))
        }
        return BatchOutput(files: [dest], note: "\(frames.count) frames")
    }
}
