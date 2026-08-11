// Tests/OllamaKitTests/OllamaChatBodyTests.swift
import Testing
import Foundation
@testable import OllamaKit
@testable import TranslationCore

private let messages = [ChatMessage(role: "user", content: "Он ждёт результата.")]

@Test func aRequestWithNoThinkSettingCarriesNoThinkKeyAtAll() {
    let body = OllamaChatBody.json(messages: messages, options: ChatOptions(model: "aya-expanse:8b"))
    #expect(body["think"] == nil)
}

@Test func disablingThinkingWritesAJSONBooleanAndNotTheStringFalse() {
    let body = OllamaChatBody.json(messages: messages,
                                   options: ChatOptions(model: "qwen3:8b", think: .off))
    #expect(body["think"] as? Bool == false)
    // The whole reason this function exists: Ollama reads `think` as a level when it is a
    // string, so `"false"` would ask for a *level named false* rather than for silence.
    #expect(body["think"] as? String == nil)
}

@Test func aThinkingLevelIsWrittenAsItsRawString() {
    for level in ThinkRequest.Level.allCases {
        let body = OllamaChatBody.json(messages: messages,
                                       options: ChatOptions(model: "gpt-oss:20b", think: .level(level)))
        #expect(body["think"] as? String == level.rawValue)
        #expect(body["think"] as? Bool == nil)
    }
}

@Test func theThinkFieldChangesNothingElseInTheBody() {
    let options = ChatOptions(model: "qwen3:8b", temperature: 0.35, keepAlive: "5m", think: .off)
    let body = OllamaChatBody.json(messages: messages, options: options)
    #expect(body["model"] as? String == "qwen3:8b")
    #expect(body["stream"] as? Bool == true)
    #expect(body["keep_alive"] as? String == "5m")
    #expect((body["options"] as? [String: Any])?["temperature"] as? Double == 0.35)
    let sent = body["messages"] as? [[String: String]]
    #expect(sent?.count == 1)
    #expect(sent?.first?["role"] == "user")
    #expect(sent?.first?["content"] == "Он ждёт результата.")
}

@Test func theBodyIsSerialisableAsJSON() {
    // `JSONSerialization` throws on a dictionary holding a non-JSON value, and `chat` builds
    // its request with `try`. A body that cannot be serialised would surface as a failed
    // translation with a transport error, which is the least diagnosable shape this can take.
    let body = OllamaChatBody.json(messages: messages,
                                   options: ChatOptions(model: "gpt-oss:20b", think: .level(.high)))
    #expect(throws: Never.self) { try JSONSerialization.data(withJSONObject: body) }
}
