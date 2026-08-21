// Sources/LMStudioKit/LMStudioClient.swift
import Foundation
import TranslationCore

/// LM Studio's native `/api/v1/*`, implementing `LLMClient`.
///
/// The endpoints this client calls, and no others: `/api/v1/chat`, `/api/v1/models`,
/// `/api/v1/models/load`, `/api/v1/models/unload`, `/api/v1/models/download` and that job's
/// `/status`. It does **not** call the OpenAI-compatible `/v1/*` surface, and the design
/// (`docs/design/specs/2026-08-21-model-engine-switch-design.md` §2.5) says why: only the native
/// endpoint separates a model's reasoning from its answer, and that separation is what keeps a
/// trace out of a translation.
public struct LMStudioClient: LLMClient {
    /// LM Studio's own default. The address is not configurable — only this port — because a
    /// free-text address field would turn «text never leaves the machine» from a property of
    /// this code into a matter of what someone typed.
    public static let defaultPort = 1234

    public static func baseURL(port: Int = defaultPort) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    let baseURL: URL
    let session: URLSession
    let catalogue: ModelCatalogue

    /// How long a call may go without receiving anything before it is abandoned, per kind of
    /// call. As in `OllamaClient.Timeout`, `URLRequest.timeoutInterval` is a *gap* between
    /// arriving data rather than a total, so each of these reads «how long silence may last».
    public enum Timeout {
        /// A translation someone is watching. The same 30 s as the Ollama path, and safe here
        /// for a stronger reason than there: this stream is *chattier* than Ollama's. A cold
        /// load emitted 113 `model_load.progress` frames inside 7.2 s (measured 2026-08-21), so
        /// even a model being paged in from disk never leaves the wire quiet.
        public static let interactive: TimeInterval = 30
        /// `/api/v1/models`, which answers from memory and backs the health indicator.
        public static let probe: TimeInterval = 10
        /// `/api/v1/models/load`, which answers only when the model **is** loaded. Measured
        /// 2026-08-21: 5.603 s for 8.97 GB and 8.134 s for 12.10 GB, both MLX. This project's
        /// largest local model is 22.81 GB, so the ceiling has to leave room for roughly
        /// double the slowest measurement rather than sit near it — hence a pull-sized value
        /// and not a probe-sized one.
        public static let load: TimeInterval = 120
        /// One poll of a download's status. It answers from memory like the probe.
        public static let downloadPoll: TimeInterval = 10
        /// Reading `capabilities.reasoning` before a translation, which happens **in front of**
        /// the chat request and therefore outside its timeout. Tighter than the probe on
        /// purpose: the interactive path's whole target is a first token inside a second, and
        /// this lookup has a safe answer when it fails — no `reasoning` key, i.e. the model's
        /// own default. Waiting ten seconds to learn something optional is the worse trade.
        public static let capabilities: TimeInterval = 3
    }

    /// How often a download's status is polled. A choice, not a measurement: these are
    /// multi-gigabyte downloads and the server reports `bytes_per_second`, so a faster poll
    /// buys a smoother bar and nothing else. Unlike Ollama's `/api/pull`, this endpoint does
    /// not stream, so polling is the only shape available.
    static let downloadPollInterval: Duration = .seconds(1)

    public init(port: Int = LMStudioClient.defaultPort) {
        let baseURL = LMStudioClient.baseURL(port: port)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Timeout.load
        config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config)
        self.baseURL = baseURL
        self.session = session
        // Built from locals rather than from `self`, which does not exist yet. The catalogue
        // exists so that `chat` can resolve a `reasoning` value the model actually accepts
        // without paying a round trip per chunk.
        self.catalogue = ModelCatalogue {
            try await LMStudioClient.models(from: baseURL, session: session,
                                            timeout: Timeout.capabilities)
        }
    }

    /// Every request this client makes is built here, so «which timeout applies to which call»
    /// is one table rather than six call sites — `OllamaClient.request` exists for the same
    /// reason and says so at greater length.
    ///
    /// `static`, with the instance method delegating, because `models(from:session:)` has to
    /// run before `self` exists (the catalogue closure in `init`). It built its own `URLRequest`
    /// by hand until a review pointed out the obvious consequence: the builder pinned by a test
    /// was not the builder that call used.
    static func request(_ path: String, timeout: TimeInterval, method: String = "GET",
                        baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    func request(_ path: String, timeout: TimeInterval, method: String = "GET") -> URLRequest {
        Self.request(path, timeout: timeout, method: method, baseURL: baseURL)
    }

    /// A connection-level failure means nothing is listening — the «LM Studio is not running»
    /// case, which has its own message and its own «Открыть LM Studio» button. Timeouts are
    /// deliberately excluded, exactly as in `OllamaClient`: those mean the server is up and
    /// slow, which the caller handles differently.
    static func mapTransportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
            return LMStudioError.notRunning
        default:
            return error
        }
    }

    // MARK: - Chat

    public func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Asked before the request is built, and answered `nil` when the model
                    // reports nothing or the lookup fails — `ReasoningChoice` turns that into
                    // «send no key», which is the fail-safe: paying for a trace is recoverable,
                    // a refused value is a failed translation.
                    let allowed = await catalogue.reasoningOptions(for: options.model)
                    let reasoning = ReasoningChoice.value(for: options.think, allowed: allowed)
                    var request = request("api/v1/chat", timeout: Timeout.interactive, method: "POST")
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: LMStudioChatBody.json(messages: messages, options: options,
                                                              reasoning: reasoning))
                    let (bytes, response) = try await session.bytes(for: request)
                    try await Self.checkStreamStart(response, bytes: bytes)
                    for try await line in bytes.lines {
                        guard let frame = SSEFrameParser.frame(from: line) else { continue }
                        // Throws on an `error` event. That is the whole point: this server
                        // sends `chat.end` *after* an error, so a reader that carried on would
                        // hand back half a translation labelled success.
                        for event in try LMStudioEventReader.events(for: frame) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: Self.mapTransportError(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The status of a *streaming* response, checked before any translation line is consumed.
    ///
    /// **A refusal's body is read**, and that is deliberate rather than tidy: the two refusals
    /// this endpoint actually produces — `unrecognized_keys` for a key the server does not know
    /// and `invalid_value` for a `reasoning` setting the model does not accept, both measured
    /// 2026-08-21 — carry their machine-readable `code` in that body, and that code is what the
    /// app keys Russian copy on. Throwing a bare `httpStatus` here would discard the only part
    /// of a refusal a later layer can render. Nothing is lost by reading it: on a non-200 the
    /// body *is* the error, not the stream this request asked for.
    private static func checkStreamStart(_ response: URLResponse,
                                        bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw LMStudioError.notRunning }
        guard http.statusCode != 200 else { return }
        // Bounded on purpose. A refusal is a few hundred bytes; an unbounded read of whatever a
        // misbehaving server sends is a memory leak with a status code in front of it.
        var data = Data()
        for try await byte in bytes.prefix(64 * 1024) { data.append(byte) }
        throw LMStudioErrorParser.parse(body: data, status: http.statusCode)
    }

    // MARK: - Models

    public func models() async throws -> [LMStudioModel] {
        let models = try await Self.models(from: baseURL, session: session, timeout: Timeout.probe)
        // The probe pays for this list on its own schedule; the catalogue takes it rather than
        // re-reading the same endpoint on the next translation.
        await catalogue.absorb(models)
        return models
    }

    static func models(from baseURL: URL, session: URLSession,
                       timeout: TimeInterval) async throws -> [LMStudioModel] {
        let request = request("api/v1/models", timeout: timeout, baseURL: baseURL)
        let (data, response) = try await send(request, on: session)
        try validate(response, data)
        return try LMStudioModelList.parse(data)
    }

    /// Loads a model and answers how long that took, in seconds.
    ///
    /// This is what «warm» means on this engine, and it is not interchangeable with sending a
    /// one-token chat: a chat JIT-loads, and a JIT-loaded model is what Auto-Evict evicts when
    /// the next model arrives. A model loaded here is exempt — measured 2026-08-21, two models
    /// stayed resident together when one of them had been loaded this way.
    @discardableResult
    public func load(model: String) async throws -> Double {
        var request = self.request("api/v1/models/load", timeout: Timeout.load, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        let (data, response) = try await Self.send(request, on: session)
        try Self.validate(response, data)
        await catalogue.invalidate()
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["load_time_seconds"] as? NSNumber)?.doubleValue) ?? 0
    }

    /// Frees a model's memory. Measured 2026-08-21: the resident set went 10.19 GB → 0.37 GB.
    ///
    /// Takes one instance id, never «everything»: a loaded instance reports `id` and `config`
    /// and nothing about who loaded it, so a blanket unload could only either reach another
    /// application's model or lie about its own scope.
    public func unload(instanceID: String) async throws {
        var request = self.request("api/v1/models/unload", timeout: Timeout.probe, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["instance_id": instanceID])
        let (data, response) = try await Self.send(request, on: session)
        try Self.validate(response, data)
        await catalogue.invalidate()
    }

    // MARK: - Download

    /// Starts a download and polls it, presenting the result as the stream the app already
    /// consumes. `/api/v1/models/download` does not stream, unlike Ollama's `/api/pull`.
    public func download(model: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var start = request("api/v1/models/download", timeout: Timeout.probe, method: "POST")
                    start.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
                    let (data, response) = try await Self.send(start, on: session)
                    try Self.validate(response, data)
                    switch try LMStudioDownloadParser.started(data) {
                    case .alreadyDownloaded:
                        // Nothing to poll, and not a failure. The pane says «уже установлена»
                        // and stops — `isFinished` is true for this status precisely because it
                        // is the only sample such a «download» ever produces.
                        continuation.yield(ModelDownloadProgress(status: "already_downloaded",
                                                                 completed: 0, total: 0))
                    case let .job(id, totalBytes):
                        try await poll(job: id, totalBytes: totalBytes, into: continuation)
                    }
                    await catalogue.invalidate()
                    continuation.finish()
                } catch { continuation.finish(throwing: Self.mapTransportError(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func poll(job id: String, totalBytes: Int64,
                      into continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation) async throws {
        while true {
            try Task.checkCancellation()
            let request = self.request("api/v1/models/download/status/\(id)",
                                       timeout: Timeout.downloadPoll)
            let (data, response) = try await Self.send(request, on: session)
            try Self.validate(response, data)
            // The start response's size is carried in, because a paused poll answers without
            // one and a bar that forgets the total it already knew loses its position.
            let progress = try LMStudioDownloadParser.progress(data, totalBytes: totalBytes)
            continuation.yield(progress)
            // Ends on completion *and* on any state that does not invite another poll — a
            // cancellation performed in LM Studio's own window, or a status a later version
            // introduces. The alternative is one request a second with no ceiling.
            if progress.isFinished || !progress.invitesAnotherPoll { return }
            try await Task.sleep(for: Self.downloadPollInterval)
        }
    }

    // MARK: - Plumbing

    private static func send(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) } catch { throw mapTransportError(error) }
    }

    private static func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LMStudioError.notRunning }
        guard http.statusCode != 200 else { return }
        throw LMStudioErrorParser.parse(body: data, status: http.statusCode)
    }
}

/// Caches what each model says it accepts for `reasoning`, so a multi-chunk translation pays
/// one `/api/v1/models` call rather than one per chunk.
///
/// A **failed** read is not cached: it answers «not known» for this request and is retried on
/// the next one. Caching a failure would silence reasoning control for the rest of the session
/// after a single blip, and the cheaper mistake is to ask again.
actor ModelCatalogue {
    private var cached: [LMStudioModel]?
    /// The read in flight, if any. Held so that concurrent askers share one request instead of
    /// each starting their own: `reasoningOptions` suspends at its `await`, and this app shares
    /// one client across the window, the panel and the queue, so a hotkey press landing while
    /// the window translates is the ordinary case rather than the exotic one.
    private var inFlight: Task<[LMStudioModel], Never>?
    private let fetch: @Sendable () async throws -> [LMStudioModel]

    init(fetch: @escaping @Sendable () async throws -> [LMStudioModel]) {
        self.fetch = fetch
    }

    func reasoningOptions(for model: String) async -> [String]? {
        if let known = await options(for: model, refetching: false) { return known }
        // A model absent from the cached list is the case that used to fail quietly *for the
        // rest of the session*: the list is read once, so a model installed or first selected
        // in LM Studio's own window after that read was permanently «not known», which sends no
        // `reasoning` key and leaves «Отключать рассуждение модели» inert — on `qwen3.8-27b`
        // that is a full `xhigh` trace per chunk. Re-read once instead of answering from a list
        // that predates the model.
        guard cached?.contains(where: { $0.key == model }) != true else { return nil }
        return await options(for: model, refetching: true)
    }

    /// The list, from cache or from the wire, and then one lookup in it.
    ///
    /// Nil covers two distinct states, deliberately: «the catalogue could not be read» and
    /// «this model reports no reasoning capability». `ReasoningChoice` answers «send nothing» to
    /// both, which is what lets them share a return type here.
    private func options(for model: String, refetching: Bool) async -> [String]? {
        if refetching { cached = nil }
        if cached == nil {
            let task = inFlight ?? Task { (try? await fetch()) ?? [] }
            inFlight = task
            let models = await task.value
            inFlight = nil
            cached = models.isEmpty ? nil : models
        }
        return cached?.first { $0.key == model }?.reasoningOptions
    }

    /// Fills the cache from a list somebody else already paid for — the health probe reads
    /// `/api/v1/models` on its own schedule, and throwing that answer away only to re-read it
    /// on the next translation is waste with a stale window in it.
    func absorb(_ models: [LMStudioModel]) {
        cached = models.isEmpty ? nil : models
    }

    func invalidate() { cached = nil }
}
