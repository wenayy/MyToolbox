import FoundationModels
import NaturalLanguage
import Observation
import PDFKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

// MARK: - Summarize

enum SummaryLength: String, CaseIterable, Identifiable {
    case short = "Short", medium = "Medium", detailed = "Detailed"
    var id: String { rawValue }
}

enum SummaryStyle: String, CaseIterable, Identifiable {
    case paragraph = "Paragraph", bullets = "Bullet Points", takeaways = "Key Takeaways"
    var id: String { rawValue }
}

enum Summarizer {
    /// The on-device model has a ~4K-token window, so long text is summarized in parts first.
    static let chunkChars = 6000

    static func chunks(_ text: String, size: Int = chunkChars) -> [String] {
        var parts: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            if current.count + paragraph.count + 1 > size, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            if paragraph.count > size {
                var rest = Substring(paragraph)
                while rest.count > size {
                    let cut = rest.index(rest.startIndex, offsetBy: size)
                    parts.append(String(rest[..<cut]))
                    rest = rest[cut...]
                }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + paragraph
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        return parts
    }

    static func instruction(_ length: SummaryLength, _ style: SummaryStyle) -> String {
        let size: String
        switch (length, style) {
        case (.short, .paragraph): size = "in 2 or 3 sentences"
        case (.medium, .paragraph): size = "in one paragraph of about 120 words"
        case (.detailed, .paragraph): size = "in 2 to 4 paragraphs, about 250 words in total"
        case (.short, _): size = "as 3 bullet points"
        case (.medium, _): size = "as 5 to 7 bullet points"
        case (.detailed, _): size = "as 8 to 12 bullet points"
        }
        let shape = style == .takeaways
            ? " Each bullet is one takeaway the reader should remember, starting with a short bold phrase."
            : style == .bullets ? " Start each bullet with \"- \"." : ""
        return "Summarize the text \(size).\(shape)"
    }

    static let rules = """
    You summarize text faithfully. Use only facts from the text. Keep names, numbers, dates and decisions. \
    Write in the same language as the text. Reply with the summary only.
    """

    static func summarize(_ text: String, length: SummaryLength, style: SummaryStyle,
                          status: @escaping @MainActor (String) -> Void,
                          partial: @escaping @MainActor (String) -> Void) async throws -> String {
        var material = text
        var parts = chunks(material)
        var round = 0
        while parts.count > 1 {
            round += 1
            var notes: [String] = []
            for (i, part) in parts.enumerated() {
                try Task.checkCancellation()
                await status("Reading part \(i + 1) of \(parts.count)…")
                let session = LanguageModelSession(instructions: rules)
                let r = try await session.respond(to: "Summarize this part of a longer text in under 120 words.\n\nText:\n\(part)")
                notes.append(r.content)
            }
            material = notes.joined(separator: "\n\n")
            parts = chunks(material)
            if round > 3 { break }
        }
        await status("Writing the summary…")
        let session = LanguageModelSession(instructions: rules)
        var final = ""
        for try await snapshot in session.streamResponse(to: "\(instruction(length, style))\n\nText:\n\(material)") {
            final = snapshot.content
            await partial(final)
        }
        return final
    }

    static func message(for error: Error) -> String {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation: return "Apple Intelligence declined to work with this text."
            case .unsupportedLanguageOrLocale: return "Apple Intelligence doesn't support this language yet."
            case .exceededContextWindowSize: return "This part of the text is too long for the on-device model."
            default: break
            }
        }
        return error.localizedDescription
    }
}

@MainActor @Observable
final class SummarizeModel {
    static let shared = SummarizeModel()
    var input = ""
    var output = ""
    var status: String?
    var error: String?
    var working = false
    var length: SummaryLength = .medium
    var style: SummaryStyle = .bullets
    @ObservationIgnored private var task: Task<Void, Never>?

    func run() {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task?.cancel()
        working = true
        error = nil
        output = ""
        let text = input, length = length, style = style
        task = Task {
            do {
                output = try await Summarizer.summarize(text, length: length, style: style,
                                                        status: { self.status = $0 }, partial: { self.output = $0 })
            } catch is CancellationError {
            } catch {
                self.error = Summarizer.message(for: error)
            }
            status = nil
            working = false
        }
    }

    func cancel() { task?.cancel() }
}

struct SummarizeView: View {
    @Bindable private var model = SummarizeModel.shared
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !AIModel.isAvailable {
                Banner(symbol: "apple.intelligence", message: "Apple Intelligence: \(AIModel.statusText).")
            }
            ControlBar {
                Picker("Length", selection: $model.length) { ForEach(SummaryLength.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
                Picker("Style", selection: $model.style) { ForEach(SummaryStyle.allCases) { Text($0.rawValue).tag($0) } }
                    .fixedSize()
                Spacer()
                if model.working {
                    Button("Stop", action: model.cancel)
                } else {
                    Button("Summarize", action: model.run)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.input.isEmpty || !AIModel.isAvailable)
                }
            }
            if let loadError { ErrorText(message: loadError) }
            if let error = model.error { ErrorText(message: error) }
            HSplitView {
                EditorBox(title: "Text", text: $model.input, monospaced: false, placeholder: "Paste text, or open a document or PDF…") {
                    Text("\(model.input.split(whereSeparator: \.isWhitespace).count) words").font(.caption).foregroundStyle(.secondary)
                    Button("Open Document…") {
                        if let url = FilePicker.choose(types: DocText.types, multiple: false).first { load(url) }
                    }
                    .controlSize(.small)
                }
                .padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Summary").font(.headline)
                        Spacer()
                        if let status = model.status { ProgressView().controlSize(.small); Text(status).font(.caption).foregroundStyle(.secondary) }
                        if !model.output.isEmpty && !model.working { CopyButton(text: model.output) }
                    }
                    .frame(minHeight: 22)
                    ScrollView {
                        Text(markdown(model.output.isEmpty ? (model.working ? "" : "The summary appears here. It's written on this Mac — nothing is uploaded.") : model.output))
                            .foregroundStyle(model.output.isEmpty ? .tertiary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                }
                .padding(.leading, 8)
            }
        }
        .receivesFiles(for: "summarize") { urls in if let url = urls.first { load(url) } }
    }

    private func load(_ url: URL) {
        do { model.input = try DocText.load(url); loadError = nil } catch { loadError = error.localizedDescription }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - Ask a Document

struct DocChunk {
    let page: Int
    let text: String
    var vector: [Double]?
}

enum DocIndex {
    static let stopWords: Set<String> = ["the", "and", "for", "are", "was", "what", "when", "where", "which", "who", "how",
                                         "does", "did", "this", "that", "with", "from", "about", "into", "there", "their", "they",
                                         "have", "has", "had", "you", "your", "can", "will", "would", "should", "could", "say", "says"]

    static func chunks(pages: [String], size: Int = 1100) -> [DocChunk] {
        var out: [DocChunk] = []
        for (i, page) in pages.enumerated() {
            for piece in Summarizer.chunks(page, size: size) where piece.trimmingCharacters(in: .whitespacesAndNewlines).count > 30 {
                out.append(DocChunk(page: i + 1, text: piece))
            }
        }
        return out
    }

    static func terms(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stopWords.contains($0) }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Best chunks for a question: sentence-embedding similarity blended with keyword overlap.
    static func retrieve(_ question: String, from chunks: [DocChunk], embedding: NLEmbedding?, k: Int = 4) -> [DocChunk] {
        let q = Set(terms(question))
        let qv = embedding?.vector(for: question)
        let scored = chunks.map { chunk -> (DocChunk, Double) in
            let words = terms(chunk.text)
            let hits = words.filter(q.contains).count
            let keyword = q.isEmpty ? 0 : Double(hits) / (Double(words.count).squareRoot() + 1)
            let semantic = (qv != nil && chunk.vector != nil) ? cosine(qv!, chunk.vector!) : 0
            return (chunk, semantic * 0.6 + min(1, keyword) * 0.4)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(k).map(\.0).sorted { $0.page < $1.page }
    }

    static func citedPages(_ answer: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: #"\[(?:p|pp|page|part)\.?\s*(\d+)(?:\s*[-–,]\s*(\d+))?\]"#, options: .caseInsensitive)
        let ns = answer as NSString
        var pages: [Int] = []
        for m in re.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            for g in 1...2 where m.range(at: g).location != NSNotFound {
                if let n = Int(ns.substring(with: m.range(at: g))), !pages.contains(n) { pages.append(n) }
            }
        }
        return pages
    }
}

@MainActor @Observable
final class AskDocumentModel {
    static let shared = AskDocumentModel()

    struct Message: Identifiable {
        let id = UUID()
        let question: Bool
        var text: String
        var pages: [Int] = []
    }

    var url: URL?
    var pdf: PDFDocument?
    var plainText = ""
    var chunks: [DocChunk] = []
    var messages: [Message] = []
    var question = ""
    var working = false
    var indexing = false
    var error: String?
    var page = 1
    @ObservationIgnored private var embedding: NLEmbedding?

    var isPDF: Bool { pdf != nil }

    func open(_ url: URL) {
        self.url = url
        messages = []
        error = nil
        indexing = true
        Task {
            do {
                let pages: [String]
                if url.pathExtension.lowercased() == "pdf" {
                    guard let doc = PDFDocument(url: url) else { throw ToolError("Can't open \(url.lastPathComponent)") }
                    pdf = doc
                    pages = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
                    if pages.joined().trimmingCharacters(in: .whitespacesAndNewlines).count < 50 {
                        throw ToolError("This PDF has no text layer. Run it through Extract Text first.")
                    }
                } else {
                    pdf = nil
                    plainText = try DocText.load(url)
                    // Non-PDFs are split into numbered parts of ~3000 characters.
                    pages = Summarizer.chunks(plainText, size: 3000)
                }
                let all = pages.joined(separator: " ")
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(String(all.prefix(2000)))
                let language = recognizer.dominantLanguage ?? .english
                let emb = NLEmbedding.sentenceEmbedding(for: language)
                embedding = emb
                let built: [DocChunk] = try await offMain {
                    DocIndex.chunks(pages: pages).map { var c = $0; c.vector = emb?.vector(for: c.text); return c }
                }
                chunks = built
            } catch {
                self.error = error.localizedDescription
            }
            indexing = false
        }
    }

    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chunks.isEmpty, !working else { return }
        question = ""
        messages.append(Message(question: true, text: q))
        messages.append(Message(question: false, text: ""))
        let answerID = messages.last!.id
        working = true
        let previous = messages.dropLast(2).last(where: \.question)?.text
        let excerpts = DocIndex.retrieve(previous.map { "\($0) \(q)" } ?? q, from: chunks, embedding: embedding)
        let label = isPDF ? "p." : "part"
        let context = excerpts.map { "[\(label) \($0.page)] \($0.text)" }.joined(separator: "\n\n")
        Task {
            do {
                let session = LanguageModelSession(instructions: """
                You answer questions about a document using only the excerpts given. After every fact, cite where it came \
                from like [\(label) 4]. If the excerpts don't contain the answer, say you couldn't find it in the document. \
                Be concise and answer in the language of the question.
                """)
                for try await snapshot in session.streamResponse(to: "Excerpts:\n\(context)\n\nQuestion: \(q)") {
                    set(answerID) { $0.text = snapshot.content }
                }
                set(answerID) { $0.pages = DocIndex.citedPages($0.text) }
                if let first = messages.last?.pages.first { page = first }
            } catch {
                set(answerID) { $0.text = Summarizer.message(for: error) }
            }
            working = false
        }
    }

    private func set(_ id: UUID, _ change: (inout Message) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { change(&messages[i]) }
    }
}

struct AskDocumentView: View {
    @Bindable private var model = AskDocumentModel.shared
    @FocusState private var focused: Bool

    var body: some View {
        HSplitView {
            documentPane
                .frame(minWidth: 320, idealWidth: 460)
            chatPane
                .frame(minWidth: 340, idealWidth: 420)
        }
        .receivesFiles(for: "askdoc") { urls in if let url = urls.first { model.open(url) } }
    }

    @ViewBuilder private var documentPane: some View {
        if let pdf = model.pdf {
            PDFKitView(document: pdf, page: $model.page)
        } else if model.url != nil, !model.plainText.isEmpty {
            ScrollView { Text(model.plainText).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text("Open a PDF or Document").font(.title3.weight(.semibold))
                Text("Ask questions and get answers with page references. Everything stays on this Mac.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Choose Document…") {
                    if let url = FilePicker.choose(types: DocText.types, multiple: false).first { model.open(url) }
                }
                .controlSize(.large)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: FileDrop.types, isTargeted: nil) { providers in
                FileDrop.load(providers) { if let url = $0.first { model.open(url) } }
                return true
            }
        }
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.url?.lastPathComponent ?? "No document").font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.url != nil {
                    Button("Open Another…") {
                        if let url = FilePicker.choose(types: DocText.types, multiple: false).first { model.open(url) }
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            Divider()
            if !AIModel.isAvailable {
                Banner(symbol: "apple.intelligence", message: "Apple Intelligence: \(AIModel.statusText).").padding(12)
            }
            if let error = model.error { ErrorText(message: error).padding(12) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.indexing {
                            HStack { ProgressView().controlSize(.small); Text("Reading the document…").foregroundStyle(.secondary) }
                        } else if model.messages.isEmpty && !model.chunks.isEmpty {
                            Text("Try asking").font(.caption).foregroundStyle(.secondary)
                            ForEach(["What is this document about?", "What are the key dates and deadlines?", "What are the main conclusions?"], id: \.self) { s in
                                Button(s) { model.question = s; model.ask() }.buttonStyle(.bordered)
                            }
                        }
                        ForEach(model.messages) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.messages.last?.text) {
                    if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                TextField("Ask about this document", text: $model.question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(model.ask)
                Button { model.ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(model.question.isEmpty || model.working || model.chunks.isEmpty || !AIModel.isAvailable)
                    .help("Ask (Return)")
            }
            .padding(12)
        }
    }

    private func bubble(_ m: AskDocumentModel.Message) -> some View {
        VStack(alignment: m.question ? .trailing : .leading, spacing: 6) {
            Group {
                if m.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(m.text).textSelection(.enabled)
                }
            }
            .padding(10)
            .background(m.question ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.background.secondary),
                        in: RoundedRectangle(cornerRadius: 12))
            if !m.pages.isEmpty {
                HStack(spacing: 6) {
                    ForEach(m.pages, id: \.self) { p in
                        Button(model.isPDF ? "Page \(p)" : "Part \(p)") { model.page = p }
                            .controlSize(.small)
                            .disabled(!model.isPDF)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: m.question ? .trailing : .leading)
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var page: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        if let target = document.page(at: max(0, page - 1)), view.currentPage !== target { view.go(to: target) }
    }
}

// MARK: - Translate

enum SubtitleText {
    /// Indices of lines that hold cue text (not numbers, timings, headers or NOTE/STYLE blocks).
    static func textLineIndices(_ lines: [String]) -> [Int] {
        var result: [Int] = []
        var skippingBlock = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { skippingBlock = false; continue }
            if skippingBlock { continue }
            if i == 0 && line.hasPrefix("WEBVTT") { skippingBlock = true; continue }
            if line.hasPrefix("NOTE") || line == "STYLE" || line == "REGION" { skippingBlock = true; continue }
            if line.contains("-->") { continue }
            if Int(line) != nil, i + 1 < lines.count, lines[i + 1].contains("-->") { continue }
            if i + 1 < lines.count, lines[i + 1].contains("-->") { continue }   // WebVTT cue identifier
            result.append(i)
        }
        return result
    }
}

@MainActor @Observable
final class TranslateModel {
    static let shared = TranslateModel()

    enum Work { case text, files([URL]) }

    var source = ""
    var target = ""
    /// Empty = detect automatically.
    var sourceLanguage = ""
    var targetLanguage = Locale.current.language.languageCode?.identifier == "en" ? "es" : "en"
    var languages: [Locale.Language] = []
    var configuration: TranslationSession.Configuration?
    var working = false
    var status: String?
    var error: String?
    var saved: [URL] = []
    var detected: String?
    @ObservationIgnored var pending: Work?

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        let all = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        languages = all.filter { seen.insert($0.minimalIdentifier).inserted }.sorted { name($0) < name($1) }
    }

    func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    func request(_ work: Work) {
        pending = work
        error = nil
        let src = sourceLanguage.isEmpty ? nil : Locale.Language(identifier: sourceLanguage)
        let tgt = Locale.Language(identifier: targetLanguage)
        if configuration?.source == src && configuration?.target == tgt {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: src, target: tgt)
        }
    }

    func swap() {
        guard !sourceLanguage.isEmpty else {
            if let d = detected { sourceLanguage = targetLanguage; targetLanguage = d; Swift.swap(&source, &target) }
            return
        }
        Swift.swap(&sourceLanguage, &targetLanguage)
        Swift.swap(&source, &target)
    }

    func perform(_ session: TranslationSession) async {
        guard let work = pending else { return }
        pending = nil
        working = true
        defer { working = false; status = nil }
        do {
            switch work {
            case .text:
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(source)
                detected = recognizer.dominantLanguage?.rawValue
                target = try await translate(lines: source.components(separatedBy: "\n"), session: session).joined(separator: "\n")
            case .files(let urls):
                let folder = Output.root
                var outs: [URL] = []
                for (i, url) in urls.enumerated() {
                    status = "Translating \(url.lastPathComponent) (\(i + 1) of \(urls.count))…"
                    outs.append(try await translateFile(url, into: folder, session: session))
                }
                saved = outs
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Translates non-empty lines in one batch and puts them back in place.
    func translate(lines: [String], session: TranslationSession) async throws -> [String] {
        var out = lines
        let indices = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !indices.isEmpty else { return lines }
        let requests = indices.map { TranslationSession.Request(sourceText: lines[$0], clientIdentifier: String($0)) }
        for response in try await session.translations(from: requests) {
            if let id = response.clientIdentifier, let i = Int(id) { out[i] = response.targetText }
        }
        return out
    }

    private func translateFile(_ url: URL, into folder: URL, session: TranslationSession) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let suffix = "-" + targetLanguage
        switch ext {
        case "srt", "vtt":
            let content = try String(contentsOf: url, encoding: .utf8)
            var lines = content.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            let indices = SubtitleText.textLineIndices(lines)
            let translated = try await translate(lines: indices.map { lines[$0] }, session: session)
            for (k, i) in indices.enumerated() { lines[i] = translated[k] }
            let out = ImageKit.outputURL(for: url, in: folder, suffix: suffix, ext: ext)
            try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            return out
        case "docx", "doc", "odt", "rtf", "html", "htm":
            let attr = try NSMutableAttributedString(url: url, options: [:], documentAttributes: nil)
            let paragraphs = (attr.string as NSString).components(separatedBy: "\n")
            let translated = try await translate(lines: paragraphs, session: session)
            // Replace back to front so earlier ranges stay valid; each paragraph keeps its own style.
            var location = 0
            var ranges: [NSRange] = []
            for p in paragraphs {
                ranges.append(NSRange(location: location, length: (p as NSString).length))
                location += (p as NSString).length + 1
            }
            for i in ranges.indices.reversed() where translated[i] != paragraphs[i] && ranges[i].length > 0 {
                attr.replaceCharacters(in: ranges[i], with: translated[i])
            }
            let type: NSAttributedString.DocumentType = switch ext {
            case "docx": .officeOpenXML
            case "doc": .docFormat
            case "odt": .openDocument
            case "rtf": .rtf
            default: .html
            }
            let data = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: type])
            let out = ImageKit.outputURL(for: url, in: folder, suffix: suffix, ext: ext)
            try data.write(to: out)
            return out
        default:
            let text = try DocText.load(url)
            let translated = try await translate(lines: text.components(separatedBy: "\n"), session: session)
            let out = ImageKit.outputURL(for: url, in: folder, suffix: suffix, ext: ext == "md" ? "md" : "txt")
            try translated.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            return out
        }
    }
}

struct TranslateView: View {
    @Bindable private var model = TranslateModel.shared
    @State private var files: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ControlBar {
                Picker("From", selection: $model.sourceLanguage) {
                    Text(model.detected.map { "Detect (\(Locale.current.localizedString(forIdentifier: $0) ?? $0))" } ?? "Detect Language").tag("")
                    Divider()
                    ForEach(model.languages, id: \.minimalIdentifier) { Text(model.name($0)).tag($0.minimalIdentifier) }
                }
                .fixedSize()
                Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Swap languages")
                Picker("To", selection: $model.targetLanguage) {
                    ForEach(model.languages, id: \.minimalIdentifier) { Text(model.name($0)).tag($0.minimalIdentifier) }
                }
                .fixedSize()
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                Button("Translate") { model.request(.text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.source.isEmpty || model.working)
            }
            if let error = model.error { ErrorText(message: error) }
            HSplitView {
                EditorBox(title: "Text", text: $model.source, monospaced: false, placeholder: "Type or paste text…").padding(.trailing, 8)
                EditorBox(title: "Translation", text: $model.target, editable: false, monospaced: false).padding(.leading, 8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    DropZone(prompt: "Translate files: Word, RTF, HTML, text, PDF, or SRT/VTT subtitles (timings kept)",
                             types: DocText.types + DocText.subtitleTypes, urls: $files)
                    HStack {
                        if let status = model.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Translate \(files.count) File\(files.count == 1 ? "" : "s")") { model.request(.files(files)) }
                            .disabled(files.isEmpty || model.working)
                    }
                    ResultList(urls: model.saved)
                }
                .padding(4)
            }
            Text("Translation runs on this Mac. The first time you use a language, macOS may ask to download it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .translationTask(model.configuration) { session in await model.perform(session) }
        .task { await model.loadLanguages() }
        .receivesFiles(for: "translate") { files.append(contentsOf: $0) }
    }
}
