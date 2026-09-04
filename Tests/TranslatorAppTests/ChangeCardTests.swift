// Tests/TranslatorAppTests/ChangeCardTests.swift
//
// `ChangeCard.of(_:)` — the popover's content, and its three shapes (issue #89).
import Testing
@testable import TranslationCore
@testable import TranslatorApp

private func change(removed: String, inserted: String,
                    scope: TextChange.Scope = .words) -> TextChange {
    TextChange(scope: scope, block: 0, insertedTokens: 0..<max(inserted.isEmpty ? 0 : 1, 0),
              removed: removed, inserted: inserted)
}

@Test func aSubstitutionShowsBothHalvesWithTheArrow() {
    let card = ChangeCard.of(change(removed: "Отчет", inserted: "Отчёт"))
    #expect(card.removed == "Отчет")
    #expect(card.inserted == "Отчёт")
    #expect(card.showsArrow)
}

@Test func aPureRemovalShowsOnlyWhatWasRemovedAndNoArrow() {
    let card = ChangeCard.of(change(removed: ", пожалуйста,", inserted: ""))
    #expect(card.removed == ", пожалуйста,")
    #expect(card.inserted == nil)
    #expect(!card.showsArrow)
}

@Test func aPureInsertionShowsOnlyWhatWasInsertedAndNoArrow() {
    let card = ChangeCard.of(change(removed: "", inserted: "уже"))
    #expect(card.removed == nil)
    #expect(card.inserted == "уже")
    #expect(!card.showsArrow)
}
