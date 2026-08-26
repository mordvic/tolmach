// Sources/TranslatorApp/EngineRouter.swift
import Foundation
import TranslationCore
import OllamaKit
import LMStudioKit

/// One installed model, as this app needs it, whichever server reported it.
///
/// `name` and `sizeBytes` are the two fields the «Модели» pane already draws, kept under those
/// names so the pane did not have to change in this wave. The other two exist because LM Studio
/// answers questions Ollama cannot: which instances are loaded (needed to unload one — an
/// instance id is what that call takes) and what the model accepts for `reasoning`.
struct EngineModel: Sendable, Equatable {
    let name: String
    let sizeBytes: Int64
    /// Empty on Ollama, which reports residency as a separate list rather than per model.
    let loadedInstanceIDs: [String]
    /// Nil where the server does not say — always on Ollama, and on LM Studio for a model that
    /// reports no `capabilities`.
    let reasoningOptions: [String]?

    var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }

    /// The last two default, because that is what an Ollama-reported model has: no per-model
    /// instance list and nothing said about reasoning.
    init(name: String, sizeBytes: Int64,
         loadedInstanceIDs: [String] = [], reasoningOptions: [String]? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.loadedInstanceIDs = loadedInstanceIDs
        self.reasoningOptions = reasoningOptions
    }
}

/// Which server, on which port — the pair, because reading one without the other is what went
/// wrong. The port key is *scoped by engine*, so «which port» is not answerable until «which
/// engine» has been decided, and a caller that asked the two questions separately could get an
/// answer to each about a different engine.
struct EngineTarget: Sendable, Equatable {
    let engine: ModelEngine
    let port: Int
}

/// An `EngineRouter` that has stopped listening to the setting.
///
/// Holds the same `ClientPool` — so it costs no `URLSession` and no connection — and a target
/// decided once. `LLMClient.pinnedForRun()` carries the reasoning; the short version is that a
/// translation is many `chat` calls and they must all reach one server.
///
/// Only `chat` is offered, and that is deliberate rather than minimal: the model list, the
/// residency commands and the downloader are things a *person* does to whichever engine is
/// selected right now, and freezing those would make «Модели» answer about an engine the radio
/// button no longer names.
struct PinnedEngineClient: LLMClient {
    let pool: ClientPool
    let target: EngineTarget

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        EngineRouter.chat(messages: messages, options: options, target: target, pool: pool)
    }

    /// Already frozen. Pinning a pinned client must answer itself, or a second `forRun()` — a
    /// правка run started from inside a translation's model, say — would quietly re-read the
    /// setting and undo the freeze.
    func pinnedForRun() -> any LLMClient { self }
}

/// What the app needs to ask an engine about its models. Named for the question rather than for
/// the server: `OllamaProbe` was this protocol's name while there was only one.
protocol EngineProbe: Sendable {
    func installedModels() async throws -> [EngineModel]
    func residentModels() async throws -> [String]
}

/// The engine, as the rest of the app sees it: one `LLMClient`, one probe, one downloader, and
/// the two residency commands.
///
/// **The setting is read on every call**, not at construction, and that is the whole point of
/// this type. `TranslatorApp.init` builds three `Translator`s over one client; if the choice of
/// engine were captured there, switching it would mean rebuilding all three and the view models
/// that hold them. Reading it per call makes the radio button take effect on the next request.
///
/// Both clients live for the whole process, which costs a second `URLSession` — the comment on
/// `TranslatorApp.client` used to be proud of having one. It is the right trade: the alternative
/// is rebuilding three view models when a radio button moves.
struct EngineRouter: LLMClient, EngineProbe {
    private let pool: ClientPool
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` in this SDK while being
    /// documented as thread-safe — «UserDefaults is thread-safe», reading and writing from any
    /// thread. The same escape, for the same kind of reason, as `HotkeyManager`'s stored
    /// `EventHandlerRef`: the annotation is where the guarantee the compiler cannot see gets
    /// written down. What is *not* safe, and is what this avoids, is capturing `AppSettings`
    /// here — an `@Observable` class whose observation registrar makes no such promise.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Reads the choice out of the **defaults store** rather than out of `AppSettings`.
    ///
    /// Not a shortcut around that type — a consequence of how it is built. `AppSettings` has no
    /// stored properties by design: every accessor reads and writes `UserDefaults` directly, so
    /// the store *is* the source of truth and the object is a typed view of it. This router is
    /// `Sendable` because `LLMClient` requires it and its calls run off the main actor;
    /// capturing the observable object in a `@Sendable` closure would be a warning today and a
    /// data race the day someone gave that class a stored property. The store is safe to read
    /// from any thread, and the keys stay in one place because it asks `AppSettings` for them.
    init(defaults: UserDefaults) {
        self.pool = ClientPool()
        self.defaults = defaults
    }

    /// Which engine, on which port — read **together**, as one decision.
    ///
    /// Every method here used to call `engine()` to pick its branch and `port()` to pick the
    /// address, and `port()` read the engine key a second time to know which port key to look
    /// under. A «Движок» change landing between those two reads therefore sent one engine's port
    /// into the other engine's client. One read, one value, no window.
    private func target() -> EngineTarget {
        let engine = AppSettings.engine(in: defaults)
        return EngineTarget(engine: engine, port: AppSettings.enginePort(in: defaults, for: engine))
    }

    private func client(for target: EngineTarget) async -> any LLMClient {
        switch target.engine {
        case .ollama: await pool.ollama(port: target.port)
        case .lmStudio: await pool.lmStudio(port: target.port)
        }
    }

    // MARK: - Translating

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        Self.chat(messages: messages, options: options, target: target(), pool: pool)
    }

    /// The body both this router and `PinnedEngineClient` run. Static and taking its target,
    /// because the only difference between the two is *when* that target was decided.
    fileprivate static func chat(messages: [ChatMessage], options: ChatOptions,
                                 target: EngineTarget,
                                 pool: ClientPool) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream: AsyncThrowingStream<ChatEvent, Error>
                    switch target.engine {
                    case .ollama:
                        stream = await pool.ollama(port: target.port).chat(messages: messages, options: options)
                    case .lmStudio:
                        stream = await pool.lmStudio(port: target.port).chat(messages: messages, options: options)
                    }
                    for try await event in stream { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The target this router would use **now**, frozen into a client that will keep using it.
    ///
    /// See `LLMClient.pinnedForRun()` for why a run may not straddle two servers. Reading the
    /// setting per call is this type's whole purpose and stays exactly as it is — a *new* run
    /// still picks up whatever the radio button says. What changes is that a run in flight no
    /// longer follows it: before this, flipping «Движок» mid-document sent one engine's model
    /// tag and protocol to the other engine's server, failed the файл being translated, and
    /// then failed every файл after it in the queue.
    func pinnedForRun() -> any LLMClient {
        PinnedEngineClient(pool: pool, target: target())
    }

    // MARK: - Asking about models

    func installedModels() async throws -> [EngineModel] {
        let target = target()
        switch target.engine {
        case .ollama:
            return try await pool.ollama(port: target.port).models().map {
                EngineModel(name: $0.name, sizeBytes: $0.sizeBytes,
                            loadedInstanceIDs: [], reasoningOptions: nil)
            }
        case .lmStudio:
            return try await pool.lmStudio(port: target.port).models().map {
                EngineModel(name: $0.key, sizeBytes: $0.sizeBytes,
                            loadedInstanceIDs: $0.loadedInstanceIDs,
                            reasoningOptions: $0.reasoningOptions)
            }
        }
    }

    func residentModels() async throws -> [String] {
        let target = target()
        switch target.engine {
        case .ollama:
            return try await pool.ollama(port: target.port).ps().map(\.name)
        case .lmStudio:
            // LM Studio reports residency per model rather than as a separate list, so this is
            // the same call as `installedModels` — one request either way, and the two answers
            // therefore describe the same moment rather than two moments a round trip apart.
            return try await pool.lmStudio(port: target.port).models()
                .filter(\.isLoaded).map(\.key)
        }
    }

    // MARK: - Memory

    /// Puts a model in memory, and answers how long that took where the server says.
    ///
    /// The two engines mean different things by «warm», which is why this is one method and not
    /// a shared implementation: Ollama has no load endpoint, so a one-token chat is the load,
    /// while on LM Studio an explicit load is the *only* kind that Auto-Evict leaves alone —
    /// a chat would JIT-load, and the next JIT load would evict it.
    func warmUp(model: String, options: ChatOptions) async throws {
        let target = target()
        switch target.engine {
        case .ollama:
            let client = await pool.ollama(port: target.port)
            for try await _ in client.chat(messages: [ChatMessage(role: "user", content: "ok")],
                                           options: options) {}
        case .lmStudio:
            try await pool.lmStudio(port: target.port).load(model: model)
        }
    }

    /// Frees one model's memory. `instanceIDs` is what LM Studio's unload takes and what its
    /// model list reports; on Ollama the model's own name is the only handle there is.
    func unload(model: EngineModel) async throws {
        let target = target()
        switch target.engine {
        case .ollama:
            try await pool.ollama(port: target.port).unload(model: model.name)
        case .lmStudio:
            let client = await pool.lmStudio(port: target.port)
            // Every instance, because a model can be loaded more than once and freeing one of
            // several would leave the row still saying «в памяти» after a successful command.
            for id in model.loadedInstanceIDs.isEmpty ? [model.name] : model.loadedInstanceIDs {
                try await client.unload(instanceID: id)
            }
        }
    }

    // MARK: - Downloading

    /// Downloads a model, presented in the vocabulary the pane already renders.
    ///
    /// This is the adaptation the design's correction note describes: `LMStudioKit` does not
    /// depend on `OllamaKit`, so its own progress value is translated here — in the one place
    /// that already knows which engine is selected — rather than by moving `PullProgress` down
    /// into the domain layer.
    func download(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let target = target()
            let task = Task {
                do {
                    switch target.engine {
                    case .ollama:
                        for try await progress in await pool.ollama(port: target.port).pull(model: model) {
                            continuation.yield(progress)
                        }
                    case .lmStudio:
                        for try await progress in await pool.lmStudio(port: target.port).download(model: model) {
                            continuation.yield(PullProgress(status: progress.status,
                                                            completed: progress.completed,
                                                            total: progress.total))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One client per engine **per port**, kept for the life of the process.
///
/// Keyed by port because the port is a setting: a client built for 1234 cannot answer for 1235,
/// and building one per request would mean a fresh `URLSession` — and a fresh connection pool,
/// and on LM Studio a fresh capability cache — for every chunk of every translation. The
/// dictionary grows only when someone edits the port, which bounds it by hand-typing.
actor ClientPool {
    private var ollamaClients: [Int: OllamaClient] = [:]
    private var lmStudioClients: [Int: LMStudioClient] = [:]

    func ollama(port: Int) -> OllamaClient {
        if let existing = ollamaClients[port] { return existing }
        let client = OllamaClient(baseURL: OllamaClient.baseURL(port: port))
        ollamaClients[port] = client
        return client
    }

    func lmStudio(port: Int) -> LMStudioClient {
        if let existing = lmStudioClients[port] { return existing }
        let client = LMStudioClient(port: port)
        lmStudioClients[port] = client
        return client
    }
}
