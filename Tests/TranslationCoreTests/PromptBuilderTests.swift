// Tests/TranslationCoreTests/PromptBuilderTests.swift
import Testing
@testable import TranslationCore

@Test func systemPromptForbidsPreambleAndProtectsCode() {
    let request = TranslationRequest(text: "hello", source: .en, target: .de, tone: .technical)
    let system = PromptBuilder.systemPrompt(for: request)
    #expect(system.contains("German"))
    #expect(system.lowercased().contains("only the translation"))
    #expect(system.contains("code")) // code-block protection rule present
    #expect(system.contains(Tone.technical.instruction))
}

@Test func glossaryEntriesAppearInSystemPrompt() {
    let request = TranslationRequest(
        text: "the profile server", source: .en, target: .ru, tone: .neutral,
        glossaryEntries: [
            GlossaryEntry(term: "FHIR", doNotTranslate: true),
            GlossaryEntry(term: "profile server", translations: ["ru": "сервер профилей"]),
        ])
    let system = PromptBuilder.systemPrompt(for: request)
    #expect(system.contains("Terminology"))
    #expect(system.contains("FHIR"))
    #expect(system.contains("сервер профилей"))
}

@Test func terminologyHeaderIsOmittedWhenNoEntryResolvesForTheTarget() {
    // Entry matched the text by substring but says nothing about Russian.
    let request = TranslationRequest(
        text: "the profile server", source: .en, target: .ru, tone: .neutral,
        glossaryEntries: [GlossaryEntry(term: "profile server", translations: ["de": "Profilserver"])])
    let system = PromptBuilder.systemPrompt(for: request)
    #expect(!system.contains("Terminology"))
}

@Test func termListPromptDemandsEchoedTermFormat() {
    let messages = PromptBuilder.termListMessages(terms: ["profile server", "changelog"], target: .ru)
    let system = messages.first { $0.role == "system" }!.content
    // The "=>" contract is what makes the parser immune to line shifts.
    #expect(system.contains("=>"))
    #expect(system.lowercased().contains("echo"))
    let user = messages.last!.content
    #expect(user.contains("profile server"))
    #expect(user.contains("changelog"))
    // No numbering: a numbered reply would put "1. " inside the parsed term.
    #expect(!user.contains("1."))
}
