// Tests/TranslationCoreTests/FakeLLMClient.swift
import Foundation
@testable import TranslationCore

/// Deterministic fake. Returns queued responses in order; records the prompts it saw.
final class FakeLLMClient: LLMClient, @unchecked Sendable {
    private(set) var receivedMessages: [[ChatMessage]] = []
    private var responses: [String]
    /// Matched by call order to `responses`: when non-nil for a given call, that
    /// call's stream fails instead of producing tokens. Shorter than `responses` is
    /// fine — calls past the end of this array never fail.
    private var errors: [Error?]
    /// Sleep before yielding every token, when set. A fully-synchronous fake never
    /// suspends, so a task cancelled while consuming it has no window in which the
    /// cancellation can actually land — everything is already buffered by the time
    /// anyone could observe it. This delay is what lets a cancellation test catch
    /// the stream genuinely mid-flight, the way a real network response would.
    private let delayPerToken: Duration?

    init(responses: [String], delayPerToken: Duration? = nil, errors: [Error?] = []) {
        self.responses = responses
        self.delayPerToken = delayPerToken
        self.errors = errors
    }

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        receivedMessages.append(messages)
        let reply = responses.isEmpty ? "" : responses.removeFirst()
        let error = errors.isEmpty ? nil : errors.removeFirst()
        let delayPerToken = delayPerToken
        return AsyncThrowingStream { continuation in
            let producer = Task {
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for piece in reply.map(String.init) {
                    if let delayPerToken { try? await Task.sleep(for: delayPerToken) }
                    continuation.yield(.token(piece))
                }
                continuation.yield(.done(ChatStats(loadDurationMS: 10, promptEvalCount: 5,
                    promptEvalDurationMS: 5, evalCount: reply.count, evalDurationMS: 20)))
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
