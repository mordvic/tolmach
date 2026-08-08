import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

@Test func promotingDocumentTermsAddsTheEditedFormAndNotTheModelsOriginal() {
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "profile", translations: ["ru": "профиль"])],
        to: Glossary(entries: []), target: .ru)
    #expect(promoted.contains { $0.term == "profile" && $0.translations["ru"] == "профиль" })
}

@Test func promotingATermTheGlossaryAlreadyHasLeavesTheUsersOwnVersionAlone() {
    let existing = Glossary(entries: [GlossaryEntry(term: "profile", doNotTranslate: true)])
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "Profile", translations: ["ru": "анкета"])],
        to: existing, target: .ru)
    // The user's own entry is the authority; promoting must not quietly retranslate it.
    // Compared case-insensitively, because GlossaryMerge is.
    #expect(promoted.count == 1)
    #expect(promoted[0].doNotTranslate)
}

@Test func promotingKeepsTheGlossarysOwnOrderAndAppendsWhatIsNew() {
    let existing = Glossary(entries: [GlossaryEntry(term: "slice", translations: ["ru": "срез"])])
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "cardinality", translations: ["ru": "кратность"])],
        to: existing, target: .ru)
    #expect(promoted.map(\.term) == ["slice", "cardinality"])
}

@Test func promotingNothingLeavesTheGlossaryUntouched() {
    let existing = Glossary(entries: [GlossaryEntry(term: "slice")])
    #expect(GlossaryPromotion.entries(adding: [], to: existing, target: .ru).map(\.term) == ["slice"])
}

@Test func aTermWithNoTranslationTypedIntoItIsNotWorthPromoting() {
    // An empty «перевод» field is a row the user did not fill in. Storing it would put a
    // term in the glossary that GlossaryVerifier can never satisfy.
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "slice", translations: ["ru": ""]),
                 GlossaryEntry(term: "profile", translations: [:])],
        to: Glossary(entries: []), target: .ru)
    #expect(promoted.isEmpty)
}

@Test func anEntryWhoseTargetTranslationIsEmptyIsDroppedEvenIfAnotherLanguageHasOne() {
    // Spelled as «any language has something», this rule let through an entry carrying a
    // stale key for another language with the target's own value cleared — stored as
    // translations[target] == "", the very shape it exists to drop, and the one
    // PromptBuilder gates on key-presence rather than value.
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "slice", translations: ["de": "Schnitt", "ru": ""])],
        to: Glossary(entries: []), target: .ru)
    #expect(promoted.isEmpty)
}

@Test func aDoNotTranslateEntryIsPromotedWithNoTranslationAtAll() {
    // `requiredTranslation(for:)` answers with the term itself for these, so the guard
    // passes without a single translation stored — which is right: the term is its own
    // required form.
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "StructureDefinition", doNotTranslate: true)],
        to: Glossary(entries: []), target: .ru)
    #expect(promoted.map(\.term) == ["StructureDefinition"])
}

@Test func aFieldClearedWithASpaceIsNotATranslation() {
    // The sheet writes the raw field into `translations[target]`, so «clearing» a row by
    // typing a space leaves `" "` — not empty, and not something GlossaryVerifier can ever
    // honour. Trimmed on both doors, this one and the engine's post-review filter.
    let promoted = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "API", translations: ["ru": " "]),
                 GlossaryEntry(term: "slice", translations: ["ru": "\n\t "])],
        to: Glossary(entries: []), target: .ru)
    #expect(promoted.isEmpty)
}
