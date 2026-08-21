// Sources/LMStudioKit/ReasoningChoice.swift
import Foundation
import TranslationCore

/// Turns «quieten this model's reasoning as far as it allows» into a value this model accepts.
///
/// **This is where the guarantee changes shape from Ollama's.** There, `"think": false` is
/// accepted by every model measured and only *enabling* reasoning can fail, which is why
/// `ThinkRequest` has no «on» case — protection by construction. Here it is inverted: measured
/// 2026-08-21, `reasoning: "off"` on `openai/gpt-oss-20b` answers **HTTP 400** «Supported
/// settings: 'low', 'medium', 'high'». So no value is safe by construction, and protection is
/// by *enquiry* — the server states `capabilities.reasoning.allowed_options` per model, and only
/// a member of that list is ever sent.
///
/// `allowed == nil` means «not known»: either the model reported no `capabilities` at all
/// (`qwen3.5-27b` does exactly that) or the lookup failed. Both answer **nil — send nothing**,
/// and that is the fail-safe rather than a gap. It follows this project's own reasoning about
/// the `qwen3:30b` leak: leaving a model reasoning costs time, and time is recoverable;
/// sending a value it refuses costs the whole translation.
enum ReasoningChoice {
    /// Quietest first — and **`on` is deliberately absent**, which is the whole mechanism rather
    /// than an omission. `off` is silence and the levels grade a trace that still happens; `on`
    /// means «reason as you see fit», i.e. exactly what the server does with no key at all. So a
    /// model offering nothing but `on` finds no match here and is sent no key, which is the
    /// right answer: asking for the default buys nothing and can only be refused.
    private static let quietestFirst = ["off", "low", "medium", "high", "xhigh"]

    static func value(for think: ThinkRequest?, allowed: [String]?) -> String? {
        // Nil is «the user did not ask for quiet», and the server's own default applies. On
        // this engine that default can be loud: `qwen/qwen3.8-27b` defaults to `xhigh`.
        guard let think, let allowed, !allowed.isEmpty else { return nil }
        switch think {
        case .off:
            return quietestFirst.first(where: allowed.contains)
        case let .level(level):
            // The caller's level if the model takes it, otherwise the nearest one it does —
            // never a *louder* value than asked for unless nothing quieter exists.
            if allowed.contains(level.rawValue) { return level.rawValue }
            return quietestFirst.first(where: allowed.contains)
        }
    }
}
