import AppKit
import UniformTypeIdentifiers
import SwiftUI

// Renders the real window for every tool off-screen and saves PNGs plus contact sheets for review.
//   swiftc -O -swift-version 5 -o .build/snapshots $(find Sources/MyToolbox -name '*.swift' ! -name MyToolboxApp.swift) Tests/snapshots/main.swift
//   .build/snapshots <out dir> [width height] [dark] [files dir to drop into batch tools]
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "snapshots")
let width = args.count > 3 ? Double(args[2])! : 1180, height = args.count > 3 ? Double(args[3])! : 760
let dark = args.contains("dark")
let filesDir = args.last.flatMap { $0.hasPrefix("/") && $0 != args[1] ? URL(fileURLWithPath: $0) : nil }
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
// Keep the person's real settings and history out of it.
UserDefaults.standard.set(FileManager.default.temporaryDirectory.appendingPathComponent("snap-out").path, forKey: Output.rootKey)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

MainActor.assumeIsolated {
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: width, height: height), styleMask: [.titled, .fullSizeContentView, .resizable],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = false
    window.contentView = NSHostingView(rootView: RootView())
    window.orderFrontRegardless()
    pump(1)

    if let filesDir, let files = try? FileManager.default.contentsOfDirectory(at: filesDir, includingPropertiesForKeys: nil) {
        for tool in ToolRegistry.all where !tool.accepts.isEmpty {
            let fit = files.filter { f in tool.accepts.contains { t in (UTType(filenameExtension: f.pathExtension) ?? .data).conforms(to: t) } }
            AppModel.shared.batch(tool.id).add(Array(fit.prefix(4)), types: tool.accepts)
        }
    }

    var shots: [(String, NSImage)] = []
    var pages: [String] = [AppModel.home, AppModel.saved] + ToolRegistry.all.map(\.id)
    if let only = ProcessInfo.processInfo.environment["SNAP_ONLY"] { pages = only.split(separator: ",").map(String.init) }
    // SNAP_OPEN="redact=/a.png;pdfeditor=/b.pdf" opens a file in a tool before its shot.
    let opens = Dictionary((ProcessInfo.processInfo.environment["SNAP_OPEN"] ?? "").split(separator: ";").compactMap { pair -> (String, URL)? in
        let kv = pair.split(separator: "=", maxSplits: 1)
        return kv.count == 2 ? (String(kv[0]), URL(fileURLWithPath: String(kv[1]))) : nil
    }, uniquingKeysWith: { a, _ in a })
    for id in pages {
        if let file = opens[id] { AppModel.shared.open(id, files: [file]) } else { AppModel.shared.selection = id }
        pump(opens[id] == nil ? 0.6 : 2.5)
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)

        try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("\(id).png"))
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        shots.append((id, image))
        print("· \(id)")
    }

    // Contact sheets, 6 per page, labelled.
    let cols = 3, rows = 2, cellW = 620.0, cellH = cellW * height / width + 24
    for (n, chunk) in stride(from: 0, to: shots.count, by: cols * rows).map({ Array(shots[$0..<min($0 + cols * rows, shots.count)]) }).enumerated() {
        let sheet = NSImage(size: CGSize(width: cellW * Double(cols), height: cellH * Double(rows)))
        sheet.lockFocus()
        NSColor.gray.setFill(); NSRect(origin: .zero, size: sheet.size).fill()
        for (i, (id, img)) in chunk.enumerated() {
            let x = Double(i % cols) * cellW, y = sheet.size.height - Double(i / cols + 1) * cellH
            img.draw(in: CGRect(x: x + 2, y: y + 2, width: cellW - 4, height: cellH - 26))
            NSAttributedString(string: id, attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white])
                .draw(at: CGPoint(x: x + 6, y: y + cellH - 21))
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(String(format: "sheet-%02d.png", n)))
        }
    }
    print("done: \(shots.count) screens in \(outDir.path)")
}
exit(0)
