import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

@Test func promotingDocumentTermsAddsTheEditedFormAndNotTheModelsOriginal() {
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "profile", translations: ["ru": "профиль"])],
        to: Glossary(entries: []))
    #expect(promoted.contains { $0.term == "profile" && $0.translations["ru"] == "профиль" })
}

@Test func promotingATermTheGlossaryAlreadyHasLeavesTheUsersOwnVersionAlone() {
    let existing = Glossary(entries: [GlossaryEntry(term: "profile", doNotTranslate: true)])
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "Profile", translations: ["ru": "анкета"])],
        to: existing)
    // The user's own entry is the authority; promoting must not quietly retranslate it.
    // Compared case-insensitively, because GlossaryMerge is.
    #expect(promoted.count == 1)
    #expect(promoted[0].doNotTranslate)
}

@Test func promotingKeepsTheGlossarysOwnOrderAndAppendsWhatIsNew() {
    let existing = Glossary(entries: [GlossaryEntry(term: "slice", translations: ["ru": "срез"])])
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "cardinality", translations: ["ru": "кратность"])],
        to: existing)
    #expect(promoted.map(\.term) == ["slice", "cardinality"])
}

@Test func promotingNothingLeavesTheGlossaryUntouched() {
    let existing = Glossary(entries: [GlossaryEntry(term: "slice")])
    #expect(GlossaryPromotion.entries(adding: [], to: existing).map(\.term) == ["slice"])
}

@Test func aTermWithNoTranslationTypedIntoItIsNotWorthPromoting() {
    // An empty «перевод» field is a row the user did not fill in. Storing it would put a
    // term in the glossary that GlossaryVerifier can never satisfy.
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "slice", translations: ["ru": ""]),
                 GlossaryEntry(term: "profile", translations: [:])],
        to: Glossary(entries: []))
    #expect(promoted.isEmpty)
}
