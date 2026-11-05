import AppKit
import SwiftUI

/// Spotlight-style launcher opened with ⌃⌥Space from any app: type, arrow, Return.
@MainActor
final class QuickOpenPanel {
    static let shared = QuickOpenPanel()

    private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(size: NSSize(width: 620, height: 420))
        panel.contentView = NSHostingView(rootView: QuickOpenView(close: { [weak self] in self?.close() }))
        return panel
    }()

    func toggle() {
        if panel.isVisible { close() } else { show() }
    }

    func show() {
        NotificationCenter.default.post(name: QuickOpenView.reset, object: nil)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.18))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.orderOut(nil) }
}

/// Borderless panel that can take keyboard focus without activating the app first.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)   // clicking elsewhere dismisses it, like Spotlight
    }
}

struct QuickOpenView: View {
    static let reset = Notification.Name("QuickOpenView.reset")
    let close: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    private var model: AppModel { .shared }

    private var results: [Tool] {
        if query.isEmpty {
            let pinned = (model.favorites + model.recents).compactMap(ToolRegistry.tool)
            var seen = Set<String>()
            let unique = pinned.filter { seen.insert($0.id).inserted }
            return unique.isEmpty ? Array(ToolRegistry.all.prefix(8)) : Array(unique.prefix(8))
        }
        return Array(ToolRegistry.search(query).prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Open a tool…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(.horizontal, 18).frame(height: 56)
            Divider()
            if results.isEmpty {
                Text("No tools match “\(query)”").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 2) {
                    if query.isEmpty {
                        Text(model.favorites.isEmpty && model.recents.isEmpty ? "Tools" : "Favorites & Recent")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 4)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, tool in
                        row(tool, selected: i == index)
                            .onTapGesture { index = i; openSelected() }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
            }
            Divider()
            HStack(spacing: 14) {
                Text("↩ Open").font(.caption)
                Text("↑↓ Move").font(.caption)
                Text("esc Close").font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).frame(height: 30)
        }
        .frame(width: 620, height: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onChange(of: query) { index = 0 }
        .onReceive(NotificationCenter.default.publisher(for: Self.reset)) { _ in
            query = ""
            index = 0
            focused = true
        }
        .onAppear { focused = true }
    }

    private func row(_ tool: Tool, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: tool.symbol)
                .foregroundStyle(selected ? Color.white : tool.category.tint)
                .frame(width: 28, height: 28)
                .background((selected ? Color.white.opacity(0.2) : tool.category.tint.opacity(0.14)), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title).font(.body.weight(.medium))
                Text(tool.summary).font(.caption).lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            }
            Spacer()
            Text(tool.category.rawValue).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
        }
        .foregroundStyle(selected ? Color.white : .primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        index = (index + delta + results.count) % results.count
    }

    private func openSelected() {
        guard results.indices.contains(index) else { return }
        let tool = results[index]
        close()
        model.open(tool.id)
    }
}

// MARK: - Toast

/// Small heads-up message that fades out, for results that happen outside the window
/// (Capture Text from the shortcut, a copied color).
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        let view = HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3)
            Text(message).font(.body.weight(.medium)).lineLimit(2)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()

        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 24, width: size.width, height: size.height), display: true)
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
