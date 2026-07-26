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

@Test func ignoredTermsMatchRegardlessOfCase() {
    // CC-6: term surfaces come from first occurrence, so a sentence-initial term
    // carries a capital the ignore-list entry may not. "Ignore" must still exclude
    // it permanently, not only when the case happens to line up.
    let entries = [GlossaryEntry(term: "Profile Server", translations: ["en": "profile server"])]
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

@Test func aTermInsideAURLIsNotReportedMissing() {
    // "FHIR" is present inside "fhir.org" but NLTagger sees one token, not two.
    let entries = [GlossaryEntry(term: "FHIR", doNotTranslate: true)]
    let checks = GlossaryVerifier.check(translation: "Смотри fhir.org для деталей.",
                                        entries: entries, target: .ru)
    #expect(checks.count == 1)
    #expect(checks[0].status != .missing)
}

@Test func aGenuinelyAbsentTermIsStillReportedMissing() {
    // The suppression must not swallow real violations.
    let entries = [GlossaryEntry(term: "profile server", translations: ["ru": "сервер профилей"])]
    let checks = GlossaryVerifier.check(translation: "База данных перезапустилась ночью.",
                                        entries: entries, target: .ru)
    #expect(checks[0].status == .missing)
}

@Test func caseDiffersButTheFormIsPresent() {
    let entries = [GlossaryEntry(term: "FHIR", doNotTranslate: true)]
    let checks = GlossaryVerifier.check(translation: "См. Fhir.org и далее.",
                                        entries: entries, target: .ru)
    #expect(checks[0].status != .missing)
}

@Test func aCoincidentalSubstringDoesNotForgiveARealViolation() {
    // "id" appears inside "valid", but the required "ID" was never rendered.
    let entries = [GlossaryEntry(term: "ID", doNotTranslate: true)]
    let checks = GlossaryVerifier.check(translation: "Это утверждение является valid для всех случаев.",
                                        entries: entries, target: .ru)
    #expect(checks[0].status == .missing)
}
