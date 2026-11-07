import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Media Info's report: plain sections of label → value, built from ffprobe's output.
enum MediaReport {
    struct Section: Identifiable {
        let id = UUID()
        let title: String
        var rows: [(String, String)]
    }

    static func sections(_ url: URL, _ p: MediaProbe) -> [Section] {
        let tags = p.format["tags"] as? [String: Any] ?? [:]
        func tag(_ keys: String...) -> String? {
            for k in keys { if let v = tags.first(where: { $0.key.lowercased() == k.lowercased() })?.value as? String, !v.isEmpty { return v } }
            return nil
        }
        var general = Section(title: "General", rows: [
            ("File", url.lastPathComponent),
            ("Size", url.fileSize.byteString),
            ("Format", (p.format["format_long_name"] as? String) ?? (p.format["format_name"] as? String) ?? "Unknown"),
            ("Duration", p.duration > 0 ? timecode(p.duration, millis: true, separator: ".") : "Unknown"),
        ])
        if let br = bitrate(p.format["bit_rate"]) { general.rows.append(("Overall bitrate", br)) }
        if let c = tag("creation_time", "com.apple.quicktime.creationdate", "date") { general.rows.append(("Created", prettyDate(c))) }
        let device = [tag("com.apple.quicktime.make", "make"), tag("com.apple.quicktime.model", "model")].compactMap { $0 }.joined(separator: " ")
        if !device.isEmpty { general.rows.append(("Device", device)) }
        if let s = tag("com.apple.quicktime.software", "encoder", "software") { general.rows.append(("Software", s)) }
        if let title = tag("title") { general.rows.append(("Title", title)) }
        if let artist = tag("artist", "album_artist") { general.rows.append(("Artist", artist)) }
        if let album = tag("album") { general.rows.append(("Album", album)) }
        if let loc = location(p) { general.rows.append(("Location", String(format: "%.5f, %.5f", loc.lat, loc.lon))) }

        var out = [general]
        var counts: [String: Int] = [:]
        for s in p.streams {
            let type = s["codec_type"] as? String ?? "data"
            counts[type, default: 0] += 1
            let n = counts[type]!
            let stags = s["tags"] as? [String: Any] ?? [:]
            var rows: [(String, String)] = [("Codec", codec(s))]
            switch type {
            case "video":
                if (s["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1 {
                    out.append(Section(title: "Cover Art", rows: rows + [("Size", "\(s["width"] as? Int ?? 0) × \(s["height"] as? Int ?? 0)")]))
                    continue
                }
                let w = s["width"] as? Int ?? 0, h = s["height"] as? Int ?? 0
                rows.append(("Resolution", "\(w) × \(h)" + resolutionName(w, h)))
                if p.rotation != 0 { rows.append(("Rotation", "\(p.rotation)° (shows as \(Int(p.displaySize.width)) × \(Int(p.displaySize.height)))")) }
                if let dar = s["display_aspect_ratio"] as? String, dar != "0:1" { rows.append(("Aspect ratio", dar)) }
                if let fps = rate(s["avg_frame_rate"] as? String) ?? rate(s["r_frame_rate"] as? String) { rows.append(("Frame rate", String(format: "%.3g fps", fps))) }
                if let br = bitrate(s["bit_rate"]) { rows.append(("Bitrate", br)) }
                if let pf = s["pix_fmt"] as? String { rows.append(("Pixel format", pf)) }
                if let bits = s["bits_per_raw_sample"] as? String { rows.append(("Bit depth", "\(bits)-bit")) }
                if let color = colorDescription(s) { rows.append(("Color", color)) }
            case "audio":
                let ch = s["channels"] as? Int ?? 0
                rows.append(("Channels", "\(ch)" + ((s["channel_layout"] as? String).map { " (\($0))" } ?? "")))
                if let sr = Int(s["sample_rate"] as? String ?? "") { rows.append(("Sample rate", String(format: "%.1f kHz", Double(sr) / 1000))) }
                if let br = bitrate(s["bit_rate"]) { rows.append(("Bitrate", br)) }
            default:
                break
            }
            if let lang = stags["language"] as? String, lang != "und" {
                rows.append(("Language", Locale.current.localizedString(forLanguageCode: lang) ?? lang))
            }
            if let t = stags["title"] as? String ?? stags["handler_name"] as? String, !t.isEmpty, !t.hasPrefix("Core Media"), t != "SoundHandler", t != "VideoHandler" {
                rows.append(("Name", t))
            }
            let label = ["video": "Video", "audio": "Audio", "subtitle": "Subtitles"][type] ?? type.capitalized
            out.append(Section(title: n == 1 && counts[type] == 1 ? label : "\(label) \(n)", rows: rows))
        }
        if p.video == nil && p.audio == nil { out.append(Section(title: "Streams", rows: [("", "No video or audio found")])) }
        return out
    }

    static func text(_ url: URL, _ p: MediaProbe) -> String {
        sections(url, p).map { s in
            ([s.title] + s.rows.map { "  \($0.0): \($0.1)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Where the recording was made, from the ISO 6709 tag phones write ("+48.8584+002.2945+035.000/").
    static func location(_ p: MediaProbe) -> (lat: Double, lon: Double)? {
        let tags = p.format["tags"] as? [String: Any] ?? [:]
        guard let s = tags.first(where: { $0.key.lowercased().hasSuffix("location.iso6709") || $0.key.lowercased() == "location" })?.value as? String else { return nil }
        let nums = s.matches(of: #/[+-]\d+(?:\.\d+)?/#).compactMap { Double($0.output) }
        guard nums.count >= 2, abs(nums[0]) <= 90, abs(nums[1]) <= 180 else { return nil }
        return (nums[0], nums[1])
    }

    private static func codec(_ s: [String: Any]) -> String {
        let name = (s["codec_name"] as? String ?? "?")
        let friendly = ["h264": "H.264", "hevc": "HEVC (H.265)", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "prores": "ProRes", "aac": "AAC",
                        "mp3": "MP3", "opus": "Opus", "vorbis": "Vorbis", "flac": "FLAC", "alac": "Apple Lossless", "ac3": "Dolby Digital",
                        "eac3": "Dolby Digital Plus", "mpeg4": "MPEG-4 Part 2", "mov_text": "Text (MP4)", "subrip": "SRT", "webvtt": "WebVTT",
                        "mjpeg": "Motion JPEG", "png": "PNG"][name] ?? (name.hasPrefix("pcm_") ? "PCM (\(name.dropFirst(4)))" : name.uppercased())
        if let profile = s["profile"] as? String, !profile.isEmpty, profile != "unknown" { return "\(friendly), \(profile)" }
        return friendly
    }

    private static func bitrate(_ v: Any?) -> String? {
        guard let b = Double(v as? String ?? ""), b > 0 else { return nil }
        return b >= 1_000_000 ? String(format: "%.1f Mbps", b / 1_000_000) : String(format: "%.0f kbps", b / 1000)
    }

    private static func rate(_ s: String?) -> Double? {
        guard let p = s?.split(separator: "/").compactMap({ Double($0) }), p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
        return p[0] / p[1]
    }

    private static func resolutionName(_ w: Int, _ h: Int) -> String {
        let short = min(w, h)
        switch short {
        case 2100...: return " (4K)"
        case 1400..<2100: return " (1440p)"
        case 1000..<1400: return " (1080p)"
        case 700..<1000: return " (720p)"
        case 460..<700: return " (480p)"
        default: return ""
        }
    }

    private static func colorDescription(_ s: [String: Any]) -> String? {
        let transfer = s["color_transfer"] as? String, primaries = s["color_primaries"] as? String
        if transfer == "arib-std-b67" { return "HDR (HLG)" + (primaries.map { ", \($0)" } ?? "") }
        if transfer == "smpte2084" { return "HDR10 (PQ)" + (primaries.map { ", \($0)" } ?? "") }
        if let side = s["side_data_list"] as? [[String: Any]], side.contains(where: { ($0["side_data_type"] as? String)?.contains("DOVI") == true }) {
            return "Dolby Vision"
        }
        return primaries.map { "SDR, \($0)" }
    }

    private static func prettyDate(_ s: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let d = iso.date(from: s) ?? plain.date(from: s) else { return s }
        return d.formatted(date: .long, time: .shortened)
    }
}

@MainActor @Observable
final class MediaInfoModel {
    static let shared = MediaInfoModel()

    struct Entry: Identifiable {
        let id = UUID()
        let url: URL
        var probe: MediaProbe?
        var error: String?
    }

    var entries: [Entry] = []
    var selection: Entry.ID?
    var saved: [URL] = []

    var selected: Entry? { entries.first { $0.id == selection } ?? entries.first }

    func add(_ urls: [URL]) {
        let known = Set(entries.map(\.url))
        for url in urls where !known.contains(url) && !url.isDirectory {
            let e = Entry(url: url)
            entries.append(e)
            Task {
                do {
                    let p = try await MediaProbe.read(url)
                    if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i].probe = p }
                } catch {
                    if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i].error = error.localizedDescription }
                }
            }
        }
        if selection == nil { selection = entries.first?.id }
    }

    func exportJSON(all: Bool) {
        let chosen = all ? entries : selected.map { [$0] } ?? []
        let objects: [Any] = chosen.compactMap { e in
            guard let p = e.probe, var obj = try? JSONSerialization.jsonObject(with: p.json) as? [String: Any] else { return nil }
            obj["file"] = e.url.path
            return obj
        }
        guard !objects.isEmpty else { return }
        let name = !all && chosen.count == 1 ? chosen[0].url.baseName + " info" : "Media Info"
        let value: Any = all ? objects : objects[0]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        let out = Output.file(name: name, ext: "json")
        try? data.write(to: out)
        saved = [out]
    }
}

struct MediaInfoView: View {
    @Bindable private var model = MediaInfoModel.shared
    @State private var targeted = false
    private let types: [UTType] = [.movie, .video, .audio]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.entries.isEmpty {
                    DropZone(prompt: "Drop videos or audio files", types: types, multiple: true, urls: Binding(get: { [] }, set: { model.add($0) }))
                        .padding(16)
                    Spacer()
                } else {
                    List(selection: $model.selection) {
                        ForEach(model.entries) { e in
                            HStack {
                                Thumbnail(url: e.url, size: 28)
                                VStack(alignment: .leading) {
                                    Text(e.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(e.error ?? e.probe.map { summary($0) } ?? "Reading…").font(.caption)
                                        .foregroundStyle(e.error == nil ? Color.secondary : Color.red).lineLimit(1)
                                }
                            }
                            .tag(e.id)
                        }
                    }
                    Divider()
                    HStack {
                        Button { model.add(FilePicker.choose(types: types)) } label: { Label("Add Files…", systemImage: "plus") }
                        Spacer()
                        Button("Clear") { model.entries = []; model.selection = nil; model.saved = [] }
                    }
                    .buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .frame(width: 280)
            .onDrop(of: FileDrop.types, isTargeted: $targeted) { providers in
                FileDrop.load(providers) { model.add($0) }
                return true
            }
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .receivesFiles(for: "mediainfo") { model.add($0) }
    }

    private func summary(_ p: MediaProbe) -> String {
        var parts: [String] = [timecode(p.duration)]
        if p.video != nil { parts.append("\(Int(p.displaySize.width))×\(Int(p.displaySize.height))") }
        if let v = p.video?["codec_name"] as? String { parts.append(v.uppercased()) }
        if let a = p.audio?["codec_name"] as? String { parts.append(a.uppercased()) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var detail: some View {
        if let e = model.selected {
            if let p = e.probe {
                VStack(spacing: 0) {
                    HStack {
                        Text(e.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let loc = MediaReport.location(p) {
                            Button { NSWorkspace.shared.open(URL(string: "https://maps.apple.com/?ll=\(loc.lat),\(loc.lon)&q=\(e.url.baseName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) } label: {
                                Label("Show in Maps", systemImage: "map")
                            }
                        }
                        CopyButton(text: MediaReport.text(e.url, p), label: "Copy as Text")
                        Menu("Export as JSON") {
                            Button("This File") { model.exportJSON(all: false) }
                            Button("All \(model.entries.count) Files") { model.exportJSON(all: true) }.disabled(model.entries.count < 2)
                        }
                        .fixedSize()
                    }
                    .padding(16)
                    if !model.saved.isEmpty { ResultList(urls: model.saved).padding(.horizontal, 16) }
                    Form {
                        ForEach(MediaReport.sections(e.url, p)) { s in
                            Section(s.title) {
                                ForEach(Array(s.rows.enumerated()), id: \.offset) { _, row in
                                    LabeledContent(row.0) { Text(row.1).textSelection(.enabled).multilineTextAlignment(.trailing) }
                                }
                            }
                        }
                        if MediaReport.location(p) == nil {
                            Section { Text("No location is stored in this file.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .formStyle(.grouped)
                }
            } else if let err = e.error {
                ErrorText(message: err).padding()
            } else {
                ProgressView()
            }
        } else {
            ContentUnavailableView("No File", systemImage: "info.circle", description: Text("Drop a video or audio file to see what's inside. Files are only read, never changed."))
        }
    }
}
