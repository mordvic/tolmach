// Sources/OllamaKit/OllamaStreamParser.swift
import Foundation
import TranslationCore

public enum OllamaStreamParser {
    /// A single line can carry both a translation token and the done marker at
    /// once — Ollama 0.31.1 was observed always sending `"content":""` on the done
    /// frame, but nothing in the protocol guarantees that, and the parser must be
    /// able to represent the combined frame rather than assume it away. Returned in
    /// document order: the token (if any) always precedes `.done` (if any), since
    /// that is the order a consumer needs to process them in — forward the token,
    /// then record completion. A blank or unparseable line returns `[]`.
    ///
    /// **Throws on an `{"error": …}` line, and that is the whole reason this is throwing.**
    /// Such a line carries no `message` and no `done`, so returning `[]` for it — which is what
    /// this did — dropped it silently: the runner could die mid-generation, the client would
    /// read to the end of the stream, and half a document came back labelled success. Non-empty
    /// TTFT meant even the empty-reply guards passed, so «Файлы» wrote the truncated file to
    /// disk as `.finished`. `LMStudioEventReader` has thrown on the equivalent frame since it
    /// was written and says why; this is the same rule on the other engine.
    ///
    /// Measured 2026-08-26 on Ollama 0.32.14: `/api/pull` for a nonexistent model answers HTTP
    /// 200 and then streams exactly this shape, `{"error":"pull model manifest: file does not
    /// exist"}`. The chat endpoint's own mid-stream error could not be provoked to order here —
    /// it needs a runner that dies mid-generation — so that half rests on the protocol and on
    /// the pull evidence rather than on a direct observation.
    public static func parse(line: String) throws -> [ChatEvent] {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        // Before anything else: an error line is not a frame with a missing field, it is the
        // server saying the answer will not be finished.
        if let message = object["error"] as? String {
            throw OllamaError.truncatedStream(message)
        }

        var events: [ChatEvent] = []
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            events.append(.token(content)) // message.thinking is intentionally ignored
        }
        if (object["done"] as? Bool) == true { events.append(.done(stats(from: object))) }
        return events
    }

    static func stats(from object: [String: Any]) -> ChatStats {
        func ms(_ key: String) -> Double { ((object[key] as? NSNumber)?.doubleValue ?? 0) / 1_000_000 }
        func count(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        return ChatStats(loadDurationMS: ms("load_duration"), promptEvalCount: count("prompt_eval_count"),
                         promptEvalDurationMS: ms("prompt_eval_duration"), evalCount: count("eval_count"),
                         evalDurationMS: ms("eval_duration"))
    }
}
