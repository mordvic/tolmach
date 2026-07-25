// Sources/TranslationCore/LemmaMatcher.swift
import Foundation
import NaturalLanguage

public enum LemmaMatcher {
    public static func lemmas(of text: String, language: Language) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(language.nlLanguage, range: text.startIndex..<text.endIndex)
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
            let lemma = tag?.rawValue
            let surface = String(text[range])
            out.append((lemma?.isEmpty == false ? lemma! : surface).lowercased())
            return true
        }
        return out
    }

    /// nil  → cannot verify (expected term produced no lemmas)
    /// true → expected lemma sequence occurs contiguously in the translation
    /// false→ it does not
    public static func matches(expected: String, in translation: String, language: Language) -> Bool? {
        let needle = lemmas(of: expected, language: language)
        guard !needle.isEmpty else { return nil }
        let haystack = lemmas(of: translation, language: language)
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}
