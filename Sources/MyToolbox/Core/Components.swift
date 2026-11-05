import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Plain-text editor (no smart quotes / dashes, monospaced by default)

struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    var monospaced = true

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = !monospaced
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = monospaced ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
        tv.drawsBackground = false
        tv.string = text
        tv.isEditable = editable
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        if tv.string != text { tv.string = text }
        tv.isEditable = editable
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

/// Editor in a rounded box with a title row, optional accessory and a placeholder.
struct EditorBox<Accessory: View>: View {
    let title: String
    @Binding var text: String
    var editable = true
    var monospaced = true
    var placeholder = ""
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                accessory()
                if !text.isEmpty { CopyButton(text: text) }
            }
            .frame(minHeight: 22)
            ZStack(alignment: .topLeading) {
                CodeTextView(text: $text, editable: editable, monospaced: monospaced)
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary)
                        .font(monospaced ? .system(.body, design: .monospaced) : .body)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        }
    }
}

extension EditorBox where Accessory == EmptyView {
    init(title: String, text: Binding<String>, editable: Bool = true, monospaced: Bool = true, placeholder: String = "") {
        self.init(title: title, text: text, editable: editable, monospaced: monospaced, placeholder: placeholder) { EmptyView() }
    }
}

/// An editor's top bar. When the window is too narrow it scrolls sideways instead of pushing the page
/// wider than the window (which used to shift canvases off-screen).
struct ToolbarRow<Content: View, Trailing: View>: View {
    @ViewBuilder let content: () -> Content
    /// Always visible at the right edge (undo, save…), however narrow the window.
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            // Full labels when there's room, then icons only (names stay in tooltips), then scroll as a last resort.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { content() }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                HStack(spacing: 6) { content() }
                    .labelStyle(.iconOnly)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { content() }
                        .labelStyle(.iconOnly)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) { trailing() }
                .fixedSize()
                .padding(.trailing, 12)
        }
    }
}

extension ToolbarRow where Trailing == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.trailing = { EmptyView() }
    }
}

/// The row of controls at the top of a text tool.
struct ControlBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 12) { content() }
            .controlSize(.regular)
            .frame(minHeight: 28)
    }
}

// MARK: - Buttons & labels

struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? "Copied" : (label.isEmpty ? "Copy" : label), systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
        .help("Copy to the clipboard")
    }
}

struct ErrorText: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }
}

/// One labeled value row with a copy button.
struct ValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle)
            Spacer()
            CopyButton(text: value, label: "")
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

/// Inline notice with an optional action, e.g. "yt-dlp is 95 days old · Update".
struct Banner<Actions: View>: View {
    let symbol: String
    let message: String
    var tint: Color = .orange
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions()
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Banner where Actions == EmptyView {
    init(symbol: String, message: String, tint: Color = .orange) {
        self.init(symbol: symbol, message: message, tint: tint) { EmptyView() }
    }
}

// MARK: - File input

enum FilePicker {
    @MainActor
    static func choose(types: [UTType], multiple: Bool = true, folders: Bool = false, files: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = folders
        panel.canChooseFiles = files
        if files && !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Compact drop target for tools that take one or a few files next to other controls.
struct DropZone: View {
    var prompt = "Drop files here or click to choose"
    var types: [UTType] = [.item]
    var multiple = true
    var folders = false
    @Binding var urls: [URL]
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: choose) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.title3)
                    Text(prompt).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: urls.isEmpty ? 84 : 44)
                .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrop(of: FileDrop.types, isTargeted: $targeted) { providers in
                FileDrop.load(providers) { add($0) }
                return true
            }

            if !urls.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        HStack {
                            Thumbnail(url: url, size: 18)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if !url.isDirectory { Text(url.fileSize.byteString).font(.caption).foregroundStyle(.secondary) }
                            Button { urls.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Remove")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func choose() {
        add(FilePicker.choose(types: types, multiple: multiple, folders: folders, files: true))
    }

    private func add(_ new: [URL]) {
        let accepted = new.filter { url in
            if url.isDirectory { return folders }
            guard let type = UTType(filenameExtension: url.pathExtension) else { return types.contains(.item) || types.contains(.data) }
            return types.contains { type.conforms(to: $0) }
        }
        if multiple {
            urls.append(contentsOf: accepted.filter { !urls.contains($0) })
        } else if let first = accepted.first {
            urls = [first]
        }
    }
}

/// Lists produced files with Open / Show in Finder.
struct ResultList: View {
    let urls: [URL]

    var body: some View {
        if !urls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Saved \(urls.count) file\(urls.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }.controlSize(.small)
                }
                ForEach(urls.prefix(6), id: \.self) { url in
                    HStack {
                        Thumbnail(url: url, size: 18)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if !url.isDirectory { Text(url.fileSize.byteString).font(.caption).foregroundStyle(.secondary) }
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .draggableFile(url)
                    .help("Drag into Finder, Mail or any app")
                }
                if urls.count > 6 { Text("+ \(urls.count - 6) more").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(12)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Live preview that re-renders a downscaled copy of `url` whenever `key` changes.
struct RenderedPreview: View {
    let url: URL
    let key: String
    var maxPixel = 900
    let render: @Sendable (CGImage) throws -> CGImage
    @State private var image: NSImage?
    @State private var error: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(6)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 220)
        .task(id: "\(url.path)|\(key)") {
            try? await Task.sleep(for: .milliseconds(120))   // debounce slider drags
            if Task.isCancelled { return }
            let url = url, maxPixel = maxPixel, render = render
            do {
                let cg = try await offMain { try render(ImageKit.load(url, maxPixel: maxPixel)) }
                image = ImageKit.nsImage(cg)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
