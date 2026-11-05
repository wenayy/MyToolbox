import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeys.register(key: kVK_Space, modifiers: controlKey | optionKey) { QuickOpenPanel.shared.toggle() }
        HotKeys.register(key: kVK_ANSI_T, modifiers: controlKey | optionKey) { CaptureText.run(showResult: false) }
        MouseFixer.shared.update()   // restore mouse-wheel fixes from last time
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.receive(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Shell.terminateAll()   // don't leave yt-dlp or ffmpeg running after quit
        KeepAwake.shared.stop()
        KeyboardLock.shared.unlock()
    }
}

/// System-wide shortcuts via Carbon (no Accessibility permission needed).
@MainActor
enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func register(key: Int, modifiers: Int, action: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let hotKeyID = id.id
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.actions[hotKeyID]?() } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4D54_4258), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
