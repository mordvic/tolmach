import Foundation

public struct GlossaryEntry: Sendable, Codable, Equatable {
    public let term: String
    public let doNotTranslate: Bool
    public let translations: [String: String]

    public init(term: String, doNotTranslate: Bool = false, translations: [String: String] = [:]) {
        self.term = term; self.doNotTranslate = doNotTranslate; self.translations = translations
    }

    public func requiredTranslation(for language: Language) -> String? {
        doNotTranslate ? term : translations[language.rawValue]
    }
}

public struct Glossary: Sendable {
    public let entries: [GlossaryEntry]
    public init(entries: [GlossaryEntry]) { self.entries = entries }

    /// Entries whose term occurs in the text.
    ///
    /// Matching respects word boundaries for scripts that separate words, so a short
    /// term like "ID" no longer matches inside "valid". That mattered beyond prompt
    /// noise: the same entry set feeds GlossaryVerifier, where a spurious entry
    /// becomes a false "term missing" warning.
    ///
    /// Chinese and Japanese write no spaces between words, so for a term containing
    /// such characters the check falls back to plain substring matching — a boundary
    /// rule would match nothing at all there.
    public func relevantEntries(for text: String) -> [GlossaryEntry] {
        entries.filter { Glossary.occurs($0.term, in: text) }
    }

    static func occurs(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        guard usesWordSeparation(term) else {
            return text.lowercased().contains(term.lowercased())
        }
        var searchStart = text.startIndex
        while let found = text.range(of: term, options: [.caseInsensitive],
                                     range: searchStart..<text.endIndex) {
            let openLeft = found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let openRight = found.upperBound == text.endIndex
                || !isWordCharacter(text[found.upperBound])
            if openLeft && openRight { return true }
            searchStart = text.index(after: found.lowerBound)
        }
        return false
    }

    /// False when the term contains Han, Hiragana or Katakana characters.
    static func usesWordSeparation(_ term: String) -> Bool {
        !term.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)    // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(scalar.value)  // CJK Extension A
                || (0x3040...0x309F).contains(scalar.value)  // Hiragana
                || (0x30A0...0x30FF).contains(scalar.value)  // Katakana
        }
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
