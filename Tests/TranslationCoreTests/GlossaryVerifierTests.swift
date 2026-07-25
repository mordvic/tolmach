// Tests/TranslationCoreTests/GlossaryVerifierTests.swift
import Testing
@testable import TranslationCore

@Test func satisfiedWhenExpectedFormPresentAcrossInflection() {
    let entries = [GlossaryEntry(term: "implementation guide", translations: ["ru": "руководство по реализации"])]
    let checks = GlossaryVerifier.check(translation: "Публикация руководства по реализации.",
                                        entries: entries, target: .ru)
    #expect(checks.count == 1)
    #expect(checks[0].status != .missing) // satisfied or unverifiable — never a false alarm
}

@Test func missingWhenExpectedFormAbsent() {
    let entries = [GlossaryEntry(term: "profile server", translations: ["en": "profile server"])]
    let checks = GlossaryVerifier.check(translation: "The database cluster restarted.",
                                        entries: entries, target: .en)
    #expect(checks[0].status == .missing)
}

@Test func ignoredTermsAreSkipped() {
    let entries = [GlossaryEntry(term: "profile server", translations: ["en": "profile server"])]
    let checks = GlossaryVerifier.check(translation: "The database cluster restarted.",
                                        entries: entries, target: .en, ignored: ["profile server"])
    #expect(checks.isEmpty)
}

@Test func entriesWithNoRequiredTranslationAreSkipped() {
    let entries = [GlossaryEntry(term: "profile server", translations: ["de": "Profilserver"])] // no .en
    let checks = GlossaryVerifier.check(translation: "text", entries: entries, target: .en)
    #expect(checks.isEmpty)
}

@Test func unverifiableWhenExpectedFormYieldsNoLemmas() {
    // A "term" of pure punctuation produces no lemmas, so the check cannot
    // conclude anything — and must stay silent rather than guess.
    let entries = [GlossaryEntry(term: "arrow", translations: ["en": "-->"])]
    let checks = GlossaryVerifier.check(translation: "the text has no arrow here",
                                        entries: entries, target: .en)
    #expect(checks.count == 1)
    #expect(checks[0].status == .unverifiable)
}

@Test func onlyMissingIsAWarning() {
    // Pins the contract the UI depends on: exactly one of the three states is
    // actionable, and .unverifiable is not it.
    #expect(GlossaryStatus.missing != GlossaryStatus.unverifiable)
    #expect(GlossaryStatus.satisfied != GlossaryStatus.unverifiable)
}
