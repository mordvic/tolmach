// Sources/OllamaKit/OllamaClient.swift
import Foundation
import TranslationCore

public struct OllamaModel: Sendable {
    public let name: String
    public let sizeBytes: Int64
    public var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }
}

public struct OllamaClient: LLMClient {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: config)
    }

    public func models() async throws -> [OllamaModel] {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
        guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
        guard http.statusCode == 200 else { throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["models"] as? [[String: Any]] else { throw OllamaError.decoding("unexpected /api/tags shape") }
        return raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return OllamaModel(name: name, sizeBytes: (entry["size"] as? NSNumber)?.int64Value ?? 0)
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
                        "model": options.model, "stream": true, "keep_alive": options.keepAlive,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "options": ["temperature": options.temperature],
                    ])
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
                    guard http.statusCode == 200 else { throw OllamaError.httpStatus(http.statusCode, "see ollama logs") }
                    for try await line in bytes.lines {
                        if let event = OllamaStreamParser.parse(line: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
