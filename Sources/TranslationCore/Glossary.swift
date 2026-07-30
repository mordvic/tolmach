import Foundation

/// The three stored properties are `var` so the settings pane can bind an editable field to
/// a row of the user's glossary. They were `let`, and nothing depended on that: every site
/// that touches them outside the initialiser below only reads — `requiredTranslation(for:)`
/// here, `PromptBuilder` and `GlossaryVerifier` in the engine, `WarningsView` in the app.
///
/// Nothing observable changed with them: `Codable` derives its keys from the property names
/// either way, so the on-disk JSON is unchanged (pinned by a test, because that file is
/// hand-edited and git-tracked); `Equatable`'s synthesis is likewise unaffected; and the
/// type is still `Sendable`, being a struct of `Sendable` value types — `var` on a value
/// type shares nothing. Callers holding an entry in a `let` still cannot mutate it.
public struct GlossaryEntry: Sendable, Codable, Equatable {
    public var term: String
    public var doNotTranslate: Bool
    public var translations: [String: String]

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
            // Advance past lowerBound rather than upperBound to keep overlapping candidates reachable.
            searchStart = text.index(after: found.lowerBound)
        }
        return false
    }

    /// False when the term contains Han, Hiragana or Katakana characters.
    static func usesWordSeparation(_ term: String) -> Bool {
        !term.unicodeScalars.contains(where: isWordSeparationless)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber else { return false }
        // Scripts that write no spaces cannot close a word boundary — otherwise a
        // Latin term embedded in Japanese would be invisible to the boundary path.
        return !character.unicodeScalars.contains(where: isWordSeparationless)
    }

    /// Han, Hiragana or Katakana — scripts that separate no words.
    static func isWordSeparationless(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)        // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(scalar.value) // CJK Extension A
            || (0xF900...0xFAFF).contains(scalar.value) // CJK Compatibility Ideographs
            || (0x20000...0x2FA1F).contains(scalar.value) // Extensions B+ (supplementary)
            || (0x3040...0x309F).contains(scalar.value) // Hiragana
            || (0x30A0...0x30FF).contains(scalar.value) // Katakana
    }
}
