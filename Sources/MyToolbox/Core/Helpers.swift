import AppKit
import SwiftUI

/// Free command-line programs some tools rely on, and installing them through Homebrew from inside the app.
struct Helper: Identifiable, Hashable {
    let id: String          // executable name
    let formula: String     // `brew install` argument
    let usedBy: String
    let essential: Bool     // shown on the home screen when missing
    var cask = false
    var installed: Bool { cask ? DocKit.appInstalled("LibreOffice") : Shell.which(id) != nil }
}

@MainActor @Observable
final class Helpers {
    static let shared = Helpers()

    static let all: [Helper] = [
        Helper(id: "ffmpeg", formula: "ffmpeg", usedBy: "Video and audio tools", essential: true),
        Helper(id: "yt-dlp", formula: "yt-dlp", usedBy: "Download Video", essential: true),
        Helper(id: "qpdf", formula: "qpdf", usedBy: "PDF passwords (stronger encryption)", essential: false),
        Helper(id: "pandoc", formula: "pandoc", usedBy: "Markdown conversions", essential: false),
        Helper(id: "cwebp", formula: "webp", usedBy: "Saving WebP images", essential: false),
        Helper(id: "soffice", formula: "libreoffice", usedBy: "Word, PowerPoint and Excel to PDF", essential: false, cask: true),
    ]

    static var brew: String? { Shell.which("brew") }
    var missing: [Helper] { _ = refreshTick; return Self.all.filter { !$0.installed } }
    var missingEssential: [Helper] { missing.filter(\.essential) }

    var installing: Set<String> = []
    var log = ""
    var error: String?
    private var refreshTick = 0

    func install(_ helpers: [Helper]) {
        guard let brew = Self.brew else { return }
        let formulae = helpers.filter { !$0.cask }.map(\.formula), casks = helpers.filter(\.cask).map(\.formula)
        installing.formUnion(helpers.map(\.id))
        error = nil
        log = "Starting Homebrew…"
        Task {
            var failed = false
            for (args, names) in [(["install"] + formulae, formulae), (["install", "--cask"] + casks, casks)] where !names.isEmpty {
                let code = (try? await Shell.stream(brew, args) { line in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if !l.isEmpty { Helpers.shared.log = String(l.prefix(160)) }
                }) ?? 1
                if code != 0 { failed = true }
            }
            installing.subtract(helpers.map(\.id))
            refreshTick += 1
            if failed { error = "Homebrew couldn't finish: \(log)" } else { log = "Installed." }
        }
    }
}

/// Lists the helpers with an install button; used in Settings and on the home screen.
struct HelperInstallButton: View {
    let helpers: [Helper]
    var title = "Install"
    @Bindable private var model = Helpers.shared

    var body: some View {
        if Helpers.brew != nil {
            Button(model.installing.isEmpty ? title : "Installing…") { model.install(helpers) }
                .disabled(!model.installing.isEmpty || helpers.isEmpty)
        } else {
            Button("Get Homebrew…") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                .help("MyToolbox installs its free helpers with Homebrew. Install Homebrew first, then come back.")
        }
    }
}

/// Shown on the home screen while the helpers most tools need are missing.
struct MissingHelpersBanner: View {
    @Bindable private var model = Helpers.shared
    @AppStorage("helpers.bannerDismissed") private var dismissed = false

    var body: some View {
        let missing = model.missingEssential
        if !missing.isEmpty && !dismissed {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A few tools need free helpers").font(.headline)
                    Text(model.installing.isEmpty
                         ? "\(missing.map(\.id).joined(separator: " and ")) — \(missing.map(\.usedBy).joined(separator: ", ")). Installed with Homebrew, about a minute."
                         : model.log)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    if let e = model.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                }
                Spacer()
                if !model.installing.isEmpty { ProgressView().controlSize(.small) }
                HelperInstallButton(helpers: missing).buttonStyle(.borderedProminent)
                Button { dismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide")
            }
            .padding(14)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
