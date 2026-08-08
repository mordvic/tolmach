// Sources/TranslatorApp/WarningsView.swift
import SwiftUI
import TranslationCore

struct WarningsView: View {
    // The three things this view actually reads, rather than the whole outcome it used to
    // take. The file queue keeps a reduced `JobResult` — an outcome carries `chunks` and
    // `translatedChunks` too, roughly three copies of the document — and `TranslationOutcome`
    // has no public initialiser, so it could not be reassembled even if that were wanted.
    // A second copy of this view is how two surfaces come to describe one run differently.
    let checks: [GlossaryCheck]
    let markupDiffs: [MarkupDiff]
    let documentGlossary: [GlossaryEntry]
    /// The target `TranslationViewModel` actually resolved for this run. Needed because
    /// `GlossaryEntry.translations` is keyed by language and `TranslationOutcome` does not
    /// carry the target — see `TranslationViewModel.resolvedTarget`.
    var target: Language?
    /// A glossary load or save failure, in Russian. Rendered here rather than logged:
    /// a «не показывать» that silently failed to persist leaves the user believing the
    /// term is muted forever when it is only muted until the app quits.
    var onMute: (String) -> Void = { _ in }

    init(checks: [GlossaryCheck], markupDiffs: [MarkupDiff], documentGlossary: [GlossaryEntry],
         target: Language? = nil,
         onMute: @escaping (String) -> Void = { _ in }) {
        self.checks = checks
        self.markupDiffs = markupDiffs
        self.documentGlossary = documentGlossary
        self.target = target
        self.onMute = onMute
    }

    /// The window's and the panel's entry point, forwarding to the one above so that the
    /// two callers cannot end up rendering warnings differently.
    init(outcome: TranslationOutcome, target: Language? = nil,
         onMute: @escaping (String) -> Void = { _ in }) {
        self.init(checks: outcome.checks, markupDiffs: outcome.markupDiffs,
                  documentGlossary: outcome.documentGlossary,
                  target: target, onMute: onMute)
    }

    private var glossaryWarnings: [(check: GlossaryCheck, text: String)] {
        checks.compactMap { check in
            DiffPresentation.describe(check).map { (check, $0) }
        }
    }

    /// How many separate things this view has to say: one per markup diff, one per missing
    /// glossary term, and one for the document glossary as a whole (its own term count is
    /// shown in its disclosure title, not multiplied in here).
    ///
    /// A refused glossary save is **not** among them. It used to be, and it does not belong:
    /// it is the app's trouble rather than the run's, so it survives runs this view does not,
    /// and counting it here made the bar say «N+1 предупреждение» beside a file row saying
    /// «N». `RunStatusBar` draws it as a row of its own, always visible, in both modes.
    ///
    /// `hasContent` is defined in terms of this count rather than restating the same four
    /// conditions as a second boolean expression, and `RunStatusBar.summary` reads this same
    /// property rather than re-deriving a total from the outcome itself. That is what makes
    /// the two agree structurally instead of by coincidence: there is exactly one count in
    /// the program that says how many warnings exist, and both the disclosure's visibility
    /// and its label read that one value.
    var warningCount: Int {
        markupDiffs.count
            + glossaryWarnings.count
            + (documentGlossary.isEmpty ? 0 : 1)
    }

    /// Whether this view would draw anything at all.
    ///
    /// It exists so a caller can decide not to reserve space for nothing, and the defect it
    /// was written for is **historical** — the panel it describes no longer exists.
    ///
    /// What was measured, on the panel of the time: it handed the warnings a fixed 120 pt
    /// slot, and an outcome with no diffs, no missing terms and no document glossary — the
    /// ordinary case for a short, clean translation — left that slot claiming its height
    /// while rendering an empty `VStack`, costing 86 of the panel's 260 points. The
    /// translation went from nine visible lines while running to four and a half once it
    /// finished, which reads as the result being truncated at the moment it completed.
    ///
    /// Neither number describes today's panel. The UI redesign removed the fixed slot and the
    /// fixed 260 pt height together — `PanelView` says so where the gate now lives, and
    /// `PanelSizer` owns the ceiling. This flag survives that change on a narrower claim: the
    /// panel measures whatever its content view contains, so an empty `VStack` still
    /// contributes its stack spacing to a height nothing is asking for. Smaller, and still a
    /// reason not to render it.
    ///
    /// `warningCount > 0` rather than a repeated disjunction, deliberately, and that is why
    /// this lives here rather than in the caller: the two must not be able to drift. If
    /// they did, the failure is either this bug again or the opposite one — a warning with
    /// nowhere to appear.
    var hasContent: Bool { warningCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !markupDiffs.isEmpty {
                section("Разметка изменилась") {
                    ForEach(Array(markupDiffs.enumerated()), id: \.offset) { _, diff in
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
            if !documentGlossary.isEmpty {
                DisclosureGroup("Термины документа (\(documentGlossary.count))") {
                    ForEach(Array(documentGlossary.enumerated()), id: \.offset) { _, entry in
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
