import AppKit
import CoreLocation
import CoreWLAN
import IOKit.pwr_mgt
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let macTools: [Tool] = [
        Tool("speedtest", "Network Speed Test", "speedometer", .mac,
             "Measure download, upload and responsiveness with Apple's own network test") { SpeedTestView() },
        Tool("storage", "Storage Explorer", "internaldrive", .mac,
             "See what's filling your disk, find the usual space hogs and clear them out safely") { StorageView() },
        Tool("wifi", "Wi-Fi Password & QR", "wifi", .mac,
             "Show the password of a saved Wi-Fi network and make a QR code guests can scan to join") { WiFiPasswordView() },
        Tool("battery", "Battery Health", "battery.75percent", .mac,
             "See battery capacity, cycle count and charger, plus AirPods and accessory levels") { BatteryView() },
        Tool("keepawake", "Keep Awake", "cup.and.saucer", .mac,
             "Stop your Mac from sleeping during downloads, renders or talks, for as long as you choose") { KeepAwakeView() },
        Tool("uninstall", "Uninstall App", "xmark.app", .mac,
             "Remove an app together with the caches, preferences and data it leaves behind",
             accepts: [.applicationBundle]) { UninstallView() },
        Tool("presentation", "Presentation Mode", "rectangle.on.rectangle", .mac,
             "One switch before you share your screen: hide desktop icons, hide the Dock and stay awake") { PresentationModeView() },
        Tool("cleankeyboard", "Clean Keyboard", "keyboard", .mac,
             "Pause the keyboard so you can wipe the keys, with an optional black screen for the display") { CleanKeyboardView() },
        Tool("deadpixel", "Dead Pixel Test", "square.grid.4x3.fill", .mac,
             "Fill every display with solid colours to spot dead, stuck or hot pixels and backlight bleed") { DeadPixelView() },
        Tool("eject", "Eject All Disks", "eject", .mac,
             "Safely eject every external drive, card and disk image at once before you unplug") { EjectView() },
        Tool("loginitems", "Login & Background Items", "power", .mac,
             "See what starts with your Mac and runs in the background, who made it, and turn off what you don't need") { LoginItemsView() },
        Tool("fixdamaged", "Fix “App Is Damaged”", "bandage", .mac,
             "Check who made an app that won't open, then clear the quarantine so macOS lets it run",
             accepts: [.applicationBundle]) { FixDamagedView() },
        Tool("resetperms", "Reset Permissions", "hand.raised", .mac,
             "Unstick an app's Screen Recording, Microphone, Camera or other privacy access so macOS asks again",
             accepts: [.applicationBundle]) { ResetPermissionsView() },
        Tool("hidden", "Hidden Settings", "slider.horizontal.3", .mac,
             "Switch on useful macOS settings that aren't in System Settings, like a faster Dock or hidden files") { HiddenSettingsView() },
        Tool("display", "Display Control", "sun.max", .mac,
             "Change the brightness, contrast and volume of your displays, including external monitors") { DisplayControlView() },
        Tool("mouse", "Mouse Fixes", "computermouse", .mac,
             "Scroll your mouse and trackpad in different directions, and make the mouse wheel faster") { MouseFixesView() },
    ]
}

// MARK: - Shared Mac helpers

enum MacKit {
    /// Runs a shell command with an administrator password prompt (the standard macOS dialog).
    static func runAsAdmin(_ command: String) async throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let r = try await Shell.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        if !r.ok {
            if r.err.contains("-128") { throw CancellationError() }
            throw ToolError(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Size on disk of a file or folder (allocated size, like Finder).
    nonisolated static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true { total += Int64(v.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func defaults(_ args: [String]) async -> String {
        (try? await Shell.run("/usr/bin/defaults", args))?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    struct AppInfo: Identifiable, Hashable {
        let url: URL
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
        var bundleID: String? { Bundle(url: url)?.bundleIdentifier }
        var version: String? { Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    /// Apps in /Applications and ~/Applications (Apple's own system apps are left out).
    static func installedApps() -> [AppInfo] {
        let dirs = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var apps: [AppInfo] = []
        for dir in dirs {
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = e?.nextObject() as? URL {
                if url.pathExtension == "app" {
                    apps.append(AppInfo(url: url))
                    e?.skipDescendants()
                } else if e?.level ?? 0 > 2 {
                    e?.skipDescendants()
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Accessibility permission, needed for Clean Keyboard and Mouse Fixes.
enum AccessibilityAccess {
    static var granted: Bool { AXIsProcessTrusted() }

    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

struct AccessibilityBanner: View {
    let feature: String
    @State private var granted = AccessibilityAccess.granted

    var body: some View {
        if !granted {
            Banner(symbol: "lock.shield", message: "\(feature) needs Accessibility access. Turn on MyToolbox in System Settings › Privacy & Security › Accessibility.") {
                Button("Allow…") { AccessibilityAccess.request(); AccessibilityAccess.openSettings() }
                Button("Check Again") { granted = AccessibilityAccess.granted }
            }
            .task {
                while !granted && !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    granted = AccessibilityAccess.granted
                }
            }
        }
    }
}

/// Big stat tile used by several Mac tools.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Network Speed Test

struct SpeedResult: Codable, Equatable {
    var download: Double   // Mbps
    var upload: Double
    var responsiveness: Double   // RPM
    var latency: Double?
    var interface: String?
    var date = Date()

    var rating: (String, Color) {
        responsiveness >= 800 ? ("High", .green) : responsiveness >= 200 ? ("Medium", .orange) : ("Low", .red)
    }

    static func parse(_ json: String) -> SpeedResult? {
        guard let data = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        guard let dl = num("dl_throughput"), let ul = num("ul_throughput") else { return nil }
        return SpeedResult(download: dl / 1_000_000, upload: ul / 1_000_000, responsiveness: num("responsiveness") ?? num("dl_responsiveness") ?? 0,
                           latency: num("base_rtt"), interface: o["interface_name"] as? String)
    }
}

struct SpeedTestView: View {
    @State private var running = false
    @State private var elapsed = 0
    @State private var result: SpeedResult?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @AppStorage("speed.history") private var historyData = Data()

    private var history: [SpeedResult] { (try? JSONDecoder().decode([SpeedResult].self, from: historyData)) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                if running {
                    Button("Stop") { task?.cancel() }.controlSize(.large)
                    ProgressView(value: min(Double(elapsed), 10), total: 10).frame(width: 160)
                    Text(elapsed < 10 ? "Measuring… \(10 - elapsed)s left" : "Finishing…").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Button { start() } label: { Label("Start Test", systemImage: "speedometer").padding(.horizontal, 6) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: .command)
                    Text("Uses Apple's networkQuality servers.").foregroundStyle(.secondary)
                }
            }
            if let error { ErrorText(message: error) }
            if let r = result ?? history.first {
                HStack(spacing: 12) {
                    StatTile(title: "Download", value: String(format: "%.0f Mbps", r.download), tint: .blue)
                    StatTile(title: "Upload", value: String(format: "%.0f Mbps", r.upload), tint: .purple)
                    StatTile(title: "Responsiveness", value: "\(Int(r.responsiveness)) RPM", detail: r.rating.0 + " — how snappy calls and browsing feel",
                             tint: r.rating.1)
                }
                Text("\(r.interface.map { "Over \($0) · " } ?? "")\(r.latency.map { String(format: "idle latency %.0f ms · ", $0) } ?? "")\(r.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !running {
                ContentUnavailableView("No Test Yet", systemImage: "speedometer", description: Text("Press Start Test to measure your connection."))
                    .frame(maxHeight: 220)
            }
            if history.count > 1 {
                Text("Earlier Tests").font(.headline)
                ForEach(Array(history.dropFirst().prefix(6).enumerated()), id: \.offset) { _, h in
                    HStack {
                        Text(h.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
                        Text(String(format: "↓ %.0f  ↑ %.0f Mbps", h.download, h.upload)).monospacedDigit()
                        Text("\(Int(h.responsiveness)) RPM").foregroundStyle(h.rating.1)
                    }
                    .font(.callout)
                }
            }
            Spacer()
        }
    }

    private func start() {
        running = true
        error = nil
        elapsed = 0
        task = Task {
            let ticker = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); elapsed += 1 } }
            defer { ticker.cancel(); running = false }
            do {
                // -M caps the test at 10 seconds (the default runs until stable, often 25 s+).
                let r = try await Shell.run("/usr/bin/networkQuality", ["-c", "-M", "10"])
                if let parsed = SpeedResult.parse(r.out) {
                    result = parsed
                    historyData = (try? JSONEncoder().encode(Array(([parsed] + history).prefix(20)))) ?? Data()
                } else {
                    error = "The test didn't finish. Check that you're online."
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Storage Explorer

@MainActor @Observable
final class StorageModel {
    static let shared = StorageModel()

    struct Spot: Identifiable {
        let id: String
        let title: String
        let detail: String
        let urls: [URL]
        /// Safe = regenerated automatically (caches, build products); the contents can go to the Trash.
        let safe: Bool
        var size: Int64?
    }

    struct BigFile: Identifiable, Hashable {
        let url: URL
        let size: Int64
        var id: URL { url }
    }

    var total: Int64 = 0
    var available: Int64 = 0
    var spots: [Spot] = []
    var bigFiles: [BigFile] = []
    var scanning = false

    static func makeSpots() -> [Spot] {
        let h = MacKit.home
        func p(_ s: String) -> URL { h.appendingPathComponent(s) }
        return [
            Spot(id: "caches", title: "App Caches", detail: "Temporary files apps recreate when needed", urls: [p("Library/Caches")], safe: true),
            Spot(id: "logs", title: "Logs", detail: "Diagnostic logs", urls: [p("Library/Logs")], safe: true),
            Spot(id: "xcode", title: "Xcode Build Data", detail: "DerivedData, old archives and device support",
                 urls: [p("Library/Developer/Xcode/DerivedData"), p("Library/Developer/Xcode/iOS DeviceSupport"), p("Library/Developer/Xcode/Archives")], safe: true),
            Spot(id: "simulators", title: "Simulators", detail: "iOS simulator devices and runtimes caches", urls: [p("Library/Developer/CoreSimulator/Caches")], safe: true),
            Spot(id: "devcaches", title: "Developer Caches", detail: "npm, pnpm, Yarn, pip, Gradle and Cargo caches",
                 urls: [p(".npm/_cacache"), p("Library/pnpm/store"), p(".cache"), p(".gradle/caches"), p(".cargo/registry/cache")], safe: true),
            Spot(id: "mail", title: "Mail Attachments", detail: "Copies of attachments you opened in Mail",
                 urls: [p("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")], safe: true),
            Spot(id: "trash", title: "Trash", detail: "Files you already deleted", urls: [p(".Trash")], safe: false),
            Spot(id: "downloads", title: "Downloads", detail: "Everything in your Downloads folder", urls: [p("Downloads")], safe: false),
            Spot(id: "backups", title: "iPhone & iPad Backups", detail: "Local device backups", urls: [p("Library/Application Support/MobileSync/Backup")], safe: false),
        ]
    }

    func scan() {
        scanning = true
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            total = Int64(v.volumeTotalCapacity ?? 0)
            available = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
        spots = Self.makeSpots()
        Task {
            await withTaskGroup(of: (String, Int64).self) { group in
                for spot in spots {
                    let urls = spot.urls
                    group.addTask { (spot.id, urls.reduce(0) { $0 + MacKit.size(of: $1) }) }
                }
                for await (id, size) in group {
                    if let i = spots.firstIndex(where: { $0.id == id }) { spots[i].size = size }
                }
            }
            let r = try? await Shell.run("/usr/bin/mdfind", ["-onlyin", MacKit.home.path, "kMDItemFSSize > 500000000"])
            let files = (r?.out ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                .filter { !$0.path.contains("/Library/") && !$0.path.contains("/.Trash/") }
            bigFiles = files.map { BigFile(url: $0, size: $0.fileSize) }.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(25).map { $0 }
            scanning = false
        }
    }

    /// Moves the contents of a safe spot to the Trash (the folders themselves stay).
    func clean(_ spot: Spot) {
        for folder in spot.urls {
            for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.trashItem(at: item, resultingItemURL: nil)
            }
        }
        if let i = spots.firstIndex(where: { $0.id == spot.id }) {
            let urls = spot.urls
            spots[i].size = nil
            Task { let s = await Task.detached { urls.reduce(0) { $0 + MacKit.size(of: $1) } }.value; spots[i].size = s }
        }
    }

    func emptyTrash() async {
        _ = try? await Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
        if let i = spots.firstIndex(where: { $0.id == "trash" }) { spots[i].size = MacKit.size(of: spots[i].urls[0]) }
    }
}

struct StorageView: View {
    @Bindable private var model = StorageModel.shared
    @State private var confirm: StorageModel.Spot?
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.total > 0 {
                    let used = model.total - model.available
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Macintosh HD").font(.headline)
                            Spacer()
                            Text("\(model.available.byteString) available of \(model.total.byteString)").foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(used), total: Double(model.total)).tint(Double(used) / Double(model.total) > 0.9 ? .red : .accentColor)
                    }
                }
                HStack {
                    Text("Space Hogs").font(.headline)
                    if model.scanning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Scan Again") { model.scan() }.disabled(model.scanning)
                }
                VStack(spacing: 0) {
                    ForEach(model.spots) { spot in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(spot.title).font(.body.weight(.medium))
                                Text(spot.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let size = spot.size { Text(size.byteString).monospacedDigit().foregroundStyle(size > 1_000_000_000 ? .orange : .secondary) }
                            else { ProgressView().controlSize(.small) }
                            Button { if let u = spot.urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { NSWorkspace.shared.open(u) } } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless).help("Open in Finder")
                            if spot.id == "trash" {
                                Button("Empty Trash…") { confirmTrash = true }.disabled((spot.size ?? 0) == 0)
                            } else if spot.safe {
                                Button("Clean…") { confirm = spot }.disabled((spot.size ?? 0) == 0)
                            } else {
                                Button("Review") { if let u = spot.urls.first { NSWorkspace.shared.open(u) } }
                            }
                        }
                        .padding(.vertical, 9).padding(.horizontal, 12)
                        Divider()
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                if !model.bigFiles.isEmpty {
                    Text("Largest Files in Your Home Folder").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(model.bigFiles) { f in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 20, height: 20)
                                Text(f.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(f.size.byteString).monospacedDigit()
                                Button { f.url.reveal() } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                            }
                            .padding(.vertical, 6).padding(.horizontal, 12)
                            .draggableFile(f.url)
                            Divider()
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .onAppear { if model.spots.isEmpty { model.scan() } }
        .alert("Move \(confirm?.title ?? "") to the Trash?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Move to Trash", role: .destructive) { if let c = confirm { model.clean(c) }; confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            Text("These are recreated automatically when needed. You can still restore them from the Trash until you empty it.")
        }
        .alert("Empty the Trash?", isPresented: $confirmTrash) {
            Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files in the Trash are deleted permanently. This can't be undone.")
        }
    }
}

// MARK: - Wi-Fi Password & QR

@MainActor @Observable
final class WiFiModel: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiModel()
    var networks: [String] = []
    var current: String?
    var selected: String?
    var password: String?
    var error: String?
    @ObservationIgnored private let location = CLLocationManager()

    func load() async {
        let ports = (try? await Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]))?.out ?? ""
        let device = ports.components(separatedBy: "Hardware Port: Wi-Fi").dropFirst().first?
            .split(separator: "\n").first { $0.hasPrefix("Device:") }?.replacingOccurrences(of: "Device: ", with: "") ?? "en0"
        let list = (try? await Shell.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", device]))?.out ?? ""
        networks = list.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The current network name needs location permission on recent macOS.
        location.delegate = self
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        current = CWWiFiClient.shared().interface()?.ssid()
        if selected == nil { selected = current ?? networks.first }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.current = CWWiFiClient.shared().interface()?.ssid(); if self.selected == nil { self.selected = self.current } }
    }

    func reveal() async {
        guard let ssid = selected else { return }
        password = nil
        error = nil
        // macOS shows its own password dialog before handing out a saved Wi-Fi password.
        let r = try? await Shell.run("/usr/bin/security", ["find-generic-password", "-D", "AirPort network password", "-a", ssid, "-w"])
        if let out = r?.out.trimmingCharacters(in: .whitespacesAndNewlines), r?.ok == true, !out.isEmpty {
            password = out
        } else {
            error = r?.err.contains("could not be found") == true ? "No saved password for “\(ssid)” on this Mac." : "macOS didn't allow access to the password."
        }
    }
}

struct WiFiPasswordView: View {
    @Bindable private var model = WiFiModel.shared
    @State private var saved: [URL] = []

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Saved Networks").font(.headline)
                List(model.networks, id: \.self, selection: $model.selected) { name in
                    HStack {
                        Image(systemName: name == model.current ? "wifi" : "wifi.exclamationmark").foregroundStyle(name == model.current ? Color.accentColor : .secondary)
                        Text(name)
                        if name == model.current { Text("Connected").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(name)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 260)
                .onChange(of: model.selected) { model.password = nil; model.error = nil }
            }
            .frame(width: 320)
            VStack(alignment: .leading, spacing: 14) {
                if let ssid = model.selected {
                    Text(ssid).font(.title2.weight(.semibold))
                    if let password = model.password {
                        ValueRow(label: "Password", value: password)
                        if let image = QR.make(QR.wifiPayload(ssid: ssid, password: password, security: "WPA", hidden: false)) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
                            Text("Guests can point their camera at this code to join.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Copy QR Image") { Pasteboard.copy(image) }
                                Button("Save QR") {
                                    let url = Output.file(name: "Wi-Fi \(ssid)", ext: "png")
                                    try? QR.pngData(image)?.write(to: url)
                                    saved = [url]
                                }
                            }
                            ResultList(urls: saved)
                        }
                    } else {
                        Button { Task { await model.reveal() } } label: { Label("Show Password", systemImage: "key") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Text("macOS asks for your Mac's password before showing a saved Wi-Fi password.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.error { ErrorText(message: error) }
                } else {
                    ContentUnavailableView("Pick a Network", systemImage: "wifi", description: Text("Choose a saved network on the left."))
                }
                Spacer()
            }
        }
        .task { await model.load() }
    }
}

// MARK: - Battery Health

struct BatteryInfo {
    var percent: Int?
    var charging = false
    var pluggedIn = false
    var cycles: Int?
    var health: String?
    var maxCapacity: String?
    var designMAh: Int?
    var currentMaxMAh: Int?
    var temperature: Double?
    var adapter: String?
    var timeRemaining: Int?

    static func read() async -> BatteryInfo? {
        guard let r = try? await Shell.run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery", "-a"]),
              let plist = try? PropertyListSerialization.propertyList(from: Data(r.out.utf8), format: nil) as? [[String: Any]],
              let b = plist.first else { return nil }
        var info = BatteryInfo()
        info.percent = b["CurrentCapacity"] as? Int
        info.charging = b["IsCharging"] as? Bool ?? false
        info.pluggedIn = b["ExternalConnected"] as? Bool ?? false
        info.cycles = b["CycleCount"] as? Int
        info.designMAh = b["DesignCapacity"] as? Int
        info.currentMaxMAh = b["AppleRawMaxCapacity"] as? Int
        if let t = b["Temperature"] as? Int { info.temperature = Double(t) / 100 }
        if let mins = b["TimeRemaining"] as? Int, mins > 0, mins < 6000 { info.timeRemaining = mins }
        if let a = b["AdapterDetails"] as? [String: Any], let w = a["Watts"] as? Int, w > 0 {
            info.adapter = "\(w) W" + ((a["Name"] as? String).map { " · \($0)" } ?? "")
        }
        if let sp = try? await Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]),
           let o = try? JSONSerialization.jsonObject(with: Data(sp.out.utf8)) as? [String: Any],
           let items = o["SPPowerDataType"] as? [[String: Any]],
           let health = items.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first {
            info.health = health["sppower_battery_health"] as? String
            info.maxCapacity = health["sppower_battery_health_maximum_capacity"] as? String
            if info.cycles == nil { info.cycles = health["sppower_battery_cycle_count"] as? Int }
        }
        return info
    }
}

struct AccessoryBattery: Identifiable {
    let id = UUID()
    let name: String
    let levels: [(String, Int)]

    static func read() async -> [AccessoryBattery] {
        var out: [AccessoryBattery] = []
        // Magic Mouse / Keyboard / Trackpad
        if let r = try? await Shell.run("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent", "-a"]),
           let list = try? PropertyListSerialization.propertyList(from: Data(r.out.utf8), format: nil) as? [[String: Any]] {
            for d in list {
                if let name = d["Product"] as? String, let pct = d["BatteryPercent"] as? Int { out.append(AccessoryBattery(name: name, levels: [("", pct)])) }
            }
        }
        // AirPods and other Bluetooth devices
        if let r = try? await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
           let o = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
           let items = o["SPBluetoothDataType"] as? [[String: Any]] {
            for item in items {
                for group in (item["device_connected"] as? [[String: Any]]) ?? [] {
                    for (name, value) in group {
                        guard let d = value as? [String: Any] else { continue }
                        var levels: [(String, Int)] = []
                        for (key, label) in [("device_batteryLevelLeft", "Left"), ("device_batteryLevelRight", "Right"),
                                             ("device_batteryLevelCase", "Case"), ("device_batteryLevelMain", "")] {
                            if let s = d[key] as? String, let n = Int(s.replacingOccurrences(of: "%", with: "")) { levels.append((label, n)) }
                        }
                        if !levels.isEmpty && !out.contains(where: { $0.name == name }) { out.append(AccessoryBattery(name: name, levels: levels)) }
                    }
                }
            }
        }
        return out
    }
}

struct BatteryView: View {
    @State private var info: BatteryInfo?
    @State private var loaded = false
    @State private var accessories: [AccessoryBattery] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let b = info {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        StatTile(title: "Charge", value: b.percent.map { "\($0)%" } ?? "—",
                                 detail: b.charging ? "Charging" : b.pluggedIn ? "Plugged in, not charging" : b.timeRemaining.map { "\($0 / 60) h \($0 % 60) min left" } ?? "On battery")
                        StatTile(title: "Maximum Capacity", value: b.maxCapacity ?? "—", detail: b.health.map { "Condition: \($0)" },
                                 tint: (Int(b.maxCapacity?.replacingOccurrences(of: "%", with: "") ?? "") ?? 100) < 80 ? .orange : .green)
                        StatTile(title: "Cycle Count", value: b.cycles.map(String.init) ?? "—", detail: "Mac batteries are rated for 1000 cycles")
                        StatTile(title: "Temperature", value: b.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
                        StatTile(title: "Charger", value: b.adapter ?? (b.pluggedIn ? "Connected" : "Not connected"))
                        if let d = b.designMAh, let m = b.currentMaxMAh {
                            StatTile(title: "Capacity (mAh)", value: "\(m) / \(d)", detail: "Now / when new")
                        }
                    }
                } else if loaded {
                    ContentUnavailableView("No Battery", systemImage: "powerplug", description: Text("This Mac runs on power only."))
                } else {
                    ProgressView()
                }
                if !accessories.isEmpty {
                    Text("Accessories").font(.headline)
                    ForEach(accessories) { a in
                        HStack {
                            Image(systemName: a.name.localizedCaseInsensitiveContains("airpods") ? "airpods" : a.name.localizedCaseInsensitiveContains("mouse") ? "computermouse" : a.name.localizedCaseInsensitiveContains("keyboard") ? "keyboard" : "headphones")
                                .frame(width: 22)
                            Text(a.name)
                            Spacer()
                            ForEach(a.levels, id: \.0) { label, n in
                                Text("\(label.isEmpty ? "" : label + " ")\(n)%").monospacedDigit().foregroundStyle(n < 20 ? .red : .primary)
                            }
                        }
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                info = await BatteryInfo.read()
                accessories = await AccessoryBattery.read()
                loaded = true
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

// MARK: - Uninstall App

@MainActor @Observable
final class UninstallModel {
    static let shared = UninstallModel()

    struct Leftover: Identifiable, Hashable {
        let url: URL
        var size: Int64
        var include = true
        var id: URL { url }
    }

    var apps: [MacKit.AppInfo] = []
    var query = ""
    var selected: MacKit.AppInfo?
    var leftovers: [Leftover] = []
    var appSize: Int64 = 0
    var searching = false
    var message: String?

    var filtered: [MacKit.AppInfo] {
        let base = apps.filter { !($0.bundleID ?? "").hasPrefix("com.apple.") }
        return query.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func load() { if apps.isEmpty { apps = MacKit.installedApps() } }

    func select(_ app: MacKit.AppInfo) {
        selected = app
        leftovers = []
        message = nil
        searching = true
        Task {
            let found = await Task.detached { Self.findLeftovers(app) }.value
            appSize = await Task.detached { MacKit.size(of: app.url) }.value
            leftovers = found
            searching = false
        }
    }

    nonisolated static func findLeftovers(_ app: MacKit.AppInfo) -> [Leftover] {
        let lib = MacKit.home.appendingPathComponent("Library")
        let id = app.bundleID ?? ""
        let name = app.name
        var names = [name]
        if !id.isEmpty { names.append(id) }
        let dirs = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Saved Application State",
                    "Logs", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents", "Application Scripts"]
        var out: [Leftover] = []
        for dir in dirs {
            let base = lib.appendingPathComponent(dir)
            guard let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                let n = item.lastPathComponent
                let match = names.contains { key in
                    !key.isEmpty && (n == key || n == key + ".plist" || n == key + ".savedState" || n.hasPrefix(key + ".") || (key == id && n.hasSuffix("." + id)) || (key == id && n.contains(id)))
                }
                if match { out.append(Leftover(url: item, size: MacKit.size(of: item))) }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    func uninstall() async {
        guard let app = selected else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID ?? "").first {
            running.terminate()
            try? await Task.sleep(for: .seconds(1.5))
        }
        var failed: [String] = []
        var appGone = (try? FileManager.default.trashItem(at: app.url, resultingItemURL: nil)) != nil
        if !appGone {
            // Apps installed by an admin need the Finder to move them (it asks for your password).
            let r = try? await Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to delete (POSIX file \"\(app.url.path)\" as alias)"])
            appGone = r?.ok == true
        }
        if !appGone { failed.append(app.name) }
        for l in leftovers where l.include {
            if (try? FileManager.default.trashItem(at: l.url, resultingItemURL: nil)) == nil { failed.append(l.url.lastPathComponent) }
        }
        message = failed.isEmpty ? "\(app.name) and its files were moved to the Trash." : "Couldn't remove: \(failed.joined(separator: ", "))"
        apps.removeAll { $0.url == app.url && appGone }
        if appGone { selected = nil; leftovers = [] }
    }
}

struct UninstallView: View {
    @Bindable private var model = UninstallModel.shared
    @State private var confirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search apps", text: $model.query).textFieldStyle(.roundedBorder)
                List(model.filtered, selection: Binding(get: { model.selected?.url }, set: { url in
                    if let app = model.filtered.first(where: { $0.url == url }) { model.select(app) }
                })) { app in
                    HStack {
                        Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                        Text(app.name)
                    }
                    .tag(app.url)
                }
            }
            .frame(width: 280)
            .padding(.trailing, 16)
            VStack(alignment: .leading, spacing: 12) {
                if let message = model.message { Banner(symbol: "checkmark.circle", message: message, tint: .green) }
                if let app = model.selected {
                    HStack(spacing: 12) {
                        Image(nsImage: app.icon).resizable().frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text(app.name).font(.title2.weight(.semibold))
                            Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                        }
                    }
                    if model.searching {
                        HStack { ProgressView().controlSize(.small); Text("Finding files it left around…").foregroundStyle(.secondary) }
                    } else {
                        Text("Will move to the Trash").font(.headline)
                        List {
                            HStack { Toggle("", isOn: .constant(true)).disabled(true).labelsHidden(); Text(app.url.lastPathComponent); Spacer(); Text(model.appSize.byteString).foregroundStyle(.secondary) }
                            ForEach($model.leftovers) { $l in
                                HStack {
                                    Toggle("", isOn: $l.include).labelsHidden()
                                    Text(l.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(l.size.byteString).foregroundStyle(.secondary)
                                    Button { l.url.reveal() } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        let total = model.appSize + model.leftovers.filter(\.include).reduce(0) { $0 + $1.size }
                        HStack {
                            Text("\(total.byteString) in total").foregroundStyle(.secondary)
                            Spacer()
                            Button("Uninstall \(app.name)…") { confirm = true }.buttonStyle(.borderedProminent).tint(.red)
                        }
                    }
                } else {
                    ContentUnavailableView("Choose an App", systemImage: "xmark.app", description: Text("Pick an app on the left, or drop one here."))
                }
            }
        }
        .onAppear { model.load() }
        .receivesFiles(for: "uninstall") { urls in if let url = urls.first(where: { $0.pathExtension == "app" }) { model.select(MacKit.AppInfo(url: url)) } }
        .alert("Uninstall \(model.selected?.name ?? "")?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { Task { await model.uninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app and the selected files go to the Trash. If it's running, it will be quit first.")
        }
    }
}

// MARK: - Presentation Mode

@MainActor @Observable
final class PresentationMode {
    static let shared = PresentationMode()
    var on = UserDefaults.standard.bool(forKey: "presentation.on")
    var hideIcons = true
    var hideDock = true
    var stayAwake = true

    func set(_ enable: Bool) async {
        let d = UserDefaults.standard
        if enable {
            d.set(await MacKit.defaults(["read", "com.apple.finder", "CreateDesktop"]), forKey: "presentation.prevIcons")
            d.set(await MacKit.defaults(["read", "com.apple.dock", "autohide"]), forKey: "presentation.prevDock")
            if hideIcons { _ = await MacKit.defaults(["write", "com.apple.finder", "CreateDesktop", "-bool", "false"]); _ = try? await Shell.run("/usr/bin/killall", ["Finder"]) }
            if hideDock { _ = await MacKit.defaults(["write", "com.apple.dock", "autohide", "-bool", "true"]); _ = try? await Shell.run("/usr/bin/killall", ["Dock"]) }
            if stayAwake { KeepAwake.shared.start(.indefinitely) }
        } else {
            let icons = d.string(forKey: "presentation.prevIcons") ?? ""
            let dock = d.string(forKey: "presentation.prevDock") ?? ""
            if icons == "0" || icons == "false" { _ = await MacKit.defaults(["write", "com.apple.finder", "CreateDesktop", "-bool", "false"]) }
            else { _ = await MacKit.defaults(["delete", "com.apple.finder", "CreateDesktop"]) }
            _ = await MacKit.defaults(["write", "com.apple.dock", "autohide", "-bool", dock == "1" ? "true" : "false"])
            _ = try? await Shell.run("/usr/bin/killall", ["Finder"])
            _ = try? await Shell.run("/usr/bin/killall", ["Dock"])
            KeepAwake.shared.stop()
        }
        on = enable
        d.set(enable, forKey: "presentation.on")
    }
}

struct PresentationModeView: View {
    @Bindable private var mode = PresentationMode.shared
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: mode.on ? "rectangle.on.rectangle.circle.fill" : "rectangle.on.rectangle.circle").font(.system(size: 44))
                    .foregroundStyle(mode.on ? Color.accentColor : .secondary)
                VStack(alignment: .leading) {
                    Text(mode.on ? "Presentation Mode is on" : "Presentation Mode is off").font(.title2.weight(.semibold))
                    Text("One switch before you share your screen or present.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(mode.on ? "Turn Off" : "Turn On") {
                    busy = true
                    Task { await mode.set(!mode.on); busy = false }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
            }
            Form {
                Toggle("Hide desktop icons", isOn: $mode.hideIcons)
                Toggle("Hide the Dock", isOn: $mode.hideDock)
                Toggle("Keep the Mac awake", isOn: $mode.stayAwake)
            }
            .formStyle(.grouped)
            .disabled(mode.on)
            Text("Turning it off puts everything back the way it was. For notifications, turn on a Focus in Control Center.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Eject All Disks

struct EjectView: View {
    struct Volume: Identifiable {
        let url: URL
        let name: String
        let size: Int64
        let kind: String
        var id: URL { url }
    }

    @State private var volumes: [Volume] = []
    @State private var results: [String] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { ejectAll() } label: { Label("Eject All", systemImage: "eject.fill").padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(volumes.isEmpty || working)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Refresh") { load() }
                if working { ProgressView().controlSize(.small) }
                Spacer()
            }
            ForEach(results, id: \.self) { Text($0).foregroundStyle($0.hasPrefix("✓") ? Color.green : .red) }
            if volumes.isEmpty {
                ContentUnavailableView("Nothing to Eject", systemImage: "externaldrive.badge.checkmark", description: Text("No external drives, cards or disk images are mounted."))
            } else {
                ForEach(volumes) { v in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: v.url.path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading) {
                            Text(v.name).font(.body.weight(.medium))
                            Text("\(v.kind) · \(v.size.byteString)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { eject([v]) } label: { Image(systemName: "eject") }.buttonStyle(.borderless).help("Eject \(v.name)")
                    }
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Spacer()
        }
        .onAppear(perform: load)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in load() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in load() }
    }

    private func load() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeNameKey,
                                      .volumeTotalCapacityKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true,
                  !url.path.hasPrefix("/System/Volumes") else { return nil }
            let external = v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsInternal == false || v.volumeIsLocal == false
            guard external else { return nil }
            let kind = v.volumeIsLocal == false ? "Network" : v.volumeIsInternal == true && v.volumeIsEjectable == true ? "Disk image" : "External drive"
            return Volume(url: url, name: v.volumeName ?? url.lastPathComponent, size: Int64(v.volumeTotalCapacity ?? 0), kind: kind)
        }
    }

    private func ejectAll() { eject(volumes) }

    private func eject(_ list: [Volume]) {
        working = true
        results = []
        Task {
            for v in list {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
                    results.append("✓ Ejected \(v.name)")
                } catch {
                    results.append("✗ \(v.name) is in use — quit the apps using it and try again")
                }
            }
            working = false
            load()
        }
    }
}
