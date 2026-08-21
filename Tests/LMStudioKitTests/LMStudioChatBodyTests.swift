// Tests/LMStudioKitTests/LMStudioChatBodyTests.swift
import Testing
import Foundation
@testable import LMStudioKit
@testable import TranslationCore

private let messages = [ChatMessage(role: "system", content: "Переводи на русский."),
                        ChatMessage(role: "user", content: "Он ждёт результата.")]

@Test func theBodyCarriesOnlyKeysThisServerRecognises() {
    // Measured 2026-08-21: an unknown key is **rejected**, not ignored —
    // `{"ttl": 1800}` answered HTTP 400 `"Unrecognized key(s) in object: 'ttl'"`. So the body
    // is a closed list, and `ChatOptions.keepAlive` in particular must not reach the wire:
    // residency on this engine is «loaded until unloaded», not «loaded for a duration».
    let body = LMStudioChatBody.json(messages: messages,
                                     options: ChatOptions(model: "google/gemma-4-e4b",
                                                          temperature: 0.2, keepAlive: "30m"),
                                     reasoning: "off")
    // Asserted as an equality and not as «no unexpected keys»: a one-sided check passes when a
    // key goes *missing* too, and `model` disappearing is a request the server rejects just as
    // surely (`docs/reference/TESTING.md`, shape 3).
    #expect(Set(body.keys) == ["model", "system_prompt", "input", "stream",
                               "temperature", "reasoning", "store"])
    #expect(body["keep_alive"] == nil)
    #expect(body["ttl"] == nil)
}

@Test func theSystemTurnBecomesSystemPromptAndTheUserTurnBecomesInput() {
    // The mapping this endpoint needs, and the one a key-set test cannot see: swapping the two
    // would send the text as instructions and the instructions as text, and every key would
    // still be present and correctly named.
    let body = LMStudioChatBody.json(messages: messages,
                                     options: ChatOptions(model: "google/gemma-4-e4b"),
                                     reasoning: nil)
    #expect(body["system_prompt"] as? String == "Переводи на русский.")
    #expect(body["input"] as? String == "Он ждёт результата.")
}

@Test func aRequestWithNoSystemTurnCarriesNoSystemPromptKeyRatherThanAnEmptyOne() {
    // An empty string is a system prompt that says nothing, which is not the same as not having
    // one — and this server rejects what it does not expect, so absent is the safe spelling.
    let body = LMStudioChatBody.json(messages: [ChatMessage(role: "user", content: "Он ждёт.")],
                                     options: ChatOptions(model: "google/gemma-4-e4b"),
                                     reasoning: nil)
    #expect(body["system_prompt"] == nil)
    #expect(body["input"] as? String == "Он ждёт.")
}

@Test func aResolvedReasoningValueIsWrittenAndAnUnresolvedOneIsOmitted() {
    let quiet = LMStudioChatBody.json(messages: messages,
                                      options: ChatOptions(model: "openai/gpt-oss-20b"),
                                      reasoning: "low")
    #expect(quiet["reasoning"] as? String == "low")
    let unknown = LMStudioChatBody.json(messages: messages,
                                        options: ChatOptions(model: "qwen3.5-27b"),
                                        reasoning: nil)
    #expect(unknown["reasoning"] == nil)
    #expect(unknown.keys.contains("reasoning") == false)
}

@Test func theBodyIsSerialisableAsJSON() {
    // `chat` builds its request with `try`, so a body holding a non-JSON value would surface as
    // a transport failure — the least diagnosable shape a translation failure can take.
    #expect(throws: Never.self) {
        try JSONSerialization.data(withJSONObject: LMStudioChatBody.json(
            messages: messages, options: ChatOptions(model: "google/gemma-4-e4b"), reasoning: "off"))
    }
}

@Test func everyRequestAsksTheServerNotToStoreTheConversation() {
    // `store` defaults to **true** on this endpoint: LM Studio keeps the chat and hands back a
    // `response_id`. This app writes to disk in exactly one place, and it does not get to
    // acquire a second one by omission.
    let body = LMStudioChatBody.json(messages: messages,
                                     options: ChatOptions(model: "google/gemma-4-e4b"),
                                     reasoning: nil)
    #expect(body["store"] as? Bool == false)
}
