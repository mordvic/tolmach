// Sources/LMStudioKit/LMStudioChatBody.swift
import Foundation
import TranslationCore

/// The `/api/v1/chat` request body, built as a value rather than inline inside `chat` — the
/// shape `OllamaChatBody` established, and for a sharper reason here: **this server rejects an
/// unrecognised key** instead of ignoring it. Measured 2026-08-21, `{"ttl": 1800}` answered
/// HTTP 400 `"Unrecognized key(s) in object: 'ttl'"`. So the set of keys is part of the
/// contract, and a test can hold it.
enum LMStudioChatBody {
    static func json(messages: [ChatMessage], options: ChatOptions,
                     reasoning: String?) -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model,
            "input": text(of: "user", in: messages),
            "stream": true,
            "temperature": options.temperature,
            // Not optional. `store` defaults to true on this endpoint, i.e. LM Studio keeps
            // the conversation; this app writes to disk in one place and does not acquire a
            // second one by omission.
            "store": false,
        ]
        // Absent rather than empty when the caller built no system turn: an empty string is a
        // system prompt that says nothing, which is not the same as not having one.
        let system = text(of: "system", in: messages)
        if !system.isEmpty { body["system_prompt"] = system }
        // Omitted entirely when unresolved — `ReasoningChoice` returns nil for «say nothing»,
        // and nothing is exactly what must go on the wire: a value this model does not accept
        // is HTTP 400 (§5.5 of the design).
        if let reasoning { body["reasoning"] = reasoning }
        return body
    }

    /// `ChatOptions.keepAlive` is deliberately not read here, and this is the only place that
    /// could have read it: residency on this engine is «loaded until unloaded»
    /// (`LMStudioClient.load`), not a duration attached to a request.
    ///
    /// Turns the app's two-turn message list into this endpoint's two fields. One system turn
    /// and one user turn is what `PromptBuilder` produces; several turns of the same role are
    /// joined rather than dropped, so a future prompt shape degrades loudly in one place
    /// instead of silently losing a turn.
    private static func text(of role: String, in messages: [ChatMessage]) -> String {
        messages.filter { $0.role == role }.map(\.content).joined(separator: "\n\n")
    }
}
