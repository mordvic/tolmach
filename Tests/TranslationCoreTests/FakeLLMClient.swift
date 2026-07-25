// Tests/TranslationCoreTests/FakeLLMClient.swift
import Foundation
@testable import TranslationCore

/// Deterministic fake. Returns queued responses in order; records the prompts it saw.
final class FakeLLMClient: LLMClient, @unchecked Sendable {
    private(set) var receivedMessages: [[ChatMessage]] = []
    private var responses: [String]
    init(responses: [String]) { self.responses = responses }

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        receivedMessages.append(messages)
        let reply = responses.isEmpty ? "" : responses.removeFirst()
        return AsyncThrowingStream { continuation in
            for piece in reply.map(String.init) { continuation.yield(.token(piece)) }
            continuation.yield(.done(ChatStats(loadDurationMS: 10, promptEvalCount: 5,
                promptEvalDurationMS: 5, evalCount: reply.count, evalDurationMS: 20)))
            continuation.finish()
        }
    }
}
