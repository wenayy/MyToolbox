import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Clean Keyboard

@MainActor
final class KeyboardLock {
    static let shared = KeyboardLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var windows: [NSWindow] = []
    private var timer: Task<Void, Never>?

    var isLocked: Bool { tap != nil }

    /// Swallows every key press (including media keys) for `seconds`. The mouse still works to stop early.
    func lock(seconds: Int, blackScreen: Bool) -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in KeyboardLock.shared.reenable() }
                return Unmanaged.passUnretained(event)
            }
            // Escape hatch: ⌥⌘L (or holding Escape for a second) unlocks.
            if type == .keyDown {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                if code == 37 && flags.contains(.maskCommand) && flags.contains(.maskAlternate) {
                    Task { @MainActor in KeyboardLock.shared.unlock() }
                } else if code == 53 && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                    Task { @MainActor in KeyboardLock.shared.unlock() }
                }
            }
            return nil   // drop the key
        }, userInfo: nil) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        showOverlay(seconds: seconds, black: blackScreen)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(seconds)))
            if !Task.isCancelled { self?.unlock() }
        }
        return true
    }

    func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    func unlock() {
        timer?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSCursor.unhide()
    }

    private func showOverlay(seconds: Int, black: Bool) {
        let end = Date().addingTimeInterval(Double(seconds))
        for screen in NSScreen.screens {
            let w = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.backgroundColor = black ? .black : NSColor.black.withAlphaComponent(0.55)
            w.isOpaque = black
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: KeyboardLockOverlay(end: end, black: black) { KeyboardLock.shared.unlock() })
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate()
    }
}

/// Borderless windows can't take clicks on their buttons unless they can become key.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct KeyboardLockOverlay: View {
    let end: Date
    let black: Bool
    let done: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 18) {
                Image(systemName: "keyboard").font(.system(size: 54)).foregroundStyle(.white.opacity(black ? 0.35 : 0.9))
                Text("Keyboard paused — wipe away").font(.title.weight(.semibold)).foregroundStyle(.white.opacity(black ? 0.45 : 1))
                Text("\(Int(max(0, end.timeIntervalSince(ctx.date)))) s").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white.opacity(black ? 0.45 : 1))
                Button("I'm Done") { done() }.controlSize(.extraLarge).buttonStyle(.borderedProminent)
                Text("Click anywhere, or press ⌥⌘L, to finish early").foregroundStyle(.white.opacity(black ? 0.4 : 0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { done() }
        }
    }
}

struct CleanKeyboardView: View {
    @AppStorage("clean.seconds") private var seconds = 60
    @AppStorage("clean.black") private var black = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AccessibilityBanner(feature: "Clean Keyboard")
            HStack(spacing: 14) {
                Image(systemName: "keyboard").font(.system(size: 40)).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Pause the keyboard while you clean it").font(.title2.weight(.semibold))
                    Text("Every key is ignored until the timer ends. Click anywhere or press ⌥⌘L to finish early.").foregroundStyle(.secondary)
                }
            }
            Picker("Pause for", selection: $seconds) { Text("30 seconds").tag(30); Text("1 minute").tag(60); Text("2 minutes").tag(120) }
                .pickerStyle(.segmented).fixedSize()
            Toggle("Black screen, so smudges on the display show up", isOn: $black)
            Button {
                if !AccessibilityAccess.granted { AccessibilityAccess.request(); error = "Allow Accessibility access first, then try again."; return }
                error = KeyboardLock.shared.lock(seconds: seconds, blackScreen: black) ? nil : "macOS didn't allow pausing the keyboard."
            } label: { Label("Start Cleaning", systemImage: "sparkles").padding(.horizontal, 6) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if let error { ErrorText(message: error) }
            Spacer()
        }
    }
}

// MARK: - Dead Pixel Test

@MainActor
final class PixelTest {
    static let shared = PixelTest()
    static let colors: [(String, NSColor)] = [("White", .white), ("Black", .black), ("Red", .red), ("Green", .green), ("Blue", .blue),
                                               ("Gray", NSColor(white: 0.5, alpha: 1)), ("Cyan", .cyan), ("Magenta", .magenta), ("Yellow", .yellow)]
    private var windows: [NSWindow] = []
    private var monitor: Any?
    private var index = 0

    func start() {
        stop()
        index = 0
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isOpaque = true
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate()
        NSCursor.hide()
        apply()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                switch event.keyCode {
                case 53: self.stop()                       // Escape
                case 123, 126: self.step(-1)                // ← ↑
                default: self.step(1)                       // → ↓ Space Return…
                }
            } else {
                self.step(event.type == .rightMouseDown ? -1 : 1)
            }
            return nil
        }
    }

    private func step(_ d: Int) {
        index = (index + d + Self.colors.count) % Self.colors.count
        apply()
    }

    private func apply() {
        let (name, color) = Self.colors[index]
        for w in windows {
            w.backgroundColor = color
            let label = NSHostingView(rootView: Text("\(name) · click or → for next · Esc to finish")
                .font(.caption).padding(6).foregroundStyle(.gray).opacity(index == 0 ? 0.8 : 0.5))
            label.frame = NSRect(x: 0, y: 0, width: w.frame.width, height: 30)
            w.contentView = NSView()
            w.contentView?.addSubview(label)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSCursor.unhide()
    }
}

struct DeadPixelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Every display fills with one solid colour at a time.").font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Label("Dead pixels stay black on white and colours", systemImage: "circle.fill")
                Label("Stuck pixels stay one colour, like red or green", systemImage: "circle.lefthalf.filled")
                Label("Hot pixels glow on black", systemImage: "sun.max")
                Label("Bright patches at the edges on black are backlight bleed", systemImage: "rectangle.dashed")
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(PixelTest.colors, id: \.0) { _, c in RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: c)).frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator)) }
            }
            Button { PixelTest.shared.start() } label: { Label("Start Test", systemImage: "play.fill").padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: .command)
            Text("Click or press → for the next colour, ← to go back, Esc to finish.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Login & Background Items

struct LaunchItem: Identifiable, Hashable {
    let plist: URL
    let label: String
    let program: String
    let scope: Scope
    var developer: String?
    var enabled: Bool
    var id: URL { plist }

    enum Scope: String { case user = "Your account", allUsers = "All users", system = "System (background)" }
}

@MainActor @Observable
final class LoginItemsModel {
    static let shared = LoginItemsModel()
    var items: [LaunchItem] = []
    var loginApps: [String] = []
    var loading = false
    var message: String?

    func load() {
        loading = true
        Task {
            let found = await Task.detached { Self.scan() }.value
            items = found
            let r = try? await Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get the name of every login item"])
            loginApps = (r?.out ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            loading = false
            // Who made each one, filled in as codesign answers.
            for i in items.indices {
                let program = items[i].program
                let dev = await Self.developer(of: program)
                if i < items.count { items[i].developer = dev }
            }
        }
    }

    nonisolated static func scan() -> [LaunchItem] {
        let uid = getuid()
        let dirs: [(String, LaunchItem.Scope)] = [(MacKit.home.appendingPathComponent("Library/LaunchAgents").path, .user),
                                                  ("/Library/LaunchAgents", .allUsers), ("/Library/LaunchDaemons", .system)]
        let disabledUser = Self.disabledLabels(domain: "gui/\(uid)")
        let disabledSystem = Self.disabledLabels(domain: "system")
        var out: [LaunchItem] = []
        for (dir, scope) in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".plist") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
                guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? file.replacingOccurrences(of: ".plist", with: "")
                let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first ?? ""
                let disabled = (scope == .system ? disabledSystem : disabledUser).contains(label) || (dict["Disabled"] as? Bool ?? false)
                out.append(LaunchItem(plist: url, label: label, program: program, scope: scope, enabled: !disabled))
            }
        }
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    nonisolated static func disabledLabels(domain: String) -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print-disabled", domain]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var set = Set<String>()
        for line in out.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let label = line.split(separator: "\"").dropFirst().first { set.insert(String(label)) }
        }
        return set
    }

    static func developer(of program: String) async -> String? {
        guard !program.isEmpty, FileManager.default.fileExists(atPath: program),
              let r = try? await Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", program]) else { return nil }
        let lines = r.err.split(separator: "\n")
        if let authority = lines.first(where: { $0.hasPrefix("Authority=") }) {
            return authority.replacingOccurrences(of: "Authority=", with: "")
                .replacingOccurrences(of: "Developer ID Application: ", with: "").replacingOccurrences(of: "Apple Development: ", with: "")
        }
        return lines.contains { $0.contains("adhoc") } ? "Not signed by a developer" : nil
    }

    func setEnabled(_ item: LaunchItem, _ enable: Bool) async {
        let uid = getuid()
        do {
            switch item.scope {
            case .user, .allUsers:
                let domain = "gui/\(uid)"
                if enable {
                    _ = try await Shell.run("/bin/launchctl", ["enable", "\(domain)/\(item.label)"])
                    _ = try await Shell.run("/bin/launchctl", ["bootstrap", domain, item.plist.path])
                } else {
                    _ = try await Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"])
                    _ = try await Shell.run("/bin/launchctl", ["disable", "\(domain)/\(item.label)"])
                }
            case .system:
                let cmd = enable
                    ? "launchctl enable system/\(item.label); launchctl bootstrap system '\(item.plist.path)'"
                    : "launchctl bootout system/\(item.label); launchctl disable system/\(item.label)"
                try await MacKit.runAsAdmin(cmd)
            }
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].enabled = enable }
            message = "\(enable ? "Turned on" : "Turned off") \(item.label)"
        } catch is CancellationError {
        } catch {
            message = error.localizedDescription
        }
    }
}

struct LoginItemsView: View {
    @Bindable private var model = LoginItemsModel.shared
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open Login Items Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                Button("Refresh") { model.load() }
            }
            if let message = model.message { Banner(symbol: "info.circle", message: message, tint: .blue) }
            if !model.loginApps.isEmpty {
                Text("Apps That Open at Login").font(.headline)
                Text(model.loginApps.joined(separator: " · ")).foregroundStyle(.secondary)
            }
            Text("Background Items").font(.headline)
            Table(model.items.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || ($0.developer ?? "").localizedCaseInsensitiveContains(query) }) {
                TableColumn("On") { item in
                    Toggle("", isOn: Binding(get: { item.enabled }, set: { v in Task { await model.setEnabled(item, v) } })).labelsHidden()
                }
                .width(34)
                TableColumn("Item") { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).lineLimit(1)
                        Text(item.program).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                TableColumn("Made by") { Text($0.developer ?? "—").foregroundStyle(.secondary).lineLimit(1) }.width(min: 120, ideal: 200)
                TableColumn("Runs for") { Text($0.scope.rawValue).foregroundStyle(.secondary) }.width(130)
                TableColumn("") { item in
                    Button { item.plist.reveal() } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show its file in Finder")
                }
                .width(26)
            }
            Text("Items for all users or the system ask for your password before changing.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if model.items.isEmpty { model.load() } }
    }
}

// MARK: - Fix "App Is Damaged"

struct AppCheck {
    var signedBy = "Unknown"
    var team: String?
    var notarized = false
    var gatekeeper = ""
    var quarantined = false

    static func run(_ app: URL) async -> AppCheck {
        var c = AppCheck()
        if let r = try? await Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path]) {
            let lines = r.err.split(separator: "\n")
            if let a = lines.first(where: { $0.hasPrefix("Authority=") }) { c.signedBy = String(a.dropFirst("Authority=".count)) }
            else if r.err.contains("not signed") { c.signedBy = "Not signed" }
            else if r.err.contains("adhoc") { c.signedBy = "Signed locally (ad-hoc), no developer" }
            c.team = lines.first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        }
        if let r = try? await Shell.run("/usr/sbin/spctl", ["-a", "-vv", "-t", "exec", app.path]) {
            c.gatekeeper = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            c.notarized = r.err.contains("Notarized")
        }
        if let r = try? await Shell.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", app.path]) { c.quarantined = r.ok }
        return c
    }
}

struct FixDamagedView: View {
    @State private var app: URL?
    @State private var check: AppCheck?
    @State private var message: String?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DropZone(prompt: "Drop the app that won't open, or click to choose it", types: [.applicationBundle], multiple: false,
                     urls: Binding(get: { app.map { [$0] } ?? [] }, set: { app = $0.first; Task { await inspect() } }))
            if let app, let c = check {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 48, height: 48)
                    Text(app.deletingPathExtension().lastPathComponent).font(.title2.weight(.semibold))
                }
                ValueRow(label: "Made by", value: c.signedBy + (c.team.map { " (\($0))" } ?? ""))
                ValueRow(label: "Notarized by Apple", value: c.notarized ? "Yes" : "No")
                ValueRow(label: "Downloaded flag", value: c.quarantined ? "Set (this is what blocks it)" : "Not set")
                if !c.gatekeeper.isEmpty { Text(c.gatekeeper).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                if !c.notarized {
                    Banner(symbol: "exclamationmark.shield", message: "Only continue if you trust where this app came from. Apple hasn't checked it.")
                }
                HStack {
                    Button("Clear Quarantine & Open") { Task { await fix(resign: false) } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Re-sign Locally") { Task { await fix(resign: true) } }
                        .help("For apps macOS still calls damaged after clearing the flag: signs it for this Mac only")
                }
            }
            if let message { Text(message).foregroundStyle(message.hasPrefix("✓") ? Color.green : .red) }
            Spacer()
        }
        .receivesFiles(for: "fixdamaged") { urls in app = urls.first; Task { await inspect() } }
    }

    private func inspect() async {
        guard let app else { check = nil; return }
        message = nil
        check = await AppCheck.run(app)
    }

    private func fix(resign: Bool) async {
        guard let app else { return }
        var cmd = "xattr -dr com.apple.quarantine '\(app.path)'"
        if resign { cmd += " && codesign --force --deep --sign - '\(app.path)'" }
        let direct = try? await Shell.run("/bin/sh", ["-c", cmd])
        if direct?.ok != true {
            do { try await MacKit.runAsAdmin(cmd) } catch is CancellationError { return } catch {
                message = error.localizedDescription
                return
            }
        }
        await inspect()
        message = "✓ Done — opening \(app.deletingPathExtension().lastPathComponent)"
        NSWorkspace.shared.open(app)
    }
}

// MARK: - Reset Permissions

struct ResetPermissionsView: View {
    static let services: [(String, String)] = [
        ("All", "Everything"), ("ScreenCapture", "Screen & System Audio Recording"), ("Microphone", "Microphone"), ("Camera", "Camera"),
        ("Accessibility", "Accessibility"), ("ListenEvent", "Input Monitoring"), ("SystemPolicyAllFiles", "Full Disk Access"),
        ("AppleEvents", "Automation"), ("Photos", "Photos"), ("AddressBook", "Contacts"), ("Calendar", "Calendars"),
        ("Reminders", "Reminders"), ("BluetoothAlways", "Bluetooth"), ("SystemPolicyDesktopFolder", "Desktop Folder"),
        ("SystemPolicyDocumentsFolder", "Documents Folder"), ("SystemPolicyDownloadsFolder", "Downloads Folder"),
    ]
    @State private var apps: [MacKit.AppInfo] = []
    @State private var query = ""
    @State private var selected: MacKit.AppInfo?
    @State private var service = "All"
    @State private var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
                List(apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, selection: Binding(get: { selected?.url }, set: { url in
                    selected = apps.first { $0.url == url }
                    message = nil
                })) { app in
                    HStack { Image(nsImage: app.icon).resizable().frame(width: 20, height: 20); Text(app.name) }.tag(app.url)
                }
            }
            .frame(width: 280)
            VStack(alignment: .leading, spacing: 14) {
                if let app = selected, let id = app.bundleID {
                    HStack(spacing: 12) {
                        Image(nsImage: app.icon).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading) { Text(app.name).font(.title2.weight(.semibold)); Text(id).foregroundStyle(.secondary) }
                    }
                    Picker("Permission", selection: $service) { ForEach(Self.services, id: \.0) { Text($0.1).tag($0.0) } }.frame(maxWidth: 360)
                    Button("Reset \(Self.services.first { $0.0 == service }?.1 ?? service)") {
                        Task {
                            let r = try? await Shell.run("/usr/bin/tccutil", ["reset", service, id])
                            message = r?.ok == true ? "✓ Reset. \(app.name) will ask again the next time it needs it — you may need to quit and reopen it."
                                                    : (r?.err.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Couldn't reset")
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if let message { Text(message).foregroundStyle(message.hasPrefix("✓") ? Color.green : .red) }
                } else {
                    ContentUnavailableView("Choose an App", systemImage: "hand.raised", description: Text("Pick the app whose permission is stuck."))
                }
                Spacer()
            }
        }
        .onAppear { if apps.isEmpty { apps = MacKit.installedApps() } }
        .receivesFiles(for: "resetperms") { urls in if let u = urls.first { selected = MacKit.AppInfo(url: u) } }
    }
}

// MARK: - Hidden Settings

struct HiddenSetting: Identifiable {
    let id: String
    let title: String
    let detail: String
    let domain: String
    let key: String
    /// Value written when on; off deletes the key (back to the macOS default) unless `offValue` is set.
    let on: [String]
    var offValue: [String]? = nil
    let restart: String?
    var extra: [(String, [String])] = []
}

struct HiddenSettingsView: View {
    static let settings: [HiddenSetting] = [
        HiddenSetting(id: "hidden", title: "Show hidden files in Finder", detail: "Dotfiles and system folders appear (⇧⌘. toggles them too)",
                      domain: "com.apple.finder", key: "AppleShowAllFiles", on: ["-bool", "true"], restart: "Finder"),
        HiddenSetting(id: "ext", title: "Show all file extensions", detail: "Always show .pdf, .jpg and so on",
                      domain: "NSGlobalDomain", key: "AppleShowAllExtensions", on: ["-bool", "true"], restart: "Finder"),
        HiddenSetting(id: "path", title: "Show the path bar in Finder", detail: "Where the current folder lives, at the bottom of each window",
                      domain: "com.apple.finder", key: "ShowPathbar", on: ["-bool", "true"], restart: "Finder"),
        HiddenSetting(id: "status", title: "Show the status bar in Finder", detail: "Item count and free space",
                      domain: "com.apple.finder", key: "ShowStatusBar", on: ["-bool", "true"], restart: "Finder"),
        HiddenSetting(id: "posix", title: "Show the full path in Finder titles", detail: "e.g. /Users/you/Documents",
                      domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", on: ["-bool", "true"], restart: "Finder"),
        HiddenSetting(id: "folders", title: "Keep folders on top", detail: "When sorting by name in Finder windows",
                      domain: "com.apple.finder", key: "_FXSortFoldersFirst", on: ["-bool", "true"], restart: "Finder"),
        HiddenSetting(id: "dockspeed", title: "Faster Dock auto-hide", detail: "The hidden Dock appears instantly",
                      domain: "com.apple.dock", key: "autohide-delay", on: ["-float", "0"], restart: "Dock",
                      extra: [("autohide-time-modifier", ["-float", "0.15"])]),
        HiddenSetting(id: "dim", title: "Dim hidden apps in the Dock", detail: "Apps you hid with ⌘H look translucent",
                      domain: "com.apple.dock", key: "showhidden", on: ["-bool", "true"], restart: "Dock"),
        HiddenSetting(id: "recents", title: "Hide recent apps in the Dock", detail: "No extra section of recently used apps",
                      domain: "com.apple.dock", key: "show-recents", on: ["-bool", "false"], restart: "Dock"),
        HiddenSetting(id: "shadow", title: "Screenshots without window shadows", detail: "Window captures (⇧⌘4, Space) have no big shadow",
                      domain: "com.apple.screencapture", key: "disable-shadow", on: ["-bool", "true"], restart: "SystemUIServer"),
        HiddenSetting(id: "jpg", title: "Save screenshots as JPEG", detail: "Smaller files than PNG",
                      domain: "com.apple.screencapture", key: "type", on: ["-string", "jpg"], restart: "SystemUIServer"),
        HiddenSetting(id: "dsstore", title: "No .DS_Store files on network and USB drives", detail: "Keeps shared drives clean",
                      domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", on: ["-bool", "true"], restart: nil,
                      extra: [("DSDontWriteUSBStores", ["-bool", "true"])]),
        HiddenSetting(id: "save", title: "Expanded save dialogs", detail: "Save panels open with the full folder browser",
                      domain: "NSGlobalDomain", key: "NSNavPanelExpandedStateForSaveMode", on: ["-bool", "true"], restart: nil),
        HiddenSetting(id: "repeat", title: "Key repeat instead of accent menu", detail: "Holding a key repeats it (apps need a restart)",
                      domain: "NSGlobalDomain", key: "ApplePressAndHoldEnabled", on: ["-bool", "false"], restart: nil),
    ]

    @State private var values: [String: Bool] = [:]
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message { Banner(symbol: "checkmark.circle", message: message, tint: .green) }
            Form {
                ForEach(Self.settings) { s in
                    Toggle(isOn: Binding(get: { values[s.id] ?? false }, set: { v in Task { await apply(s, v) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title)
                            Text(s.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task { await read() }
    }

    private func read() async {
        for s in Self.settings {
            let v = await MacKit.defaults(["read", s.domain, s.key])
            let onValue = s.on.last ?? "true"
            let normalized = v == "1" ? "true" : v == "0" ? "false" : v
            values[s.id] = !v.isEmpty && (normalized == onValue || (onValue == "0" && Double(v) == 0))
        }
    }

    private func apply(_ s: HiddenSetting, _ on: Bool) async {
        if on {
            _ = await MacKit.defaults(["write", s.domain, s.key] + s.on)
            for (k, v) in s.extra { _ = await MacKit.defaults(["write", s.domain, k] + v) }
        } else {
            _ = await MacKit.defaults(["delete", s.domain, s.key])
            for (k, _) in s.extra { _ = await MacKit.defaults(["delete", s.domain, k]) }
        }
        if let app = s.restart { _ = try? await Shell.run("/usr/bin/killall", [app]) }
        values[s.id] = on
        message = "\(on ? "Turned on" : "Turned off"): \(s.title)"
    }
}

// MARK: - Display Control

/// Built-in brightness via DisplayServices; external monitors over DDC/CI with m1ddc.
enum Displays {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    static func builtInBrightness(_ id: CGDirectDisplayID) -> Float? {
        guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        var v: Float = 0
        return unsafeBitCast(sym, to: GetFn.self)(id, &v) == 0 ? v : nil
    }

    static func setBuiltInBrightness(_ id: CGDirectDisplayID, _ value: Float) {
        guard let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(sym, to: SetFn.self)(id, value)
    }

    struct Screen: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let builtIn: Bool
        let index: Int   // m1ddc display number for externals (1-based)
    }

    static func screens() -> [Screen] {
        var external = 0
        return NSScreen.screens.compactMap { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            if !builtIn { external += 1 }
            return Screen(id: id, name: s.localizedName, builtIn: builtIn, index: builtIn ? 0 : external)
        }
    }

    static func ddcGet(_ what: String, display: Int) async -> Double? {
        guard let m = Shell.which("m1ddc"), let r = try? await Shell.run(m, ["display", String(display), "get", what]) else { return nil }
        return Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func ddcSet(_ what: String, _ value: Int, display: Int) async {
        guard let m = Shell.which("m1ddc") else { return }
        _ = try? await Shell.run(m, ["display", String(display), "set", what, String(value)])
    }
}

struct DisplayControlView: View {
    @State private var screens = Displays.screens()
    @State private var builtIn: [CGDirectDisplayID: Double] = [:]
    @State private var ddc: [String: Double] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(screens) { s in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(s.name, systemImage: s.builtIn ? "laptopcomputer" : "display").font(.headline)
                        if s.builtIn {
                            slider("Brightness", "sun.max", value: Binding(get: { builtIn[s.id] ?? Double(Displays.builtInBrightness(s.id) ?? 0.5) },
                                                                          set: { builtIn[s.id] = $0; Displays.setBuiltInBrightness(s.id, Float($0)) }), range: 0...1)
                        } else if Shell.which("m1ddc") != nil {
                            ForEach([("luminance", "Brightness", "sun.max"), ("contrast", "Contrast", "circle.lefthalf.filled"), ("volume", "Volume", "speaker.wave.2")], id: \.0) { key, label, icon in
                                slider(label, icon, value: Binding(get: { ddc["\(s.index)-\(key)"] ?? 50 }, set: { v in
                                    ddc["\(s.index)-\(key)"] = v
                                    Task { await Displays.ddcSet(key, Int(v), display: s.index) }
                                }), range: 0...100)
                            }
                        } else {
                            Banner(symbol: "cable.connector", message: "External monitors are controlled over DDC with the free m1ddc tool. Install it in Terminal: brew install m1ddc") {
                                CopyButton(text: "brew install m1ddc", label: "Copy")
                            }
                        }
                    }
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Button("Sleep Displays Now") { Task { _ = try? await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) } }
                    Button("Refresh") { screens = Displays.screens(); Task { await loadDDC() } }
                }
                Text("Some monitors don't support DDC, or only over certain ports. Built-in brightness works on every Mac with a built-in display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await loadDDC() }
    }

    private func slider(_ label: String, _ icon: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Label(label, systemImage: icon).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
            Text(range.upperBound == 1 ? "\(Int(value.wrappedValue * 100))%" : "\(Int(value.wrappedValue))").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private func loadDDC() async {
        for s in screens where !s.builtIn {
            for key in ["luminance", "contrast", "volume"] {
                if let v = await Displays.ddcGet(key, display: s.index) { ddc["\(s.index)-\(key)"] = v }
            }
        }
    }
}

// MARK: - Mouse Fixes

/// Changes mouse-wheel scrolling (not the trackpad): reverse direction and/or speed it up. Needs Accessibility.
@MainActor
final class MouseFixer {
    static let shared = MouseFixer()
    nonisolated(unsafe) static var reverse = UserDefaults.standard.bool(forKey: "mouse.reverse")
    nonisolated(unsafe) static var speed = max(1, UserDefaults.standard.double(forKey: "mouse.speed"))
    private var tap: CFMachPort?

    var running: Bool { tap != nil }

    func update() {
        let needed = Self.reverse || Self.speed > 1.01
        if needed && tap == nil { start() } else if !needed && tap != nil { stop() }
    }

    func start() {
        guard AccessibilityAccess.granted, tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in if let t = MouseFixer.shared.tap { CGEvent.tapEnable(tap: t, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            // Continuous scroll = trackpad or Magic Mouse gestures; leave those alone.
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return Unmanaged.passUnretained(event) }
            let sign: Int64 = MouseFixer.reverse ? -1 : 1
            let speed = MouseFixer.speed
            let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((Double(lines * sign) * speed).rounded()))
            let points = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: points * Double(sign) * speed)
            let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed * Double(sign) * speed)
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
    }
}

struct MouseFixesView: View {
    @AppStorage("mouse.reverse") private var reverse = false
    @AppStorage("mouse.speed") private var speed = 1.0
    @State private var running = MouseFixer.shared.running

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccessibilityBanner(feature: "Mouse Fixes")
            Form {
                Section {
                    Toggle(isOn: $reverse) {
                        VStack(alignment: .leading) {
                            Text("Reverse the mouse wheel")
                            Text("The trackpad keeps its direction. Use this when Natural Scrolling feels wrong on a mouse.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Mouse wheel speed") {
                        HStack {
                            Slider(value: $speed, in: 1...5, step: 0.5)
                            Text(String(format: "%.1f×", speed)).monospacedDigit().frame(width: 40)
                        }
                    }
                } footer: {
                    Text(running ? "Active. MyToolbox needs to keep running (it lives in the menu bar)." : "Off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Trackpad") {
                    Button("Open Trackpad Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!) }
                    Text("The trackpad follows the system's Natural Scrolling setting.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Spacer()
        }
        .onChange(of: reverse) { apply() }
        .onChange(of: speed) { apply() }
    }

    private func apply() {
        MouseFixer.reverse = reverse
        MouseFixer.speed = speed
        if (reverse || speed > 1.01) && !AccessibilityAccess.granted { AccessibilityAccess.request() }
        MouseFixer.shared.update()
        running = MouseFixer.shared.running
    }
}
