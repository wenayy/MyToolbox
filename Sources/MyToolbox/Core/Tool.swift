import SwiftUI
import UniformTypeIdentifiers

enum ToolCategory: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    case images = "Images"
    case docs = "Docs"
    case text = "Text & Speech"
    case files = "Files"
    case mac = "Mac"
    case developer = "Developer"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .images: "photo"
        case .docs: "doc.text"
        case .text: "sparkles"
        case .files: "folder"
        case .mac: "desktopcomputer"
        case .developer: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// One tint per category, used only on tool icons so 60+ tools stay scannable.
    var tint: Color {
        switch self {
        case .video: .pink
        case .audio: .red
        case .images: .orange
        case .docs: .blue
        case .text: .purple
        case .files: .teal
        case .mac: .gray
        case .developer: .green
        }
    }
}

struct Tool: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let category: ToolCategory
    let summary: String
    /// File types the tool takes; drives the "drop anything" chooser. Empty = text-only tool.
    let accepts: [UTType]
    /// Tools with their own split layout fill the whole detail column.
    var fullBleed = false
    let view: () -> AnyView

    init<V: View>(_ id: String, _ title: String, _ symbol: String, _ category: ToolCategory, _ summary: String,
                  accepts: [UTType] = [], fullBleed: Bool = false, @ViewBuilder view: @escaping () -> V) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.category = category
        self.summary = summary
        self.accepts = accepts
        self.fullBleed = fullBleed
        self.view = { AnyView(view()) }
    }

    /// Higher is better; nil = no match. Title prefix > word prefix > initials > contains > summary.
    func score(_ query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return 0 }
        let t = title.lowercased()
        if t.hasPrefix(q) { return 100 }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if String(words.compactMap(\.first)).hasPrefix(q) { return 70 }
        if t.contains(q) { return 60 }
        if category.rawValue.lowercased().hasPrefix(q) { return 40 }
        if summary.lowercased().contains(q) { return 20 }
        return nil
    }

    func accepts(_ url: URL) -> Bool {
        if url.isDirectory { return !accepts.isEmpty && accepts.contains { $0 != .text && $0 != .plainText } }
        guard let type = UTType.forExtension(url.pathExtension) else { return false }
        return accepts.contains { type.conforms(to: $0) }
    }
}

/// Every tool in the app. Each category file contributes its own list.
enum ToolRegistry {
    static let all: [Tool] = videoTools + conversionTools + videoEditTools + audioTools + imageTools + editorTools + docTools + cropPDFTools
        + textTools + fileTools + organizeTools + macTools + developerTools

    static func tools(in category: ToolCategory) -> [Tool] { all.filter { $0.category == category } }
    static func tool(_ id: String) -> Tool? { all.first { $0.id == id } }

    static func search(_ query: String) -> [Tool] {
        all.compactMap { tool in tool.score(query).map { (tool, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

extension UTType {
    /// Containers macOS has no type for unless a player that declares them is installed.
    static let unknownVideoExtensions = ["mkv", "mk3d", "flv", "f4v", "ts", "m2ts", "mts", "vob", "ogv", "rm", "rmvb", "divx", "wmv", "asf", "3gp"]
    static let unknownAudioExtensions = ["opus", "oga", "mka", "ape", "wv", "weba", "tta", "dsf"]

    /// The type of a file extension, counting MKV, Opus and the like as video or audio even when macOS doesn't know them.
    static func forExtension(_ ext: String) -> UTType? {
        let e = ext.lowercased()
        let type = UTType(filenameExtension: e)
        if let type, !type.isDynamic { return type }
        if unknownVideoExtensions.contains(e) { return .movie }
        if unknownAudioExtensions.contains(e) { return .audio }
        return type
    }

    /// `types` plus whatever macOS calls those unknown containers, so open panels let them be chosen.
    static func withUnknownMedia(_ types: [UTType]) -> [UTType] {
        let video = types.contains { UTType.movie.conforms(to: $0) }, audio = types.contains { UTType.audio.conforms(to: $0) }
        let extra = (video ? unknownVideoExtensions : []) + (audio ? unknownAudioExtensions : [])
        return types + extra.compactMap { UTType(filenameExtension: $0) }.filter { $0.isDynamic }
    }
}
