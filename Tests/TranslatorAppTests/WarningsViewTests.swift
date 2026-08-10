import Testing
@testable import TranslatorApp
@testable import TranslationCore

// MARK: - Why every test in this file is `@MainActor`
//
// Not style, and not a `@MainActor` sprinkled to silence a diagnostic. `WarningsView` is a
// `View`, and `View` is declared `@MainActor @preconcurrency`, so a closure written inside one
// of its computed properties inherits main-actor isolation — `glossaryWarnings`' `compactMap`
// closure is the one that matters here. Under `.swiftLanguageMode(.v5)` that isolation is
// never checked and these tests ran on whatever task swift-testing gave them. Under `.v6` it
// is checked at **run time**, and the check is a trap rather than a diagnostic: the build
// stays clean and the process dies.
//
// Measured when this package moved to `.v6`: the suite went from green to `signal code 5`,
// deterministic at 3 runs out of 3 against 0 out of 3 on the previous commit. The backtrace:
//
//     _dispatch_assert_queue_fail
//     _swift_task_checkIsolatedSwift
//     swift_task_isCurrentExecutorWithFlagsImpl
//     closure #1 in WarningsView.glossaryWarnings.getter
//     Sequence.compactMap
//     WarningsView.warningCount.getter → hasContent.getter
//
// Exactly two of the four tests below died — the two passing a **non-empty** `checks`. The two
// that lived pass an empty one, so `compactMap` never ran the closure at all. That is worth
// keeping in view: an empty collection hides this defect completely, which is why
// `theCollapsedStatusBarSaysHowManyWarningsAreHidingUnderIt` survived despite reaching the
// same getter through `RunStatusBar.summary`.
//
// The alternative was to declare `WarningsView` itself `nonisolated` (SE-0449). It was tried
// and rejected on measurement: it does stop the trap, but it also strips isolation from `body`,
// where `.buttonStyle(.link)` is a main-actor-isolated static — «main actor-isolated static
// property 'link' can not be referenced from a nonisolated context», plus a `sending 'self'`
// error on the `Button` closure. Annotating the three decision properties instead moved the
// error to the synthesised initialiser, and hand-writing that initialiser moved it again to
// the stored properties, which are isolated whether they are `let` or `var`. Every production
// caller of `hasContent`/`warningCount` is already on the main actor — two SwiftUI bodies and
// `RunStatusBar.summary` — so the isolation is true of this type, and it is the tests that
// were wrong to run off it.

/// An outcome with nothing worth warning about — the ordinary result of a short, clean
/// translation, and the case that cost the panel 86 of its 260 points.
private func quietOutcome(documentGlossary: [GlossaryEntry] = [],
                          checks: [GlossaryCheck] = [],
                          markupDiffs: [MarkupDiff] = []) -> TranslationOutcome {
    TranslationOutcome(final: "Привет.",
                       chunks: [],
                       translatedChunks: ["Привет."],
                       documentGlossary: documentGlossary,
                       detectedSource: .en,
                       checks: checks,
                       markupDiffs: markupDiffs,
                       stats: [],
                       timeToFirstTokenMS: 12,
                       totalMS: 34,
                       documentGlossaryFailure: nil,
                       documentGlossaryAttempted: false,
                       modelChunkCount: 1)
}

@MainActor @Test func anOutcomeWithNothingToWarnAboutDrawsNothing() {
    // The whole point of the property. `WarningsView` renders an empty `VStack` here, and a
    // caller that reserves a fixed slot for it takes space from the translation for no
    // reason — in the panel, a run went from nine visible lines to four and a half at the
    // moment it finished, which reads as the result being truncated on completion.
    #expect(WarningsView(outcome: quietOutcome()).hasContent == false)
}

@MainActor @Test func eachThingWorthShowingTurnsTheSlotBackOn() {
    // Four separate assertions rather than one composite, because the failure this guards
    // against is `hasContent` drifting from `body` on *one* of the branches — which would
    // silently drop that kind of warning rather than showing it in a smaller box.
    #expect(WarningsView(outcome: quietOutcome(markupDiffs: [
        MarkupDiff(expected: .blockquote, actual: nil, note: "dropped in translation"),
    ])).hasContent)

    #expect(WarningsView(outcome: quietOutcome(checks: [
        GlossaryCheck(term: "profile server", expected: "сервер профилей", status: .missing),
    ])).hasContent)

    #expect(WarningsView(outcome: quietOutcome(documentGlossary: [
        GlossaryEntry(term: "endpoint", translations: ["ru": "конечная точка"]),
    ])).hasContent)

    // A glossary load or save failure is deliberately **not** among them: it belongs to the
    // app and not to the run, it outlives the run, and `RunStatusBar` draws it as a row of
    // its own. Counted here it made the bar say «N+1» beside a file row saying «N».
    #expect(WarningsView(outcome: quietOutcome()).hasContent == false)
}

@MainActor @Test func aSatisfiedCheckIsNotSomethingToShow() {
    // `DiffPresentation.describe` returns nil for everything but `.missing`, so a run whose
    // every term was honoured has checks and still nothing to say. Reading `checks.isEmpty`
    // instead of the described warnings would reserve the slot for a blank box on exactly
    // the runs that went best.
    #expect(WarningsView(outcome: quietOutcome(checks: [
        GlossaryCheck(term: "endpoint", expected: "конечная точка", status: .satisfied),
        GlossaryCheck(term: "payload", expected: "полезная нагрузка", status: .unverifiable),
    ])).hasContent == false)
}

@MainActor @Test func theCollapsedStatusBarSaysHowManyWarningsAreHidingUnderIt() {
    // A disclosure triangle with no summary is a triangle the user has no reason to press.
    // The summary must agree with `WarningsView.hasContent` exactly: a bar that offered «0
    // предупреждений» would be a control that expands to nothing.
    #expect(RunStatusBar.summary(outcome: quietOutcome()) == nil)

    let dropped = MarkupDiff(expected: .paragraphBreak, actual: nil,
                             note: "dropped in translation")
    let added = MarkupDiff(expected: nil, actual: .hardLineBreak, note: "added in translation")

    #expect(RunStatusBar.summary(outcome: quietOutcome(markupDiffs: [dropped])) == "1 предупреждение")
    #expect(RunStatusBar.summary(
        outcome: quietOutcome(markupDiffs: [dropped, added])) == "2 предупреждения")
}

@MainActor @Test func theTwoWarningCountsForOneFileAgreeWithTheViewThatDrawsThem() {
    // `JobResult.warningCount`/`disclosureCount` are a second, independent spelling of
    // `WarningsView.warningCount`. Two mutations survived: counting `.unverifiable`, and
    // dropping the документный-глоссарий term. Both put two different numbers for one файл
    // on screen at once — the row's and the bar's — which is the failure the doc comments
    // on both sides name.
    let result = JobResult(
        final: "перевод",
        checks: [
            GlossaryCheck(term: "endpoint", expected: "конечная точка", status: .missing),
            // The one that must **not** count: `LemmaMatcher` could not decide, which is a
            // statement about the checker. Counted, `stopOnWarnings` pauses on every
            // Japanese file.
            GlossaryCheck(term: "payload", expected: "полезная нагрузка", status: .unverifiable),
            GlossaryCheck(term: "server", expected: "сервер", status: .satisfied),
        ],
        markupDiffs: [MarkupDiff(expected: .blockquote, actual: nil, note: "dropped in translation")],
        documentGlossary: [GlossaryEntry(term: "endpoint", translations: ["ru": "конечная точка"])],
        elapsedMS: 10)

    let view = WarningsView(checks: result.checks, markupDiffs: result.markupDiffs,
                            documentGlossary: result.documentGlossary, target: .ru)

    // «Is something wrong with this файл» — the number `stopOnWarnings` reads.
    #expect(result.warningCount == 2)
    // «What is under the chevron» — and it is the view's own count, asked of the view.
    #expect(result.disclosureCount == view.warningCount)
    #expect(view.warningCount == 3)
}
