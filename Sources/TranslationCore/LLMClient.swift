// Sources/TranslationCore/LLMClient.swift  (value types; protocol appended in Task 12)
import Foundation

public struct ChatMessage: Sendable, Equatable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public struct ChatOptions: Sendable {
    public let model: String
    public let temperature: Double
    public let keepAlive: String
    public init(model: String, temperature: Double = 0.2, keepAlive: String = "30m") {
        self.model = model; self.temperature = temperature; self.keepAlive = keepAlive
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
