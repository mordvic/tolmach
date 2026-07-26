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
    public static func parse(line: String) -> [ChatEvent] {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

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
