// Tests/TranslationCoreTests/LemmaMatcherTests.swift
import Testing
@testable import TranslationCore

@Test func matchesAcrossEnglishInflection() {
    // gating case — English lemmatization is reliable
    #expect(LemmaMatcher.matches(expected: "implementation guide",
                                 in: "Publishing the implementation guides locally.",
                                 language: .en) == true)
}

@Test func reportsAbsenceWhenTermIsNotPresent() {
    #expect(LemmaMatcher.matches(expected: "profile server",
                                 in: "The database cluster restarted overnight.",
                                 language: .en) == false)
}

@Test func matchesAcrossRussianCase() {
    // real-world target: genitive «руководства» must match nominative «руководство»
    let result = LemmaMatcher.matches(expected: "руководство по реализации",
                                      in: "Публикация руководства по реализации на сервере.",
                                      language: .ru)
    // Accept true; tolerate nil (unverifiable) but never a false negative.
    #expect(result != false)
}

// MARK: - The rule itself, independent of what this machine can lemmatise
//
// The three tests above cannot pin the rule: each of them runs `NLTagger`, so each answers a
// question about the machine as much as about the code. `matchesAcrossRussianCase` passes on a
// macOS with Russian lemma data and fails on one without — which is how CI found the defect
// these cover, on its first run. `decide` takes the tagged words as values, so these do not
// depend on the environment at all.

/// Nothing to look for. The one `nil` case the old code could actually reach.
@Test func anEmptyExpectedTermCannotBeVerified() {
    #expect(LemmaMatcher.decide(needle: ([], lemmatised: false),
                                haystack: (["a", "b"], lemmatised: true)) == nil)
    #expect(LemmaMatcher.decide(needle: ([], lemmatised: true),
                                haystack: (["a", "b"], lemmatised: true)) == nil)
}

/// The ordinary success, and it must stay a success whether or not anything was normalised —
/// identical words really do occur, however they were produced.
@Test func aContiguousRunOfTheExpectedWordsMatchesEitherWay() {
    let hay = ["публикация", "руководство", "по", "реализация", "на", "сервер"]
    let needle = ["руководство", "по", "реализация"]
    #expect(LemmaMatcher.decide(needle: (needle, lemmatised: true),
                                haystack: (hay, lemmatised: true)) == true)
    #expect(LemmaMatcher.decide(needle: (needle, lemmatised: false),
                                haystack: (hay, lemmatised: false)) == true)
}

/// **The defect CI found.** With nothing normalised on either side the words compared were
/// surface forms, and a surface comparison cannot tell an absent term from an inflected one —
/// «руководства» is not «руководство» as a string, and is the same word. Reporting `false`
/// there is what made `GlossaryVerifier` raise `.missing` on a correct translation.
@Test func aMissWithNothingLemmatisedOnEitherSideIsUnverifiable() {
    #expect(LemmaMatcher.decide(needle: (["руководство"], lemmatised: false),
                                haystack: (["публикация", "руководства"], lemmatised: false)) == nil)
}

/// **The case the first version of the fix got wrong.** A term can have no lemma of its own on
/// a perfectly equipped machine — «ID» is an acronym and `NLTagger` returns nothing for it. The
/// haystack is running prose, so its flag is what says whether this language can be lemmatised
/// at all; against a normalised haystack a miss is a real miss. Reading the needle's flag alone
/// turned `aCoincidentalSubstringDoesNotForgiveARealViolation` into `.unverifiable` and switched
/// off the check it exists to keep.
@Test func anUnlemmatisableTermIsStillCheckedAgainstALemmatisedTranslation() {
    #expect(LemmaMatcher.decide(needle: (["id"], lemmatised: false),
                                haystack: (["это", "утверждение", "являться", "valid"],
                                           lemmatised: true)) == false)
}

/// The other side of the same coin, and the reason this is not «return nil whenever unsure»:
/// once the words have been normalised a miss is a real miss and must stay reportable, or the
/// checker stops saying anything at all.
@Test func aLemmatisedMissIsStillAbsence() {
    #expect(LemmaMatcher.decide(needle: (["сервер", "профиль"], lemmatised: true),
                                haystack: (["база", "данные", "перезапуск"], lemmatised: true)) == false)
}

/// A haystack shorter than the needle takes the same fork rather than short-circuiting to
/// `false`: it is still «not found», and whether that means absent still depends on the witness.
@Test func aTooShortTranslationFollowsTheSameRule() {
    #expect(LemmaMatcher.decide(needle: (["a", "b", "c"], lemmatised: true),
                                haystack: (["a"], lemmatised: false)) == false)
    #expect(LemmaMatcher.decide(needle: (["a", "b", "c"], lemmatised: false),
                                haystack: (["a"], lemmatised: false)) == nil)
}
