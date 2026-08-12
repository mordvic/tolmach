// Sources/OllamaKit/OllamaChatBody.swift
import Foundation
import TranslationCore

/// The `/api/chat` request body, built as a value rather than inline inside `chat`.
///
/// It was inline until `think` arrived, and nothing in this package could say what went on the
/// wire — the only way to see the body was a live server. That is affordable for fields whose
/// JSON type is obvious and not for this one: `think` is a **boolean** when it disables
/// reasoning and a **string** when it grades it, and Ollama reads the string `"false"` as a
/// level rather than as silence. A pure function is what lets a test hold that distinction.
enum OllamaChatBody {
    static func json(messages: [ChatMessage], options: ChatOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model, "stream": true, "keep_alive": options.keepAlive,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "options": ["temperature": options.temperature],
        ]
        switch options.think {
        case nil: break   // absent, not false — see `ChatOptions.think`
        case .off: body["think"] = false
        case .level(let level): body["think"] = level.rawValue
        }
        return body
    }
}
