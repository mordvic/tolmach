// Sources/TranslatorApp/WarningsView.swift
import SwiftUI
import TranslationCore

struct WarningsView: View {
    let outcome: TranslationOutcome
    /// The target `TranslationViewModel` actually resolved for this run. Needed because
    /// `GlossaryEntry.translations` is keyed by language and `TranslationOutcome` does not
    /// carry the target — see `TranslationViewModel.resolvedTarget`.
    var target: Language?
    /// A glossary load or save failure, in Russian. Rendered here rather than logged:
    /// a «не показывать» that silently failed to persist leaves the user believing the
    /// term is muted forever when it is only muted until the app quits.
    var problem: String?
    var onMute: (String) -> Void = { _ in }

    private var glossaryWarnings: [(check: GlossaryCheck, text: String)] {
        outcome.checks.compactMap { check in
            DiffPresentation.describe(check).map { (check, $0) }
        }
    }

    /// Whether this view would draw anything at all.
    ///
    /// It exists so a caller can decide not to reserve space for nothing. The panel does:
    /// it hands the warnings a fixed 120pt slot, and an outcome with no diffs, no missing
    /// terms and no document glossary — the ordinary case for a short, clean translation —
    /// left that slot claiming its height while rendering an empty `VStack`, costing 86 of
    /// the panel's 260 points. The translation went from nine visible lines while running
    /// to four and a half once it finished, which reads as the result being truncated at
    /// the moment it completed.
    ///
    /// The conditions are the disjunction of `body`'s own, deliberately, and that is why
    /// this lives here rather than in the caller: the two must not be able to drift. If
    /// they did, the failure is either this bug again or the opposite one — a warning with
    /// nowhere to appear.
    var hasContent: Bool {
        problem != nil
            || !outcome.markupDiffs.isEmpty
            || !glossaryWarnings.isEmpty
            || !outcome.documentGlossary.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if !outcome.markupDiffs.isEmpty {
                section("Разметка изменилась") {
                    ForEach(Array(outcome.markupDiffs.enumerated()), id: \.offset) { _, diff in
                        Text("• " + DiffPresentation.describe(diff)).font(.caption)
                    }
                }
            }
            if !glossaryWarnings.isEmpty {
                section("Термины") {
                    // Indexed, not keyed by `check.term`. A user glossary is a hand-edited
                    // file with no uniquing anywhere on the path to `checks`
                    // (`Glossary.relevantEntries` filters, `GlossaryMerge.merge` only drops
                    // *document* entries that collide with user ones, and
                    // `GlossaryVerifier.check` is a `compactMap`), so the same term listed
                    // twice with two different translations yields two `.missing` checks.
                    // Keyed by term, SwiftUI would silently render one of them.
                    ForEach(Array(glossaryWarnings.enumerated()), id: \.offset) { _, warning in
                        HStack {
                            Text("• " + warning.text).font(.caption)
                            Button("не показывать") { onMute(warning.check.term) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
            if !outcome.documentGlossary.isEmpty {
                DisclosureGroup("Термины документа (\(outcome.documentGlossary.count))") {
                    ForEach(Array(outcome.documentGlossary.enumerated()), id: \.offset) { _, entry in
                        Text("\(entry.term) → \(rendered(entry))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Deterministic by construction. `translations` is a `[String: String]` and
    /// `Dictionary.values` has no defined order, so picking `.first` would show a
    /// different translation between renders for any entry carrying more than one.
    private func rendered(_ entry: GlossaryEntry) -> String {
        // An empty `translations` is the *point* of such an entry, not missing data:
        // the term is meant to survive translation unchanged, so «—» would be a lie.
        if entry.doNotTranslate { return "не переводить" }
        if let target, let forTarget = entry.translations[target.rawValue] { return forTarget }
        // No target, or the entry has nothing for it. Lexicographically first key rather
        // than an arbitrary one, so the same entry always renders the same way.
        if let anyTranslation = entry.translations.min(by: { $0.key < $1.key })?.value {
            return anyTranslation
        }
        return "—"
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold())
            content()
        }
    }
}
