import Foundation
import NaturalLanguage
import TranslationEngine

// PROTOTYPE — throwaway. Answers: does a document glossary fix terminology drift,
// and does the corrector-framed second pass earn its cost?

// MARK: - Lemmas

enum Lemmas {
    /// Word lemmas in order, lowercased. Falls back to the surface form when the
    /// tagger has no lemma for a token.
    static func sequence(of text: String, language: NLLanguage) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
            let surface = String(text[range])
            let lemma = tag?.rawValue
            out.append(((lemma?.isEmpty == false) ? lemma! : surface).lowercased())
            return true
        }
        return out
    }

    /// Does `needle`'s lemma sequence occur contiguously inside `haystack`'s?
    static func contains(_ haystack: String, _ needle: String, language: NLLanguage) -> Bool {
        let n = sequence(of: needle, language: language)
        guard !n.isEmpty else { return false }
        let h = sequence(of: haystack, language: language)
        guard h.count >= n.count else { return false }
        for start in 0...(h.count - n.count) where Array(h[start..<(start + n.count)]) == n {
            return true
        }
        return false
    }
}

// MARK: - Term extraction

enum Terms {
    static let stopWords: Set<String> = [
        "the", "a", "an", "of", "to", "and", "or", "is", "are", "be", "been", "was", "were",
        "in", "on", "for", "that", "this", "with", "as", "it", "its", "by", "at", "from",
        "not", "no", "but", "than", "then", "so", "such", "which", "what", "who", "when",
        "have", "has", "had", "do", "does", "did", "can", "will", "would", "many", "much",
        "more", "most", "other", "same", "own", "one", "two", "first", "last", "new", "old",
    ]

    struct Token {
        let surface: String
        let lemma: String
        let isNoun: Bool
        let isAdjective: Bool
        var isContent: Bool { isNoun || isAdjective }
    }

    static func tokens(of text: String, language: NLLanguage) -> [Token?] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        var out: [Token?] = []
        // Punctuation is kept as `nil` so noun phrases never span a boundary.
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace]) { tag, range in
            let surface = String(text[range])
            guard let tag, tag == .noun || tag == .adjective else { out.append(nil); return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            out.append(Token(surface: surface,
                             lemma: ((lemma?.isEmpty == false) ? lemma! : surface).lowercased(),
                             isNoun: tag == .noun,
                             isAdjective: tag == .adjective))
            return true
        }
        return out
    }

    /// Repeated content terms, most frequent first. Counted by lemma so inflected
    /// forms collapse; returned as the surface form of the first occurrence.
    static func extract(from text: String, language: NLLanguage, cap: Int, minFrequency: Int) -> [String] {
        let stream = tokens(of: text, language: language)
        var counts: [String: (count: Int, surface: String, order: Int)] = [:]

        func note(_ key: String, _ surface: String) {
            guard key.count > 2, !stopWords.contains(key) else { return }
            if let existing = counts[key] {
                counts[key] = (existing.count + 1, existing.surface, existing.order)
            } else {
                counts[key] = (1, surface, counts.count)
            }
        }

        // Single nouns and adjectives.
        for case let token? in stream where token.isContent {
            note(token.lemma, token.surface)
        }

        // 2–3 word noun phrases: runs of noun/adjective ending in a noun.
        var run: [Token] = []
        func flush() {
            guard run.count >= 2 else { run = []; return }
            for size in [2, 3] where run.count >= size {
                for start in 0...(run.count - size) {
                    let window = Array(run[start..<(start + size)])
                    guard window.last!.isNoun else { continue }
                    note(window.map(\.lemma).joined(separator: " "),
                         window.map(\.surface).joined(separator: " "))
                }
            }
            run = []
        }
        for entry in stream {
            if let token = entry, token.isContent { run.append(token) } else { flush() }
        }
        flush()

        return counts
            .filter { $0.value.count >= minFrequency }
            .sorted { ($0.value.count, $1.value.order) > ($1.value.count, $0.value.order) }
            .prefix(cap)
            .map(\.value.surface)
    }
}

// MARK: - Document glossary

struct DocTerm {
    let source: String
    let translated: String
}

enum DocGlossary {
    /// Asks the model to echo each source term back beside its translation, so a
    /// dropped or reordered line can never shift every later pairing.
    static func messages(terms: [String], target: Language) -> [ChatMessage] {
        let system = """
        You translate a list of glossary terms into \(target.englishName).

        Output one line per input term, in exactly this format:
        source term => translation

        Echo the source term exactly as given, then " => ", then the translation. \
        No numbering, no commentary, no extra lines. Keep identifiers and product names \
        untranslated when they have no established target-language form.
        """
        return [ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: terms.joined(separator: "\n"))]
    }

    static func parse(_ raw: String, knownTerms: [String]) -> [DocTerm] {
        let bySource = Dictionary(uniqueKeysWithValues: knownTerms.map { ($0.lowercased(), $0) })
        var seen = Set<String>()
        var out: [DocTerm] = []
        for line in raw.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let translated = parts[1].trimmingCharacters(in: .whitespaces)
            guard let canonical = bySource[key], !translated.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(DocTerm(source: canonical, translated: translated))
        }
        return out
    }
}

// MARK: - Adherence measurement

struct Adherence {
    let honoured: Int
    let applicable: Int
    var percent: Double { applicable == 0 ? 0 : Double(honoured) / Double(applicable) * 100 }
}

enum Measure {
    /// For every (term, chunk) pair where the SOURCE chunk contains the term, check
    /// whether the translated chunk carries the term's agreed translation.
    /// This is exactly "does the same term render the same way everywhere".
    static func adherence(sourceChunks: [String], translatedChunks: [String], glossary: [DocTerm],
                          source: NLLanguage, target: NLLanguage) -> (Adherence, [String: [Bool]]) {
        var honoured = 0
        var applicable = 0
        var detail: [String: [Bool]] = [:]

        for term in glossary {
            var perChunk: [Bool] = []
            var appeared = false
            for (index, sourceChunk) in sourceChunks.enumerated() {
                guard Lemmas.contains(sourceChunk, term.source, language: source) else { continue }
                appeared = true
                applicable += 1
                let ok = index < translatedChunks.count
                    && Lemmas.contains(translatedChunks[index], term.translated, language: target)
                if ok { honoured += 1 }
                perChunk.append(ok)
            }
            if appeared { detail[term.source] = perChunk }
        }
        return (Adherence(honoured: honoured, applicable: applicable), detail)
    }
}

// MARK: - LLM helper

enum LLM {
    static func complete(_ messages: [ChatMessage], model: String, client: OllamaClientBox) async throws -> String {
        var buffer = ""
        for try await event in client.chat(messages: messages, options: ChatOptions(model: model, temperature: 0.2, keepAlive: "30m")) {
            if case .token(let piece) = event { buffer += piece }
        }
        return buffer
    }
}

/// Thin box so `main.swift` stays readable.
typealias OllamaClientBox = LLMClient
