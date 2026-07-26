// Sources/TranslationCore/TermExtractor.swift
import Foundation
import NaturalLanguage

public enum TermExtractor {
    // Minimal multi-language stop set; extend as needed. Lowercased.
    static let stopWords: Set<String> = [
        "the", "a", "an", "of", "to", "and", "or", "is", "are", "be", "been", "was", "were",
        "in", "on", "for", "that", "this", "with", "as", "it", "its", "by", "at", "from",
        "not", "no", "but", "than", "then", "so", "such", "which", "what", "who", "when",
        "have", "has", "had", "do", "does", "did", "can", "will", "would", "many", "much",
        "more", "most", "other", "same", "own", "one", "two", "first", "last", "new", "old",
        "и", "в", "на", "с", "по", "не", "что", "как", "это", "для", "от", "или", "но",
    ]

    struct Token {
        let surface: String
        let lemma: String
        let isNoun: Bool
        let isAdjective: Bool
        var isContent: Bool { isNoun || isAdjective }
    }

    /// Content words in document order. `nil` marks anything else — punctuation, verbs,
    /// determiners — and acts as a hard boundary so no noun phrase spans one.
    static func tokens(of text: String, language: Language) -> [Token?] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        tagger.setLanguage(language.nlLanguage, range: text.startIndex..<text.endIndex)

        var out: [Token?] = []
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

    /// Fenced blocks and inline code are removed before extraction. An identifier
    /// inside code is not prose terminology, and harvesting one produces a glossary
    /// entry instructing the model to translate that identifier — which overrides
    /// the prompt rule that code must be reproduced verbatim. Measured: `--strict`
    /// harvested from a bash block came back as `--строгий` inside inline code.
    ///
    /// Removed spans are replaced with `"."`, not a blank line or a plain space.
    /// `tokens(of:language:)` enumerates with `.omitWhitespace`, which means
    /// whitespace — spaces, newlines, blank lines, any amount of it — never
    /// produces a token at all; it is skipped in silence. Only an actually-tagged
    /// token (punctuation included) yields the `nil` that acts as a boundary. A
    /// removed span bordered only by whitespace therefore does *not* separate its
    /// neighbours: "The server `x` cluster" stripped to a bare space still tags
    /// "server" and "cluster" as directly adjacent nouns, welding them into the
    /// phantom phrase "server cluster". A period is unambiguously tagged as
    /// punctuation and reliably breaks the run.
    static func strippingCode(_ text: String) -> String {
        var output: [String] = []
        var insideFence = false

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                // Leave a boundary marker where the block was, so no noun phrase
                // can span the removed region.
                if !insideFence { output.append(".") }
                continue
            }
            if insideFence { continue }

            // Inline code spans become a boundary marker for the same reason.
            var stripped = ""
            var insideSpan = false
            for character in line {
                if character == "`" {
                    insideSpan.toggle()
                    if !insideSpan { stripped.append(".") }
                    continue
                }
                if !insideSpan { stripped.append(character) }
            }
            output.append(stripped)
        }
        return output.joined(separator: "\n")
    }

    public static func extract(from text: String, language: Language, max: Int = 20, minFrequency: Int = 2) -> [String] {
        let stream = tokens(of: strippingCode(text), language: language)
        // key = lemma (lowercased) -> (occurrences, first surface form, discovery order)
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

        // 2–3-word noun phrases: runs of noun/adjective ending in a noun.
        var run: [Token] = []
        func flush() {
            guard run.count >= 2 else { run = []; return }
            for size in [2, 3] where run.count >= size {
                for start in 0...(run.count - size) {
                    let window = Array(run[start..<(start + size)])
                    guard window.last!.isNoun else { continue }
                    guard !window.contains(where: { stopWords.contains($0.lemma) }) else { continue }
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
            .prefix(max)
            .map(\.value.surface)
    }
}
