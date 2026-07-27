import Testing
@testable import TranslatorApp
@testable import TranslationCore

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
                       totalMS: 34)
}

@Test func anOutcomeWithNothingToWarnAboutDrawsNothing() {
    // The whole point of the property. `WarningsView` renders an empty `VStack` here, and a
    // caller that reserves a fixed slot for it takes space from the translation for no
    // reason — in the panel, a run went from nine visible lines to four and a half at the
    // moment it finished, which reads as the result being truncated on completion.
    #expect(WarningsView(outcome: quietOutcome()).hasContent == false)
}

@Test func eachThingWorthShowingTurnsTheSlotBackOn() {
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

    // `problem` is a glossary load or save failure and has nothing to do with the outcome,
    // so an otherwise silent run must still make room for it.
    #expect(WarningsView(outcome: quietOutcome(), problem: "Не удалось сохранить глоссарий.")
        .hasContent)
}

@Test func aSatisfiedCheckIsNotSomethingToShow() {
    // `DiffPresentation.describe` returns nil for everything but `.missing`, so a run whose
    // every term was honoured has checks and still nothing to say. Reading `checks.isEmpty`
    // instead of the described warnings would reserve the slot for a blank box on exactly
    // the runs that went best.
    #expect(WarningsView(outcome: quietOutcome(checks: [
        GlossaryCheck(term: "endpoint", expected: "конечная точка", status: .satisfied),
        GlossaryCheck(term: "payload", expected: "полезная нагрузка", status: .unverifiable),
    ])).hasContent == false)
}
