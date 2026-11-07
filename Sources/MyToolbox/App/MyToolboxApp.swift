import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
struct MyToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("MyToolbox", id: "main") {
            RootView()
                .onAppear { AppModel.shared.openMainWindow = { openWindow(id: "main") } }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }

        MenuBarExtra("MyToolbox", systemImage: "wrench.and.screwdriver") {
            Button("Open MyToolbox") { AppModel.shared.showMainWindow() }
            Button("Quick Open…  ⌃⌥Space") { QuickOpenPanel.shared.toggle() }
            Button("Capture Text  ⌃⌥T") { CaptureText.run(showResult: false) }
            Button("Pick Color") { AppModel.shared.open("colorpicker") }
            Button(KeepAwake.shared.active ? "Stop Keeping Awake" : "Keep Awake for 1 Hour") {
                if KeepAwake.shared.active { KeepAwake.shared.stop() } else { KeepAwake.shared.start(.forTime(3600)) }
            }
            Divider()
            Button("Saved Files") { AppModel.shared.open(AppModel.saved) }
            Button("Show Output Folder") { NSWorkspace.shared.open(Output.root) }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit MyToolbox") { NSApp.terminate(nil) }
        }
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .newItem) {
            Button("Quick Open…") { QuickOpenPanel.shared.toggle() }
                .keyboardShortcut("k")
            Button("Open Files…") {
                let urls = FilePicker.choose(types: [.item], multiple: true, folders: true)
                AppModel.shared.receive(urls)
            }
            .keyboardShortcut("o")
            Divider()
            Button("Show Output Folder") { NSWorkspace.shared.open(Output.root) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Back") { AppModel.shared.goBack() }.keyboardShortcut("[")
            Button("Forward") { AppModel.shared.goForward() }.keyboardShortcut("]")
            Divider()
            Button("All Tools") { AppModel.shared.selection = AppModel.home }
                .keyboardShortcut("0")
            Button("Saved Files") { AppModel.shared.selection = AppModel.saved }
                .keyboardShortcut("9")
            Divider()
            ForEach(Array(ToolCategory.allCases.enumerated()), id: \.element) { index, category in
                Menu(category.rawValue) {
                    ForEach(ToolRegistry.tools(in: category)) { tool in
                        Button(tool.title) { AppModel.shared.open(tool.id) }
                    }
                }
            }
            Divider()
            // ⌘1…⌘7 jump to the first tool of each category.
            ForEach(Array(ToolCategory.allCases.enumerated()), id: \.element) { index, category in
                if let first = ToolRegistry.tools(in: category).first {
                    Button("First \(category.rawValue) Tool") { AppModel.shared.open(first.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Toolbox Website") { NSWorkspace.shared.open(URL(string: "https://mactoolbox.app")!) }
        }
    }
}
