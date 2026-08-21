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
    /// Whether the reply says the model was actually freed.
    ///
    /// `done_reason: "unload"` is the only confirmation this call has, and checking it is what
    /// keeps an unverified round trip from being a silent one: if an Ollama build ever ignores
    /// `keep_alive: 0` on an empty message list, it answers HTTP 200 with `done_reason: "stop"`
    /// — the button would report success and 17 GB would stay resident with nothing to diagnose
    /// from. `nil` for an unreadable body, so the caller can tell «said no» from «said nothing».
    static func confirmsUnload(_ data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["done_reason"] as? String else { return nil }
        return reason == "unload"
    }

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
