// Sources/LMStudioKit/LMStudioEventReader.swift
import Foundation
import TranslationCore

enum LMStudioEventReader {
    static func events(for frame: SSEFrame) throws -> [ChatEvent] {
        switch frame.type {
        case "message.delta":
            guard let content = frame.json["content"] as? String, !content.isEmpty else { return [] }
            return [.token(content)]
        case "chat.end":
            return [.done(stats(from: frame.json))]
        case "error":
            throw LMStudioErrorParser.parse(frame.json)
        default:
            return []
        }
    }

    /// `chat.end` nests its payload under `result`, which is where the documentation and the
    /// server disagree (measured 2026-08-21 — the docs show `message` / `usage` flat). Fields
    /// this server does not report stay zero: it times the *phases* differently from Ollama,
    /// giving totals and a load time but no prompt-eval or eval duration.
    ///
    /// **`time_to_first_token_seconds` is read by nobody on purpose.** `docs/adr/0006` defines
    /// this project's TTFT as the first emission the user could see, after cleaning — the
    /// server's figure is the first token off the wire, and on a reasoning model it fires while
    /// the trace is still streaming (3.182 s measured on `gpt-oss-20b`). Substituting it moves
    /// the gate that guards the sub-second requirement.
    private static func stats(from object: [String: Any]) -> ChatStats {
        let stats = ((object["result"] as? [String: Any])?["stats"] as? [String: Any]) ?? [:]
        func number(_ key: String) -> Double { (stats[key] as? NSNumber)?.doubleValue ?? 0 }
        let outputTokens = number("total_output_tokens")
        let tokensPerSecond = number("tokens_per_second")
        return ChatStats(loadDurationMS: number("model_load_time_seconds") * 1000,
                         promptEvalCount: Int(number("input_tokens")),
                         // Not reported by this server, and zero is the only way this struct can
                         // say so: its durations are not optional. It costs nothing today —
                         // nothing reads `promptEvalDurationMS` — and a later reader is told here
                         // rather than left to infer a suspiciously instant prefill.
                         promptEvalDurationMS: 0,
                         evalCount: Int(outputTokens),
                         // Derived from the server's own `tokens_per_second` rather than left at
                         // zero, because `ChatStats.tokensPerSecond` divides by this: leaving it
                         // zero made a model generating 57.7 tokens a second report a flat 0.
                         // The division is inverted, not invented — and it is skipped when either
                         // figure is missing, since a fabricated duration is worse than an absent
                         // one.
                         evalDurationMS: tokensPerSecond > 0 && outputTokens > 0
                             ? outputTokens / tokensPerSecond * 1000
                             : 0)
    }
}
