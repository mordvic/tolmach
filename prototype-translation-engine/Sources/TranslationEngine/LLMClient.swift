import Foundation

public struct ChatOptions: Sendable {
    public let model: String
    public let temperature: Double
    /// Keeps the model resident so a hotkey translation does not pay the load cost.
    public let keepAlive: String

    public init(model: String, temperature: Double = 0.2, keepAlive: String = "30m") {
        self.model = model
        self.temperature = temperature
        self.keepAlive = keepAlive
    }
}

public struct ChatStats: Sendable {
    public let loadDurationMS: Double
    public let promptEvalCount: Int
    public let promptEvalDurationMS: Double
    public let evalCount: Int
    public let evalDurationMS: Double

    public init(
        loadDurationMS: Double,
        promptEvalCount: Int,
        promptEvalDurationMS: Double,
        evalCount: Int,
        evalDurationMS: Double
    ) {
        self.loadDurationMS = loadDurationMS
        self.promptEvalCount = promptEvalCount
        self.promptEvalDurationMS = promptEvalDurationMS
        self.evalCount = evalCount
        self.evalDurationMS = evalDurationMS
    }

    public var tokensPerSecond: Double {
        evalDurationMS > 0 ? Double(evalCount) / (evalDurationMS / 1000) : 0
    }
}

public enum ChatEvent: Sendable {
    case token(String)
    case done(ChatStats)
}

/// The seam. TranslationEngine knows this protocol and nothing about Ollama.
public protocol LLMClient: Sendable {
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error>
}
