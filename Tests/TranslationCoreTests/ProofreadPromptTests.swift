import Testing
@testable import TranslationCore

@Test func theProofreadPromptCarriesTheLevelInstructionAndTheTranslationBan() {
    let messages = PromptBuilder.proofreadMessages(text: "Превет, мир.", language: .ru,
                                                   level: .errorsOnly, style: .original)
    let system = messages.first { $0.role == "system" }!.content
    #expect(system.contains(ProofreadingLevel.errorsOnly.instruction))
    #expect(system.contains("Never translate"))
    // The single most damaging failure is a model that helpfully translates, so a known
    // language is named twice — about the text and about the output (spec §4.2).
    #expect(system.components(separatedBy: "Russian").count >= 3)
    let user = messages.last!.content
    #expect(user.contains("<text>"))
    #expect(user.contains("Превет, мир."))
}

@Test func theStyleInstructionReachesThePromptOnlyUnderErrorsAndStyle() {
    let friendly = RewriteStyle.friendly.instruction!
    let with = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsAndStyle,
                                                   style: .friendly)
    #expect(with.contains(friendly))
    // The engine-side half of the rule the UI expresses by disabling the control:
    // a style passed with .errorsOnly never reaches the prompt (spec §4.1).
    let errorsOnly = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsOnly,
                                                         style: .friendly)
    #expect(!errorsOnly.contains(friendly))
    let original = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsAndStyle,
                                                       style: .original)
    #expect(!original.contains(friendly))
}

@Test func anUndetectedLanguageKeepsTheBanWithoutNamingALanguage() {
    let system = PromptBuilder.proofreadSystemPrompt(language: nil, level: .errorsOnly,
                                                     style: .original)
    #expect(system.contains("same language as the original"))
    #expect(!system.contains("The text is in"))
}

@Test func theProofreadPromptSharesTheProtectionRulesAndCarriesNoGlossary() {
    let system = PromptBuilder.proofreadSystemPrompt(language: .en, level: .errorsOnly,
                                                     style: .original)
    #expect(system.contains("fenced code blocks"))
    #expect(system.contains("byte for byte"))
    #expect(system.contains("URLs"))
    #expect(system.lowercased().contains("only the corrected text"))
    // Правка has no target language to key translations[target] on (spec §4.2).
    #expect(!system.contains("Terminology"))
}
