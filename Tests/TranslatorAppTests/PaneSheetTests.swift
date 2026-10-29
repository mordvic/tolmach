// Tests/TranslatorAppTests/PaneSheetTests.swift
import Testing
@testable import TranslationCore
@testable import TranslatorApp

// MARK: - The split between the sheets

@Test func anEvenSplitGivesEachSheetHalfOfWhatTheGapLeaves() {
    // 1084 is the window's 1100 less the frame's two 8 pt sides; the gap takes 8 more.
    #expect(PaneSheet.leadingWidth(total: 1084, fraction: 0.5,
                                   leadingMin: 280, trailingMin: 360) == 538)
}

@Test func theBoundaryStopsAtTheSourceSheetsFloor() {
    // Mutation: the `max(…, leadingMin)` dropped → 108 here.
    #expect(PaneSheet.leadingWidth(total: 1084, fraction: 0.1,
                                   leadingMin: 280, trailingMin: 360) == 280)
}

@Test func theBoundaryStopsWhereTheTranslationSheetWouldGoUnderItsFloor() {
    // 1076 available, 360 kept for the перевод sheet → 716 at most.
    // Mutation: the ceiling dropped → 968 here, and the перевод sheet 108 pt wide.
    #expect(PaneSheet.leadingWidth(total: 1084, fraction: 0.9,
                                   leadingMin: 280, trailingMin: 360) == 716)
}

@Test func atTheWindowsMinimumTheBoundaryTravelsBetweenTheTwoFloors() {
    // 700 less the frame's 16 is 684; the gap leaves 676, and the floors want 640 — so the
    // boundary has 36 pt of travel, and both ends of it are the floors.
    #expect(PaneSheet.leadingWidth(total: 684, fraction: 0, leadingMin: 280, trailingMin: 360) == 280)
    #expect(PaneSheet.leadingWidth(total: 684, fraction: 1, leadingMin: 280, trailingMin: 360) == 316)
}

@Test func whenTheFloorsCannotBothFitTheSourceSheetKeepsItsOwn() {
    #expect(PaneSheet.leadingWidth(total: 500, fraction: 0.5,
                                   leadingMin: 280, trailingMin: 360) == 280)
}

// MARK: - The language over a sheet

@MainActor
@Test func aChosenLanguageIsNamedPlainly() {
    #expect(LanguageMenu.title(selection: .de, resolved: .ru, placeholder: "По правилу") == "Немецкий")
}

@MainActor
@Test func aLanguageTheSheetsTextIsInIsNamedWhenNoneIsChosen() {
    // Mutation: `resolved` dropped from the title → «По правилу» here.
    #expect(LanguageMenu.title(selection: nil, resolved: .ru, placeholder: "По правилу") == "Русский")
}

@MainActor
@Test func withNothingKnownTheHeaderShowsThePlaceholderItsMenuOffers() {
    #expect(LanguageMenu.title(selection: nil, resolved: nil, placeholder: "Определить язык")
            == "Определить язык")
}

@Test func aStandaloneLanguageNameStartsWithACapital() {
    #expect(Language.ru.russianTitle == "Русский")
    // The running-text form is untouched: «перевод на немецкий».
    #expect(Language.de.russianName == "немецкий")
}

// MARK: - «Локально»

@MainActor
@Test func theLocalityLineNamesTheEngineAndTheModel() {
    #expect(RunStatusBar.localityLine(engineName: "Ollama", modelName: "aya-expanse:8b")
            == "Локально · Ollama · aya-expanse:8b")
    #expect(RunStatusBar.localityLine(engineName: "LM Studio", modelName: nil) == "Локально · LM Studio")
}
