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
            // `.level(x)` reads «as quiet as this model allows, and **no louder than x** if it
            // cannot be silenced». So silence still wins where it is on offer, and the level is
            // a *ceiling* rather than a target.
            //
            // That is the app's only intent here — the setting behind it is «Отключать
            // рассуждение модели», and «Длина рассуждения» exists precisely for the models
            // that cannot honour it. An earlier revision of this function read the level as a
            // target, on a review's finding that a request for `high` against
            // `qwen/qwen3.8-27b` came back `off`. Building the app layer showed the finding had
            // the right defect and the wrong owner: with a target, the app could not express
            // «quiet, but no louder than x» without knowing each model's capabilities, which
            // live here rather than there. The contradiction the review found is settled where
            // it belongs — the pane draws «Длина рассуждения» only for a model that offers
            // levels and no `off`, so a model that can be silenced never shows a control whose
            // value it would then ignore.
            if allowed.contains("off") { return "off" }
            if allowed.contains(level.rawValue) { return level.rawValue }
            // Nothing at the ceiling, so the loudest option still under it — and failing that,
            // the quietest on offer.
            let underTheCeiling = quietestFirst.prefix { $0 != level.rawValue }
            return underTheCeiling.last(where: allowed.contains)
                ?? quietestFirst.first(where: allowed.contains)
        }
    }
}
