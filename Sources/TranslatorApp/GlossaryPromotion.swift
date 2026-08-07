// Sources/TranslatorApp/GlossaryPromotion.swift
import Foundation
import TranslationCore

/// Moving reviewed document terms into the user's own glossary.
///
/// Pure, and separate from the button that calls it, for `OutputNaming`'s reason: the rule
/// decides what happens to a file the user hand-edits and keeps in git, so it has to be
/// checkable rather than trusted.
enum GlossaryPromotion {
    /// The glossary's entries with `additions` merged in.
    ///
    /// A term the glossary already carries is left exactly as it is. That is not caution —
    /// it is the same precedence `GlossaryMerge.merge(user:document:)` applies during a run,
    /// where the user's entry wins over the model's. Promoting the model's version would
    /// silently overwrite a decision the user had already made, and the sheet does not even
    /// offer those rows for editing.
    ///
    /// Compared case-insensitively, because `GlossaryMerge` is.
    ///
    /// An addition with nothing typed into its «перевод» is dropped: a term with no required
    /// translation is one `GlossaryVerifier` can never satisfy, so storing it would arm a
    /// warning that nothing can turn off.
    static func entries(adding additions: [GlossaryEntry], to glossary: Glossary) -> [GlossaryEntry] {
        let existing = Set(glossary.entries.map { $0.term.lowercased() })
        var seen = existing
        var out = glossary.entries
        for entry in additions {
            let key = entry.term.lowercased()
            guard !seen.contains(key) else { continue }
            guard entry.doNotTranslate || entry.translations.values.contains(where: { !$0.isEmpty })
            else { continue }
            seen.insert(key)
            out.append(entry)
        }
        return out
    }
}
