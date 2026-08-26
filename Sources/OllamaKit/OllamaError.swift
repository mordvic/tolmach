// Sources/OllamaKit/OllamaError.swift
import Foundation

public enum OllamaError: LocalizedError {
    case notRunning
    case httpStatus(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        // No address: this value is thrown by a client that may have been built for any port,
        // and naming the default one misdiagnosed every non-default client. The settings pane
        // renders the address it actually calls, from the setting itself.
        case .notRunning: "Ollama is not reachable. Start it with `ollama serve`."
        case let .httpStatus(code, body): "Ollama returned HTTP \(code): \(body)"
        case let .decoding(detail): "Could not decode Ollama response: \(detail)"
        }
    }
}
