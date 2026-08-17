// Tests/TranslationCoreTests/GlossaryVerifierTests.swift
import Testing
@testable import TranslationCore

/// Whether this machine can lemmatise `language` at all.
///
/// A property of the OS's NaturalLanguage data rather than of this code, and the two tests
/// below cannot hold without it. Measured on a `macos-15` CI runner: Russian produced no lemma
/// for any word, while the same call on macOS 26 lemmatises 4 words out of 4.
///
/// Where there is no lemma data, `LemmaMatcher.decide` returns `nil` and a check becomes
/// `.unverifiable` — deliberately, because a surface comparison cannot tell an absent term from
/// an inflected one, and answering `.missing` there is the false alarm spec §4.6 forbids. That
/// trade is recorded in `docs/reference/OPEN-ITEMS.md` §2.
///
/// **Gated rather than relaxed.** Rewriting these two as `!= .satisfied` would let
/// `.unverifiable` satisfy them everywhere, and then nothing would notice if the checker went
/// quiet on a machine that *can* lemmatise — `docs/reference/TESTING.md`'s first lesson. The rule itself
/// is pinned machine-independently by `aLemmatisedMissIsStillAbsence` in `LemmaMatcherTests`;
/// these two are the end-to-end confirmation, and they run wherever the data exists.
private func lemmatises(_ language: Language, sample: String) -> Bool {
    LemmaMatcher.tagged(sample, language: language).lemmatised
}

private let russianIsLemmatised = lemmatises(.ru, sample: "Публикация руководства по реализации.")

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

@Test(.enabled(if: russianIsLemmatised, "no Russian lemma data on this machine"))
func aGenuinelyAbsentTermIsStillReportedMissing() {
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

@Test(.enabled(if: russianIsLemmatised, "no Russian lemma data on this machine"))
func aCoincidentalSubstringDoesNotForgiveARealViolation() {
    // "id" appears inside "valid", but the required "ID" was never rendered.
    let entries = [GlossaryEntry(term: "ID", doNotTranslate: true)]
    let checks = GlossaryVerifier.check(translation: "Это утверждение является valid для всех случаев.",
                                        entries: entries, target: .ru)
    #expect(checks[0].status == .missing)
}
