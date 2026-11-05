import AppKit
import Observation
import SwiftUI

/// App-wide navigation and hand-off state. Lives for the whole app, so running jobs
/// and dropped files survive switching tools.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    static let home = "home"
    static let saved = "saved"

    var selection: String? = UserDefaults.standard.string(forKey: "tool") ?? UserDefaults.standard.string(forKey: "lastTool") ?? AppModel.home {
        didSet {
            guard let id = selection, id != oldValue else { return }
            UserDefaults.standard.set(id, forKey: "lastTool")
            if id != Self.home && id != Self.saved { recents = Array(([id] + recents.filter { $0 != id }).prefix(6)) }
            if !navigatingHistory, let old = oldValue {
                back.append(old)
                if back.count > 50 { back.removeFirst() }
                forward = []
            }
        }
    }

    // Back / forward between tools (⌘[ and ⌘]).
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    @ObservationIgnored private var navigatingHistory = false

    func goBack() {
        guard let previous = back.popLast(), let current = selection else { return }
        forward.append(current)
        navigatingHistory = true
        selection = previous
        navigatingHistory = false
    }

    func goForward() {
        guard let next = forward.popLast(), let current = selection else { return }
        back.append(current)
        navigatingHistory = true
        selection = next
        navigatingHistory = false
    }

    var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favorites") ?? [] {
        didSet { UserDefaults.standard.set(favorites, forKey: "favorites") }
    }

    var recents: [String] = UserDefaults.standard.stringArray(forKey: "recents") ?? [] {
        didSet { UserDefaults.standard.set(recents, forKey: "recents") }
    }

    /// Files dropped on Home or the Dock icon, waiting for the person to pick a tool.
    var unassignedFiles: [URL] = []

    /// Files handed to a specific tool; the tool drains its inbox when it appears.
    private(set) var inbox: [String: [URL]] = [:]

    @ObservationIgnored private var batches: [String: BatchRun] = [:]
    @ObservationIgnored var openMainWindow: (() -> Void)?

    var currentTool: Tool? { selection.flatMap(ToolRegistry.tool) }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
    }

    func open(_ id: String, files: [URL] = []) {
        if !files.isEmpty { inbox[id, default: []].append(contentsOf: files) }
        selection = id
        showMainWindow()
    }

    func takeInbox(_ id: String) -> [URL] {
        guard let files = inbox[id], !files.isEmpty else { return [] }
        inbox[id] = nil
        return files
    }

    /// Files from Finder, the Dock icon or Home: straight to the current tool if it takes them,
    /// otherwise ask which tool to use.
    func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Web links: video sites go to Download Video, anything else to Web Page to PDF.
        let links = urls.filter { !$0.isFileURL }
        if !links.isEmpty {
            let videos = links.filter { YTDLP.isLikelyVideoLink($0.absoluteString) }
            if !videos.isEmpty { open("download", files: videos) }
            let pages = links.filter { !YTDLP.isLikelyVideoLink($0.absoluteString) }
            if !pages.isEmpty { open("webpdf", files: pages) }
        }
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        if let tool = currentTool, urls.allSatisfy(tool.accepts) {
            open(tool.id, files: urls)
        } else {
            unassignedFiles = urls
            selection = Self.home
            showMainWindow()
        }
    }

    func tools(accepting urls: [URL]) -> [Tool] {
        ToolRegistry.all.filter { tool in !tool.accepts.isEmpty && urls.allSatisfy(tool.accepts) }
    }

    func batch(_ id: String) -> BatchRun {
        if let run = batches[id] { return run }
        let run = BatchRun()
        batches[id] = run
        return run
    }

    func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

extension View {
    /// Delivers files handed to `toolID` (from Home, the Dock icon or Quick Open) when the tool appears
    /// and whenever more arrive while it is open.
    func receivesFiles(for toolID: String, perform: @escaping ([URL]) -> Void) -> some View {
        modifier(InboxReceiver(toolID: toolID, perform: perform))
    }
}

private struct InboxReceiver: ViewModifier {
    let toolID: String
    let perform: ([URL]) -> Void
    private var model: AppModel { .shared }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: drain)
            .onChange(of: model.inbox[toolID]?.count ?? 0) { drain() }
    }

    private func drain() {
        let files = model.takeInbox(toolID)
        if !files.isEmpty { perform(files) }
    }
}
