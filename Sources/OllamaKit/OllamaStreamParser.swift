// Sources/OllamaKit/OllamaStreamParser.swift
import Foundation
import TranslationCore

public enum OllamaStreamParser {
    public static func parse(line: String) -> ChatEvent? {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if (object["done"] as? Bool) == true { return .done(stats(from: object)) }

        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            return .token(content) // message.thinking is intentionally ignored
        }
        return nil
    }

    static func stats(from object: [String: Any]) -> ChatStats {
        func ms(_ key: String) -> Double { ((object[key] as? NSNumber)?.doubleValue ?? 0) / 1_000_000 }
        func count(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        return ChatStats(loadDurationMS: ms("load_duration"), promptEvalCount: count("prompt_eval_count"),
                         promptEvalDurationMS: ms("prompt_eval_duration"), evalCount: count("eval_count"),
                         evalDurationMS: ms("eval_duration"))
    }
}
