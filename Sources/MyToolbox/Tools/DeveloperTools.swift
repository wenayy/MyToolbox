import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

extension ToolRegistry {
    static let developerTools: [Tool] = [
        Tool("json", "JSON Formatter", "curlybraces", .developer, "Pretty-print, minify and validate JSON, with the line and column of any mistake") { JSONFormatterView() },
        Tool("base64", "Base64", "01.square", .developer, "Encode and decode Base64 text and files, with URL-safe and line-wrap options", accepts: [.item]) { Base64View() },
        Tool("hash", "Hash Generator", "number", .developer, "MD5, SHA-1 and SHA-2 checksums of text or files of any size, checked against an expected hash", accepts: [.item]) { HashView() },
        Tool("uuid", "UUID Generator", "touchid", .developer, "Make random v4 or time-ordered v7 UUIDs in bulk, and inspect any UUID") { UUIDView() },
        Tool("jwt", "JWT Decoder", "key", .developer, "Read a JSON Web Token's header and claims, see when it expires, and check HMAC signatures") { JWTView() },
        Tool("timestamp", "Timestamp Converter", "clock", .developer, "Turn Unix timestamps into dates and back, in s, ms or µs, in any time zone") { TimestampView() },
        Tool("diff", "Diff Checker", "arrow.left.arrow.right", .developer, "Compare two texts or files side by side or inline, with changed words highlighted") { DiffView() },
        Tool("regex", "Regex Tester", "asterisk", .developer, "Test regular expressions with live highlights, capture groups and a replace preview") { RegexView() },
        Tool("cleanlinks", "Clean Links", "link", .developer, "Strip tracking like utm_source and fbclid from links, and unwrap Google and Facebook redirects") { CleanLinksView() },
        Tool("coords", "Coordinate Picker", "mappin.and.ellipse", .developer, "Click a map or search a place for its coordinates, measure distances, look up a list") { CoordinatePickerView() },
        Tool("unicode", "Unicode Inspector", "character.magnify", .developer, "See every character and find hidden ones: zero-width spaces, odd spaces and look-alike letters") { UnicodeView() },
        Tool("lorem", "Lorem Ipsum", "paragraphsign", .developer, "Make placeholder text by the word, sentence or paragraph, as plain text, HTML or Markdown") { LoremView() },
    ]
}

// MARK: - JSON

enum JSONIndent: String, CaseIterable, Identifiable {
    case two = "2 Spaces", four = "4 Spaces", tab = "Tabs"
    var id: String { rawValue }
    var unit: String { self == .two ? "  " : self == .four ? "    " : "\t" }
}

enum JSONTool {
    /// Pretty-prints or minifies; errors carry Foundation's "around line X, column Y" text.
    static func format(_ input: String, pretty: Bool, sortKeys: Bool, indent: JSONIndent) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed, .json5Allowed])
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        if sortKeys { options.insert(.sortedKeys) }
        let out = String(decoding: try JSONSerialization.data(withJSONObject: object, options: options), as: UTF8.self)
        return pretty ? reindent(out, indent) : out
    }

    static func reindent(_ text: String, _ indent: JSONIndent) -> String {
        let lines = text.components(separatedBy: "\n")
        let unit = lines.map { $0.prefix(while: { $0 == " " }).count }.filter { $0 > 0 }.min() ?? 2
        return lines.map { line in
            let n = line.prefix(while: { $0 == " " }).count
            return String(repeating: indent.unit, count: n / unit) + line.dropFirst(n)
        }.joined(separator: "\n")
    }

    static func message(_ error: Error) -> String {
        let ns = error as NSError
        return (ns.userInfo["NSDebugDescription"] as? String) ?? ns.localizedDescription
    }
}

struct JSONFormatterView: View {
    @State private var input = ""
    @State private var output = ""
    @State private var error: String?
    @State private var pretty = true
    @AppStorage("json.sort") private var sortKeys = false
    @AppStorage("json.indent") private var indent: JSONIndent = .two

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlBar {
                Picker("", selection: $pretty) {
                    Text("Pretty").tag(true)
                    Text("Minified").tag(false)
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                Picker("Indent", selection: $indent) { ForEach(JSONIndent.allCases) { Text($0.rawValue).tag($0) } }
                    .fixedSize().disabled(!pretty)
                Toggle("Sort keys", isOn: $sortKeys)
                Spacer()
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                } else if !output.isEmpty {
                    Label("Valid JSON", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            HSplitView {
                EditorBox(title: "Input", text: $input, placeholder: "Paste JSON — it's formatted as you type") {
                    Button("Paste") { input = Pasteboard.string ?? "" }.controlSize(.small)
                }
                .padding(.trailing, 6)
                EditorBox(title: "Output", text: $output).padding(.leading, 6)
            }
        }
        .onChange(of: input) { run() }
        .onChange(of: pretty) { run() }
        .onChange(of: sortKeys) { run() }
        .onChange(of: indent) { run() }
    }

    private func run() {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { output = ""; error = nil; return }
        do {
            output = try JSONTool.format(input, pretty: pretty, sortKeys: sortKeys, indent: indent)
            error = nil
        } catch {
            self.error = JSONTool.message(error)
            output = ""
        }
    }
}

// MARK: - Base64

struct Base64View: View {
    @State private var decodeMode = false
    @State private var urlSafe = false
    @State private var wrap = false
    @State private var input = ""
    @State private var files: [URL] = []
    @State private var saved: [URL] = []

    private var output: String {
        decodeMode ? (decodedData.map { String(data: $0, encoding: .utf8) ?? "‹binary data, \($0.count) bytes — use Save as File›" } ?? (input.isEmpty ? "" : "Invalid Base64"))
                   : encode(Data(input.utf8))
    }

    private var decodedData: Data? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = s.firstIndex(of: ","), s.hasPrefix("data:") { s = String(s[s.index(after: comma)...]) }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        while s.count % 4 != 0 { s += "=" }
        return s.isEmpty ? nil : Data(base64Encoded: s)
    }

    private func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        if urlSafe {
            s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        if wrap {
            s = stride(from: 0, to: s.count, by: 76).map { i in
                let start = s.index(s.startIndex, offsetBy: i), end = s.index(start, offsetBy: min(76, s.count - i))
                return String(s[start..<end])
            }.joined(separator: "\n")
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $decodeMode) {
                    Text("Encode").tag(false)
                    Text("Decode").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 200)
                Toggle("URL-safe", isOn: $urlSafe).disabled(decodeMode)
                Toggle("Wrap at 76", isOn: $wrap).disabled(decodeMode).help("Break lines every 76 characters, as in email (MIME)")
                Spacer()
                if decodeMode, let data = decodedData {
                    Button("Save as File") {
                        let url = Output.file(name: "decoded", ext: "bin")
                        try? data.write(to: url)
                        saved = [url]
                    }
                }
            }
            if !decodeMode {
                DropZone(prompt: "Or drop a file to encode it", types: [.item], multiple: false, urls: $files)
                    .onChange(of: files) {
                        guard let url = files.first, let data = try? Data(contentsOf: url) else { return }
                        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        input = ""
                        fileOutput = encode(data)
                        dataURI = "data:\(mime);base64,\(data.base64EncodedString())"
                    }
            }
            ResultList(urls: saved)
            if !decodeMode, !fileOutput.isEmpty, !files.isEmpty {
                HStack {
                    Text("\(files[0].lastPathComponent) → \(fileOutput.count) characters")
                    Spacer()
                    CopyButton(text: fileOutput, label: "Copy Base64")
                    CopyButton(text: dataURI, label: "Copy data: URI")
                }
            } else {
                HSplitView {
                    EditorBox(title: "Input", text: $input, placeholder: decodeMode ? "Paste Base64…" : "Type or paste text…").padding(.trailing, 6)
                    EditorBox(title: "Output", text: .constant(output), editable: false).padding(.leading, 6)
                }
            }
        }
        .onChange(of: input) { if !input.isEmpty { files = []; fileOutput = "" } }
    }

    @State private var fileOutput = ""
    @State private var dataURI = ""
}

// MARK: - Hash

struct HashView: View {
    @State private var input = ""
    @State private var files: [URL] = []
    @State private var hmacKey = ""
    @State private var compare = ""
    @State private var results: [(String, String)] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorBox(title: "Text", text: $input, placeholder: "Type text, or drop a file below…").frame(height: 140)
            DropZone(prompt: "Drop a file to hash it", types: [.item], multiple: false, urls: $files)
            HStack {
                TextField("HMAC key (optional, text only)", text: $hmacKey).textFieldStyle(.roundedBorder)
                TextField("Paste a hash to compare", text: $compare).textFieldStyle(.roundedBorder)
            }
            if working { ProgressView("Hashing…") }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(results, id: \.0) { name, value in
                    HStack {
                        ValueRow(label: name, value: value)
                        if !compare.isEmpty && value.caseInsensitiveCompare(compare.trimmingCharacters(in: .whitespaces)) == .orderedSame {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Matches")
                        }
                    }
                }
            }
            Spacer()
        }
        .onChange(of: input) { if !input.isEmpty { files = [] }; recompute() }
        .onChange(of: files) { if !files.isEmpty { input = "" }; recompute() }
        .onChange(of: hmacKey) { recompute() }
    }

    private func recompute() {
        if let url = files.first {
            working = true
            Task.detached {
                let r = Self.hashFile(url)
                await MainActor.run { results = r; working = false }
            }
        } else if input.isEmpty {
            results = []
        } else {
            let data = Data(input.utf8)
            var r = Self.digests(data)
            if !hmacKey.isEmpty {
                let key = SymmetricKey(data: Data(hmacKey.utf8))
                r.append(("HMAC-SHA256", Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).hex))
                r.append(("HMAC-SHA512", Data(HMAC<SHA512>.authenticationCode(for: data, using: key)).hex))
            }
            results = r
        }
    }

    nonisolated static func digests(_ data: Data) -> [(String, String)] {
        [("MD5", Data(Insecure.MD5.hash(data: data)).hex),
         ("SHA-1", Data(Insecure.SHA1.hash(data: data)).hex),
         ("SHA-256", Data(SHA256.hash(data: data)).hex),
         ("SHA-384", Data(SHA384.hash(data: data)).hex),
         ("SHA-512", Data(SHA512.hash(data: data)).hex)]
    }

    /// Streams the file in 1 MB chunks so large files don't load into memory.
    nonisolated static func hashFile(_ url: URL) -> [(String, String)] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [("Error", "Can't read file")] }
        defer { try? handle.close() }
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), s256 = SHA256(), s384 = SHA384(), s512 = SHA512()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            md5.update(data: chunk); sha1.update(data: chunk); s256.update(data: chunk); s384.update(data: chunk); s512.update(data: chunk)
        }
        return [("MD5", Data(md5.finalize()).hex), ("SHA-1", Data(sha1.finalize()).hex), ("SHA-256", Data(s256.finalize()).hex),
                ("SHA-384", Data(s384.finalize()).hex), ("SHA-512", Data(s512.finalize()).hex)]
    }
}

// MARK: - UUID

enum UUIDInfo {
    /// Version, variant and (for v1/v6/v7) the embedded time.
    static func inspect(_ s: String) -> [(String, String)]? {
        guard let uuid = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let b = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        let version = Int(b[6] >> 4)
        let variant: String = switch b[8] >> 5 {
        case 0...3: "NCS (reserved)"
        case 4, 5: "RFC 9562"
        case 6: "Microsoft (reserved)"
        default: "Future (reserved)"
        }
        let names = [1: "1 (time + MAC)", 3: "3 (MD5 name)", 4: "4 (random)", 5: "5 (SHA-1 name)", 6: "6 (reordered time)",
                     7: "7 (Unix time + random)", 8: "8 (custom)"]
        var rows = [("Version", names[version] ?? "\(version)"), ("Variant", variant), ("Canonical", uuid.uuidString.lowercased())]
        var date: Date?
        if version == 7 {
            let ms = b[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            date = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else if version == 1 || version == 6 {
            let low = b[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let mid = UInt64(b[4]) << 8 | UInt64(b[5])
            let hi = UInt64(b[6] & 0x0F) << 8 | UInt64(b[7])
            let ticks = version == 1 ? (hi << 48 | mid << 32 | low) : (low << 28 | mid << 12 | hi)
            date = Date(timeIntervalSince1970: (Double(ticks) - 122_192_928_000_000_000) / 10_000_000)
        }
        if let date {
            rows.append(("Created", date.formatted(date: .abbreviated, time: .standard) + " (" + date.formatted(.relative(presentation: .named)) + ")"))
            rows.append(("Unix ms", String(Int64(date.timeIntervalSince1970 * 1000))))
        }
        return rows
    }
}

struct UUIDView: View {
    @State private var count = 5
    @AppStorage("uuid.v7") private var v7 = false
    @AppStorage("uuid.upper") private var uppercase = false
    @AppStorage("uuid.hyphens") private var hyphens = true
    @State private var output = ""
    @State private var inspect = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ControlBar {
                Picker("Version", selection: $v7) {
                    Text("v4 · Random").tag(false)
                    Text("v7 · Time-ordered").tag(true)
                }
                .fixedSize()
                Stepper("Count: \(count)", value: $count, in: 1...1000)
                Toggle("Uppercase", isOn: $uppercase)
                Toggle("Hyphens", isOn: $hyphens)
                Spacer()
                Button("Generate") { generate() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            }
            EditorBox(title: "UUIDs", text: $output)
            GroupBox("Inspect a UUID") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Paste any UUID to see its version and timestamp", text: $inspect)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    if !inspect.isEmpty {
                        if let rows = UUIDInfo.inspect(inspect) {
                            ForEach(rows, id: \.0) { ValueRow(label: $0.0, value: $0.1) }
                        } else {
                            ErrorText(message: "Not a valid UUID")
                        }
                    }
                }
                .padding(6)
            }
        }
        .onAppear(perform: generate)
        .onChange(of: v7) { generate() }
        .onChange(of: count) { generate() }
        .onChange(of: uppercase) { generate() }
        .onChange(of: hyphens) { generate() }
    }

    private func generate() {
        output = (0..<count).map { _ in
            var s = (v7 ? Self.uuidV7() : UUID()).uuidString
            if !uppercase { s = s.lowercased() }
            if !hyphens { s = s.replacingOccurrences(of: "-", with: "") }
            return s
        }.joined(separator: "\n")
    }

    static func uuidV7() -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, 16)
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return NSUUID(uuidBytes: bytes) as UUID
    }
}

// MARK: - JWT

struct JWTView: View {
    @State private var token = ""
    @State private var secret = ""

    private var parts: [String] { token.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".") }

    static func base64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    static func pretty(_ data: Data?) -> String {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return data.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        return String(decoding: out, as: UTF8.self)
    }

    private var header: [String: Any] {
        (parts.first.flatMap(Self.base64URL).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private var payload: [String: Any] {
        (parts.count > 1 ? Self.base64URL(parts[1]).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] : nil) ?? [:]
    }

    private var signatureStatus: (String, Color)? {
        guard parts.count == 3, !secret.isEmpty, let alg = header["alg"] as? String,
              let sig = Self.base64URL(parts[2]) else { return nil }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac: Data
        switch alg {
        case "HS256": mac = Data(HMAC<SHA256>.authenticationCode(for: signed, using: key))
        case "HS384": mac = Data(HMAC<SHA384>.authenticationCode(for: signed, using: key))
        case "HS512": mac = Data(HMAC<SHA512>.authenticationCode(for: signed, using: key))
        default: return ("Only HS256/384/512 can be verified with a secret", .secondary)
        }
        return mac == sig ? ("Signature verified", .green) : ("Invalid signature", .red)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorBox(title: "Token", text: $token, placeholder: "Paste a JWT (eyJ…)").frame(height: 100)
            if parts.count < 2 && !token.isEmpty {
                ErrorText(message: "Not a JWT — expected header.payload.signature")
            }
            claims
            HSplitView {
                EditorBox(title: "Header", text: .constant(Self.pretty(parts.first.flatMap(Self.base64URL))), editable: false).padding(.trailing, 6)
                EditorBox(title: "Payload", text: .constant(parts.count > 1 ? Self.pretty(Self.base64URL(parts[1])) : ""), editable: false).padding(.leading, 6)
            }
            HStack {
                SecureField("Secret to verify HMAC signature (optional)", text: $secret).textFieldStyle(.roundedBorder)
                if let (text, color) = signatureStatus { Text(text).foregroundStyle(color) }
            }
        }
    }

    @ViewBuilder private var claims: some View {
        let dates: [(String, String)] = [("exp", "Expires"), ("iat", "Issued"), ("nbf", "Not before")].compactMap { key, label in
            guard let t = payload[key] as? Double else { return nil }
            let d = Date(timeIntervalSince1970: t)
            return (label, d.formatted(date: .abbreviated, time: .standard) + "  (" + d.formatted(.relative(presentation: .named)) + ")")
        }
        if !dates.isEmpty {
            HStack(spacing: 18) {
                ForEach(dates, id: \.0) { label, value in
                    VStack(alignment: .leading) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        Text(value).textSelection(.enabled)
                    }
                }
                if let exp = payload["exp"] as? Double {
                    let expired = Date(timeIntervalSince1970: exp) < .now
                    Text(expired ? "EXPIRED" : "VALID").bold()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((expired ? Color.red : .green).opacity(0.2), in: Capsule())
                }
            }
        }
    }
}

// MARK: - Timestamp

enum TimestampUnit: String, CaseIterable, Identifiable {
    case auto = "Auto", seconds = "Seconds", millis = "Milliseconds", micros = "Microseconds", nanos = "Nanoseconds"
    var id: String { rawValue }
}

enum Timestamps {
    static func parse(_ s: String, unit: TimestampUnit = .auto) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Double(t) {
            let divisor: Double
            switch unit {
            case .seconds: divisor = 1
            case .millis: divisor = 1e3
            case .micros: divisor = 1e6
            case .nanos: divisor = 1e9
            case .auto:
                let a = abs(n)
                divisor = a > 1e17 ? 1e9 : a > 1e14 ? 1e6 : a > 1e11 ? 1e3 : 1
            }
            return Date(timeIntervalSince1970: n / divisor)
        }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            iso.formatOptions = options
            if let d = iso.date(from: t) { return d }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for f in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "EEE, dd MMM yyyy HH:mm:ss Z", "dd/MM/yyyy", "MM/dd/yyyy"] {
            df.dateFormat = f
            if let d = df.date(from: t) { return d }
        }
        return nil
    }

    static func rows(_ d: Date, zone: TimeZone) -> [(String, String)] {
        let iso = ISO8601DateFormatter()
        let isoZone = ISO8601DateFormatter()
        isoZone.timeZone = zone
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        rfc.timeZone = zone
        let local = DateFormatter()
        local.dateStyle = .full
        local.timeStyle = .long
        local.timeZone = zone
        let t = d.timeIntervalSince1970
        return [
            ("Seconds", String(Int64(t.rounded(.down)))),
            ("Milliseconds", String(Int64((t * 1e3).rounded(.down)))),
            ("Microseconds", String(Int64((t * 1e6).rounded(.down)))),
            ("ISO 8601 (UTC)", iso.string(from: d)),
            ("ISO 8601 (zone)", isoZone.string(from: d)),
            (zone.identifier, local.string(from: d)),
            ("RFC 2822", rfc.string(from: d)),
            ("Relative", d.formatted(.relative(presentation: .named))),
        ]
    }
}

struct TimestampView: View {
    @State private var input = ""
    @State private var unit: TimestampUnit = .auto
    @AppStorage("ts.zone") private var zoneID = TimeZone.current.identifier
    @State private var date = Date()

    private var zone: TimeZone { TimeZone(identifier: zoneID) ?? .current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack {
                        Text("Now").font(.headline)
                        Text(String(Int64(ctx.date.timeIntervalSince1970))).font(.system(.title2, design: .monospaced))
                        CopyButton(text: String(Int64(ctx.date.timeIntervalSince1970)))
                        Spacer()
                        Picker("Time zone", selection: $zoneID) {
                            Text("Local (\(TimeZone.current.identifier))").tag(TimeZone.current.identifier)
                            Text("UTC").tag("UTC")
                            Divider()
                            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                        }
                        .frame(maxWidth: 320)
                    }
                }
                GroupBox("Timestamp or date → every format") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("1730000000, 1730000000000, 2026-10-31T12:00:00Z…", text: $input)
                                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                            Picker("Unit", selection: $unit) { ForEach(TimestampUnit.allCases) { Text($0.rawValue).tag($0) } }
                                .fixedSize().labelsHidden()
                        }
                        if !input.isEmpty {
                            if let d = Timestamps.parse(input, unit: unit) {
                                ForEach(Timestamps.rows(d, zone: zone), id: \.0) { ValueRow(label: $0.0, value: $0.1) }
                            } else {
                                ErrorText(message: "Couldn't read that as a timestamp or date")
                            }
                        }
                    }
                    .padding(6)
                }
                GroupBox("Date → Unix") {
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, zone)
                        ForEach(Timestamps.rows(date, zone: zone).prefix(4), id: \.0) { ValueRow(label: $0.0, value: $0.1) }
                    }
                    .padding(6)
                }
            }
        }
    }
}

// MARK: - Diff

struct DiffLine: Identifiable {
    enum Kind { case same, added, removed }
    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

enum Differ {
    static func diff(_ old: String, _ new: String, ignoreWhitespace: Bool, ignoreCase: Bool) -> [DiffLine] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        func key(_ s: String) -> String {
            var k = ignoreWhitespace ? s.split(whereSeparator: \.isWhitespace).joined(separator: " ") : s
            if ignoreCase { k = k.lowercased() }
            return k
        }
        let changes = b.map(key).difference(from: a.map(key))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && removed.contains(i) {
                lines.append(DiffLine(id: lines.count, kind: .removed, oldNumber: i + 1, newNumber: nil, text: a[i])); i += 1
            } else if j < b.count && inserted.contains(j) {
                lines.append(DiffLine(id: lines.count, kind: .added, oldNumber: nil, newNumber: j + 1, text: b[j])); j += 1
            } else {
                lines.append(DiffLine(id: lines.count, kind: .same, oldNumber: i + 1, newNumber: j + 1, text: j < b.count ? b[j] : a[i]))
                i += 1; j += 1
            }
        }
        return lines
    }
}

enum WordDiff {
    static func tokens(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"\s+|\w+|[^\w\s]"#)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// The old and new line with changed words marked, for highlighting.
    static func highlight(old: String, new: String) -> (old: [(String, Bool)], new: [(String, Bool)]) {
        let a = tokens(old), b = tokens(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        return (a.enumerated().map { ($1, removed.contains($0)) }, b.enumerated().map { ($1, inserted.contains($0)) })
    }

    static func attributed(_ parts: [(String, Bool)], color: Color) -> AttributedString {
        var out = AttributedString()
        for (text, changed) in parts {
            var piece = AttributedString(text)
            if changed { piece.backgroundColor = color.opacity(0.45) }
            out += piece
        }
        return out
    }
}

/// One row of the side-by-side view; removed/added lines in the same block are paired up.
struct DiffPair: Identifiable {
    let id: Int
    let left: DiffLine?
    let right: DiffLine?

    static func pairs(_ lines: [DiffLine]) -> [DiffPair] {
        var out: [DiffPair] = []
        var i = 0
        while i < lines.count {
            if lines[i].kind == .same {
                out.append(DiffPair(id: out.count, left: lines[i], right: lines[i])); i += 1; continue
            }
            var removed: [DiffLine] = [], added: [DiffLine] = []
            while i < lines.count && lines[i].kind == .removed { removed.append(lines[i]); i += 1 }
            while i < lines.count && lines[i].kind == .added { added.append(lines[i]); i += 1 }
            for k in 0..<max(removed.count, added.count) {
                out.append(DiffPair(id: out.count, left: k < removed.count ? removed[k] : nil, right: k < added.count ? added[k] : nil))
            }
        }
        return out
    }
}

struct DiffView: View {
    @State private var left = ""
    @State private var right = ""
    @AppStorage("diff.ws") private var ignoreWhitespace = false
    @AppStorage("diff.case") private var ignoreCase = false
    @AppStorage("diff.only") private var onlyChanges = false
    @AppStorage("diff.sideBySide") private var sideBySide = true

    var body: some View {
        let lines = Differ.diff(left, right, ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase)
        let added = lines.filter { $0.kind == .added }.count, removed = lines.filter { $0.kind == .removed }.count
        VSplitView {
            HSplitView {
                EditorBox(title: "Original", text: $left, placeholder: "Paste the original, or open a file…") {
                    Button("Open…") { if let t = open() { left = t } }.controlSize(.small)
                }
                .padding(.trailing, 6)
                EditorBox(title: "Changed", text: $right, placeholder: "Paste the changed version…") {
                    Button("Open…") { if let t = open() { right = t } }.controlSize(.small)
                }
                .padding(.leading, 6)
            }
            .frame(minHeight: 160)
            VStack(alignment: .leading, spacing: 6) {
                ControlBar {
                    Text("+\(added)").foregroundStyle(.green).bold()
                    Text("−\(removed)").foregroundStyle(.red).bold()
                    if added + removed == 0 && !left.isEmpty { Label("Identical", systemImage: "equal.circle").foregroundStyle(.secondary) }
                    Spacer()
                    Picker("", selection: $sideBySide) {
                        Text("Side by Side").tag(true)
                        Text("Inline").tag(false)
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                    Toggle("Ignore whitespace", isOn: $ignoreWhitespace)
                    Toggle("Ignore case", isOn: $ignoreCase)
                    Toggle("Only changes", isOn: $onlyChanges)
                }
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if sideBySide {
                            ForEach(DiffPair.pairs(lines).filter { !onlyChanges || $0.left?.kind != .same }) { pair in
                                sideRow(pair)
                            }
                        } else {
                            ForEach(lines.filter { !onlyChanges || $0.kind != .same }) { inlineRow($0) }
                        }
                    }
                    .textSelection(.enabled)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 8)
        }
    }

    private func open() -> String? {
        guard let url = FilePicker.choose(types: [.text, .sourceCode, .data], multiple: false).first else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func inlineRow(_ line: DiffLine) -> some View {
        HStack(spacing: 8) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text).fixedSize()
        }
        .font(.system(.body, design: .monospaced))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .added ? Color.green.opacity(0.13) : line.kind == .removed ? Color.red.opacity(0.13) : .clear)
    }

    private func sideRow(_ pair: DiffPair) -> some View {
        let changed = pair.left != nil && pair.right != nil && pair.left!.kind == .removed
        let words = changed ? WordDiff.highlight(old: pair.left!.text, new: pair.right!.text) : nil
        return HStack(spacing: 0) {
            sideCell(pair.left, number: pair.left?.oldNumber, tint: pair.left?.kind == .removed ? .red : nil,
                     text: words.map { WordDiff.attributed($0.old, color: .red) })
            Divider()
            sideCell(pair.right, number: pair.right?.newNumber, tint: pair.right?.kind == .added ? .green : nil,
                     text: words.map { WordDiff.attributed($0.new, color: .green) })
        }
        .font(.system(.body, design: .monospaced))
    }

    private func sideCell(_ line: DiffLine?, number: Int?, tint: Color?, text: AttributedString?) -> some View {
        HStack(spacing: 8) {
            Text(number.map(String.init) ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(.tertiary)
            if let text { Text(text).fixedSize() } else { Text(line?.text.isEmpty == false ? line!.text : " ").fixedSize() }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(minWidth: 380, maxWidth: .infinity, alignment: .leading)
        .background(line == nil ? Color.secondary.opacity(0.06) : (tint?.opacity(0.13) ?? .clear))
    }
}

// MARK: - Regex

struct RegexView: View {
    @State private var pattern = ""
    @State private var text = ""
    @State private var replacement = ""
    @State private var caseInsensitive = false
    @State private var multiline = true
    @State private var dotAll = false

    private var regex: Result<NSRegularExpression, Error>? {
        guard !pattern.isEmpty else { return nil }
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multiline { options.insert(.anchorsMatchLines) }
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        return Result { try NSRegularExpression(pattern: pattern, options: options) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("/").foregroundStyle(.secondary)
                TextField("Pattern, e.g. (\\w+)@(\\w+)\\.com", text: $pattern)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Text("/").foregroundStyle(.secondary)
                Toggle("i", isOn: $caseInsensitive).help("Case insensitive")
                Toggle("m", isOn: $multiline).help("^ and $ match at line breaks")
                Toggle("s", isOn: $dotAll).help(". matches newlines")
            }
            .toggleStyle(.button)
            EditorBox(title: "Test text", text: $text, placeholder: "Paste text to search…").frame(minHeight: 120)

            switch regex {
            case .failure(let error): ErrorText(message: (error as NSError).localizedDescription)
            case .success(let re):
                let ns = text as NSString
                let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
                Text("\(matches.count) match\(matches.count == 1 ? "" : "es")").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(highlighted(matches)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                        ForEach(Array(matches.prefix(200).enumerated()), id: \.offset) { index, m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Match \(index + 1): \(ns.substring(with: m.range))").font(.system(.callout, design: .monospaced))
                                ForEach(1..<max(m.numberOfRanges, 1), id: \.self) { g in
                                    let r = m.range(at: g)
                                    Text("   group \(g): \(r.location == NSNotFound ? "—" : ns.substring(with: r))")
                                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack {
                            TextField("Replace with ($1, $2…)", text: $replacement).textFieldStyle(.roundedBorder)
                        }
                        if !replacement.isEmpty {
                            let replaced = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
                            HStack(alignment: .top) {
                                Text(replaced).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                CopyButton(text: replaced)
                            }
                        }
                    }
                }
            case nil: Spacer()
            }
        }
    }

    private func highlighted(_ matches: [NSTextCheckingResult]) -> AttributedString {
        var attributed = AttributedString(text)
        for m in matches {
            guard let range = Range(m.range, in: text), let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = .yellow.opacity(0.45)
        }
        return attributed
    }
}

// MARK: - Clean Links

enum LinkCleaner {
    static let trackingParams: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "igsh", "si",
        "yclid", "twclid", "ttclid", "li_fat_id", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id",
        "spm", "scm", "ref_src", "ref_url", "s_cid", "cmpid", "share_id", "feature", "pp", "_ga", "_gl", "trk", "trkCampaign",
        "rcm", "ncid", "sr_share", "smid", "cvid", "ocid", "epik", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pd_rd_i", "pf_rd_p",
        "pf_rd_r", "pf_rd_s", "pf_rd_t", "pf_rd_i", "pf_rd_m", "content-id", "ref_", "tag", "linkCode", "creative", "creativeASIN",
    ]

    /// Params removed only on these hosts (they carry meaning elsewhere).
    static let hostSpecific: [String: Set<String>] = [
        "youtube.com": ["si", "feature", "pp"], "youtu.be": ["si", "feature"],
    ]

    static func isTracking(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || n.hasPrefix("hsa_") || n.hasPrefix("pk_") || n.hasPrefix("mtm_") || trackingParams.contains(name)
            || trackingParams.contains(n)
    }

    /// Unwraps redirect wrappers (Google, Facebook, LinkedIn, Outlook safelinks…), then drops tracking params.
    static func clean(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let host = comps.host?.lowercased() ?? ""
        let wrapperKeys = ["url", "q", "u", "target", "dest", "redirect", "to"]
        let isWrapper = host.contains("google.") && comps.path == "/url" || host.hasSuffix("facebook.com") && comps.path.hasPrefix("/l.php")
            || host.contains("safelinks.protection.outlook.com") || host == "l.instagram.com" || host == "out.reddit.com"
            || host.hasSuffix("linkedin.com") && comps.path.hasPrefix("/redir") || host == "t.umblr.com" || host == "away.vk.com"
        if isWrapper, let inner = comps.queryItems?.first(where: { wrapperKeys.contains($0.name) && ($0.value ?? "").hasPrefix("http") })?.value,
           let innerURL = URL(string: inner) {
            return clean(innerURL)
        }
        if let items = comps.queryItems {
            let kept = items.filter { item in !isTracking(item.name) }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        if host.hasSuffix("amazon.com") || host.contains("amazon."), let r = comps.path.range(of: "/ref=") {
            comps.path = String(comps.path[..<r.lowerBound])
        }
        return comps.url ?? url
    }

    static func cleanText(_ text: String) -> (String, Int) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return (text, 0) }
        var result = text
        var changed = 0
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in matches.reversed() {
            guard let range = Range(m.range, in: result), let url = m.url, url.scheme?.hasPrefix("http") == true else { continue }
            let cleaned = clean(url).absoluteString
            if cleaned != String(result[range]) {
                result.replaceSubrange(range, with: cleaned)
                changed += 1
            }
        }
        return (result, changed)
    }
}

struct CleanLinksView: View {
    @State private var input = ""

    var body: some View {
        let (output, changed) = LinkCleaner.cleanText(input)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Clean Clipboard") {
                    input = Pasteboard.string ?? ""
                    Pasteboard.copy(LinkCleaner.cleanText(input).0)
                }
                .keyboardShortcut(.return, modifiers: .command)
                Text("Reads the clipboard, cleans every link and copies the result back.").foregroundStyle(.secondary)
                Spacer()
                if !input.isEmpty { Text("\(changed) link\(changed == 1 ? "" : "s") cleaned").foregroundStyle(.green) }
            }
            HSplitView {
                EditorBox(title: "Input", text: $input, placeholder: "Paste text or links…").padding(.trailing, 6)
                EditorBox(title: "Clean", text: .constant(output), editable: false).padding(.leading, 6)
            }
        }
    }
}

// MARK: - Unicode

enum Confusables {
    /// Letters from other scripts that look like Latin ones — a common trick in phishing links.
    static let map: [UInt32: String] = [
        0x0430: "a", 0x0435: "e", 0x043E: "o", 0x0440: "p", 0x0441: "c", 0x0443: "y", 0x0445: "x", 0x0456: "i", 0x0458: "j",
        0x0455: "s", 0x04BB: "h", 0x0501: "d", 0x0410: "A", 0x0412: "B", 0x0415: "E", 0x041A: "K", 0x041C: "M", 0x041D: "H",
        0x041E: "O", 0x0420: "P", 0x0421: "C", 0x0422: "T", 0x0425: "X", 0x0406: "I", 0x0408: "J", 0x0405: "S",
        0x03BF: "o", 0x03BD: "v", 0x03C1: "p", 0x0391: "A", 0x0392: "B", 0x0395: "E", 0x0396: "Z", 0x0397: "H", 0x0399: "I",
        0x039A: "K", 0x039C: "M", 0x039D: "N", 0x039F: "O", 0x03A1: "P", 0x03A4: "T", 0x03A5: "Y", 0x03A7: "X",
        0x0131: "i", 0x0261: "g", 0x01C0: "l", 0x2160: "I", 0x2170: "i", 0x217C: "l", 0x2113: "l",
    ]

    static func latin(for s: Unicode.Scalar) -> String? {
        if let m = map[s.value] { return m }
        if (0xFF21...0xFF3A).contains(s.value) || (0xFF41...0xFF5A).contains(s.value) {   // fullwidth A–Z, a–z
            return String(Unicode.Scalar(s.value - 0xFEE0)!)
        }
        return nil
    }
}

struct UnicodeView: View {
    @State private var input = ""
    @State private var onlySuspicious = false

    static func isHidden(_ s: Unicode.Scalar) -> Bool {
        let invisible: Set<UInt32> = [0x00A0, 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x2028, 0x2029,
                                      0x202F, 0x205F, 0x3000, 0x3164, 0xFEFF, 0xFFA0]
        let v = s.value
        return invisible.contains(v) || (0x2000...0x200F).contains(v) || (0x202A...0x202E).contains(v) || (0x2060...0x206F).contains(v)
            || (0xFE00...0xFE0F).contains(v) || (0xE0000...0xE007F).contains(v) || (s.properties.generalCategory == .control && v != 0x0A && v != 0x09)
    }

    static func isSuspicious(_ s: Unicode.Scalar) -> Bool { isHidden(s) || Confusables.latin(for: s) != nil }

    var body: some View {
        let scalars = Array(input.unicodeScalars)
        let hidden = scalars.filter(Self.isHidden).count
        let lookalikes = scalars.filter { Confusables.latin(for: $0) != nil }.count
        VStack(alignment: .leading, spacing: 10) {
            EditorBox(title: "Text", text: $input, monospaced: false, placeholder: "Paste text to inspect every character…").frame(height: 120)
            ControlBar {
                Text("\(input.count) characters").bold()
                Text("\(scalars.count) code points").foregroundStyle(.secondary)
                Text("\(input.utf8.count) UTF-8 bytes").foregroundStyle(.secondary)
                if hidden > 0 {
                    Label("\(hidden) hidden", systemImage: "eye.slash").foregroundStyle(.orange)
                    Button("Remove Hidden") { input = String(String.UnicodeScalarView(scalars.filter { !Self.isHidden($0) })) }
                }
                if lookalikes > 0 {
                    Label("\(lookalikes) look-alike letter\(lookalikes == 1 ? "" : "s")", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Replace with Latin") {
                        input = scalars.map { Confusables.latin(for: $0) ?? String($0) }.joined()
                    }
                }
                Spacer()
                Toggle("Only suspicious", isOn: $onlySuspicious)
            }
            Table(scalars.enumerated().filter { !onlySuspicious || Self.isSuspicious($0.element) }.map { ScalarRow(index: $0.offset, scalar: $0.element) }) {
                TableColumn("Char") { Text($0.display).font(.title3) }.width(50)
                TableColumn("Code point") { Text($0.codePoint).font(.system(.body, design: .monospaced)).textSelection(.enabled) }.width(100)
                TableColumn("Name") { row in
                    Text(row.name + (row.lookalike.map { "  — looks like “\($0)”" } ?? ""))
                        .foregroundStyle(row.suspicious ? .orange : .primary).textSelection(.enabled)
                }
                TableColumn("Category") { Text($0.category).foregroundStyle(.secondary) }.width(140)
                TableColumn("UTF-8") { Text($0.utf8).font(.system(.caption, design: .monospaced)) }.width(110)
            }
        }
    }
}

struct ScalarRow: Identifiable {
    let index: Int
    let scalar: Unicode.Scalar
    var id: Int { index }
    var suspicious: Bool { UnicodeView.isSuspicious(scalar) }
    var lookalike: String? { Confusables.latin(for: scalar) }
    var display: String { UnicodeView.isHidden(scalar) || scalar.properties.generalCategory == .control ? "·" : String(scalar) }
    var codePoint: String { String(format: "U+%04X", scalar.value) }
    var name: String { scalar.properties.name ?? scalar.properties.nameAlias ?? "<unnamed>" }
    var category: String { String(describing: scalar.properties.generalCategory) }
    var utf8: String { String(scalar).utf8.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

// MARK: - Lorem Ipsum

struct LoremView: View {
    enum Unit: String, CaseIterable { case paragraphs, sentences, words }
    enum Format: String, CaseIterable { case plain = "Plain Text", html = "HTML", markdown = "Markdown" }
    @State private var unit: Unit = .paragraphs
    @State private var count = 3
    @State private var format: Format = .plain
    @State private var classicStart = true
    @State private var paragraphs: [String] = []

    static let words = """
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua enim ad \
    minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute irure in reprehenderit \
    voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt culpa qui officia deserunt \
    mollit anim id est laborum curabitur pretium tincidunt lacus nulla gravida orci a odio nullam varius turpis et commodo pharetra \
    est eros bibendum elit nec luctus magna felis sollicitudin mauris integer dignissim quam quisque vel risus mattis viverra
    """.split(separator: " ").map(String.init)

    private var output: String {
        switch format {
        case .plain: paragraphs.joined(separator: "\n\n")
        case .html: paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n")
        case .markdown: (unit == .paragraphs ? "# Lorem Ipsum\n\n" : "") + paragraphs.joined(separator: "\n\n")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlBar {
                Stepper("\(count)", value: $count, in: 1...500).fixedSize()
                Picker("", selection: $unit) { ForEach(Unit.allCases, id: \.self) { Text($0.rawValue.capitalized) } }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                Picker("As", selection: $format) { ForEach(Format.allCases, id: \.self) { Text($0.rawValue) } }.fixedSize()
                Toggle("Start with “Lorem ipsum…”", isOn: $classicStart)
                Spacer()
                Button("Regenerate") { generate() }
                CopyButton(text: output).controlSize(.regular)
            }
            EditorBox(title: "Text", text: .constant(output), editable: false, monospaced: format != .plain)
        }
        .onAppear(perform: generate)
        .onChange(of: unit) { generate() }
        .onChange(of: count) { generate() }
        .onChange(of: classicStart) { generate() }
    }

    private func sentence() -> String {
        let n = Int.random(in: 6...16)
        let s = (0..<n).map { _ in Self.words.randomElement()! }.joined(separator: " ")
        return s.prefix(1).uppercased() + s.dropFirst() + "."
    }

    private func generate() {
        let classic = "Lorem ipsum dolor sit amet, consectetur adipiscing elit."
        switch unit {
        case .words:
            var w = (0..<count).map { _ in Self.words.randomElement()! }
            if classicStart { w = Array((["Lorem", "ipsum", "dolor", "sit", "amet"] + w).prefix(count)) }
            paragraphs = [w.joined(separator: " ")]
        case .sentences:
            var s = (0..<count).map { _ in sentence() }
            if classicStart { s[0] = classic }
            paragraphs = [s.joined(separator: " ")]
        case .paragraphs:
            paragraphs = (0..<count).map { _ in (0..<Int.random(in: 4...7)).map { _ in sentence() }.joined(separator: " ") }
            if classicStart { paragraphs[0] = classic + " " + paragraphs[0] }
        }
    }
}
