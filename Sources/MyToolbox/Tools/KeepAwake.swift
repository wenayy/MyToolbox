import AppKit
import IOKit
import IOKit.pwr_mgt
import Observation
import SwiftUI

// MARK: - Keep Awake

/// Holds a power assertion so the Mac doesn't go to sleep on its own. It never *makes* the Mac sleep: when it ends,
/// macOS goes back to its usual settings and sleeps only once the Mac has been left alone for the time set there.
@MainActor @Observable
final class KeepAwake {
    static let shared = KeepAwake()

    enum Mode: Equatable {
        /// A fixed time from now, even while nobody is at the Mac (downloads, renders).
        case forTime(TimeInterval)
        /// Until nobody has used the keyboard, mouse or trackpad for this long; every touch starts the wait again.
        case untilAway(TimeInterval)
        /// Until a time of day.
        case until(Date)
        /// While an app is open.
        case whileAppOpen(bundleID: String, name: String)
        case indefinitely
    }

    private(set) var mode: Mode?
    /// The end, for modes that have one.
    private(set) var deadline: Date?
    /// Seconds since the keyboard, mouse or trackpad was last used (refreshed while active).
    private(set) var idle: TimeInterval = 0
    var active: Bool { mode != nil }
    var keepDisplayOn = true

    /// Seconds since the person last used the Mac, and whether an app is running; replaceable in tests.
    @ObservationIgnored var idleSeconds: () -> TimeInterval = KeepAwake.systemIdleSeconds
    @ObservationIgnored var appIsRunning: (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var loop: Task<Void, Never>?

    static let assertionName = "MyToolbox Keep Awake"

    func start(_ mode: Mode) {
        stop()
        let now = Date()
        switch mode {
        case .forTime(let t): deadline = now.addingTimeInterval(t)
        case .until(let date): deadline = date
        default: deadline = nil
        }
        if let deadline, deadline <= now { return }
        guard takeAssertion() else { return }
        self.mode = mode
        // Stop App Nap from delaying the checks below while MyToolbox sits in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Keep Awake is on")
        idle = idleSeconds()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.check()
            }
        }
    }

    /// Adds time to a timed session.
    func extend(by t: TimeInterval) {
        guard let mode, let deadline else { return }
        let newDeadline = deadline.addingTimeInterval(t)
        switch mode {
        case .forTime: self.deadline = newDeadline
        case .until: self.mode = .until(newDeadline); self.deadline = newDeadline
        default: return
        }
        _ = takeAssertion()   // renews the system-side timeout
    }

    func stop() {
        loop?.cancel(); loop = nil
        releaseAssertion()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        mode = nil
        deadline = nil
    }

    /// Ends the session when its condition is met. Runs every second while active.
    func check(now: Date = Date()) {
        guard let mode else { return }
        idle = idleSeconds()
        let running: Bool
        if case .whileAppOpen(let id, _) = mode { running = appIsRunning(id) } else { running = true }
        if Self.shouldEnd(mode, deadline: deadline, idle: idle, appRunning: running, now: now) { stop() }
    }

    /// When a session is over. Pure, so it's testable.
    nonisolated static func shouldEnd(_ mode: Mode, deadline: Date?, idle: TimeInterval, appRunning: Bool, now: Date) -> Bool {
        switch mode {
        case .forTime, .until: return deadline.map { now >= $0 } ?? true
        case .untilAway(let limit): return idle >= limit
        case .whileAppOpen: return !appRunning
        case .indefinitely: return false
        }
    }

    /// When an "until away" session would end if nobody touches the Mac from now on.
    var awayEnds: Date? {
        guard case .untilAway(let limit) = mode else { return nil }
        return Date().addingTimeInterval(max(0, limit - idle))
    }

    /// The assertion carries its own timeout for timed sessions, so macOS ends it on time even if MyToolbox is busy.
    private func takeAssertion() -> Bool {
        releaseAssertion()
        var props: [String: Any] = [
            kIOPMAssertionTypeKey: (keepDisplayOn ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep) as String,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionNameKey: Self.assertionName,
        ]
        if let deadline {
            props[kIOPMAssertionTimeoutKey] = max(1, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            props[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
        }
        return IOPMAssertionCreateWithProperties(props as CFDictionary, &assertion) == kIOReturnSuccess
    }

    private func releaseAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    /// Seconds since the last keyboard, mouse or trackpad event, from the HID system (no permission needed).
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return 0 }
        return value.doubleValue / 1_000_000_000
    }
}

enum KeepAwakeKind: String, CaseIterable, Identifiable {
    case forTime = "For a set time", untilAway = "Until I'm away", until = "Until a time", whileApp = "While an app is open", forever = "Until I turn it off"
    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .forTime: "Stays awake for the whole time, even if nobody is at the Mac — for downloads, renders and backups."
        case .untilAway: "Stays awake while you use the Mac and for the time you choose after you stop. Every touch of the keyboard, mouse or trackpad starts the wait again."
        case .until: "Stays awake until the time you choose, even if nobody is at the Mac."
        case .whileApp: "Stays awake while the app is open — a render, a call, a game — and ends when you quit it."
        case .forever: "Stays awake until you turn it off here or in the menu bar."
        }
    }
}

struct KeepAwakeView: View {
    @Bindable private var awake = KeepAwake.shared
    @AppStorage("keepawake.kind") private var kind: KeepAwakeKind = .forTime
    @State private var untilTime = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
    @State private var apps: [NSRunningApplication] = []
    @State private var appID = ""
    private let durations: [(String, TimeInterval)] = [("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("5 hours", 18000)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            status
            Divider()
            Picker("Keep awake", selection: $kind) { ForEach(KeepAwakeKind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            Text(kind.explanation).foregroundStyle(.secondary)
            choices
            Toggle("Keep the display on too", isOn: $awake.keepDisplayOn).disabled(awake.active)
            Text("Keep Awake never puts your Mac to sleep. When it ends, your Mac goes back to its usual settings and sleeps only after it has been left alone for the time set in System Settings → Lock Screen — so if nobody used it during the session, the screen may turn off right away. Closing the lid still sleeps a MacBook unless it's connected to a display and power.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear(perform: loadApps)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 14) {
            Image(systemName: awake.active ? "cup.and.saucer.fill" : "cup.and.saucer").font(.system(size: 40))
                .foregroundStyle(awake.active ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(awake.active ? "Your Mac is staying awake" : "Your Mac sleeps normally").font(.title2.weight(.semibold))
                if awake.active {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(detail(now: ctx.date)).foregroundStyle(.secondary).monospacedDigit() }
                }
            }
            Spacer()
            if awake.active {
                if awake.deadline != nil { Button("+15 Minutes") { awake.extend(by: 900) } }
                Button("Turn Off") { awake.stop() }.controlSize(.large)
            }
        }
    }

    private func detail(now: Date) -> String {
        switch awake.mode {
        case .forTime, .until:
            guard let d = awake.deadline else { return "" }
            return "Until \(d.formatted(date: .omitted, time: .shortened)) · \(timecode(max(0, d.timeIntervalSince(now)))) left"
        case .untilAway(let limit):
            let away = awake.idle
            return away < 60
                ? "While you're using it · ends after \(minutes(limit)) away"
                : "Away for \(timecode(away)) · ends in \(timecode(max(0, limit - away))) unless you come back"
        case .whileAppOpen(_, let name): return "While \(name) is open"
        case .indefinitely: return "Until you turn it off"
        case nil: return ""
        }
    }

    private func minutes(_ t: TimeInterval) -> String {
        t >= 3600 ? "\(Int(t / 3600)) hour\(t >= 7200 ? "s" : "")" : "\(Int(t / 60)) minutes"
    }

    @ViewBuilder private var choices: some View {
        switch kind {
        case .forTime, .untilAway:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(durations, id: \.1) { label, seconds in
                    let mode: KeepAwake.Mode = kind == .forTime ? .forTime(seconds) : .untilAway(seconds)
                    let current = isCurrent(mode)
                    Button { current ? awake.stop() : awake.start(mode) } label: {
                        HStack(spacing: 6) {
                            if current { Image(systemName: "checkmark") }
                            Text(kind == .untilAway ? "\(label) away" : label)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                    .tint(current ? .orange : nil)
                    .help(current ? "Running — click to turn off" : "")
                }
            }
        case .until:
            HStack {
                DatePicker("Until", selection: $untilTime, displayedComponents: [.hourAndMinute, .date])
                    .fixedSize()
                Button("Start") { awake.start(.until(untilTime)) }.buttonStyle(.borderedProminent)
                    .disabled(untilTime <= Date())
            }
        case .whileApp:
            HStack {
                Picker("App", selection: $appID) {
                    Text("Choose an open app…").tag("")
                    ForEach(apps, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? "App").tag(app.bundleIdentifier ?? "")
                    }
                }
                .frame(maxWidth: 320)
                Button { loadApps() } label: { Image(systemName: "arrow.clockwise") }.help("Look for open apps again")
                Button("Start") {
                    let name = apps.first { $0.bundleIdentifier == appID }?.localizedName ?? "the app"
                    awake.start(.whileAppOpen(bundleID: appID, name: name))
                }
                .buttonStyle(.borderedProminent).disabled(appID.isEmpty)
            }
        case .forever:
            Button(awake.mode == .indefinitely ? "Turn Off" : "Keep Awake") {
                awake.mode == .indefinitely ? awake.stop() : awake.start(.indefinitely)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func isCurrent(_ mode: KeepAwake.Mode) -> Bool {
        switch (awake.mode, mode) {
        case (.untilAway(let a), .untilAway(let b)): a == b
        // A timed session counts as this button if it was started from it (ignoring +15 extensions).
        case (.forTime(let a), .forTime(let b)): a == b
        default: false
        }
    }

    private func loadApps() {
        let me = Bundle.main.bundleIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != me }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}
