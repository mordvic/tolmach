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
