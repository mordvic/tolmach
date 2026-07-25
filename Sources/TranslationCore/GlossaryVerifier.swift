// Sources/TranslationCore/GlossaryVerifier.swift
import Foundation

public enum GlossaryStatus: Sendable, Equatable { case satisfied, missing, unverifiable }

public struct GlossaryCheck: Sendable, Equatable {
    public let term: String
    public let expected: String
    public let status: GlossaryStatus
}

public enum GlossaryVerifier {
    public static func check(translation: String, entries: [GlossaryEntry], target: Language,
                             ignored: Set<String> = []) -> [GlossaryCheck] {
        entries.compactMap { entry in
            guard !ignored.contains(entry.term) else { return nil }
            guard let expected = entry.requiredTranslation(for: target) else { return nil }
            let status: GlossaryStatus
            switch LemmaMatcher.matches(expected: expected, in: translation, language: target) {
            case true:
                status = .satisfied
            case false:
                // Lemma matching found no token sequence, but the text may still contain the
                // form inside a URL, identifier or filename, where NLTagger tokenises
                // differently ("fhir.org" is one token). That is ambiguous, not absent —
                // and an ambiguous case must not produce a warning.
                status = translation.lowercased().contains(expected.lowercased()) ? .unverifiable : .missing
            case nil:
                status = .unverifiable
            }
            return GlossaryCheck(term: entry.term, expected: expected, status: status)
        }
    }
}
