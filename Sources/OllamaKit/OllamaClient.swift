// Sources/OllamaKit/OllamaClient.swift
import Foundation
import TranslationCore

public struct OllamaModel: Sendable {
    public let name: String
    public let sizeBytes: Int64
    public var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }

    /// Public so the app's tests can build one. A struct with public stored properties gets
    /// only an internal memberwise initialiser, which is invisible across the module
    /// boundary — the reason this is spelled out rather than synthesised.
    public init(name: String, sizeBytes: Int64) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

public struct OllamaClient: LLMClient {
    /// Where Ollama is expected to be, and the one place that address is written.
    ///
    /// Public because the settings pane shows it to the user — spec §5.3 asks the «Ollama»
    /// section for whether it is running, *the address*, and a re-check — and an address
    /// typed into a view is an address that can disagree with the one being called.
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    let baseURL: URL
    let session: URLSession

    /// How long a call may go without receiving anything before it is abandoned, per kind of
    /// call. `URLSessionConfiguration.timeoutIntervalForRequest` is a *gap* between arriving
    /// data, not a total, so each of these is «how long silence is allowed to last».
    ///
    /// One session with a per-request override rather than three sessions: `URLRequest`'s own
    /// `timeoutInterval` supersedes the configuration's, and a second `URLSession` costs a
    /// second connection pool for no gain.
    public enum Timeout {
        /// A download of several gigabytes. The session's own value, left where it was.
        public static let pull: TimeInterval = 120
        /// A translation the user is watching.
        ///
        /// 120 s was the value every call shared, and it is wrong for this one: the panel's
        /// whole design target is a first token inside a second, and an Ollama that accepts
        /// the connection and then never answers held the panel — spinner, no text, «Отмена»
        /// the only way out — for two minutes.
        ///
        /// 30 s is chosen against this project's own measurements rather than picked. The
        /// pinned interactive model is `aya-expanse:8b` at a measured TTFT under 1 s
        /// (spec §5), so this is roughly thirty times the supported case. The slowest figure
        /// anywhere in this repository is `ModelPolicy`'s note on `qwen3:30b` — «78 seconds of
        /// reasoning before the first character of translation» — and that model is
        /// blacklisted for exactly that reason, i.e. it is already declared unsuitable for the
        /// path this timeout governs.
        ///
        /// **A reasoning model cannot trip this, and that is measured rather than assumed.**
        /// The obvious objection to any interactive timeout is `ModelPolicy`'s 78 seconds —
        /// but this timer counts *silence*, not elapsed time, and reasoning is not silent.
        /// Probed against the live server with `qwen3:8b`, `keep_alive: 0`, one translation
        /// request, recording the arrival time of every frame:
        ///
        ///     frames                       258
        ///     first frame                  2.12 s   (cold model load — the only long gap)
        ///     first `message.thinking`     2.12 s
        ///     first `message.content`      7.12 s
        ///     largest gap between frames   0.062 s
        ///
        /// So the five seconds of reasoning before the first character of translation carried
        /// 250-odd frames, and the wire never went quiet for more than 62 ms.
        /// `OllamaStreamParser` reads `message.thinking` and discards it, but a discarded frame
        /// is still bytes arriving, and arriving bytes reset this timer. The measurement is of
        /// Ollama's streaming protocol rather than of one model, so it carries to `qwen3:30b`
        /// — which was deliberately *not* loaded to take it, an 18 GB model being a poor thing
        /// to page in to answer a question an 8 B model answers identically.
        ///
        /// What this value does still catch is the case it was written for: a server that
        /// accepts the connection and then sends nothing at all.
        public static let interactive: TimeInterval = 30
        /// `/api/tags` and `/api/ps`, which answer from memory and back the health indicator.
        /// They ran on the 120 s value too, so a hung server left `OllamaStatusModel.refresh`
        /// — which awaits both in turn — reporting nothing for up to four minutes about the
        /// one thing it exists to report.
        public static let probe: TimeInterval = 10
    }

    public init(baseURL: URL = OllamaClient.defaultBaseURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Timeout.pull
        config.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: config)
    }

    /// Every request this client makes is built here, so that «which timeout applies to which
    /// call» is one table rather than four call sites.
    ///
    /// A function rather than four inline constructions because it is the only part of the
    /// timeout decision a test can look at: a `URLSession` that never times out in a test
    /// process cannot show which interval was requested, and one that does would make the
    /// suite wait for it. Same shape, and the same reasoning, as
    /// `PermissionsGate.trustOptions(prompting:)`.
    func request(_ path: String, timeout: TimeInterval, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        return request
    }

    public func models() async throws -> [OllamaModel] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request("api/tags", timeout: Timeout.probe))
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
        guard http.statusCode == 200 else { throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["models"] as? [[String: Any]] else { throw OllamaError.decoding("unexpected /api/tags shape") }
        return raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return OllamaModel(name: name, sizeBytes: (entry["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// A connection-level failure means nothing is listening — that is the
    /// "Ollama isn't running" case, and it must surface as such rather than as a
    /// raw URLError. Timeouts are deliberately excluded: those mean Ollama IS
    /// running and is too slow, which the caller handles differently.
    static func mapTransportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
            return OllamaError.notRunning
        default:
            return error
        }
    }

    public func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request("api/chat", timeout: Timeout.interactive,
                                         method: "POST")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: OllamaChatBody.json(messages: messages, options: options))
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
                    guard http.statusCode == 200 else { throw OllamaError.httpStatus(http.statusCode, "see ollama logs") }
                    for try await line in bytes.lines {
                        for event in OllamaStreamParser.parse(line: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: Self.mapTransportError(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct RunningModel: Sendable {
    public let name: String
}

public struct PullProgress: Sendable, Equatable {
    public let status: String
    public let completed: Int64
    public let total: Int64
    /// Nil when the server sent no byte counts — many pull lines are bare status
    /// updates, and a fabricated 0% would make the bar jump backwards.
    public var fraction: Double? {
        total > 0 ? Double(completed) / Double(total) : nil
    }
}

public enum PullProgressParser {
    public static func parse(line: String) -> PullProgress? {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else { return nil }
        return PullProgress(status: status,
                            completed: (object["completed"] as? NSNumber)?.int64Value ?? 0,
                            total: (object["total"] as? NSNumber)?.int64Value ?? 0)
    }
}

extension OllamaClient {
    public func ps() async throws -> [RunningModel] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request("api/ps", timeout: Timeout.probe))
        } catch { throw Self.mapTransportError(error) }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
        guard http.statusCode == 200 else {
            throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["models"] as? [[String: Any]] else {
            throw OllamaError.decoding("unexpected /api/ps shape")
        }
        return raw.compactMap { ($0["name"] as? String).map(RunningModel.init(name:)) }
    }

    /// Frees a model's memory. See `OllamaUnloadBody` for why the body looks like a translation
    /// request with nothing to translate.
    ///
    /// `Timeout.probe` rather than `interactive`: nothing is generated, the server answers as
    /// soon as it has dropped the weights.
    public func unload(model: String) async throws {
        var request = request("api/chat", timeout: Timeout.probe, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: OllamaUnloadBody.json(model: model))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch { throw Self.mapTransportError(error) }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
        guard http.statusCode == 200 else {
            throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request("api/pull", timeout: Timeout.pull, method: "POST")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: ["model": model, "stream": true])
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
                    guard http.statusCode == 200 else {
                        throw OllamaError.httpStatus(http.statusCode, "see ollama logs")
                    }
                    for try await line in bytes.lines {
                        if let progress = PullProgressParser.parse(line: line) {
                            continuation.yield(progress)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: Self.mapTransportError(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
