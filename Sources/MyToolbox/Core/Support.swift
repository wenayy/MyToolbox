import AppKit
import Foundation

// MARK: - Output folders

/// Every result goes into one folder, ~/Downloads/MyToolbox (changeable in Settings), so it's always
/// easy to find. Names get a suffix like " compressed" and never overwrite an existing file.
enum Output {
    static let rootKey = "outputRoot"

    static var root: URL {
        let custom = UserDefaults.standard.string(forKey: rootKey) ?? ""
        let url = custom.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("MyToolbox")
            : URL(fileURLWithPath: custom)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `name.ext` in the output folder; adds " 2", " 3"… if taken.
    static func file(name: String, ext: String) -> URL {
        unique(root.appendingPathComponent(name).appendingPathExtension(ext))
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Display form for the "Saves to" line.
    static var rootDisplay: String {
        root.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Errors

/// An error whose message is already written for the person reading it.
struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ShellError: LocalizedError {
    case missing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let tool): "\(tool) isn't installed. Install it in MyToolbox Settings → Helpers (or in Terminal: brew install \(tool))."
        case .failed(let message): message
        }
    }
}

/// Runs CPU-heavy work off the main actor.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

// MARK: - Shell

enum Shell {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func which(_ name: String) -> String? {
        searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func require(_ name: String) throws -> String {
        guard let path = which(name) else { throw ShellError.missing(name) }
        return path
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    /// Labels the processes a job starts, so the job can pause or resume just its own processes.
    @TaskLocal static var tag: String?

    // Every child process, so quitting the app never leaves yt-dlp or ffmpeg running.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var processes: [ObjectIdentifier: (Process, String?)] = [:]

    private static func track(_ p: Process) {
        lock.lock(); processes[ObjectIdentifier(p)] = (p, tag); lock.unlock()
    }

    private static func untrack(_ p: Process) {
        lock.lock(); processes[ObjectIdentifier(p)] = nil; lock.unlock()
    }

    static func terminateAll() {
        lock.lock(); let all = processes.values.map(\.0); lock.unlock()
        all.forEach { if $0.isRunning { kill($0.processIdentifier, SIGCONT); $0.terminate() } }
    }

    /// Pauses (SIGSTOP) or resumes (SIGCONT) every running process started under `tag`, including
    /// helpers they spawned (yt-dlp runs ffmpeg).
    static func setPaused(_ paused: Bool, tag: String) {
        lock.lock(); let mine = processes.values.filter { $0.1 == tag }.map(\.0); lock.unlock()
        for p in mine where p.isRunning {
            let pid = p.processIdentifier
            for child in childPIDs(of: pid) { kill(child, paused ? SIGSTOP : SIGCONT) }
            kill(pid, paused ? SIGSTOP : SIGCONT)
        }
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let ids = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0) }
        return ids + ids.flatMap(childPIDs)
    }

    struct Result {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
    }

    /// Runs to completion and captures output. Cancelling the task stops the process.
    /// Nothing here blocks a thread: output is collected as it arrives and the exit is a callback.
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, input: Data? = nil) async throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        if let cwd { p.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = input == nil ? nil : Pipe()
        p.standardInput = inPipe ?? FileHandle.nullDevice
        let out = DataBox(), err = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }
        try Task.checkCancellation()
        track(p)
        defer { untrack(p) }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                p.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    out.append(drain(outPipe.fileHandleForReading))
                    err.append(drain(errPipe.fileHandleForReading))
                    cont.resume(returning: proc.terminationStatus)
                }
                do {
                    try p.run()
                    if let input, let inPipe {
                        DispatchQueue.global().async {
                            inPipe.fileHandleForWriting.write(input)
                            try? inPipe.fileHandleForWriting.close()
                        }
                    }
                } catch {
                    p.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if p.isRunning { kill(p.processIdentifier, SIGCONT); p.terminate() }
        }
        try Task.checkCancellation()
        return Result(status: status, out: String(decoding: out.data, as: UTF8.self), err: String(decoding: err.data, as: UTF8.self))
    }

    /// Reads whatever is left in a pipe without waiting (a grandchild holding the pipe open can't hang us).
    static func drain(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            result.append(buffer, count: n)
        }
        return result
    }

    /// Runs and streams merged stdout/stderr line by line (on the main queue).
    /// Cancelling the task stops the process; the call then throws CancellationError.
    static func stream(_ exe: String, _ args: [String], cwd: URL? = nil,
                       onLine: @escaping (String) -> Void) async throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let splitter = LineSplitter(onLines: { lines in DispatchQueue.main.async { lines.forEach(onLine) } })
        let flush: @Sendable (Data, Bool) -> Void = { splitter.feed($0, final: $1) }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { flush(data, false) }
        }
        try Task.checkCancellation()
        track(p)
        defer { untrack(p) }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                p.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    flush(drain(pipe.fileHandleForReading), true)
                    DispatchQueue.main.async { cont.resume(returning: proc.terminationStatus) }
                }
                do { try p.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if p.isRunning { kill(p.processIdentifier, SIGCONT); p.terminate() }
        }
        try Task.checkCancellation()
        return status
    }
}

/// Thread-safe byte buffer for collecting process output.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { guard !d.isEmpty else { return }; lock.lock(); storage.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Accumulates bytes and emits complete lines (split on \n or \r, so progress bars count as lines).
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLines: ([String]) -> Void

    init(onLines: @escaping ([String]) -> Void) { self.onLines = onLines }

    func feed(_ data: Data, final: Bool) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...i)
        }
        if final, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        lock.unlock()
        let nonEmpty = lines.filter { !$0.isEmpty }
        if !nonEmpty.isEmpty { onLines(nonEmpty) }
    }
}

// MARK: - Small helpers

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func copy(png data: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }

    static var string: String? { NSPasteboard.general.string(forType: .string) }

    static var image: NSImage? {
        NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension URL {
    var fileSize: Int64 {
        (try? resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    }

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var baseName: String { deletingPathExtension().lastPathComponent }

    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([self]) }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// "12.4 MB → 3.1 MB (−75%)"
func sizeChange(_ before: Int64, _ after: Int64) -> String {
    guard before > 0 else { return after.byteString }
    let pct = Int((Double(after - before) / Double(before) * 100).rounded())
    return "\(before.byteString) → \(after.byteString) (\(pct <= 0 ? "−" : "+")\(abs(pct))%)"
}

func timecode(_ seconds: Double, millis: Bool = false, separator: String = ",") -> String {
    let s = max(0, seconds)
    let h = Int(s) / 3600, m = Int(s) / 60 % 60, sec = Int(s) % 60
    if millis { return String(format: "%02d:%02d:%02d%@%03d", h, m, sec, separator, Int((s - s.rounded(.down)) * 1000)) }
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
