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

    /// Entries whose term occurs in the text. Matching is a deliberate substring test,
    /// not a word-boundary one: Chinese and Japanese are target languages and separate
    /// no words with spaces, so a boundary check would match nothing there. The cost is
    /// a false positive on short terms ("ID" inside "valid"), which adds one unneeded
    /// line to the prompt rather than producing a wrong translation.
    public func relevantEntries(for text: String) -> [GlossaryEntry] {
        let haystack = text.lowercased()
        return entries.filter { haystack.contains($0.term.lowercased()) }
    }
}
