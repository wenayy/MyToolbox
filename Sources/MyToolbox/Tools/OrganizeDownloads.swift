import Observation
import Photos
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let organizeTools: [Tool] = [
        Tool("organizedownloads", "Organize Downloads", "tray.full", .files,
             "Sort downloaded images by the site they came from, into folders or Photos albums") { OrganizeDownloadsView() },
    ]
}

/// "pbs.twimg.com → X": a domain (and its subdomains) and the source it counts as.
struct SourceRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var domain: String
    var name: String
}

enum DownloadSources {
    static let key = "organize.rules"

    static let defaults: [SourceRule] = [
        ("twimg.com", "X"), ("x.com", "X"), ("twitter.com", "X"),
        ("cdninstagram.com", "Instagram"), ("instagram.com", "Instagram"),
        ("fbcdn.net", "Facebook"), ("facebook.com", "Facebook"),
        ("pinimg.com", "Pinterest"), ("pinterest.com", "Pinterest"),
        ("redd.it", "Reddit"), ("redditmedia.com", "Reddit"), ("reddit.com", "Reddit"),
        ("ytimg.com", "YouTube"), ("youtube.com", "YouTube"),
        ("tiktokcdn.com", "TikTok"), ("tiktokcdn-us.com", "TikTok"), ("tiktok.com", "TikTok"),
        ("cdn.bsky.app", "Bluesky"), ("bsky.app", "Bluesky"), ("threads.net", "Threads"), ("threads.com", "Threads"),
        ("licdn.com", "LinkedIn"), ("linkedin.com", "LinkedIn"),
        ("tumblr.com", "Tumblr"), ("imgur.com", "Imgur"), ("unsplash.com", "Unsplash"), ("pexels.com", "Pexels"),
        ("wikimedia.org", "Wikipedia"), ("wikipedia.org", "Wikipedia"),
        ("discordapp.net", "Discord"), ("discordapp.com", "Discord"), ("discord.com", "Discord"),
        ("whatsapp.net", "WhatsApp"), ("whatsapp.com", "WhatsApp"), ("telegram.org", "Telegram"),
        ("slack-edge.com", "Slack"), ("slack.com", "Slack"),
        ("googleusercontent.com", "Google"), ("gstatic.com", "Google"), ("google.com", "Google"),
        ("media-amazon.com", "Amazon"), ("amazon.com", "Amazon"), ("behance.net", "Behance"), ("dribbble.com", "Dribbble"),
        ("artstation.com", "ArtStation"), ("deviantart.net", "DeviantArt"), ("deviantart.com", "DeviantArt"),
    ].map { SourceRule(domain: $0.0, name: $0.1) }

    static func load() -> [SourceRule] {
        guard let data = UserDefaults.standard.data(forKey: key), let rules = try? JSONDecoder().decode([SourceRule].self, from: data) else { return defaults }
        return rules
    }

    static func save(_ rules: [SourceRule]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: key)
    }

    /// The download and page addresses macOS stores with a file ("Where from" in Get Info).
    static func whereFroms(_ url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return [] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
    }

    static func host(_ s: String) -> String? {
        URL(string: s)?.host?.lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
    }

    /// The source name for a file's addresses: the first that matches a rule (longest domain wins),
    /// else the page's own domain. Nil when there's nothing stored.
    static func source(_ froms: [String], rules: [SourceRule]) -> String? {
        let hosts = froms.compactMap(host)
        guard !hosts.isEmpty else { return nil }
        let sorted = rules.filter { !$0.domain.isEmpty }.sorted { $0.domain.count > $1.domain.count }
        for h in hosts {
            if let r = sorted.first(where: { h == $0.domain.lowercased() || h.hasSuffix("." + $0.domain.lowercased()) }) { return r.name }
        }
        return hosts.count > 1 ? hosts[1] : hosts[0]
    }
}

enum OrganizeMode: String, CaseIterable, Identifiable {
    case folders = "Move into folders", photos = "Add to Photos albums"
    var id: String { rawValue }
}

enum OrganizeBy: String, CaseIterable, Identifiable {
    case kind = "Kind", site = "Website"
    var id: String { rawValue }
}

/// The groups files are sorted into by kind; each is also its folder's name.
enum FileKind: String, CaseIterable, Identifiable {
    case screenshots = "Screenshots", images = "Images", videos = "Videos", audio = "Audio", pdfs = "PDFs",
         documents = "Documents", spreadsheets = "Spreadsheets", presentations = "Presentations",
         archives = "Archives", installers = "Installers", other = "Other"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .images: "photo"
        case .videos: "film"
        case .audio: "waveform"
        case .pdfs: "doc.richtext"
        case .documents: "doc.text"
        case .spreadsheets: "tablecells"
        case .presentations: "rectangle.on.rectangle.angled"
        case .archives: "archivebox"
        case .installers: "shippingbox"
        case .other: "questionmark.folder"
        }
    }

    static let installersExtensions: Set = ["dmg", "pkg", "mpkg", "iso", "xip"]
    static let archivesExtensions: Set = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "lz", "lzma", "cab", "sit", "sitx"]
    static let spreadsheetsExtensions: Set = ["xlsx", "xls", "xlsm", "csv", "tsv", "numbers", "ods"]
    static let presentationsExtensions: Set = ["pptx", "ppt", "pps", "ppsx", "key", "odp"]
    static let documentsExtensions: Set = ["docx", "doc", "pages", "odt", "rtf", "rtfd", "txt", "md", "markdown", "epub", "tex", "html", "htm", "srt", "vtt", "json", "xml"]
    static let screenshotPrefixes = ["Screenshot ", "Screen Shot ", "CleanShot ", "Bildschirmfoto ", "Capture d’écran ", "Captura de pantalla ",
                                     "Schermafbeelding ", "Istantanea ", "スクリーンショット", "截屏", "스크린샷"]

    static func of(_ url: URL) -> FileKind {
        let kind = byExtension(url)
        // No extension, or one nobody knows ("photo.jpg_small", "1ab329ee-…"): look inside.
        return kind == .other ? (sniff(url) ?? .other) : kind
    }

    private static func byExtension(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if installersExtensions.contains(ext) { return .installers }
        if archivesExtensions.contains(ext) { return .archives }
        if spreadsheetsExtensions.contains(ext) { return .spreadsheets }
        if presentationsExtensions.contains(ext) { return .presentations }
        guard let type = UTType.forExtension(ext) else { return documentsExtensions.contains(ext) ? .documents : .other }
        if type.conforms(to: .pdf) { return .pdfs }
        if type.conforms(to: .image) { return isScreenshot(url) ? .screenshots : .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
        if type.conforms(to: .audio) { return .audio }
        if documentsExtensions.contains(ext) { return .documents }
        return .other
    }

    /// The kind from the first bytes of the file, for files whose name doesn't say.
    static func sniff(_ url: URL) -> FileKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64), data.count >= 4 else { return nil }
        let b = [UInt8](data)
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool { b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes }
        func ascii(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }
        if starts([0xFF, 0xD8, 0xFF]) || starts([0x89, 0x50, 0x4E, 0x47]) || ascii("GIF8") || ascii("BM")
            || (ascii("RIFF") && ascii("WEBP", at: 8)) || starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) {
            return isScreenshot(url) ? .screenshots : .images
        }
        if ascii("ftyp", at: 4) {
            let brand = String(decoding: b[8..<min(12, b.count)], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1", "avif", "heis"].contains(brand) { return .images }
            if ["M4A ", "M4B ", "M4P "].contains(brand) { return .audio }
            return .videos
        }
        if ascii("%PDF") { return .pdfs }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) || (ascii("RIFF") && ascii("AVI ", at: 8)) || starts([0x00, 0x00, 0x01, 0xBA]) { return .videos }
        if ascii("ID3") || starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) || starts([0xFF, 0xF2]) || ascii("fLaC") || ascii("OggS")
            || (ascii("RIFF") && ascii("WAVE", at: 8)) || ascii("FORM") || ascii("caff") { return .audio }
        if starts([0x50, 0x4B, 0x03, 0x04]) || ascii("Rar!") || starts([0x37, 0x7A, 0xBC, 0xAF]) || starts([0x1F, 0x8B]) || starts([0xFD, 0x37, 0x7A, 0x58]) {
            return .archives
        }
        if ascii("koly", at: max(0, b.count - 512)) || ascii("xar!") { return .installers }
        return nil
    }

    /// Screenshots macOS took are marked as screen captures; others are known by their usual names.
    static func isScreenshot(_ url: URL) -> Bool {
        if let flag = FileMeta.plist(url, "com.apple.metadata:kMDItemIsScreenCapture") as? Bool { return flag }
        if (FileMeta.plist(url, "com.apple.metadata:kMDItemIsScreenCapture") as? NSNumber)?.boolValue == true { return true }
        let name = url.lastPathComponent
        return screenshotPrefixes.contains { name.hasPrefix($0) }
    }
}

/// Extended attributes macOS keeps with files (binary property lists).
enum FileMeta {
    static func plist(_ url: URL, _ name: String) -> Any? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}

/// Which files in a folder can be sorted, and moving them (and back).
enum Organizer {
    /// Partial downloads from Safari, Chrome, Firefox, Edge, Opera, torrents and download managers.
    static let partialExtensions: Set = ["download", "crdownload", "part", "partial", "opdownload", "tmp", "temp", "!qb", "aria2", "filepart", "crswap", "dtapart", "!ut"]

    /// Files worth sorting: plain, visible, finished files directly inside `folder`. With `settle`, files changed
    /// in the last few seconds are left for later (a download may still be writing them).
    static func candidates(in folder: URL, settle: TimeInterval = 0, now: Date = Date()) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        let names = Set(files.map(\.lastPathComponent))
        return files.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isPackage != true else { return false }
            if partialExtensions.contains(url.pathExtension.lowercased()) { return false }
            if (v.fileSize ?? 0) == 0 { return false }   // Firefox's placeholder while the .part downloads
            if partialExtensions.contains(where: { names.contains(url.lastPathComponent + "." + $0) }) { return false }
            if settle > 0, let m = v.contentModificationDate, now.timeIntervalSince(m) < settle { return false }
            return true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Where each file goes, as a folder name (nil = stays where it is).
    static func destination(_ item: OrganizeModel.Item, by: OrganizeBy, includeRest: Bool) -> String? {
        switch by {
        case .kind: item.kind == .other && !includeRest ? nil : item.kind.rawValue
        case .site: item.kind == .images || item.kind == .screenshots ? item.source ?? (includeRest ? "Unknown" : nil) : nil
        }
    }

    struct Move: Equatable { let from: URL; let to: URL }

    /// Moves each file into a folder named for its group, inside `folder`, never overwriting. Returns what moved, for Undo.
    static func move(_ plan: [(URL, String)], into folder: URL) throws -> [Move] {
        var done: [Move] = []
        for (url, name) in plan where FileManager.default.fileExists(atPath: url.path) {
            let dir = folder.appendingPathComponent(OrganizeModel.safeName(name), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let to = Output.unique(dir.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.moveItem(at: url, to: to)
            done.append(Move(from: url, to: to))
        }
        return done
    }

    /// Puts moved files back where they were (skipping any that were moved again or whose old place is taken).
    static func undo(_ moves: [Move]) -> Int {
        var n = 0
        for m in moves.reversed() where FileManager.default.fileExists(atPath: m.to.path) && !FileManager.default.fileExists(atPath: m.from.path) {
            if (try? FileManager.default.moveItem(at: m.to, to: m.from)) != nil { n += 1 }
        }
        return n
    }
}

@MainActor @Observable
final class OrganizeModel {
    static let shared = OrganizeModel()

    struct Item: Identifiable {
        var id: URL { url }
        let url: URL
        let froms: [String]
        var source: String?
        let kind: FileKind
    }

    static let folderKey = "organize.folder"
    static var savedFolder: URL {
        let path = UserDefaults.standard.string(forKey: folderKey) ?? ""
        return path.isEmpty ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] : URL(fileURLWithPath: path)
    }

    var folder: URL = OrganizeModel.savedFolder {
        didSet { UserDefaults.standard.set(folder.path, forKey: Self.folderKey) }
    }
    var items: [Item] = []
    var rules = DownloadSources.load()
    var scanning = false
    var working = false
    var message: String?
    var error: String?
    /// The last organize (by hand or automatic), for Undo.
    var lastMoves: [Organizer.Move] = []

    func scan() {
        scanning = true; error = nil
        let folder = folder, rules = rules
        Task {
            items = (try? await offMain { try Self.items(in: folder, rules: rules) }) ?? []
            scanning = false
        }
    }

    func reclassify() {
        DownloadSources.save(rules)
        for i in items.indices { items[i].source = DownloadSources.source(items[i].froms, rules: rules) }
    }

    func organize(by: OrganizeBy, mode: OrganizeMode, includeRest: Bool) {
        let plan = items.compactMap { item in Organizer.destination(item, by: by, includeRest: includeRest).map { (item.url, $0) } }
        guard !plan.isEmpty else { message = "Nothing to organize."; return }
        working = true; error = nil; message = nil
        Task {
            do {
                if by == .site && mode == .photos {
                    try await PhotosAlbums.add(plan)
                    message = "Added \(plan.count) image\(plan.count == 1 ? "" : "s") to Photos. The files stay where they are."
                } else {
                    let folder = folder
                    let moves = try await offMain { try Organizer.move(plan, into: folder) }
                    lastMoves = moves
                    let groups = Set(plan.map(\.1)).count
                    message = "Moved \(moves.count) file\(moves.count == 1 ? "" : "s") into \(groups) folder\(groups == 1 ? "" : "s") in \(folder.lastPathComponent)."
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
            scan()
        }
    }

    func undo() {
        let n = Organizer.undo(lastMoves)
        lastMoves = []
        message = "Put \(n) file\(n == 1 ? "" : "s") back."
        scan()
    }

    /// Everything directly inside `folder` that can be sorted, with its kind and the site it came from.
    nonisolated static func items(in folder: URL, rules: [SourceRule], settle: TimeInterval = 0) throws -> [Item] {
        try Organizer.candidates(in: folder, settle: settle).map { url in
            let froms = DownloadSources.whereFroms(url)
            return Item(url: url, froms: froms, source: DownloadSources.source(froms, rules: rules), kind: FileKind.of(url))
        }
    }

    nonisolated static func safeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Unknown" : cleaned
    }
}

/// Sorts new files as they arrive in the watched folder, while MyToolbox runs (it stays in the menu bar).
@MainActor @Observable
final class DownloadsWatcher {
    static let shared = DownloadsWatcher()
    static let enabledKey = "organize.auto"

    private(set) var watching: URL?
    /// The latest automatic moves, newest first, shown in the tool.
    private(set) var recent: [Organizer.Move] = []
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// How long a file must be left unchanged before it's moved.
    @ObservationIgnored var settle: TimeInterval = 3

    /// Turns watching on at launch if the person left it on.
    func restore() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start(OrganizeModel.savedFolder) }
    }

    func start(_ folder: URL) {
        stop()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.schedule() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        watching = folder
        schedule()   // sort whatever is already waiting
    }

    func stop() {
        pending?.cancel(); pending = nil
        source?.cancel(); source = nil
        watching = nil
    }

    /// Runs a pass once things have been quiet for a moment; a pass that leaves files still downloading checks again.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.settle + 0.5))
            guard !Task.isCancelled else { return }
            let waiting = await self.pass()
            if waiting { self.schedule() }
        }
    }

    /// Sorts settled files with the tool's current choices. Returns whether some files are still being downloaded.
    @discardableResult
    func pass() async -> Bool {
        guard let folder = watching else { return false }
        let d = UserDefaults.standard
        let by = OrganizeBy(rawValue: d.string(forKey: "organize.by") ?? "") ?? .kind
        let includeRest = d.bool(forKey: "organize.unknown")
        let rules = OrganizeModel.shared.rules, settle = settle
        let (moves, waiting) = (try? await offMain { () -> ([Organizer.Move], Bool) in
            let all = try Organizer.candidates(in: folder)
            let ready = try OrganizeModel.items(in: folder, rules: rules, settle: settle)
            let plan = ready.compactMap { item in Organizer.destination(item, by: by, includeRest: includeRest).map { (item.url, $0) } }
            return (try Organizer.move(plan, into: folder), all.count > ready.count)
        }) ?? ([], false)
        if !moves.isEmpty {
            recent = Array((moves.reversed() + recent).prefix(30))
            OrganizeModel.shared.lastMoves = moves
            if OrganizeModel.shared.folder == folder { OrganizeModel.shared.scan() }
        }
        return waiting
    }
}

enum PhotosAlbums {
    /// Imports each file into the album named for it, creating albums that don't exist yet.
    static func add(_ plan: [(URL, String)]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ToolError("MyToolbox can't add to Photos. Allow it in System Settings → Privacy & Security → Photos.")
        }
        for (name, urls) in Dictionary(grouping: plan, by: \.1).mapValues({ $0.map(\.0) }) {
            let album = try await album(named: name)
            try await PHPhotoLibrary.shared().performChanges {
                let placeholders = urls.compactMap { PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: $0)?.placeholderForCreatedAsset }
                PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray)
            }
        }
    }

    private static func album(named name: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject { return existing }
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id, let made = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ToolError("Couldn't make the album \(name) in Photos.")
        }
        return made
    }
}

struct OrganizeDownloadsView: View {
    @Bindable private var model = OrganizeModel.shared
    @Bindable private var watcher = DownloadsWatcher.shared
    @AppStorage("organize.by") private var by: OrganizeBy = .kind
    @AppStorage("organize.mode") private var mode: OrganizeMode = .folders
    @AppStorage("organize.unknown") private var includeRest = false
    @AppStorage(DownloadsWatcher.enabledKey) private var auto = false
    @State private var editingRules = false
    @State private var loginItem = LoginItem.enabled

    private var planCount: Int { model.items.filter { Organizer.destination($0, by: by, includeRest: includeRest) != nil }.count }
    private var destinationSymbol: String { by == .site && mode == .photos ? "rectangle.stack" : "folder" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label(model.folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose Folder…") {
                    if let f = FilePicker.choose(types: [], multiple: false, folders: true, files: false).first {
                        model.folder = f
                        model.scan()
                        if auto { watcher.start(f) }
                    }
                }
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.help("Look again")
                Spacer()
                if !model.lastMoves.isEmpty {
                    Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .help("Put the files from the last organize back where they were")
                }
                if by == .site { Button("Edit Source Names…") { editingRules = true } }
            }
            HStack(spacing: 16) {
                Picker("Sort by", selection: $by) { ForEach(OrganizeBy.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
                if by == .site {
                    Picker("Put into", selection: $mode) { ForEach(OrganizeMode.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                }
                Toggle(by == .kind ? "Also move files that fit no group (into “Other”)" : "Include images with no source (as “Unknown”)", isOn: $includeRest)
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                Button("Organize \(planCount) File\(planCount == 1 ? "" : "s")") { model.organize(by: by, mode: mode, includeRest: includeRest) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.working || model.scanning || planCount == 0)
            }
            autoRow
            if let m = model.message { Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let e = model.error { ErrorText(message: e) }

            if model.scanning {
                ProgressView("Looking at the files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView("Nothing to Sort", systemImage: "tray",
                                       description: Text("\(model.folder.lastPathComponent) has no loose files. Folders, hidden files and downloads still in progress are left alone."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.items) {
                    TableColumn("File") { item in
                        HStack { Thumbnail(url: item.url, size: 28); Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                            .draggableFile(item.url)
                    }
                    TableColumn(by == .kind ? "Kind" : "Came from") { item in
                        if by == .kind {
                            Label(item.kind.rawValue, systemImage: item.kind.symbol)
                        } else {
                            Text(item.froms.first.flatMap(DownloadSources.host) ?? "No source stored").foregroundStyle(item.froms.isEmpty ? .secondary : .primary)
                                .help(item.froms.joined(separator: "\n"))
                        }
                    }
                    TableColumn("Goes to") { item in
                        if let d = Organizer.destination(item, by: by, includeRest: includeRest) {
                            Label(d, systemImage: destinationSymbol)
                        } else {
                            Text("Stays where it is").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
        .task { model.scan() }
        .onChange(of: auto) { auto ? watcher.start(model.folder) : watcher.stop() }
        .sheet(isPresented: $editingRules) { SourceRulesEditor(rules: $model.rules) { model.reclassify() } }
    }

    @ViewBuilder private var autoRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("Organize new files automatically", isOn: $auto)
                    .disabled(by == .site && mode == .photos)
                if auto, watcher.watching != nil {
                    Label("Watching \(model.folder.lastPathComponent)", systemImage: "eye").foregroundStyle(.green).font(.callout)
                }
                if auto && !loginItem {
                    Button("Open MyToolbox at Login") { try? LoginItem.set(true); loginItem = LoginItem.enabled }
                        .controlSize(.small)
                        .help("Automatic sorting runs while MyToolbox is open. It keeps running in the menu bar when you close its window.")
                }
            }
            Text(by == .site && mode == .photos
                 ? "Automatic sorting moves files into folders; turn off Photos albums to use it."
                 : "New files are sorted with the choices above a few seconds after they finish downloading, while MyToolbox is running (it stays in the menu bar).")
                .font(.caption).foregroundStyle(.secondary)
            if auto, let last = watcher.recent.first {
                Text("Last: \(last.to.lastPathComponent) → \(last.to.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: String {
        if by == .site && mode == .photos { return "Photos asks for permission the first time. Albums are created if they don't exist; the files stay where they are." }
        return "Folders are made inside \(model.folder.lastPathComponent). Nothing is uploaded; files are never overwritten, and Undo puts them back."
    }
}

private struct SourceRulesEditor: View {
    @Binding var rules: [SourceRule]
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source Names").font(.title3.weight(.semibold))
            Text("Images from a domain (or any of its subdomains) go to the source on the right.").foregroundStyle(.secondary)
            List {
                ForEach($rules) { $rule in
                    HStack {
                        TextField("Domain", text: $rule.domain).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Source", text: $rule.name).textFieldStyle(.roundedBorder)
                        Button { rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this rule")
                    }
                }
            }
            .frame(minHeight: 320)
            HStack {
                Button { rules.insert(SourceRule(domain: "", name: ""), at: 0) } label: { Label("Add Rule", systemImage: "plus") }
                Button("Restore Defaults") { rules = DownloadSources.defaults }
                Spacer()
                Button("Done") { onDone(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
