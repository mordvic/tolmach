import Foundation
import TranslationEngine

public struct OllamaModel: Sendable {
    public let name: String
    public let sizeBytes: Int64

    public var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }
}

public enum OllamaError: LocalizedError {
    case notRunning
    case httpStatus(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama is not reachable on 127.0.0.1:11434. Start it with `ollama serve`."
        case let .httpStatus(code, body):
            return "Ollama returned HTTP \(code): \(body)"
        case let .decoding(detail):
            return "Could not decode Ollama response: \(detail)"
        }
    }
}

public struct OllamaClient: LLMClient {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: configuration)
    }

    public func models() async throws -> [OllamaModel] {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
        guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
        guard http.statusCode == 200 else {
            throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["models"] as? [[String: Any]] else {
            throw OllamaError.decoding("unexpected /api/tags shape")
        }
        return raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
            return OllamaModel(name: name, sizeBytes: size)
        }
    }

    public func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": options.model,
                        "stream": true,
                        "keep_alive": options.keepAlive,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "options": ["temperature": options.temperature],
                    ])

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
                    guard http.statusCode == 200 else {
                        throw OllamaError.httpStatus(http.statusCode, "see ollama logs")
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }

                        if let message = object["message"] as? [String: Any],
                           let content = message["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(.token(content))
                        }

                        if (object["done"] as? Bool) == true {
                            continuation.yield(.done(stats(from: object)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // Ollama reports durations in nanoseconds.
    func stats(from object: [String: Any]) -> ChatStats {
        func ms(_ key: String) -> Double {
            ((object[key] as? NSNumber)?.doubleValue ?? 0) / 1_000_000
        }
        func count(_ key: String) -> Int {
            (object[key] as? NSNumber)?.intValue ?? 0
        }
        return ChatStats(
            loadDurationMS: ms("load_duration"),
            promptEvalCount: count("prompt_eval_count"),
            promptEvalDurationMS: ms("prompt_eval_duration"),
            evalCount: count("eval_count"),
            evalDurationMS: ms("eval_duration")
        )
    }
}
