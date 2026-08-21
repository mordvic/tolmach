// Sources/OllamaKit/OllamaUnloadBody.swift
import Foundation

/// The body that frees a model's memory on Ollama, which has no unload endpoint.
///
/// Documented behaviour rather than a trick: «if the messages array is empty and the
/// `keep_alive` parameter is set to `0`, a model will be unloaded from memory», and the reply
/// carries `done_reason: "unload"`. A value rather than an inline dictionary for
/// `OllamaChatBody`'s reason — the two fields that make it work are easy to get subtly wrong
/// (a non-empty list translates something; a *string* `"0"` is a duration, not zero), and a
/// pure function is what lets a test hold them.
///
/// **Not verified against a live server.** It is built and pinned offline; the round trip is
/// listed in `docs/reference/OPEN-ITEMS.md`.
enum OllamaUnloadBody {
    static func json(model: String) -> [String: Any] {
        [
            "model": model,
            "messages": [[String: String]](),
            "keep_alive": 0,
            // No stream to drain: this call returns one frame whose only interesting content is
            // that it succeeded.
            "stream": false,
        ]
    }
}
