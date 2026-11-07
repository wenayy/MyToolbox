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

@MainActor @Observable
final class OrganizeModel {
    static let shared = OrganizeModel()

    struct Item: Identifiable {
        var id: URL { url }
        let url: URL
        let froms: [String]
        var source: String?
    }

    var folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var items: [Item] = []
    var rules = DownloadSources.load()
    var scanning = false
    var working = false
    var message: String?
    var error: String?

    func scan() {
        scanning = true; message = nil; error = nil
        let folder = folder, rules = rules
        Task {
            let found = (try? await offMain { try Self.images(in: folder, rules: rules) }) ?? []
            items = found
            scanning = false
            if found.isEmpty { message = "No images in \(folder.lastPathComponent)." }
        }
    }

    func reclassify() {
        DownloadSources.save(rules)
        for i in items.indices { items[i].source = DownloadSources.source(items[i].froms, rules: rules) }
    }

    func destination(_ item: Item, includeUnknown: Bool) -> String? {
        item.source ?? (includeUnknown ? "Unknown" : nil)
    }

    func organize(mode: OrganizeMode, includeUnknown: Bool) {
        let plan = items.compactMap { item in destination(item, includeUnknown: includeUnknown).map { (item.url, $0) } }
        guard !plan.isEmpty else { message = "Nothing to organize."; return }
        working = true; error = nil; message = nil
        Task {
            do {
                switch mode {
                case .folders:
                    let folder = folder
                    try await offMain { try Self.move(plan, into: folder) }
                    message = "Moved \(plan.count) image\(plan.count == 1 ? "" : "s") into \(Set(plan.map(\.1)).count) folder\(Set(plan.map(\.1)).count == 1 ? "" : "s") in \(folder.lastPathComponent)."
                    scan()
                case .photos:
                    try await PhotosAlbums.add(plan)
                    message = "Added \(plan.count) image\(plan.count == 1 ? "" : "s") to Photos. The files stay where they are."
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    /// The images directly inside `folder`, with where each came from.
    nonisolated static func images(in folder: URL, rules: [SourceRule]) throws -> [Item] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let froms = DownloadSources.whereFroms(url)
                return Item(url: url, froms: froms, source: DownloadSources.source(froms, rules: rules))
            }
    }

    /// Moves each file into a folder named for its source, inside `folder`, never overwriting.
    nonisolated static func move(_ plan: [(URL, String)], into folder: URL) throws {
        for (url, name) in plan {
            let dir = folder.appendingPathComponent(safeName(name), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: Output.unique(dir.appendingPathComponent(url.lastPathComponent)))
        }
    }

    nonisolated static func safeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Unknown" : cleaned
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
    @AppStorage("organize.mode") private var mode: OrganizeMode = .folders
    @AppStorage("organize.unknown") private var includeUnknown = false
    @State private var editingRules = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label(model.folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose Folder…") {
                    if let f = FilePicker.choose(types: [], multiple: false, folders: true, files: false).first { model.folder = f; model.scan() }
                }
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.help("Look again")
                Spacer()
                Button("Edit Source Names…") { editingRules = true }
            }
            HStack(spacing: 16) {
                Picker("Organize", selection: $mode) { ForEach(OrganizeMode.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                Toggle("Include images with no source (as “Unknown”)", isOn: $includeUnknown)
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                Button("Organize \(planCount) Image\(planCount == 1 ? "" : "s")") { model.organize(mode: mode, includeUnknown: includeUnknown) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.working || model.scanning || planCount == 0)
            }
            if let m = model.message { Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let e = model.error { ErrorText(message: e) }

            if model.scanning {
                ProgressView("Reading where each image came from…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView("No Images", systemImage: "photo.on.rectangle",
                                       description: Text("Images you download keep the address they came from. Choose a folder with downloaded images."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.items) {
                    TableColumn("Image") { item in
                        HStack { Thumbnail(url: item.url, size: 28); Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                            .draggableFile(item.url)
                    }
                    TableColumn("Came from") { item in
                        Text(item.froms.first.flatMap(DownloadSources.host) ?? "No source stored").foregroundStyle(item.froms.isEmpty ? .secondary : .primary)
                            .help(item.froms.joined(separator: "\n"))
                    }
                    TableColumn("Goes to") { item in
                        if let d = model.destination(item, includeUnknown: includeUnknown) {
                            Label(d, systemImage: mode == .folders ? "folder" : "rectangle.stack").foregroundStyle(item.source == nil ? .secondary : .primary)
                        } else {
                            Text("Stays where it is").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(mode == .folders ? "Folders are made inside \(model.folder.lastPathComponent). Nothing is uploaded — the addresses are read from the files on this Mac."
                                  : "Photos asks for permission the first time. Albums are created if they don't exist; the files stay where they are.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { if model.items.isEmpty { model.scan() } }
        .sheet(isPresented: $editingRules) { SourceRulesEditor(rules: $model.rules) { model.reclassify() } }
    }

    private var planCount: Int { model.items.filter { model.destination($0, includeUnknown: includeUnknown) != nil }.count }
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
