import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension ToolRegistry {
    static let fileTools: [Tool] = [
        Tool("qr", "QR Code", "qrcode", .files, "Make QR codes for links, text and Wi-Fi, or read codes and barcodes from images",
             accepts: [.image]) { QRCodeView() },
        Tool("rename", "Batch Rename", "character.cursor.ibeam", .files,
             "Rename many files at once with find and replace, numbering, dates or case changes", accepts: [.item]) { BatchRenameView() },
        Tool("duplicates", "Find Duplicates", "plus.square.on.square", .files,
             "Find identical files across folders and move the extras to the Trash", accepts: [.folder, .item]) { DuplicatesView() },
        Tool("zip", "Zip & Unzip", "archivebox", .files, "Open ZIP, RAR, 7z and TAR files, or make a ZIP, with a password if you like",
             accepts: [.item]) { ZipView() },
    ]
}

// MARK: - QR Code

enum QR {
    static func make(_ text: String, correction: String = "M", size: CGFloat = 1024) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Reads every barcode (QR, Aztec, EAN, Code128…) in an image.
    static func read(_ url: URL) -> [String] {
        let request = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(url: url).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    static func wifiPayload(ssid: String, password: String, security: String, hidden: Bool) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "WIFI:T:\(security);S:\(esc(ssid));P:\(security == "nopass" ? "" : esc(password));\(hidden ? "H:true;" : "");"
    }
}

struct QRCodeView: View {
    enum Mode: String, CaseIterable { case text = "Text / Link", wifi = "Wi-Fi", read = "Read QR" }
    @State private var mode: Mode = .text
    @State private var text = ""
    @State private var ssid = ""
    @State private var password = ""
    @State private var security = "WPA"
    @State private var hidden = false
    @State private var correction = "M"
    @State private var saved: [URL] = []
    @State private var readFiles: [URL] = []
    @State private var decoded: [String] = []

    private var payload: String {
        mode == .wifi ? (ssid.isEmpty ? "" : QR.wifiPayload(ssid: ssid, password: password, security: security, hidden: hidden)) : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).frame(width: 360)

            if mode == .read {
                DropZone(prompt: "Drop an image with a QR code or barcode", types: [.image], multiple: false, urls: $readFiles)
                    .onChange(of: readFiles) { decoded = readFiles.first.map(QR.read) ?? [] }
                if !readFiles.isEmpty && decoded.isEmpty { ErrorText(message: "No code found in that image") }
                ForEach(decoded, id: \.self) { value in
                    HStack(alignment: .top) {
                        Text(value).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        Spacer()
                        CopyButton(text: value)
                        if let url = URL(string: value), url.scheme?.hasPrefix("http") == true {
                            Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.small)
                        }
                    }
                }
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        if mode == .text {
                            EditorBox(title: "Content", text: $text, monospaced: false, placeholder: "https://… or any text").frame(height: 160)
                        } else {
                            Form {
                                TextField("Network name", text: $ssid)
                                SecureField("Password", text: $password)
                                Picker("Security", selection: $security) {
                                    Text("WPA/WPA2/WPA3").tag("WPA")
                                    Text("WEP").tag("WEP")
                                    Text("None").tag("nopass")
                                }
                                Toggle("Hidden network", isOn: $hidden)
                            }
                            .formStyle(.grouped).frame(maxWidth: 420)
                        }
                        Picker("Error correction", selection: $correction) {
                            Text("Low").tag("L"); Text("Medium").tag("M"); Text("Quartile").tag("Q"); Text("High").tag("H")
                        }
                        .frame(width: 280)
                        ResultList(urls: saved)
                    }
                    if !payload.isEmpty, let image = QR.make(payload, correction: correction) {
                        VStack(spacing: 10) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 260, height: 260)
                                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                            HStack {
                                Button("Copy Image") { Pasteboard.copy(image) }
                                Button("Save PNG") {
                                    let url = Output.file(name: mode == .wifi ? "WiFi \(ssid)" : "QR", ext: "png")
                                    try? QR.pngData(image)?.write(to: url)
                                    saved = [url]
                                }
                            }
                        }
                    }
                }
                Spacer()
            }
        }
        .receivesFiles(for: "qr") { urls in mode = .read; readFiles = Array(urls.prefix(1)) }
    }
}

// MARK: - Batch Rename

struct BatchRenameView: View {
    enum CaseChange: String, CaseIterable { case none = "Keep", lower = "lowercase", upper = "UPPERCASE", title = "Title Case" }
    enum DateMode: String, CaseIterable { case none = "No date", created = "Date created", modified = "Date modified", today = "Today's date" }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dateString(_ url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let date: Date? = switch dateMode {
        case .none: nil
        case .created: values?.creationDate
        case .modified: values?.contentModificationDate
        case .today: Date()
        }
        return date.map(Self.dateFormat.string)
    }
    @State private var files: [URL] = []
    @State private var find = ""
    @State private var replace = ""
    @State private var useRegex = false
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var numbering = false
    @State private var startAt = 1
    @State private var padding = 2
    @State private var baseName = ""
    @State private var caseChange: CaseChange = .none
    @State private var newExtension = ""
    @State private var dateMode: DateMode = .none
    @State private var lastRun: [(from: URL, to: URL)] = []
    @State private var message: String?

    private func newName(_ url: URL, index: Int) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        var ext = url.pathExtension
        if !baseName.isEmpty { name = baseName }
        if !find.isEmpty {
            if useRegex, let re = try? NSRegularExpression(pattern: find) {
                name = re.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: replace)
            } else {
                name = name.replacingOccurrences(of: find, with: replace)
            }
        }
        switch caseChange {
        case .none: break
        case .lower: name = name.lowercased()
        case .upper: name = name.uppercased()
        case .title: name = name.capitalized
        }
        name = prefix + name + suffix
        if let date = dateString(url) { name = "\(date) \(name)" }
        if numbering {
            let n = String(format: "%0\(padding)d", startAt + index)
            name = baseName.isEmpty ? "\(name) \(n)" : "\(name)\(n)"
        }
        if !newExtension.isEmpty { ext = newExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    private var plan: [(from: URL, to: URL)] {
        files.enumerated().map { i, url in (url, url.deletingLastPathComponent().appendingPathComponent(newName(url, index: i))) }
    }

    private func conflicts(_ plan: [(from: URL, to: URL)]) -> Set<URL> {
        var seen = Set<String>(), bad = Set<URL>()
        let sources = Set(plan.map { $0.from.path })
        for p in plan {
            let key = p.to.path.lowercased()
            if seen.contains(key) || (FileManager.default.fileExists(atPath: p.to.path) && !sources.contains(p.to.path) && p.to != p.from) {
                bad.insert(p.from)
            }
            seen.insert(key)
        }
        return bad
    }

    var body: some View {
        let plan = plan
        let bad = conflicts(plan)
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    DropZone(prompt: "Drop files to rename", types: [.item], urls: $files)
                    GroupBox("Find & replace") {
                        VStack(alignment: .leading) {
                            TextField("Find", text: $find)
                            TextField("Replace with", text: $replace)
                            Toggle("Regular expression", isOn: $useRegex)
                        }.padding(4)
                    }
                    GroupBox("Name") {
                        VStack(alignment: .leading) {
                            TextField("New base name (replaces the whole name)", text: $baseName)
                            TextField("Prefix", text: $prefix)
                            TextField("Suffix", text: $suffix)
                            Picker("Case", selection: $caseChange) { ForEach(CaseChange.allCases, id: \.self) { Text($0.rawValue) } }
                            TextField("New extension (optional)", text: $newExtension)
                        }.padding(4)
                    }
                    GroupBox("Date") {
                        Picker("Add at the start", selection: $dateMode) { ForEach(DateMode.allCases, id: \.self) { Text($0.rawValue) } }
                            .padding(4)
                    }
                    GroupBox("Numbering") {
                        VStack(alignment: .leading) {
                            Toggle("Add sequence number", isOn: $numbering)
                            Stepper("Start at \(startAt)", value: $startAt, in: 0...100000)
                            Stepper("Digits: \(padding)", value: $padding, in: 1...6)
                        }.padding(4).disabled(!numbering)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.trailing, 10)
            }
            .frame(minWidth: 300, idealWidth: 340)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Preview").font(.headline)
                    Spacer()
                    if !lastRun.isEmpty { Button("Undo Last Rename", action: undo) }
                    Button("Rename \(plan.filter { $0.from != $0.to }.count) Files", action: { apply(plan) })
                        .buttonStyle(.borderedProminent)
                        .disabled(files.isEmpty || !bad.isEmpty)
                }
                if !bad.isEmpty { ErrorText(message: "\(bad.count) name conflict\(bad.count == 1 ? "" : "s") — fix before renaming") }
                if let message { Text(message).foregroundStyle(.green) }
                Table(plan.map { RenameRow(from: $0.from, to: $0.to, conflict: bad.contains($0.from)) }) {
                    TableColumn("Current") { Text($0.from.lastPathComponent).foregroundStyle(.secondary) }
                    TableColumn("New") { row in
                        Text(row.to.lastPathComponent).foregroundStyle(row.conflict ? .red : row.from == row.to ? .secondary : .primary)
                    }
                }
            }
            .padding(.leading, 10)
        }
        .receivesFiles(for: "rename") { urls in files.append(contentsOf: urls.filter { !files.contains($0) }) }
    }

    private func apply(_ plan: [(from: URL, to: URL)]) {
        let fm = FileManager.default
        var done: [(URL, URL)] = []
        message = nil
        // Two-phase via temp names so swaps like a→b, b→a work.
        var temps: [(URL, URL, URL)] = []
        for p in plan where p.from != p.to {
            let temp = p.from.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            do { try fm.moveItem(at: p.from, to: temp); temps.append((p.from, temp, p.to)) } catch { message = error.localizedDescription }
        }
        for (from, temp, to) in temps {
            do { try fm.moveItem(at: temp, to: to); done.append((from, to)) } catch {
                try? fm.moveItem(at: temp, to: from)
                message = error.localizedDescription
            }
        }
        lastRun = done
        files = files.map { url in done.first { $0.0 == url }?.1 ?? url }
        let failed = plan.filter { $0.from != $0.to }.count - done.count
        message = "Renamed \(done.count) file\(done.count == 1 ? "" : "s")"
            + (failed > 0 ? " · \(failed) couldn't be renamed (\(message ?? "unknown error"))" : "")
        resetRules()
    }

    private func undo() {
        let fm = FileManager.default
        for (from, to) in lastRun.reversed() { try? fm.moveItem(at: to, to: from) }
        files = files.map { url in lastRun.first { $0.1 == url }?.0 ?? url }
        message = "Undid \(lastRun.count) rename\(lastRun.count == 1 ? "" : "s")"
        lastRun = []
    }

    private func resetRules() {
        find = ""; replace = ""; prefix = ""; suffix = ""; baseName = ""; numbering = false; caseChange = .none; newExtension = ""
        dateMode = .none
    }
}

struct RenameRow: Identifiable {
    let from: URL
    let to: URL
    let conflict: Bool
    var id: URL { from }
}

// MARK: - Find Duplicates

struct DuplicateFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: URL { url }
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let files: [DuplicateFile]
    var wasted: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

enum DuplicateScanner {
    static func scan(_ roots: [URL], minSize: Int64, progress: @escaping (String) -> Void) -> [DuplicateGroup] {
        let fm = FileManager.default
        var bySize: [Int64: [DuplicateFile]] = [:]
        var count = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        for root in roots {
            // Single files can be compared directly, alongside folders.
            if !root.isDirectory {
                if let v = try? root.resourceValues(forKeys: Set(keys)), let size = v.fileSize, Int64(size) >= minSize {
                    bySize[Int64(size), default: []].append(DuplicateFile(url: root, size: Int64(size), modified: v.contentModificationDate ?? .distantPast))
                    count += 1
                }
                continue
            }
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, let size = v.fileSize,
                      Int64(size) >= minSize else { continue }
                bySize[Int64(size), default: []].append(DuplicateFile(url: url, size: Int64(size), modified: v.contentModificationDate ?? .distantPast))
                count += 1
                if count % 200 == 0 { progress("Looked at \(count) files…") }
            }
        }
        var groups: [DuplicateGroup] = []
        // The same file added twice (or nested folders) shouldn't count as a duplicate of itself.
        let candidates = bySize.values.map { list in
            var seen = Set<String>()
            return list.filter { seen.insert($0.url.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
        }.filter { $0.count > 1 }
        for (i, sameSize) in candidates.enumerated() {
            if i % 50 == 0 { progress("Comparing \(i)/\(candidates.count) size groups…") }
            // Cheap first pass on the first 64 KB, then full hash.
            let byHead = Dictionary(grouping: sameSize) { hash($0.url, limit: 65_536) ?? UUID().uuidString }
            for headGroup in byHead.values where headGroup.count > 1 {
                let byFull = Dictionary(grouping: headGroup) { hash($0.url, limit: nil) ?? UUID().uuidString }
                for g in byFull.values where g.count > 1 {
                    groups.append(DuplicateGroup(files: g.sorted { $0.modified < $1.modified }))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if let limit, read + chunk.count > limit {
                hasher.update(data: chunk.prefix(limit - read)); break
            }
            hasher.update(data: chunk)
            read += chunk.count
        }
        return Data(hasher.finalize()).hex
    }
}

@MainActor @Observable
final class DuplicatesModel {
    static let shared = DuplicatesModel()
    var places: [URL] = []
    var minSizeKB = 1
    var groups: [DuplicateGroup] = []
    var selected = Set<URL>()
    var status = ""
    var scanning = false
    var scanned = false

    func add(_ urls: [URL]) {
        places.append(contentsOf: urls.filter { u in !places.contains(u) })
        scanned = false
    }

    func scan() {
        guard !places.isEmpty else { return }
        scanning = true
        scanned = false
        groups = []
        selected = []
        status = "Starting…"
        let roots = places, min = Int64(minSizeKB) * 1024
        Task.detached {
            let found = DuplicateScanner.scan(roots, minSize: min) { msg in Task { @MainActor in DuplicatesModel.shared.status = msg } }
            await MainActor.run {
                let m = DuplicatesModel.shared
                m.groups = found
                m.scanning = false
                m.scanned = true
                m.selectAllButOldest()
            }
        }
    }

    func selectAllButOldest() { selected = Set(groups.flatMap { $0.files.dropFirst().map(\.url) }) }

    func trash() -> Int {
        var failed = 0
        for url in selected {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failed += 1 }
        }
        groups = groups.compactMap { g in
            let left = g.files.filter { !selected.contains($0.url) }
            return left.count > 1 ? DuplicateGroup(files: left) : nil
        }
        selected = []
        return failed
    }
}

struct DuplicatesView: View {
    @Bindable private var model = DuplicatesModel.shared
    @State private var confirmTrash = false
    @State private var message: String?
    @State private var targeted = false

    private let quickPlaces: [(String, String, FileManager.SearchPathDirectory?)] = [
        ("Downloads", "arrow.down.circle", .downloadsDirectory), ("Desktop", "menubar.dock.rectangle", .desktopDirectory),
        ("Documents", "doc", .documentDirectory), ("Pictures", "photo", .picturesDirectory), ("Home", "house", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Look in").foregroundStyle(.secondary)
                ForEach(quickPlaces, id: \.0) { name, icon, dir in
                    Button { model.add([dir.map { FileManager.default.urls(for: $0, in: .userDomainMask)[0] } ?? MacKit.home]) } label: {
                        Label(name, systemImage: icon)
                    }
                }
                Button { model.add(FilePicker.choose(types: [.item], multiple: true, folders: true)) } label: { Label("Choose…", systemImage: "plus") }
            }
            .controlSize(.regular)

            VStack(alignment: .leading, spacing: 4) {
                if model.places.isEmpty {
                    Text("Pick a place above, or drop folders and files here.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(model.places, id: \.self) { url in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.places.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(model.scanning)
                        }
                    }
                }
            }
            .padding(10)
            .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .onDrop(of: FileDrop.types, isTargeted: $targeted) { providers in
                FileDrop.load(providers) { model.add($0.filter(\.isFileURL)) }
                return true
            }

            HStack {
                Stepper("Ignore files under \(model.minSizeKB) KB", value: $model.minSizeKB, in: 0...102_400)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small); Text(model.status).foregroundStyle(.secondary).monospacedDigit() }
                Button(model.scanning ? "Scanning…" : "Find Duplicates") { model.scan() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.places.isEmpty || model.scanning)
            }
            if let message { Banner(symbol: "info.circle", message: message, tint: .blue) }

            if !model.groups.isEmpty {
                let total = model.groups.reduce(0) { $0 + $1.wasted }
                let selectedSize = model.groups.flatMap(\.files).filter { model.selected.contains($0.url) }.reduce(0) { $0 + $1.size }
                HStack {
                    Text("\(model.groups.count) sets of duplicates · \(total.byteString) can be freed").bold()
                    Spacer()
                    Button("Keep Oldest of Each") { model.selectAllButOldest() }
                    Button("Select None") { model.selected = [] }
                    Button("Move \(model.selected.count) to Trash (\(selectedSize.byteString))") { confirmTrash = true }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(model.selected.isEmpty)
                }
                List {
                    ForEach(model.groups) { group in
                        Section("\(group.files.count) identical copies · \(group.files[0].size.byteString) each") {
                            ForEach(group.files) { file in
                                HStack {
                                    Toggle("", isOn: Binding(get: { model.selected.contains(file.url) },
                                                             set: { if $0 { model.selected.insert(file.url) } else { model.selected.remove(file.url) } }))
                                        .labelsHidden()
                                    Thumbnail(url: file.url, size: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.url.lastPathComponent).lineLimit(1)
                                        Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                    Spacer()
                                    if !model.selected.contains(file.url) { Text("Keep").font(.caption.weight(.semibold)).foregroundStyle(.green) }
                                    Text(file.modified.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                                    Button { file.url.reveal() } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                                }
                                .draggableFile(file.url)
                            }
                        }
                    }
                }
            } else if model.scanned {
                ContentUnavailableView("No Duplicates", systemImage: "checkmark.seal", description: Text("Every file in these places is unique."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .receivesFiles(for: "duplicates") { model.add($0) }
        .alert("Move \(model.selected.count) files to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let failed = model.trash()
                message = failed > 0 ? "\(failed) files couldn't be moved." : "Moved to the Trash. You can put them back from there."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One copy of each file is kept. You can restore them from the Trash.")
        }
    }
}

// MARK: - Zip & Unzip

struct ZipView: View {
    @State private var toZip: [URL] = []
    @State private var archiveName = "Archive"
    @State private var password = ""
    @State private var toExtract: [URL] = []
    @State private var extractPassword = ""
    @State private var outputs: [URL] = []
    @State private var error: String?
    @State private var working = false

    static let archiveTypes: [UTType] = [.zip, .archive, .gzip, .bz2, UTType(filenameExtension: "7z") ?? .archive,
                                         UTType(filenameExtension: "rar") ?? .archive, UTType(filenameExtension: "xz") ?? .archive,
                                         UTType(filenameExtension: "tar") ?? .archive, UTType(filenameExtension: "tgz") ?? .archive]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Compress") {
                    VStack(alignment: .leading, spacing: 8) {
                        DropZone(prompt: "Drop files or folders to zip", types: [.item], folders: true, urls: $toZip)
                        HStack {
                            TextField("Archive name", text: $archiveName).frame(width: 220)
                            SecureField("Password (optional)", text: $password).frame(width: 220)
                            Spacer()
                            Button("Create Zip", action: zip).buttonStyle(.borderedProminent).disabled(toZip.isEmpty || working)
                        }
                        .textFieldStyle(.roundedBorder)
                        Text("Leaves out .DS_Store and other macOS clutter.").font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                GroupBox("Extract") {
                    VStack(alignment: .leading, spacing: 8) {
                        DropZone(prompt: "Drop .zip, .7z, .rar, .tar.gz, .tgz, .xz archives", types: Self.archiveTypes, urls: $toExtract)
                        HStack {
                            SecureField("Password (if the zip has one)", text: $extractPassword).textFieldStyle(.roundedBorder).frame(width: 260)
                            Spacer()
                            Button("Extract", action: extract).buttonStyle(.borderedProminent).disabled(toExtract.isEmpty || working)
                        }
                    }.padding(6)
                }
                if working { ProgressView() }
                if let error { ErrorText(message: error) }
                ResultList(urls: outputs)
            }
        }
        .receivesFiles(for: "zip") { urls in
            let archives = urls.filter { BatchRun.matches($0, Self.archiveTypes) }
            toExtract.append(contentsOf: archives)
            toZip.append(contentsOf: urls.filter { !archives.contains($0) })
        }
    }

    private func zip() {
        working = true; error = nil; outputs = []
        let items = toZip, pass = password
        let name = archiveName.isEmpty ? "Archive" : archiveName
        Task {
            defer { working = false }
            let out = Output.file(name: name, ext: "zip")
            for item in items {
                var args = ["-r", "-q", "-y"]
                if !pass.isEmpty { args += ["-P", pass] }
                args += [out.path, item.lastPathComponent, "-x", "*.DS_Store", "-x", "__MACOSX/*", "-x", "*/.DS_Store"]
                do {
                    let r = try await Shell.run("/usr/bin/zip", args, cwd: item.deletingLastPathComponent())
                    if !r.ok { try? FileManager.default.removeItem(at: out); error = r.err.isEmpty ? "zip failed (\(r.status))" : r.err; return }
                } catch { try? FileManager.default.removeItem(at: out); self.error = error.localizedDescription; return }
            }
            outputs = [out]
        }
    }

    private func extract() {
        working = true; error = nil; outputs = []
        let archives = toExtract, pass = extractPassword
        Task {
            defer { working = false }
            var made: [URL] = []
            for archive in archives {
                var base = archive.deletingPathExtension()
                if base.pathExtension == "tar" { base = base.deletingPathExtension() }
                let dest = Output.unique(Output.root.appendingPathComponent(base.lastPathComponent))
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                do {
                    let r: Shell.Result
                    if archive.pathExtension.lowercased() == "zip" {
                        r = pass.isEmpty
                            ? try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, dest.path])
                            : try await Shell.run("/usr/bin/unzip", ["-q", "-o", "-P", pass, archive.path, "-d", dest.path])
                    } else {
                        r = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", dest.path])
                    }
                    if r.ok {
                        try? FileManager.default.removeItem(at: dest.appendingPathComponent("__MACOSX"))
                        made.append(dest)
                    } else {
                        try? FileManager.default.removeItem(at: dest)
                        let msg = r.err.lowercased()
                        error = "\(archive.lastPathComponent): " + (msg.contains("password") || msg.contains("encrypt") || msg.contains("incorrect") || (!pass.isEmpty && msg.isEmpty)
                            ? (pass.isEmpty ? "it's password-protected — type the password above and try again." : "that password didn't work.")
                            : r.err.isEmpty ? "couldn't be opened." : r.err)
                    }
                } catch { try? FileManager.default.removeItem(at: dest); self.error = error.localizedDescription }
            }
            outputs = made
        }
    }
}
