import FoundationModels
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Helpers", systemImage: "shippingbox") { HelperSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(Output.rootKey) private var rootPath = ""
    @State private var loginItem = LoginItem.enabled
    @AppStorage("hoverOpens") private var hoverOpens = true
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Save results to") {
                    HStack {
                        Text(Output.root.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") {
                            if let url = FilePicker.choose(types: [], multiple: false, folders: true, files: false).first {
                                rootPath = url.path
                            }
                        }
                        if !rootPath.isEmpty { Button("Reset") { rootPath = "" } }
                    }
                }
                Text("Every tool saves here, so results are always in one place. Nothing is ever overwritten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open tools by hovering in the sidebar", isOn: $hoverOpens)
            }
            Section {
                Toggle("Open MyToolbox at login", isOn: $loginItem)
                    .onChange(of: loginItem) {
                        do { try LoginItem.set(loginItem); loginError = nil } catch {
                            loginError = error.localizedDescription
                            loginItem = LoginItem.enabled
                        }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
            }
            Section("Keyboard Shortcuts") {
                LabeledContent("Open any tool, from any app", value: "⌃⌥Space")
                LabeledContent("Capture text on screen", value: "⌃⌥T")
                LabeledContent("Quick Open in the window", value: "⌘K")
                LabeledContent("Run the current tool", value: "⌘↩")
                LabeledContent("Search tools", value: "⌘F")
                LabeledContent("Back / Forward", value: "⌘[  ⌘]")
                LabeledContent("Categories", value: "⌘1 … ⌘7")
                LabeledContent("All Tools / Saved Files", value: "⌘0  ⌘9")
            }
        }
        .formStyle(.grouped)
    }
}

private struct HelperSettings: View {
    @State private var versions: [String: String] = [:]
    @State private var updating = false
    @State private var updateLog = ""
    @Bindable private var helpers = Helpers.shared

    var body: some View {
        Form {
            Section {
                ForEach(Helpers.all) { h in
                    LabeledContent {
                        if helpers.installing.contains(h.id) {
                            ProgressView().controlSize(.small)
                        } else if !h.installed {
                            HelperInstallButton(helpers: [h])
                        } else {
                            Text(versions[h.id] ?? "Installed").foregroundStyle(.secondary).lineLimit(1)
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(h.cask ? "LibreOffice" : h.id).font(.body.monospaced())
                            Text(h.usedBy).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    if !helpers.installing.isEmpty || helpers.error != nil {
                        Text(helpers.error ?? helpers.log).font(.caption.monospaced())
                            .foregroundStyle(helpers.error == nil ? Color.secondary : Color.red).lineLimit(2)
                    }
                    Spacer()
                    if helpers.missing.count > 1 { HelperInstallButton(helpers: helpers.missing, title: "Install All Missing") }
                    Button(updating ? "Updating…" : "Update yt-dlp") { update() }.disabled(updating || Shell.which("yt-dlp") == nil)
                }
                if !updateLog.isEmpty { Text(updateLog).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3) }
            } header: {
                Text("Command-line helpers")
            } footer: {
                Text(Helpers.brew == nil
                     ? "Helpers are installed with Homebrew, the free package manager for the Mac. Get it at brew.sh, then come back."
                     : "Free, open-source programs installed with Homebrew. Sites change often — if a download fails, update yt-dlp first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On-device AI") {
                LabeledContent("Apple Intelligence", value: AIModel.statusText)
                Text("Summarize and Ask a Document run fully on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: helpers.installing) { await loadVersions() }
    }

    private func loadVersions() async {
        for h in Helpers.all where !h.cask {
            guard let exe = Shell.which(h.id) else { continue }
            let args = h.id == "ffmpeg" || h.id == "cwebp" ? ["-version"] : ["--version"]
            let out = (try? await Shell.run(exe, args))?.out ?? ""
            versions[h.id] = out.split(separator: "\n").first.map { String($0.prefix(40)) } ?? "Installed"
        }
    }

    private func update() {
        updating = true
        Task {
            updateLog = await YTDLP.update()
            versions["yt-dlp"] = nil
            await loadVersions()
            updating = false
        }
    }
}

/// Availability of the on-device Apple Intelligence model, in words a person understands.
enum AIModel {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var statusText: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Ready"
        case .unavailable(.deviceNotEligible): "Not supported on this Mac"
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady): "Downloading the model — try again soon"
        case .unavailable: "Unavailable"
        }
    }
}
