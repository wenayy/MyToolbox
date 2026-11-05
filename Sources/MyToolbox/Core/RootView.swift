import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable private var model = AppModel.shared
    @State private var query = ""
    @State private var searchFocused = false
    /// The sidebar holds focus at launch, so no stray focus ring appears and arrow keys move between tools.
    @FocusState private var sidebarFocused: Bool
    @AppStorage("collapsedCategories") private var collapsedStore = ""

    private var collapsed: Set<String> { Set(collapsedStore.split(separator: ",").map(String.init)) }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .searchable(text: $query, isPresented: $searchFocused, placement: .sidebar, prompt: "Search Tools")
        .onSubmit(of: .search) {
            if let first = ToolRegistry.search(query).first { model.selection = first.id }
        }
        .onDrop(of: FileDrop.types, isTargeted: nil) { providers in
            FileDrop.load(providers) { model.receive($0) }
            return true
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            if query.isEmpty {
                Label("All Tools", systemImage: "square.grid.2x2").tag(AppModel.home).hoverSelects(AppModel.home)
                Label("Saved Files", systemImage: "tray.full").tag(AppModel.saved).hoverSelects(AppModel.saved)
                let favorites = model.favorites.compactMap(ToolRegistry.tool)
                if !favorites.isEmpty {
                    Section("Favorites") { ForEach(favorites) { row($0) } }
                }
                ForEach(ToolCategory.allCases) { category in
                    let tools = ToolRegistry.tools(in: category)
                    if !tools.isEmpty {
                        Section(category.rawValue, isExpanded: expansion(category)) {
                            ForEach(tools) { row($0) }
                        }
                    }
                }
            } else {
                let results = ToolRegistry.search(query)
                if results.isEmpty {
                    Text("No tools match “\(query)”").foregroundStyle(.secondary)
                } else {
                    Section("\(results.count) Results") { ForEach(results) { row($0) } }
                }
            }
        }
        .listStyle(.sidebar)
        .focused($sidebarFocused)
        .onAppear { sidebarFocused = true }
    }

    private func row(_ tool: Tool) -> some View {
        Label {
            Text(tool.title)
        } icon: {
            Image(systemName: tool.symbol).foregroundStyle(tool.category.tint)
        }
        .tag(tool.id)
        .hoverSelects(tool.id)
        .contextMenu { FavoriteButton(id: tool.id) }
    }

    private func expansion(_ category: ToolCategory) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(category.id) },
            set: { open in
                var set = collapsed
                if open { set.remove(category.id) } else { set.insert(category.id) }
                collapsedStore = set.sorted().joined(separator: ",")
            })
    }

    // MARK: Detail

    private var detail: some View {
        ZStack {
            if let tool = model.currentTool {
                ToolPage(tool: tool)
                    .id(tool.id)
                    .transition(.opacity)
            } else if model.selection == AppModel.saved {
                SavedFilesView()
                    .navigationTitle("Saved Files")
                    .navigationSubtitle("Everything MyToolbox makes is saved here")
                    .transition(.opacity)
            } else {
                HomeView()
                    .navigationTitle("All Tools")
                    .navigationSubtitle("\(ToolRegistry.all.count) tools · ⌃⌥Space from any app")
                    .transition(.opacity)
            }
        }
        // Crossfade between tools instead of snapping.
        .animation(.easeInOut(duration: 0.18), value: model.selection)
    }
}

/// Hovering a sidebar row opens it once the pointer comes to rest there (about a third of a second),
/// so gliding past rows doesn't flick through tools. Clicking still works instantly.
private struct HoverSelect: ViewModifier {
    let id: String
    @AppStorage("hoverOpens") private var enabled = true
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())   // the whole row, not just the label text
            .onContinuousHover { phase in
                pending?.cancel()
                guard enabled, case .active = phase, AppModel.shared.selection != id else { return }
                // Every pointer move restarts the wait, so this only fires when the pointer rests.
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { AppModel.shared.selection = id }
                }
            }
    }
}

extension View {
    func hoverSelects(_ id: String) -> some View { modifier(HoverSelect(id: id)) }
}

struct FavoriteButton: View {
    let id: String
    var body: some View {
        let on = AppModel.shared.isFavorite(id)
        Button(on ? "Remove from Favorites" : "Add to Favorites", systemImage: on ? "star.slash" : "star") {
            AppModel.shared.toggleFavorite(id)
        }
    }
}

struct ToolPage: View {
    let tool: Tool
    private var model: AppModel { .shared }

    var body: some View {
        Group {
            if tool.fullBleed {
                tool.view()
            } else {
                tool.view().padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(tool.title)
        .navigationSubtitle(tool.summary)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let on = model.isFavorite(tool.id)
                Button { model.toggleFavorite(tool.id) } label: {
                    Label(on ? "Remove from Favorites" : "Add to Favorites", systemImage: on ? "star.fill" : "star")
                }
                .help(on ? "Remove this tool from Favorites" : "Add this tool to Favorites in the sidebar")
            }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    private var model: AppModel { .shared }
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MissingHelpersBanner()
                dropHint
                let pinned = (model.favorites + model.recents.filter { !model.favorites.contains($0) }).compactMap(ToolRegistry.tool)
                if !pinned.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Favorites & Recent").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                            ForEach(pinned.prefix(8)) { ToolTile(tool: $0, compact: true) }
                        }
                    }
                }
                ForEach(ToolCategory.allCases) { category in
                    let tools = ToolRegistry.tools(in: category)
                    if !tools.isEmpty { CategoryCard(category: category, tools: tools) }
                }
            }
            .padding(20)
        }
        .onDrop(of: FileDrop.types, isTargeted: $dropTargeted) { providers in
            FileDrop.load(providers) { model.receive($0) }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: Binding(get: { !model.unassignedFiles.isEmpty }, set: { if !$0 { model.unassignedFiles = [] } })) {
            OpenWithSheet(files: model.unassignedFiles)
        }
    }

    private var dropHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Drop files anywhere in this window").font(.headline)
                Text("You'll see every tool that can work with them.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Files…") {
                model.receive(FilePicker.choose(types: [.item], multiple: true, folders: true))
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CategoryCard: View {
    let category: ToolCategory
    let tools: [Tool]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: category.symbol).foregroundStyle(category.tint)
                Text(category.rawValue).font(.title3.weight(.semibold))
                Text("\(tools.count)").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                ForEach(tools) { ToolTile(tool: $0) }
            }
        }
    }
}

struct ToolTile: View {
    let tool: Tool
    var compact = false
    @State private var hovering = false

    var body: some View {
        Button { AppModel.shared.open(tool.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tool.category.tint)
                    .frame(width: 30, height: 30)
                    .background(tool.category.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if !compact {
                        Text(tool.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: compact ? 0 : 68, alignment: .topLeading)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background.secondary), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { FavoriteButton(id: tool.id) }
        .help(tool.summary)
        .accessibilityLabel("\(tool.title). \(tool.summary)")
    }
}

/// Shown after files are dropped on Home or the Dock icon.
struct OpenWithSheet: View {
    let files: [URL]
    @Environment(\.dismiss) private var dismiss
    private var model: AppModel { .shared }

    var body: some View {
        let tools = model.tools(accepting: files)
        VStack(alignment: .leading, spacing: 14) {
            Text("Open \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) Items") With…")
                .font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            if tools.isEmpty {
                ContentUnavailableView("No Tool for These Files", systemImage: "questionmark.folder",
                                       description: Text("None of the tools work with this kind of file yet."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                        ForEach(tools) { tool in
                            Button {
                                model.unassignedFiles = []
                                model.open(tool.id, files: files)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: tool.symbol).foregroundStyle(tool.category.tint).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(tool.title).font(.body.weight(.medium))
                                        Text(tool.category.rawValue).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.unassignedFiles = []; dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

enum FileDrop {
    /// Everything that can be dropped: Finder files, MyNotch shelf items, images dragged out of browsers
    /// or screenshot thumbnails (file promises / raw data), and web links.
    static let types: [UTType] = [.fileURL, .url, .image, .pdf, .movie, .audio, .data, .plainText]

    /// Where dropped data without a file (a browser image, a screenshot thumbnail) is saved first.
    static var inbox: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MyToolbox/Dropped")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolves dropped items to file URLs (or web URLs for links), then calls back once on the main actor.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        func add(_ url: URL?) { if let url { lock.lock(); urls.append(url); lock.unlock() } }
        for provider in providers {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in add(url); group.leave() }
            } else if let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0).map { $0.conforms(to: .image) || $0.conforms(to: .pdf) || $0.conforms(to: .audiovisualContent) } ?? false
            }) {
                provider.loadFileRepresentation(forTypeIdentifier: type) { temp, _ in
                    if let temp {
                        let ext = UTType(type)?.preferredFilenameExtension ?? temp.pathExtension
                        let name = (provider.suggestedName ?? temp.deletingPathExtension().lastPathComponent)
                        let dest = Output.unique(inbox.appendingPathComponent(name).appendingPathExtension(ext))
                        if (try? FileManager.default.copyItem(at: temp, to: dest)) != nil { add(dest) }
                    }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in add(url); group.leave() }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true { add(url) }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
    }
}

extension View {
    /// Lets a row be dragged out as a real file — into Finder, MyNotch's shelf, Mail, anywhere.
    func draggableFile(_ url: URL?) -> some View {
        onDrag {
            guard let url else { return NSItemProvider() }
            let p = NSItemProvider(object: url as NSURL)
            p.suggestedName = url.lastPathComponent
            return p
        }
    }
}
