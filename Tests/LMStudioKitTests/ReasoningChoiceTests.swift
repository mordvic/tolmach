// Tests/LMStudioKitTests/ReasoningChoiceTests.swift
import Testing
@testable import LMStudioKit
@testable import TranslationCore

/// What the live server answered on 2026-08-21, per model. These are fixtures, not guesses.
private let gptOss = ["low", "medium", "high"]          // openai/gpt-oss-20b — no «off»
private let qwen = ["off", "low", "medium", "xhigh", "on"] // qwen/qwen3.8-27b, default xhigh
private let gemma = ["off", "on"]                        // google/gemma-4-e4b, default on

@Test func aModelThatCannotBeSilencedIsAskedForItsLowestLevelRatherThanForOff() {
    // `reasoning: "off"` on this model is HTTP 400 — «Supported settings: 'low', 'medium',
    // 'high'» — so «as quiet as this model allows» is `low`. Ollama's path reaches the same
    // answer through `ModelPolicy.thinkingLevelsOnly`; here the server says it, so no table is
    // consulted and no model name is parsed.
    #expect(ReasoningChoice.value(for: .off, allowed: gptOss) == "low")
}

@Test func aModelThatAllowsOffIsAskedForOff() {
    #expect(ReasoningChoice.value(for: .off, allowed: qwen) == "off")
    #expect(ReasoningChoice.value(for: .off, allowed: gemma) == "off")
}

@Test func aModelThatReportsNoCapabilitiesIsSentNoReasoningKeyAtAll() {
    // `qwen3.5-27b` on this machine reports no `capabilities` object. Absent means unknown,
    // and unknown must not mean «send off and hope» — that is the request that returns 400.
    #expect(ReasoningChoice.value(for: .off, allowed: nil) == nil)
    #expect(ReasoningChoice.value(for: .level(.low), allowed: nil) == nil)
}

@Test func aFailedCapabilityLookupSendsNoReasoningKeyEither() {
    // The client reports a failed `/api/v1/models` read as «not known», i.e. the same empty
    // list. Paying for a trace is recoverable; a refused value is a failed translation.
    #expect(ReasoningChoice.value(for: .off, allowed: []) == nil)
}

@Test func anUnquietRunSendsNoReasoningKeyWhateverTheModelAllows() {
    for allowed in [gptOss, qwen, gemma, []] {
        #expect(ReasoningChoice.value(for: nil, allowed: allowed) == nil)
    }
}

@Test func aRequestedLevelIsHonouredWhenTheModelOffersItAndLoweredWhenItDoesNot() {
    #expect(ReasoningChoice.value(for: .level(.high), allowed: gptOss) == "high")
    #expect(ReasoningChoice.value(for: .level(.medium), allowed: gptOss) == "medium")
    // gemma offers no levels at all, so the quietest thing it does offer is silence.
    #expect(ReasoningChoice.value(for: .level(.high), allowed: gemma) == "off")
}

@Test func aModelOfferingOnlyOnGetsNoKeyBecauseOnIsNotQuieterThanItsDefault() {
    // Sending «on» would ask for exactly what the server does anyway, so the key buys nothing
    // and risks a refusal on a server that validates it differently. `on` is deliberately
    // absent from the quietest-first list.
    #expect(ReasoningChoice.value(for: .off, allowed: ["on"]) == nil)
}
