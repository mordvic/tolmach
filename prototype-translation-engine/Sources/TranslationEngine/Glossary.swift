import Foundation

public struct GlossaryEntry: Sendable, Codable, Equatable {
    public let term: String
    public let doNotTranslate: Bool
    /// Language code -> required translation. Ignored when `doNotTranslate` is true.
    public let translations: [String: String]

    public init(term: String, doNotTranslate: Bool = false, translations: [String: String] = [:]) {
        self.term = term
        self.doNotTranslate = doNotTranslate
        self.translations = translations
    }

    public func requiredTranslation(for language: Language) -> String? {
        doNotTranslate ? term : translations[language.rawValue]
    }
}

public struct Glossary: Sendable {
    public let entries: [GlossaryEntry]

    public init(entries: [GlossaryEntry]) {
        self.entries = entries
    }

    /// Only entries whose term actually occurs in the text. Sending the whole
    /// glossary bloats the prompt and measurably degrades output on small models.
    public func relevantEntries(for text: String) -> [GlossaryEntry] {
        let haystack = text.lowercased()
        return entries.filter { haystack.contains($0.term.lowercased()) }
    }
}

public struct GlossaryViolation: Sendable, Equatable {
    public let term: String
    public let expected: String
}

public enum GlossaryVerifier {
    /// Entries that were in scope but whose required form is missing from the output.
    /// Advisory only — a warning, never a hard failure.
    public static func violations(
        in translation: String,
        entries: [GlossaryEntry],
        target: Language
    ) -> [GlossaryViolation] {
        let haystack = translation.lowercased()
        return entries.compactMap { entry in
            guard let expected = entry.requiredTranslation(for: target) else { return nil }
            guard !haystack.contains(expected.lowercased()) else { return nil }
            return GlossaryViolation(term: entry.term, expected: expected)
        }
    }
}
