import Testing
import Foundation
import AppKit
@testable import TranslatorApp
@testable import TranslationCore

private func freshStore() -> InMemoryDefaults { InMemoryDefaults(prefix: "router") }

private func pinnedTarget(of client: any LLMClient) -> EngineTarget? {
    (client as? PinnedEngineClient)?.target
}

/// The router reads «Движок» on every call by design, so a *new* run follows the radio button
/// without a relaunch. That is wanted and stays.
@Test func afreshPinFollowsWhicheverEngineIsSelectedNow() {
    let defaults = freshStore()
    let router = EngineRouter(defaults: defaults)
    #expect(pinnedTarget(of: router.pinnedForRun())
            == EngineTarget(engine: .ollama, port: ModelEngine.ollama.defaultPort))

    AppSettings(defaults: defaults).engine = .lmStudio
    #expect(pinnedTarget(of: router.pinnedForRun())
            == EngineTarget(engine: .lmStudio, port: ModelEngine.lmStudio.defaultPort))
}

/// The defect. A run is many calls — a term list, then one per часть — and the router answered
/// each of them from whatever the setting said at that instant. Flipping «Движок» mid-document
/// therefore sent one engine's model tag and protocol to the other engine's server: the файл
/// being translated failed, and so did every файл queued behind it.
@Test func aPinnedClientIgnoresAnEngineChangeThatLandsMidRun() {
    let defaults = freshStore()
    let router = EngineRouter(defaults: defaults)
    let pinned = router.pinnedForRun()
    let before = pinnedTarget(of: pinned)

    AppSettings(defaults: defaults).engine = .lmStudio

    #expect(pinnedTarget(of: pinned) == before)
    #expect(before == EngineTarget(engine: .ollama, port: ModelEngine.ollama.defaultPort))
}

/// The port half of the same defect, and the one that was torn rather than merely late: the
/// engine key was read once to pick the branch and again inside the port lookup to pick the key.
/// A pin must carry a port that belongs to the engine it names.
@Test func aPinnedTargetCarriesThePortOfTheEngineItNames() {
    let defaults = freshStore()
    let settings = AppSettings(defaults: defaults)
    settings.enginePort = 11500          // Ollama's
    settings.engine = .lmStudio
    settings.enginePort = 1300           // LM Studio's

    #expect(pinnedTarget(of: EngineRouter(defaults: defaults).pinnedForRun())
            == EngineTarget(engine: .lmStudio, port: 1300))

    settings.engine = .ollama
    #expect(pinnedTarget(of: EngineRouter(defaults: defaults).pinnedForRun())
            == EngineTarget(engine: .ollama, port: 11500))
}

/// Pinning a pinned client answers itself. Otherwise a second `forRun()` inside a run — правка
/// started from the model that was translating, say — would quietly re-read the setting and undo
/// the freeze.
@Test func pinningAnAlreadyPinnedClientChangesNothing() {
    let defaults = freshStore()
    let once = EngineRouter(defaults: defaults).pinnedForRun()
    AppSettings(defaults: defaults).engine = .lmStudio
    #expect(pinnedTarget(of: once.pinnedForRun()) == pinnedTarget(of: once))
}

/// The default implementation, which is what every other client in the tree gets: a client with
/// one target has nothing to freeze and must not be wrapped.
@Test func aClientWithOneTargetPinsToItself() {
    let client = QueueClient(replies: [])
    #expect(client.pinnedForRun() as AnyObject === client as AnyObject)
    #expect(pinnedTarget(of: client.pinnedForRun()) == nil)
}

// MARK: - The three models actually ask for a frozen client

/// Counts the pins and forwards the chat, so a test can tell «the seam exists» from «the seam is
/// used». The first is a property of `EngineRouter`; the second is a property of the three
/// places that start runs, and it is the half that a refactor silently drops.
final class PinCountingClient: LLMClient, @unchecked Sendable {
    private let inner: LLMClient
    private let lock = NSLock()
    private var _pins = 0
    var pins: Int { lock.lock(); defer { lock.unlock() }; return _pins }

    init(_ inner: LLMClient) { self.inner = inner }

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        inner.chat(messages: messages, options: options)
    }
    func pinnedForRun() -> any LLMClient {
        lock.lock(); _pins += 1; lock.unlock()
        return self
    }
}

@MainActor @Test func aWindowTranslationFreezesTheEngineBeforeItStarts() async {
    let client = PinCountingClient(QueueClient(replies: ["перевод"]))
    let model = TranslationViewModel(translator: Translator(client: client),
                                     settings: AppSettings(defaults: InMemoryDefaults(prefix: "pin-t")),
                                     glossary: scratchGlossary(),
                                     pasteboard: NSPasteboard(name: NSPasteboard.Name("pin-t")))
    model.sourceText = "Одна строка прозы."

    await model.translate()

    #expect(model.state == .finished)
    #expect(client.pins == 1)
}

@MainActor @Test func aправкаRunFreezesTheEngineBeforeItStarts() async {
    let client = PinCountingClient(QueueClient(replies: ["правленый текст"]))
    let model = TranslationViewModel(translator: Translator(client: client),
                                     settings: AppSettings(defaults: InMemoryDefaults(prefix: "pin-p")),
                                     glossary: scratchGlossary(),
                                     pasteboard: NSPasteboard(name: NSPasteboard.Name("pin-p")))
    model.sourceText = "Одна строка прозы."
    model.operation = .proofread

    await model.run()

    #expect(model.state == .finished)
    #expect(client.pins == 1)
}

/// One pin per файл rather than one for the whole queue, and that is the right granularity: the
/// queue is a sequence of runs, and a «Движок» change between two files is a change the *next*
/// file should follow.
@MainActor @Test func theQueueFreezesTheEngineOncePerFile() async {
    let client = PinCountingClient(QueueClient(replies: ["первый", "второй"]))
    let model = makeQueueModel(client, prefix: "pin-q")
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])

    await model.run()

    #expect(model.jobs.allSatisfy { $0.state == .finished })
    #expect(client.pins == 2)
}
