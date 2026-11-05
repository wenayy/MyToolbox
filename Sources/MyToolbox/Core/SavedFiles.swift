import AppKit
import Observation
import SwiftUI

/// Watches the output folder so the Saved Files page updates as tools save results.
@MainActor @Observable
final class SavedFilesModel {
    static let shared = SavedFilesModel()

    struct File: Identifiable, Hashable {
        let url: URL
        let size: Int64
        let date: Date
        var id: URL { url }
    }

    var files: [File] = []
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedPath = ""

    func reload() {
        let root = Output.root
        watch(root)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .totalFileAllocatedSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        files = urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return File(url: url, size: Int64(v?.fileSize ?? v?.totalFileAllocatedSize ?? 0), date: v?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    private func watch(_ folder: URL) {
        guard folder.path != watchedPath else { return }
        source?.cancel()
        watchedPath = folder.path
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { @Sendable in Task { @MainActor in SavedFilesModel.shared.reload() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    func trash(_ urls: Set<URL>) {
        for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        reload()
    }
}

struct SavedFilesView: View {
    @Bindable private var model = SavedFilesModel.shared
    @State private var selection = Set<URL>()
    @State private var query = ""

    private var shown: [SavedFilesModel.File] {
        query.isEmpty ? model.files : model.files.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(Output.rootDisplay).lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Show in Finder") { NSWorkspace.shared.open(Output.root) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if model.files.isEmpty {
                ContentUnavailableView("Nothing Saved Yet", systemImage: "tray",
                                       description: Text("Results from every tool land here. Drag them straight into Finder, Mail or any app."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(shown) { file in
                        HStack(spacing: 10) {
                            Thumbnail(url: file.url, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text("\(file.date.formatted(.relative(presentation: .named))) · \(file.url.isDirectory ? "Folder" : file.size.byteString)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(file.url)
                        .draggableFile(file.url)
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(file.url) }
                            Button("Show in Finder") { file.url.reveal() }
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([file.url as NSURL]) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { model.trash(selection.contains(file.url) ? selection : [file.url]) }
                        }
                    }
                }
                .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in urls.forEach { NSWorkspace.shared.open($0) } }
                .onDeleteCommand { model.trash(selection); selection = [] }
                Divider()
                HStack {
                    Text("\(model.files.count) item\(model.files.count == 1 ? "" : "s") · drag any of them out, double-click to open")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
        .onAppear { model.reload() }
    }
}
