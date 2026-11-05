import AppKit
import Observation
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What one file produced.
struct BatchOutput {
    var files: [URL] = []
    var note: String?
}

/// The files of one batch tool and their progress. Owned by AppModel, so a run keeps going
/// (and its results stay visible) while the person looks at other tools.
@MainActor @Observable
final class BatchRun {
    enum Status: Equatable {
        case ready
        case working(Double?)
        case done(String?)
        case skipped(String)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status: Status = .ready
        var outputs: [URL] = []
    }

    var items: [Item] = []
    var selection: Item.ID?
    private(set) var running = false
    private(set) var paused = false
    @ObservationIgnored private let tag = UUID().uuidString
    private(set) var outputFolder: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    var selectedItem: Item? { items.first { $0.id == selection } ?? items.first }
    var outputs: [URL] { items.flatMap(\.outputs) }
    var finished: Bool { !running && items.contains { if case .ready = $0.status { false } else { true } } }

    var completedCount: Int {
        items.filter { item in
            switch item.status { case .ready, .working: false; default: true }
        }.count
    }

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0.0) { sum, item in
            switch item.status {
            case .ready: sum
            case .working(let p): sum + (p ?? 0)
            default: sum + 1
            }
        }
        return total / Double(items.count)
    }

    var summary: String {
        let done = items.filter { if case .done = $0.status { true } else { false } }.count
        let failed = items.filter { if case .failed = $0.status { true } else { false } }.count
        let skipped = items.filter { if case .skipped = $0.status { true } else { false } }.count
        var parts = ["\(done) done"]
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    /// Adds files, expanding folders to the matching files inside them.
    func add(_ urls: [URL], types: [UTType]) {
        let known = Set(items.map(\.url))
        var new: [URL] = []
        for url in urls {
            if url.isDirectory {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = e?.nextObject() as? URL {
                    if Self.matches(file, types) { new.append(file) }
                }
            } else if Self.matches(url, types) {
                new.append(url)
            }
        }
        let fresh = new.filter { !known.contains($0) }
        items.append(contentsOf: fresh.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Item(url: $0) })
        if selection == nil { selection = items.first?.id }
        if !running { resetStatuses() }
    }

    static func matches(_ url: URL, _ types: [UTType]) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    func remove(_ ids: Set<Item.ID>) {
        guard !running else { return }
        items.removeAll { ids.contains($0.id) }
    }

    func clear() {
        guard !running else { return }
        items = []
        outputFolder = nil
        selection = nil
    }

    private func resetStatuses() {
        for i in items.indices { items[i].status = .ready; items[i].outputs = [] }
        outputFolder = nil
    }

    func start(folderName: String, concurrency: Int,
               process: @escaping BatchProcess) {
        guard !running, !items.isEmpty else { return }
        resetStatuses()
        let folder = Output.root
        outputFolder = folder
        running = true
        let ids = items.map(\.id)
        let tag = tag
        task = Task { [weak self] in
            await Shell.$tag.withValue(tag) {
                await withTaskGroup(of: Void.self) { group in
                    var next = 0
                    func launch() {
                        guard next < ids.count else { return }
                        let id = ids[next]
                        next += 1
                        group.addTask { @MainActor in
                            // While paused, files that haven't started wait here.
                            while self?.paused == true && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
                            await self?.runOne(id, folder: folder, process: process)
                        }
                    }
                    for _ in 0..<max(1, concurrency) { launch() }
                    while await group.next() != nil { launch() }
                }
            }
            self?.finish()
        }
    }

    /// Pauses running helpers (ffmpeg…) in place and holds back files that haven't started.
    func setPaused(_ pause: Bool) {
        guard running, pause != paused else { return }
        paused = pause
        Shell.setPaused(pause, tag: tag)
    }

    private func runOne(_ id: Item.ID, folder: URL,
                        process: @MainActor (URL, URL, @escaping @MainActor (Double) -> Void) async throws -> BatchOutput) async {
        guard let url = items.first(where: { $0.id == id })?.url else { return }
        if Task.isCancelled { return }
        update(id) { $0.status = .working(nil) }
        do {
            let out = try await process(url, folder) { [weak self] p in
                self?.update(id) { $0.status = .working(min(1, max(0, p))) }
            }
            update(id) {
                $0.outputs = out.files
                $0.status = out.files.isEmpty ? .skipped(out.note ?? "Nothing to change") : .done(out.note)
            }
        } catch is CancellationError {
            update(id) { $0.status = .ready }
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    private func update(_ id: Item.ID, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    private func finish() {
        paused = false
        running = false
        task = nil
    }

    func cancel() {
        if paused { setPaused(false) }
        task?.cancel()
    }
}

typealias BatchProcess = @MainActor (URL, URL, @escaping @MainActor (Double) -> Void) async throws -> BatchOutput

/// Each file tool's Run action by tool id, recorded when its view is built with the current options.
/// The end-to-end tests (Tests/e2e) drive exactly these closures.
@MainActor enum ToolActions {
    static var process: [String: BatchProcess] = [:]
    static var combine: [String: @MainActor ([URL]) async throws -> URL] = [:]
}

/// Shared layout for every "drop files, pick options, run" tool:
/// files on the left, options and the action on the right, like an inspector.
struct BatchToolView<Options: View, Preview: View>: View {
    let toolID: String
    let folderName: String
    let types: [UTType]
    /// "Video", "Photo"… used in prompts and the button title.
    let noun: String
    let verb: String
    var concurrency = 2
    @ViewBuilder let options: () -> Options
    @ViewBuilder let preview: (URL) -> Preview
    let process: BatchProcess

    @Bindable private var run: BatchRun
    @State private var targeted = false

    init(toolID: String, folderName: String, types: [UTType], noun: String, verb: String, concurrency: Int = 2,
         @ViewBuilder options: @escaping () -> Options,
         @ViewBuilder preview: @escaping (URL) -> Preview,
         process: @escaping @MainActor (URL, URL, @escaping @MainActor (Double) -> Void) async throws -> BatchOutput) {
        self.toolID = toolID
        self.folderName = folderName
        self.types = types
        self.noun = noun
        self.verb = verb
        self.concurrency = concurrency
        self.options = options
        self.preview = preview
        self.process = process
        self.run = AppModel.shared.batch(toolID)
        ToolActions.process[toolID] = process
    }

    private func plural(_ n: Int) -> String { n == 1 ? noun : noun + "s" }

    var body: some View {
        HStack(spacing: 0) {
            filesColumn
                .frame(minWidth: 320, maxWidth: .infinity)
            Divider()
            inspector
                .frame(width: 320)
                .clipped()
        }
        .receivesFiles(for: toolID) { run.add($0, types: types) }
    }

    // MARK: Files

    @ViewBuilder private var filesColumn: some View {
        VStack(spacing: 0) {
            if run.items.isEmpty {
                emptyState
            } else {
                List(selection: $run.selection) {
                    ForEach(run.items) { item in
                        BatchRow(item: item, remove: run.running ? nil : { run.remove([item.id]) }).tag(item.id)
                            .contextMenu {
                                if let out = item.outputs.first {
                                    Button("Show Result in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.outputs) }
                                    Button("Open Result") { NSWorkspace.shared.open(out) }
                                    Divider()
                                }
                                Button("Show Original in Finder") { item.url.reveal() }
                                Button("Remove from List") { run.remove([item.id]) }.disabled(run.running)
                            }
                    }
                }
                .onDeleteCommand { if let id = run.selection { run.remove([id]) } }
                Divider()
                HStack {
                    Button { choose() } label: { Label("Add \(noun)s…", systemImage: "plus") }
                        .disabled(run.running)
                    Spacer()
                    Text("\(run.items.count) \(plural(run.items.count))").foregroundStyle(.secondary)
                    Button("Clear") { run.clear() }.disabled(run.running)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .onDrop(of: FileDrop.types, isTargeted: $targeted) { providers in
            FileDrop.load(providers) { run.add($0, types: types) }
            return !run.running
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06)).padding(6).allowsHitTesting(false)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("Drop \(noun)s or a Folder").font(.title3.weight(.semibold))
            Text(typeHint).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose \(noun)s…") { choose() }.controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var typeHint: String {
        if types.contains(where: { $0.conforms(to: .movie) || $0 == .video }) { return "MP4, MOV, MKV, AVI and more. Folders work too." }
        if types.contains(.image) { return "JPEG, PNG, HEIC, WebP, TIFF and more. Folders work too." }
        return "Folders work too."
    }

    private func choose() {
        run.add(FilePicker.choose(types: types, multiple: true, folders: true), types: types)
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let item = run.selectedItem {
                        if let result = item.outputs.first {
                            ResultPreviewCard(original: item.url, result: result, note: { if case .done(let n) = item.status { n } else { nil } }())
                                .padding([.horizontal, .top], 16)
                        } else {
                            preview(item.url)
                                .padding([.horizontal, .top], 16)
                        }
                    }
                    Form { options() }
                        .formStyle(.grouped)
                        .frame(width: 320)
                        .scrollDisabled(true)
                        .disabled(run.running)
                }
            }
            Divider()
            actionArea.padding(16)
        }
        .background(.background)
    }

    @ViewBuilder private var actionArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if run.running {
                ProgressView(value: run.progress)
                HStack {
                    Text(run.paused ? "Paused · \(run.completedCount) of \(run.items.count) done" : "\(run.completedCount) of \(run.items.count) done…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(run.paused ? "Resume" : "Pause") { run.setPaused(!run.paused) }
                        .keyboardShortcut("p")
                    Button("Cancel") { run.cancel() }.keyboardShortcut(.cancelAction)
                }
            } else {
                if run.finished {
                    HStack {
                        Label(run.summary, systemImage: run.outputs.isEmpty ? "info.circle" : "checkmark.circle.fill")
                            .foregroundStyle(run.outputs.isEmpty ? Color.secondary : Color.green)
                        Spacer()
                        if let folder = run.outputFolder {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(run.outputs.isEmpty ? [folder] : run.outputs) }
                        }
                    }
                }
                Button {
                    run.start(folderName: folderName, concurrency: concurrency, process: process)
                } label: {
                    // "Remove Background from" reads oddly on its own, so drop the dangling word when empty.
                    Text(run.items.isEmpty ? verb.replacingOccurrences(of: #" (from|in)$"#, with: "", options: .regularExpression)
                                           : "\(verb) \(run.items.count) \(plural(run.items.count))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(run.items.isEmpty)
                SavesToLine()
            }
        }
    }
}

extension BatchToolView where Preview == EmptyView {
    init(toolID: String, folderName: String, types: [UTType], noun: String, verb: String, concurrency: Int = 2,
         @ViewBuilder options: @escaping () -> Options,
         process: @escaping @MainActor (URL, URL, @escaping @MainActor (Double) -> Void) async throws -> BatchOutput) {
        self.init(toolID: toolID, folderName: folderName, types: types, noun: noun, verb: verb, concurrency: concurrency,
                  options: options, preview: { _ in EmptyView() }, process: process)
    }
}

/// Quick Look of any file: plays videos, shows images, PDFs and documents.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .compact)!
        v.autostarts = false
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
}

/// The finished file, shown right in the tool: preview, before → after, and ways to use it.
struct ResultPreviewCard: View {
    let original: URL
    let result: URL
    let note: String?
    @State private var showFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if result.isDirectory {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: result.path)).resizable().aspectRatio(contentMode: .fit).padding(30)
                } else {
                    QuickLookPreview(url: result)
                }
            }
            .frame(height: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Label("Result", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.semibold))
                Spacer()
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Text(result.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                .draggableFile(result)
                .help("Drag the file anywhere")
            HStack {
                Button("Open") { NSWorkspace.shared.open(result) }
                Button("Show in Finder") { result.reveal() }
                Spacer()
                if !result.isDirectory { Button { showFull = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Bigger preview") }
            }
            .controlSize(.small)
        }
        .sheet(isPresented: $showFull) { PreviewSheet(url: result) }
    }
}

struct PreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            QuickLookPreview(url: url).frame(minWidth: 820, minHeight: 520)
        }
    }
}

/// "Saves to ~/Downloads/MyToolbox" — click to open the folder.
struct SavesToLine: View {
    var body: some View {
        Button { NSWorkspace.shared.open(Output.root) } label: {
            Label("Saves to \(Output.rootDisplay)", systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Open the output folder. Change it in Settings (⌘,).")
    }
}

struct BatchRow: View {
    let item: BatchRun.Item
    var remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: item.url, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(detailColor).lineLimit(2)
            }
            Spacer(minLength: 8)
            if hovering, let remove, item.status == .ready {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Remove from the list (Delete)")
            } else {
                statusIcon
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .draggableFile(item.outputs.first ?? item.url)
    }

    private var detail: String {
        switch item.status {
        case .ready, .working: item.url.fileSize.byteString
        case .done(let note): note ?? "Done"
        case .skipped(let why): why
        case .failed(let why): why
        }
    }

    private var detailColor: Color {
        if case .failed = item.status { return .red }
        return .secondary
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .ready: EmptyView()
        case .working(let p):
            if let p { ProgressView(value: p).progressViewStyle(.circular).controlSize(.small) }
            else { ProgressView().controlSize(.small) }
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Skipped")
        case .failed(let why): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(why).accessibilityLabel("Failed")
        }
    }
}

/// Finder-style thumbnail, cached.
struct Thumbnail: View {
    let url: URL
    var size: CGFloat = 36
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await ThumbnailCache.shared.image(for: url, size: size) }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL, size: CGFloat) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache.setObject(rep.nsImage, forKey: url as NSURL)
        return rep.nsImage
    }
}
