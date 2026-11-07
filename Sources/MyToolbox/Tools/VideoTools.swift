import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let videoTools: [Tool] = [
        Tool("download", "Download Video", "arrow.down.circle", .video,
             "Save videos or audio from YouTube, X, Instagram, TikTok and 1000+ sites") { DownloadVideoView() },
        Tool("compressvideo", "Compress Video", "rectangle.compress.vertical", .video,
             "Make videos smaller with barely visible quality loss", accepts: [.movie], fullBleed: true) { CompressVideoView() },
    ]
}

// MARK: - yt-dlp

struct DownloadOptions: Equatable {
    enum Quality: String, CaseIterable, Identifiable {
        case best = "Best Quality", p1080 = "1080p", p720 = "720p", m4a = "Audio Only (M4A)", mp3 = "Audio Only (MP3)"
        var id: String { rawValue }
        var isAudio: Bool { self == .m4a || self == .mp3 }
    }

    var quality: Quality = .best
    var preferH264 = true
    var playlist = false
    var subtitles = false
    /// Read the login from this browser. Only set after a sign-in error, never by default:
    /// reading Chrome's cookies makes macOS ask for the keychain password.
    var cookiesBrowser: String?
}

enum YTDLP {
    static let tab = "\t"

    static func arguments(url: String, options o: DownloadOptions, outDir: URL, tempDir: URL, ffmpeg: String?) -> [String] {
        var args = ["--newline", "--progress", "--no-colors", "--no-mtime", "--no-simulate",
                    "-P", outDir.path, "-P", "temp:\(tempDir.path)",
                    "-o", "%(title).150B [%(id)s].%(ext)s",
                    "--print", "video:MTBXMETA\(tab)%(.{id,title,thumbnail,duration,format_id,filesize_approx,uploader})j",
                    "--print", "after_move:MTBXDONE\(tab)%(id)s\(tab)%(filepath)s",
                    "--progress-template", ["download:MTBXP", "%(info.id)s", "%(info.format_id)s", "%(progress.status)s",
                                            "%(progress.downloaded_bytes)s", "%(progress.total_bytes)s", "%(progress.total_bytes_estimate)s",
                                            "%(progress.speed)s", "%(progress.eta)s", "%(progress.fragment_index)s",
                                            "%(progress.fragment_count)s"].joined(separator: tab)]
        let sort = o.preferH264 ? "vcodec:h264,res,acodec:m4a" : "res,fps,vcodec,acodec"
        switch o.quality {
        case .best:
            args += ["-f", "bv*+ba/b", "-S", sort, "--merge-output-format", o.preferH264 ? "mp4" : "mp4/mkv"]
        case .p1080:
            args += ["-f", "bv*[height<=1080]+ba/b[height<=1080]/b", "-S", sort, "--merge-output-format", "mp4"]
        case .p720:
            args += ["-f", "bv*[height<=720]+ba/b[height<=720]/b", "-S", sort, "--merge-output-format", "mp4"]
        case .m4a:
            args += ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]
        case .mp3:
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        }
        args.append(o.playlist ? "--yes-playlist" : "--no-playlist")
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg] }
        if let browser = o.cookiesBrowser { args += ["--cookies-from-browser", browser] }
        if o.subtitles && !o.quality.isAudio {
            args += ["--write-subs", "--write-auto-subs", "--sub-langs", "en.*,en", "--embed-subs"]
        }
        args.append(url)
        return args
    }

    enum Failure: Equatable {
        case needsLogin, outdated, other
    }

    static func classify(_ error: String) -> Failure {
        let e = error.lowercased()
        let login = ["sign in to confirm", "login required", "log in to", "private video", "video is private", "age-restricted",
                     "age restricted", "confirm your age", "members-only", "members only", "requires authentication",
                     "use --cookies", "--cookies-from-browser"]
        if login.contains(where: e.contains) { return .needsLogin }
        let outdated = ["http error 403", "unable to extract", "nsig", "signature extraction", "requested format is not available",
                        "please report this issue"]
        if outdated.contains(where: e.contains) { return .outdated }
        return .other
    }

    /// Days since this yt-dlp release (its version is its date, e.g. 2026.10.26).
    static func ageInDays() async -> Int? {
        guard let exe = Shell.which("yt-dlp"), let r = try? await Shell.run(exe, ["--version"]) else { return nil }
        let parts = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }

    /// Updates through Homebrew when that's how it was installed, else yt-dlp's own updater.
    static func update() async -> String {
        guard let exe = Shell.which("yt-dlp") else { return "yt-dlp isn't installed. Install it with: brew install yt-dlp" }
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: exe)) ?? exe
        let result: Shell.Result?
        if resolved.contains("Cellar"), let brew = Shell.which("brew") {
            result = try? await Shell.run(brew, ["upgrade", "yt-dlp"])
        } else {
            result = try? await Shell.run(exe, ["-U"])
        }
        let version = (try? await Shell.run(exe, ["--version"]))?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        if let result, !result.ok, !result.err.contains("already installed") {
            return "Update failed: " + (result.err.split(separator: "\n").last.map(String.init) ?? "unknown error")
        }
        return "yt-dlp \(version) is installed."
    }

    static let videoHosts = ["youtube.com", "youtu.be", "x.com", "twitter.com", "instagram.com", "tiktok.com", "vimeo.com",
                             "reddit.com", "twitch.tv", "soundcloud.com", "facebook.com", "fb.watch", "dailymotion.com",
                             "bilibili.com", "threads.net", "linkedin.com", "pinterest.com", "streamable.com", "bandcamp.com"]

    static func isLikelyVideoLink(_ s: String) -> Bool {
        guard let host = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return videoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

// MARK: - Download queue

@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()

    struct Item: Identifiable {
        let id: String
        var title: String
        var thumbnail: URL?
        var duration: Double?
        var uploader: String?
        var parts: [String] = []
        var approxSize: Int64?
        var progress: Double = 0
        var speed: Double?
        var eta: Double?
        var processing = false
        var file: URL?
    }

    enum State: Equatable {
        case queued, running, paused, finished, cancelled
        case failed(String, YTDLP.Failure)
    }

    struct Job: Identifiable {
        let id = UUID()
        let url: String
        var options: DownloadOptions
        var state: State = .queued
        var items: [Item] = []
        var log: [String] = []
    }

    var jobs: [Job] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private let maxParallel = 2

    var hasFinished: Bool { jobs.contains { [.finished, .cancelled].contains($0.state) || { if case .failed = $0.state { true } else { false } }($0) } }
    var activeCount: Int { jobs.filter { $0.state == .running || $0.state == .paused }.count }
    var allPaused: Bool { activeCount > 0 && jobs.allSatisfy { $0.state != .running } }

    /// Freezes the download where it is (yt-dlp and its ffmpeg); Resume carries on from the same byte.
    func pause(_ id: UUID) {
        guard let i = index(id), jobs[i].state == .running else { return }
        Shell.setPaused(true, tag: id.uuidString)
        jobs[i].state = .paused
    }

    func resume(_ id: UUID) {
        guard let i = index(id), jobs[i].state == .paused else { return }
        Shell.setPaused(false, tag: id.uuidString)
        jobs[i].state = .running
    }

    func pauseAll() { jobs.filter { $0.state == .running }.forEach { pause($0.id) } }
    func resumeAll() { jobs.filter { $0.state == .paused }.forEach { resume($0.id) } }
    var outputFolder: URL { Output.root }

    func add(_ urls: [String], options: DownloadOptions) {
        for url in urls { jobs.append(Job(url: url, options: options)) }
        pump()
    }

    func retry(_ id: UUID, cookies browser: String? = nil) {
        guard let i = index(id) else { return }
        var options = jobs[i].options
        if let browser { options.cookiesBrowser = browser }
        jobs[i] = Job(url: jobs[i].url, options: options)
        pump()
    }

    func cancel(_ id: UUID) {
        if let i = index(id), jobs[i].state == .paused { Shell.setPaused(false, tag: id.uuidString) }
        if let task = tasks[id] { task.cancel() } else if let i = index(id) { jobs[i].state = .cancelled }
    }

    func remove(_ id: UUID) {
        cancel(id)
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll { ![.queued, .running, .paused].contains($0.state) }
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func pump() {
        while tasks.count < maxParallel, let next = jobs.first(where: { $0.state == .queued }) {
            let id = next.id
            jobs[index(id)!].state = .running
            tasks[id] = Task { await Shell.$tag.withValue(id.uuidString) { await self.run(id) } }
        }
    }

    private func run(_ id: UUID) async {
        defer { tasks[id] = nil; pump() }
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard let exe = Shell.which("yt-dlp") else {
            mutate(id) { $0.state = .failed("yt-dlp isn't installed. Install it in Terminal with: brew install yt-dlp", .other) }
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MyToolbox-download-\(id.uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }   // partial files never reach the output folder

        let args = YTDLP.arguments(url: job.url, options: job.options, outDir: outputFolder, tempDir: temp, ffmpeg: Shell.which("ffmpeg"))
        do {
            let code = try await Shell.stream(exe, args) { [weak self] line in self?.handle(line, job: id) }
            mutate(id) { job in
                let done = job.items.filter { $0.file != nil }.count
                if code == 0 || done > 0 {
                    job.state = .finished
                } else {
                    let error = job.log.last(where: { $0.hasPrefix("ERROR") }) ?? "yt-dlp stopped with code \(code)"
                    let message = error.replacingOccurrences(of: #"^ERROR:\s*(\[[^\]]+\]\s*[^:]+:\s*)?"#, with: "", options: .regularExpression)
                    job.state = .failed(message, YTDLP.classify(error))
                }
            }
        } catch is CancellationError {
            mutate(id) { $0.state = .cancelled }
        } catch {
            mutate(id) { $0.state = .failed(error.localizedDescription, .other) }
        }
    }

    private func mutate(_ id: UUID, _ change: (inout Job) -> Void) {
        if let i = index(id) { change(&jobs[i]) }
    }

    private func handle(_ line: String, job id: UUID) {
        let fields = line.components(separatedBy: YTDLP.tab)
        switch fields.first {
        case "MTBXMETA":
            guard fields.count > 1, let data = fields[1].data(using: .utf8),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let vid = meta["id"] as? String else { return }
            let item = Item(id: vid, title: meta["title"] as? String ?? vid,
                            thumbnail: (meta["thumbnail"] as? String).flatMap(URL.init(string:)),
                            duration: meta["duration"] as? Double,
                            uploader: meta["uploader"] as? String,
                            parts: (meta["format_id"] as? String)?.components(separatedBy: "+") ?? [],
                            approxSize: (meta["filesize_approx"] as? NSNumber)?.int64Value)
            mutate(id) { job in
                if let i = job.items.firstIndex(where: { $0.id == vid }) { job.items[i] = item } else { job.items.append(item) }
            }
        case "MTBXP":
            guard fields.count >= 11 else { return }
            let vid = fields[1], format = fields[2], status = fields[3]
            let downloaded = Double(fields[4]), total = Double(fields[5]) ?? Double(fields[6])
            let frag = Double(fields[9]), frags = Double(fields[10])
            mutate(id) { job in
                guard let i = job.items.firstIndex(where: { $0.id == vid }) else { return }
                let parts = max(1, job.items[i].parts.count)
                let part = Double(job.items[i].parts.firstIndex(of: format) ?? 0)
                var fraction: Double = 0
                if let frag, let frags, frags > 0 { fraction = frag / frags }
                else if let downloaded, let total, total > 0 { fraction = downloaded / total }
                if status == "finished" { fraction = 1 }
                job.items[i].progress = min(1, (part + min(1, fraction)) / Double(parts))
                job.items[i].speed = Double(fields[7])
                job.items[i].eta = Double(fields[8])
                if status == "finished" && Int(part) == parts - 1 { job.items[i].processing = true }
            }
        case "MTBXDONE":
            guard fields.count >= 3 else { return }
            mutate(id) { job in
                if let i = job.items.firstIndex(where: { $0.id == fields[1] }) {
                    job.items[i].file = URL(fileURLWithPath: fields[2])
                    job.items[i].progress = 1
                    job.items[i].processing = false
                }
            }
        default:
            mutate(id) { job in
                job.log.append(line)
                if job.log.count > 200 { job.log.removeFirst(job.log.count - 200) }
                if line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[EmbedSubtitle]") {
                    if let i = job.items.indices.last(where: { job.items[$0].file == nil }) { job.items[i].processing = true }
                }
            }
        }
    }
}

// MARK: - Download view

struct DownloadVideoView: View {
    @State private var links = ""
    @State private var options = DownloadOptions()
    @AppStorage("dl.format") private var quality: DownloadOptions.Quality = .best
    @AppStorage("dl.h264") private var preferH264 = true
    @State private var ytdlpAge: Int?
    @State private var updating = false
    @State private var updateMessage: String?
    @FocusState private var linkFocused: Bool
    private var manager: DownloadManager { .shared }

    private var urls: [String] {
        links.components(separatedBy: .whitespacesAndNewlines).filter { $0.hasPrefix("http") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let needed = Optional(Helpers.shared.missing.filter { $0.id == "yt-dlp" || $0.id == "ffmpeg" }), !needed.isEmpty {
                Banner(symbol: "exclamationmark.triangle.fill",
                       message: Helpers.shared.installing.isEmpty
                           ? "Download Video needs the free \(needed.map(\.id).joined(separator: " and ")) helper\(needed.count > 1 ? "s" : "")."
                           : Helpers.shared.log) {
                    HelperInstallButton(helpers: needed)
                }
            } else if let age = ytdlpAge, age > 45 {
                Banner(symbol: "clock.badge.exclamationmark", message: "yt-dlp is \(age) days old. Sites change often, so downloads may fail until you update.") {
                    Button(updating ? "Updating…" : "Update yt-dlp", action: update).disabled(updating)
                }
            }
            if let updateMessage { Banner(symbol: "checkmark.circle", message: updateMessage, tint: .green) }

            HStack(alignment: .top, spacing: 8) {
                TextField("Paste a link — or several, one per line", text: $links, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($linkFocused)
                    .onSubmit(start)
                Button("Paste") { if let s = Pasteboard.string { links = s } }
                    .help("Paste links from the clipboard")
                Button("Download", action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(urls.isEmpty)
            }

            HStack(spacing: 16) {
                Picker("Format", selection: $quality) {
                    ForEach(DownloadOptions.Quality.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Toggle("Prefer H.264", isOn: $preferH264)
                    .disabled(quality.isAudio)
                    .help("Plays in QuickTime, Photos and on iPhone. Turn off to allow 4K, which comes as VP9 or AV1 and won't play in QuickTime.")
                Menu("More Options") {
                    Toggle("Download Whole Playlist", isOn: $options.playlist)
                    Toggle("Embed English Subtitles", isOn: $options.subtitles)
                }
                .fixedSize()
                Spacer()
            }

            Divider()
            queue
        }
        .receivesFiles(for: "download") { urls in
            let new = urls.filter { !$0.isFileURL }.map(\.absoluteString)
            if !new.isEmpty { manager.add(new, options: currentOptions) }
        }
        .task {
            ytdlpAge = await YTDLP.ageInDays()
            if links.isEmpty, let clip = Pasteboard.string, YTDLP.isLikelyVideoLink(clip),
               !manager.jobs.contains(where: { $0.url == clip.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                links = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            linkFocused = true
        }
    }

    @ViewBuilder private var queue: some View {
        if manager.jobs.isEmpty {
            ContentUnavailableView {
                Label("No Downloads Yet", systemImage: "arrow.down.circle")
            } description: {
                Text("Copy a link from YouTube, X, Instagram, TikTok, Vimeo, Reddit or SoundCloud, paste it above and press Return.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(manager.jobs.reversed()) { job in
                    if job.items.isEmpty {
                        DownloadPlaceholderRow(job: job)
                    } else {
                        ForEach(job.items) { item in DownloadItemRow(job: job, item: item) }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            HStack {
                Button { NSWorkspace.shared.open(manager.outputFolder) } label: {
                    Label("Saves to \(manager.outputFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))", systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                if manager.activeCount > 0 {
                    Button(manager.allPaused ? "Resume All" : "Pause All") { manager.allPaused ? manager.resumeAll() : manager.pauseAll() }
                }
                Button("Clear Finished") { manager.clearFinished() }.disabled(!manager.hasFinished)
            }
        }
    }

    private var currentOptions: DownloadOptions {
        var o = options
        o.quality = quality
        o.preferH264 = preferH264
        return o
    }

    private func start() {
        guard !urls.isEmpty else { return }
        manager.add(urls, options: currentOptions)
        links = ""
    }

    private func update() {
        updating = true
        Task {
            updateMessage = await YTDLP.update()
            ytdlpAge = await YTDLP.ageInDays()
            updating = false
        }
    }
}

private struct DownloadPlaceholderRow: View {
    let job: DownloadManager.Job
    private var manager: DownloadManager { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 96, height: 54)
                .overlay { Image(systemName: "link").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 4) {
                Text(job.url).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .queued: Text("Waiting…").foregroundStyle(.secondary)
                case .paused: Text("Paused").foregroundStyle(.secondary)
                case .running: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Getting video info…").foregroundStyle(.secondary) }
                case .cancelled: Text("Cancelled").foregroundStyle(.secondary)
                case .finished: Text("Nothing to download").foregroundStyle(.secondary)
                case .failed(let message, let kind): DownloadFailure(job: job, message: message, kind: kind)
                }
            }
            Spacer()
            DownloadJobButtons(job: job)
        }
        .padding(.vertical, 4)
        .contextMenu { DownloadContextMenu(job: job) }
    }
}

private struct DownloadItemRow: View {
    let job: DownloadManager.Job
    let item: DownloadManager.Item
    @State private var previewing: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: item.thumbnail) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                if let d = item.duration {
                    Text(timecode(d)).font(.caption2.monospacedDigit()).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white).padding(3)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                status
            }
            Spacer()
            if let file = item.file {
                HStack(spacing: 4) {
                    Button { previewing = file } label: { Image(systemName: "eye.circle") }
                        .help("Preview here")
                    Button { NSWorkspace.shared.open(file) } label: { Image(systemName: "play.circle") }
                        .help("Open \(file.lastPathComponent)")
                    Button { file.reveal() } label: { Image(systemName: "magnifyingglass.circle") }
                        .help("Show in Finder")
                }
                .buttonStyle(.borderless).font(.title2)
            } else {
                DownloadJobButtons(job: job)
            }
        }
        .padding(.vertical, 4)
        .contextMenu { DownloadContextMenu(job: job, file: item.file) }
        .draggableFile(item.file)
        .sheet(item: $previewing) { PreviewSheet(url: $0) }
        .onTapGesture(count: 2) { if let f = item.file { NSWorkspace.shared.open(f) } }
    }

    @ViewBuilder private var status: some View {
        if let file = item.file {
            Label("\(file.fileSize.byteString) · \(file.pathExtension.uppercased())", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        } else {
            switch job.state {
            case .failed(let message, let kind): DownloadFailure(job: job, message: message, kind: kind)
            case .cancelled: Text("Cancelled").font(.callout).foregroundStyle(.secondary)
            case .queued: Text("Waiting…").font(.callout).foregroundStyle(.secondary)
            case .paused:
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: item.progress).tint(.secondary)
                    Text("Paused at \(Int(item.progress * 100))%").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360)
            default:
                VStack(alignment: .leading, spacing: 3) {
                    if item.processing {
                        ProgressView().progressViewStyle(.linear)
                        Text("Finishing up…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView(value: item.progress)
                        Text(progressText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 360)
            }
        }
    }

    private var progressText: String {
        var parts = ["\(Int(item.progress * 100))%"]
        if let size = item.approxSize { parts.append("of ~\(size.byteString)") }
        if let s = item.speed, s > 0 { parts.append("· \(Int64(s).byteString)/s") }
        if let eta = item.eta, eta > 0 { parts.append("· \(timecode(eta)) left") }
        return parts.joined(separator: " ")
    }
}

private struct DownloadFailure: View {
    let job: DownloadManager.Job
    let message: String
    let kind: YTDLP.Failure
    private var manager: DownloadManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .needsLogin:
                Text("This video needs you to be signed in.").foregroundStyle(.orange)
                HStack {
                    Menu("Retry Using Browser Login") {
                        ForEach(["Safari", "Chrome", "Firefox", "Arc", "Brave", "Edge"], id: \.self) { name in
                            Button(name) { manager.retry(job.id, cookies: name.lowercased()) }
                        }
                    }
                    .fixedSize()
                }
                Text("Uses the login from the browser you pick. For Chrome, macOS asks once for your keychain password — choose Always Allow.")
                    .font(.caption).foregroundStyle(.secondary)
            case .outdated:
                Text("The site changed and yt-dlp can't read it yet. Update yt-dlp, then retry.").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            case .other:
                Text(message).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
        }
        .font(.callout)
    }
}

private struct DownloadJobButtons: View {
    let job: DownloadManager.Job
    private var manager: DownloadManager { .shared }

    var body: some View {
        Group {
            switch job.state {
            case .queued:
                Button { manager.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Cancel this download")
            case .running, .paused:
                HStack(spacing: 2) {
                    if job.state == .paused {
                        Button { manager.resume(job.id) } label: { Image(systemName: "play.circle.fill") }.help("Resume")
                    } else {
                        Button { manager.pause(job.id) } label: { Image(systemName: "pause.circle.fill") }.help("Pause")
                    }
                    Button { manager.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }.help("Cancel this download")
                }
            case .failed, .cancelled:
                Button { manager.retry(job.id) } label: { Image(systemName: "arrow.clockwise.circle") }
                    .help("Try again")
            case .finished:
                EmptyView()
            }
        }
        .buttonStyle(.borderless).font(.title2).foregroundStyle(.secondary)
    }
}

private struct DownloadContextMenu: View {
    let job: DownloadManager.Job
    var file: URL?
    private var manager: DownloadManager { .shared }

    var body: some View {
        if let file {
            Button("Open") { NSWorkspace.shared.open(file) }
            Button("Show in Finder") { file.reveal() }
            Divider()
        }
        Button("Copy Link") { Pasteboard.copy(job.url) }
        if !job.log.isEmpty { Button("Copy Details") { Pasteboard.copy(job.log.joined(separator: "\n")) } }
        Divider()
        Button("Remove from List") { manager.remove(job.id) }
    }
}

// MARK: - Compress Video

enum VideoQuality: String, CaseIterable, Identifiable {
    case high = "High", balanced = "Balanced", small = "Small"
    var id: String { rawValue }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264", hevc = "HEVC"
    var id: String { rawValue }
}

struct CompressVideoSettings: Equatable {
    var quality: VideoQuality = .balanced
    var codec: VideoCodec = .h264
    /// Shorter side cap in pixels; 0 = keep.
    var maxResolution = 0
    var removeAudio = false
    var hardware = false

    func ffmpegArguments(input: URL, output: URL) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"]
        let scale = maxResolution > 0
            ? "scale='if(gte(iw,ih),-2,min(\(maxResolution),iw))':'if(gte(iw,ih),min(\(maxResolution),ih),-2)'"
            : "scale='trunc(iw/2)*2':'trunc(ih/2)*2'"
        args += ["-vf", scale]
        switch (codec, hardware) {
        case (.h264, false):
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", ["High": "20", "Balanced": "24", "Small": "28"][quality.rawValue]!,
                     "-pix_fmt", "yuv420p"]
        case (.hevc, false):
            args += ["-c:v", "libx265", "-preset", "medium", "-crf", ["High": "22", "Balanced": "26", "Small": "30"][quality.rawValue]!,
                     "-tag:v", "hvc1", "-x265-params", "log-level=error"]
        case (.h264, true):
            args += ["-c:v", "h264_videotoolbox", "-q:v", ["High": "65", "Balanced": "55", "Small": "45"][quality.rawValue]!, "-pix_fmt", "yuv420p"]
        case (.hevc, true):
            args += ["-c:v", "hevc_videotoolbox", "-q:v", ["High": "65", "Balanced": "55", "Small": "45"][quality.rawValue]!, "-tag:v", "hvc1"]
        }
        if removeAudio {
            args.append("-an")
        } else {
            args += ["-c:a", "aac", "-b:a", quality == .small ? "96k" : "128k"]
        }
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
        return args
    }
}

enum FFmpeg {
    static func duration(_ url: URL) async -> Double? {
        guard let probe = Shell.which("ffprobe"),
              let r = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]) else {
            return nil
        }
        return Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs ffmpeg with `-progress pipe:1`, reporting 0…1.
    static func run(_ args: [String], duration: Double?, cwd: URL? = nil, progress: @escaping @MainActor (Double) -> Void) async throws {
        let exe = try Shell.require("ffmpeg")
        var errors: [String] = []
        let code = try await Shell.stream(exe, args, cwd: cwd) { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), let d = duration, d > 0 {
                MainActor.assumeIsolated { progress(us / 1_000_000 / d) }
            } else if !line.contains("=") {
                errors.append(line)
            }
        }
        if code != 0 { throw ToolError(explain(errors)) }
    }

    /// ffmpeg's last words, translated where we know what they mean.
    static func explain(_ lines: [String]) -> String {
        let all = lines.joined(separator: "\n")
        if all.contains("Invalid data found when processing input") || all.contains("could not find codec parameters") {
            return "This file isn't a video or audio file that can be read — it may be damaged or a different kind of file."
        }
        if all.contains("does not contain any stream") || all.contains("Output file does not contain any stream")
            || (all.contains("matches no streams") && all.contains("0:a")) {
            return "This file has no sound track."
        }
        if all.contains("No space left on device") { return "The disk is full." }
        if all.contains("Permission denied") { return "MyToolbox isn't allowed to read or write that file." }
        if all.contains("No such filter: 'subtitles'") || all.contains("No such filter: 'ass'") {
            return "Your ffmpeg can't draw subtitles (it was built without libass). Reinstall it in Terminal with: brew reinstall ffmpeg"
        }
        if all.contains("Unknown encoder") || all.contains("Encoder not found") {
            return "Your ffmpeg can't make this format. Update it in Terminal with: brew upgrade ffmpeg"
        }
        return lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "ffmpeg failed"
    }

    /// Whether the file has a sound track (nil if it can't be checked).
    static func hasAudio(_ url: URL) async -> Bool? {
        guard let probe = Shell.which("ffprobe"),
              let r = try? await Shell.run(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", url.path]) else { return nil }
        return !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CompressVideoView: View {
    @State private var settings = CompressVideoSettings()

    var body: some View {
        BatchToolView(toolID: "compressvideo", folderName: "Compress Video", types: [.movie, .video], noun: "Video", verb: "Compress",
                      concurrency: 1, previewKey: String(describing: settings)) {
            Section("Quality") {
                Picker("Quality", selection: $settings.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(qualityHint).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Format", selection: $settings.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(settings.codec == .h264 ? "Plays everywhere." : "About half the size of H.264. Slower, and older devices may not play it.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Max resolution", selection: $settings.maxResolution) {
                    Text("Keep original").tag(0)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                    Text("480p").tag(480)
                }
                Toggle("Remove audio", isOn: $settings.removeAudio)
                Toggle("Use hardware encoder", isOn: $settings.hardware)
                if settings.hardware {
                    Text("Much faster, but files come out larger.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Format")
            } footer: {
                Text("Originals are never changed, and videos are never made larger.").font(.caption).foregroundStyle(.secondary)
            }
        } process: { [settings] url, folder, progress in
            if Shell.which("ffmpeg") == nil { throw ShellError.missing("ffmpeg") }
            let duration = await FFmpeg.duration(url)
            let out = Output.unique(folder.appendingPathComponent(url.baseName + " compressed").appendingPathExtension("mp4"))
            do {
                try await FFmpeg.run(settings.ffmpegArguments(input: url, output: out), duration: duration, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
            let before = url.fileSize, after = out.fileSize
            if after >= before {
                try? FileManager.default.removeItem(at: out)
                return BatchOutput(note: "Already small — compressing wouldn't save space")
            }
            return BatchOutput(files: [out], note: sizeChange(before, after))
        }
    }

    private var qualityHint: String {
        switch settings.quality {
        case .high: "Barely noticeable difference from the original."
        case .balanced: "Good quality at a much smaller size. Best for most videos."
        case .small: "Smallest files. Fine for sharing in chats."
        }
    }
}
