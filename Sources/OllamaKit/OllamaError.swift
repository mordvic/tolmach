// Sources/OllamaKit/OllamaError.swift
import Foundation

public enum OllamaError: LocalizedError {
    case notRunning
    case httpStatus(Int, String)
    case decoding(String)
    /// The stream stopped before it delivered a complete reply.
    ///
    /// Two causes, one meaning. An `{"error": …}` line arrived mid-generation — Ollama sends
    /// those inside an already-200 response, measured on 0.32.14 for `/api/pull`, which
    /// answers 200 and then streams `{"error":"pull model manifest: file does not exist"}` —
    /// or the stream ended without the `done` frame that every complete response carries.
    ///
    /// Both mean what arrived is a fragment, and handing a fragment back as a translation is
    /// the «partial result reported as a success» failure that this project already refuses on
    /// the LM Studio side (`LMStudioEventReader` throws on an `error` frame) and inside the
    /// engine (`Translator`'s cancellation checks). This is the same rule at the third place it
    /// was missing.
    case truncatedStream(String)
    /// One line of a 200 response grew past `BoundedLines.defaultMaxBytes`. Nothing this server
    /// sends comes close; something answering on its port is not speaking this protocol.
    case oversizedLine(Int)

    public var errorDescription: String? {
        switch self {
        // No address: this value is thrown by a client that may have been built for any port,
        // and naming the default one misdiagnosed every non-default client. The settings pane
        // renders the address it actually calls, from the setting itself.
        case .notRunning: "Ollama is not reachable. Start it with `ollama serve`."
        case let .httpStatus(code, body): "Ollama returned HTTP \(code): \(body)"
        case let .decoding(detail): "Could not decode Ollama response: \(detail)"
        case let .truncatedStream(detail): "Ollama stopped mid-answer: \(detail)"
        case let .oversizedLine(limit): "A single response line exceeded \(limit) bytes; this is not Ollama's protocol."
        }
    }
}
