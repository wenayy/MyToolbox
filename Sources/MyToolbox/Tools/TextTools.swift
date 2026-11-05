import NaturalLanguage
import SwiftUI

// MARK: - Word Counter

struct WordCounterView: View {
    @State private var text = ""

    var body: some View {
        let stats = TextStats(text)
        HSplitView {
            EditorBox(title: "Text", text: $text, monospaced: false, placeholder: "Type or paste text…").padding(.trailing, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        stat("Words", stats.words)
                        stat("Characters", stats.characters)
                        stat("No spaces", stats.charactersNoSpaces)
                        stat("Sentences", stats.sentences)
                        stat("Paragraphs", stats.paragraphs)
                        stat("Lines", stats.lines)
                    }
                    ValueRow(label: "Reading time", value: duration(Double(stats.words) / 238))
                    ValueRow(label: "Speaking time", value: duration(Double(stats.words) / 140))
                    if !stats.topWords.isEmpty {
                        Text("Top words").font(.headline).padding(.top, 6)
                        ForEach(stats.topWords, id: \.0) { word, n in
                            HStack { Text(word); Spacer(); Text("\(n)").foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(.leading, 8)
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.system(.title, design: .rounded).weight(.semibold))
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func duration(_ minutes: Double) -> String {
        let seconds = Int((minutes * 60).rounded())
        return seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min \(seconds % 60) sec"
    }
}

struct TextStats {
    var words = 0, characters = 0, charactersNoSpaces = 0, sentences = 0, paragraphs = 0, lines = 0
    var topWords: [(String, Int)] = []

    static let stopWords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "is", "it", "that", "for", "on", "with", "as",
                                         "was", "are", "be", "this", "at", "by", "i", "you", "he", "she", "we", "they", "but", "not", "from"]

    init(_ text: String) {
        characters = text.count
        charactersNoSpaces = text.filter { !$0.isWhitespace }.count
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines = text.components(separatedBy: .newlines).count
        paragraphs = text.components(separatedBy: "\n").split { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var freq: [String: Int] = [:]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            words += 1
            let w = text[range].lowercased()
            if w.count > 2 && !Self.stopWords.contains(w) { freq[w, default: 0] += 1 }
            return true
        }
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        sentences = sentenceTokenizer.tokens(for: text.startIndex..<text.endIndex)
            .filter { text[$0].contains { $0.isLetter || $0.isNumber } }.count
        topWords = freq.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(8).map { ($0.key, $0.value) }
    }
}

// MARK: - Case Converter

enum CaseStyle: String, CaseIterable, Identifiable {
    case upper = "UPPER CASE", lower = "lower case", title = "Title Case", sentence = "Sentence case"
    case camel = "camelCase", pascal = "PascalCase", snake = "snake_case", kebab = "kebab-case", constant = "CONSTANT_CASE"
    case dot = "dot.case", alternating = "aLtErNaTiNg", inverse = "iNVERSE"
    var id: String { rawValue }

    static let smallWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "the", "to", "up", "via", "vs"]

    /// Splits "someText_like-THIS" into ["some", "Text", "like", "THIS"].
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if !c.isLetter && !c.isNumber {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            if c.isUppercase, !current.isEmpty, let last = current.last {
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if last.isLowercase || last.isNumber || (last.isUppercase && nextIsLower) { out.append(current); current = "" }
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    func apply(_ text: String) -> String {
        switch self {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title:
            return text.components(separatedBy: "\n").map { line in
                line.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, w in
                    let lw = w.lowercased()
                    return i > 0 && Self.smallWords.contains(lw) ? lw : lw.prefix(1).uppercased() + lw.dropFirst()
                }.joined(separator: " ")
            }.joined(separator: "\n")
        case .sentence:
            var result = ""
            var capitalizeNext = true
            for c in text.lowercased() {
                if capitalizeNext && c.isLetter { result += c.uppercased(); capitalizeNext = false } else { result.append(c) }
                if ".!?\n".contains(c) { capitalizeNext = true }
            }
            return result.replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression)
        case .alternating:
            var upper = false
            return String(text.map { c in
                guard c.isLetter else { return c }
                upper.toggle()
                return upper ? Character(c.lowercased()) : Character(c.uppercased())
            })
        case .inverse:
            return String(text.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
        default:
            return text.components(separatedBy: "\n").map { line in
                let w = Self.words(line)
                switch self {
                case .camel: return w.enumerated().map { $0 == 0 ? $1.lowercased() : $1.prefix(1).uppercased() + $1.dropFirst().lowercased() }.joined()
                case .pascal: return w.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
                case .snake: return w.map { $0.lowercased() }.joined(separator: "_")
                case .kebab: return w.map { $0.lowercased() }.joined(separator: "-")
                case .constant: return w.map { $0.uppercased() }.joined(separator: "_")
                case .dot: return w.map { $0.lowercased() }.joined(separator: ".")
                default: return line
                }
            }.joined(separator: "\n")
        }
    }
}

struct CaseConverterView: View {
    @State private var text = ""

    var body: some View {
        HSplitView {
            EditorBox(title: "Text", text: $text, monospaced: false, placeholder: "Type or paste text…").padding(.trailing, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(CaseStyle.allCases) { style in
                        let converted = style.apply(text.isEmpty ? "The quick brown fox" : text)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(style.rawValue).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Use") { text = converted }.controlSize(.small).disabled(text.isEmpty)
                                CopyButton(text: converted, label: "").labelStyle(.iconOnly)
                            }
                            Text(converted).lineLimit(3).textSelection(.enabled)
                                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                        }
                        .padding(8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.leading, 8)
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
        }
    }
}
