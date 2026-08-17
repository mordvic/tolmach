// Sources/TranslationCore/LLMClient.swift  (value types; protocol appended in Task 12)
import Foundation

public struct ChatMessage: Sendable, Equatable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

/// Whether to ask a model *not* to reason, and how — the request side of Ollama's `think`.
///
/// **There is deliberately no «on» case, and that absence is a safety property.** Measured
/// 2026-08-11 across all eight installed models (`docs/reference/PLATFORM-TRAPS.md`): `false` is accepted
/// by every model, including the four whose `/api/show` capabilities lack `thinking`, while
/// `true` or a level sent to one of those four answers **HTTP 400** — a failed translation, not
/// a degraded one. With no way to spell «on», no value this app can construct can fail the
/// request, which is why nothing here needs a capability probe. Adding a case removes that
/// property and must bring `/api/show` with it.
public enum ThinkRequest: Sendable, Equatable {
    /// `"think": false`. Silences `qwen3:8b` and `gemma4:26b` completely; ignored by
    /// `gpt-oss:20b`; puts the reasoning into the translation on `qwen3:30b`. Which models may
    /// be sent this is `ModelPolicy.thinkRequest(for:quiet:level:)`, not a caller's judgement.
    case off
    /// `"think": "low" | "medium" | "high"`. Grades `gpt-oss:20b` — 15 / 441 / 889 characters of
    /// trace at 0.49 / 1.99 / 3.77 s to first token, warm — and means no more than «on»
    /// elsewhere.
    case level(Level)

    public enum Level: String, Sendable, Equatable, CaseIterable { case low, medium, high }
}

public struct ChatOptions: Sendable {
    public let model: String
    public let temperature: Double
    public let keepAlive: String
    /// `nil` writes no `think` key at all, which is not the same as `.off`: absent leaves the
    /// model's own default in place — and Ollama's default for a capable model is to reason.
    public let think: ThinkRequest?
    public init(model: String, temperature: Double = 0.2, keepAlive: String = "30m",
                think: ThinkRequest? = nil) {
        self.model = model; self.temperature = temperature; self.keepAlive = keepAlive
        self.think = think
    }
}

public struct ChatStats: Sendable {
    public let loadDurationMS: Double
    public let promptEvalCount: Int
    public let promptEvalDurationMS: Double
    public let evalCount: Int
    public let evalDurationMS: Double
    public init(loadDurationMS: Double, promptEvalCount: Int, promptEvalDurationMS: Double, evalCount: Int, evalDurationMS: Double) {
        self.loadDurationMS = loadDurationMS; self.promptEvalCount = promptEvalCount
        self.promptEvalDurationMS = promptEvalDurationMS; self.evalCount = evalCount; self.evalDurationMS = evalDurationMS
    }
    public var tokensPerSecond: Double { evalDurationMS > 0 ? Double(evalCount) / (evalDurationMS / 1000) : 0 }
}

public enum ChatEvent: Sendable {
    case token(String)
    case done(ChatStats)
}

public protocol LLMClient: Sendable {
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error>
}

extension ChatStats: Equatable {}
extension ChatEvent: Equatable {
    public static func == (lhs: ChatEvent, rhs: ChatEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.token(a), .token(b)): a == b
        case let (.done(a), .done(b)): a == b
        default: false
        }
    }
}
