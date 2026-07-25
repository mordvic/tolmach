// Tests/TranslationCoreTests/LanguageTests.swift
import Testing
@testable import TranslationCore

@Test func detectsRussianAndEnglish() {
    #expect(LanguageDetector.detect("Сервер профилей проверяет ресурсы перед публикацией.") == .ru)
    #expect(LanguageDetector.detect("The profile server validates resources before publishing.") == .en)
}

@Test func detectReturnsNilForUnsupportedOrEmpty() {
    #expect(LanguageDetector.detect("") == nil)
}

@Test func everyLanguageHasEnglishNameAndCode() {
    for language in Language.allCases {
        #expect(!language.englishName.isEmpty)
        #expect(language.shortCode.count == 2)
    }
}

@Test func toneInstructionsAreNonEmptyAndDistinct() {
    let instructions = Tone.allCases.map(\.instruction)
    #expect(Set(instructions).count == Tone.allCases.count)
}
