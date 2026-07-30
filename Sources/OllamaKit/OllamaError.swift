// Sources/OllamaKit/OllamaError.swift
import Foundation

public enum OllamaError: LocalizedError {
    case notRunning
    case httpStatus(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Ollama is not reachable on 127.0.0.1:11434. Start it with `ollama serve`."
        case let .httpStatus(code, body): "Ollama returned HTTP \(code): \(body)"
        case let .decoding(detail): "Could not decode Ollama response: \(detail)"
        }
    }
}
