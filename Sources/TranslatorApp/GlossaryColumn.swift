// Sources/TranslatorApp/GlossaryColumn.swift
import Foundation
import TranslationCore

/// Which language's translations the glossary pane shows, when the user has not said.
///
/// ## The defect this replaces
///
/// The pane used to default to `settings.workingLanguage`, described as «the useful default:
/// that is the language the primary-language text gets translated into». That sentence is true
/// and describes the *minority* direction.
///
/// `AppSettings.targetLanguage(forDetected:)` is `detected == primaryLanguage ? working :
/// primary`, so everything that is **not** already in the user's own language is translated
/// **into** it. A translator is overwhelmingly pointed at foreign text, so the entries a
/// glossary accumulates carry `translations["ru"]` on a default install — while the pane
/// showed the `en` column. Observed by rendering the real pane with four populated entries:
/// every «перевод» field was blank, with no indication why. The language picker that would
/// have explained it is `.labelsHidden()` and carries only a tooltip.
///
/// ## The rule
///
/// Show the language the user's glossary is actually written in. Fall back to the language the
/// app translates *into* by default — the primary one — when the glossary cannot say: it is
/// empty, or has no translations at all, or two languages tie.
///
/// Deriving it from content rather than from either setting is what makes both directions
/// work. A user who writes Russian and translates it to English accumulates `en` entries and
/// sees the `en` column; the reverse user sees `ru`. Neither has to know the picker exists.
///
/// ## The caller must not call this on every keystroke
///
/// The same contract `GlossaryOrder` carries, and here the consequence is worse than a row
/// moving. `GlossaryEntryRow` binds its field to `entry.translations[language.rawValue]`, so a
/// language that changed between one keystroke and the next would write the rest of the word
/// into a **different key** — splitting one translation across two languages, silently, in a
/// file the user hand-edits. `SettingsGlossaryView` therefore computes this once when the pane
/// appears and again only when the file is re-read, and stores the answer.
enum GlossaryColumn {
    /// - Parameters:
    ///   - entries: the glossary as it stands.
    ///   - fallback: what to show when the entries do not decide it. The caller passes
    ///     `settings.primaryLanguage`; it is a parameter so the rule can be tested without
    ///     standing up `AppSettings`.
    static func language(for entries: [GlossaryEntry], fallback: Language) -> Language {
        var counts: [Language: Int] = [:]
        for entry in entries {
            // A «не переводить» entry is not evidence about which language the user works in.
            // `GlossaryEntry.requiredTranslation(for:)` lets `doNotTranslate` win over
            // `translations` everywhere the engine consults it, and `GlossaryEntryRow` disables
            // the field — so whatever such an entry still carries is stale text that nothing
            // uses. Counting it would let ten disabled rows with a leftover `en` value hide the
            // one live `ru` entry the user actually cares about.
            guard !entry.doNotTranslate else { continue }
            for (code, translation) in entry.translations {
                // A hand-edited file can hold anything. An unknown code is not a language this
                // app can show a column for, and a blank translation is the absence of one —
                // `GlossaryEntryRow` removes the key rather than storing `""`, so a blank value
                // here can only have come from outside the app.
                guard let language = Language(rawValue: code),
                      !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                counts[language, default: 0] += 1
            }
        }
        guard let best = counts.values.max(), best > 0 else { return fallback }
        let leaders = counts.filter { $0.value == best }.keys
        // The fallback wins a tie, which is the case that matters: a glossary with one `en`
        // entry and one `ru` entry on a default install is a user who mostly translates into
        // Russian and has one entry going the other way.
        if leaders.contains(fallback) { return fallback }
        // No fallback among the leaders, so pick by raw value rather than by whatever order
        // `Dictionary` hands back — the same reasoning as `WarningsView.rendered`, which sorts
        // its keys for exactly this: an arbitrary choice renders differently between runs.
        return leaders.min { $0.rawValue < $1.rawValue } ?? fallback
    }
}
