import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

/// One scripted reply per model call, in order. `TranslationViewModelTests` has a
/// `ScriptedClient` of its own; this is a separate one on purpose, because that one is
/// `private` to its file and sharing it would couple two suites' fixtures.
final class QueueClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private var _callCount = 0
    /// Blocks each reply behind a small sleep, so a cancellation has a window in which to
    /// land. A fully synchronous fake never suspends, and a test against it would pin
    /// nothing about cancellation at all.
    private let paced: Bool

    init(replies: [String], paced: Bool = false) { self.replies = replies; self.paced = paced }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        _callCount += 1
        // Deliberately does **not** run out: a queue that re-scanned its work list would
        // loop forever here, and a fixture that exhausted itself would turn that hang
        // into a different, misleading failure. The call count is what the test asserts.
        let reply = replies.isEmpty ? "перевод" : replies.removeFirst()
        lock.unlock()
        let paced = self.paced
        return AsyncThrowingStream { continuation in
            let producer = Task {
                if paced { try? await Task.sleep(for: .milliseconds(20)) }
                if !reply.isEmpty { continuation.yield(.token(reply)) }
                continuation.yield(.done(ChatStats(loadDurationMS: 1, promptEvalCount: 1,
                    promptEvalDurationMS: 1, evalCount: reply.count, evalDurationMS: 1)))
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

/// Never `GlossaryStore()`: its default URL is the developer's real
/// ~/Library/Application Support/LocalTranslator/glossary.json, and a suite that reads a
/// person's own file is the failure `InMemoryDefaults` exists to prevent, one directory
/// over.
@MainActor
func scratchGlossary() -> GlossaryStore {
    GlossaryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("glossary-\(UUID().uuidString).json"))
}

@MainActor
func makeQueueModel(_ client: LLMClient,
                    prefix: String,
                    configure: (AppSettings) -> Void = { _ in }) -> FileQueueModel {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: prefix))
    configure(settings)
    return FileQueueModel(translator: Translator(client: client),
                          settings: settings,
                          glossary: scratchGlossary(),
                          // Saving is TranslatedFileWriter's; here it always succeeds and
                          // reports where, so these tests never touch a filesystem.
                          save: { job, _ in .saved(job.url.appendingPathExtension("ru")) })
}

func queueJob(_ name: String, _ text: String) -> FileJob {
    FileJob(url: URL(fileURLWithPath: "/tmp/\(name)"), text: text, partsTotal: 1)
}

@MainActor @Test func theQueueTranslatesItsFilesInOrder() async {
    let client = QueueClient(replies: ["один", "два", "три"])
    let model = makeQueueModel(client, prefix: "queue-order")
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second"), queueJob("c.md", "third")])

    await model.run()

    #expect(model.jobs.allSatisfy { $0.state == .finished })
    #expect(model.jobs.map { $0.result?.final } == ["один", "два", "три"])
    #expect(client.callCount == 3)
}

@MainActor @Test func cancelStopsTheRunningFileAndLeavesTheRestQueued() async {
    let client = QueueClient(replies: ["один", "два", "три"], paced: true)
    let model = makeQueueModel(client, prefix: "queue-cancel")
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second"), queueJob("c.md", "third")])

    let run = Task { await model.run() }
    // Let the first file get into the stream, then stop it.
    try? await Task.sleep(for: .milliseconds(10))
    model.cancel()
    await run.value

    #expect(model.jobs[0].state == .interrupted)
    #expect(model.jobs[1].state == .queued)
    #expect(model.jobs[2].state == .queued)
    #expect(!model.isRunning)
}

@MainActor @Test func runningAgainRetriesWhatDidNotFinishRatherThanSkippingIt() async {
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let model = makeQueueModel(client, prefix: "queue-resume")
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])

    let first = Task { await model.run() }
    try? await Task.sleep(for: .milliseconds(10))
    model.cancel()
    await first.value
    #expect(model.jobs[0].state == .interrupted)

    await model.run()

    // The interrupted файл is retried, not stepped over: a queue that silently skips
    // what it failed to do reports success for work it never performed.
    #expect(model.jobs.allSatisfy { $0.state == .finished })
}

@MainActor @Test func aFileThatFailsIsNotRetriedWithinTheSameRun() async {
    // The test that catches a re-scanning loop. `run()` must decide its work list once:
    // a loop that re-asked «what is not finished?» after each задание would find the one
    // it had just marked .failed and translate it again, forever, on the main actor.
    //
    // QueueClient answers every call, so a re-scanning implementation hangs rather than
    // failing — which is why the assertion is on the call count. A test that wedges the
    // suite instead of naming the defect is worse than no test.
    let client = QueueClient(replies: ["", "второй"])
    let model = makeQueueModel(client, prefix: "queue-failure")
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])

    await model.run()

    if case .failed = model.jobs[0].state {} else { Issue.record("expected the first file to fail") }
    #expect(model.jobs[1].state == .finished)
    #expect(client.callCount == 2)   // one attempt each, not one-and-forever
}

@MainActor @Test func anUnreadableFileIsShownButNeverTranslated() async {
    let client = QueueClient(replies: ["перевод"])
    let model = makeQueueModel(client, prefix: "queue-unreadable")
    var refused = queueJob("broken.pdf", "")
    refused.state = .unreadable
    model.add([refused, queueJob("b.md", "second")])

    await model.run()

    // It stays on screen naming the file the drop could not take, and the queue neither
    // translates it nor retries it on a later run.
    #expect(model.jobs[0].state == .unreadable)
    #expect(model.jobs[1].state == .finished)
    #expect(client.callCount == 1)
}

@MainActor @Test func theSelectionStaysWhereTheUserPutIt() async {
    // The queue must not follow the running file: a user reading a finished translation
    // would have it pulled out from under them, and the status bar already says which
    // file is running.
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let model = makeQueueModel(client, prefix: "queue-selection")
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])
    model.selection = model.jobs[1].id

    await model.run()

    #expect(model.selection == model.jobs[1].id)
}

@MainActor @Test func aSecondRunIsRefusedWhileOneIsAlreadyGoing() async {
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let model = makeQueueModel(client, prefix: "queue-reentrancy")
    model.add([queueJob("a.md", "first")])

    let first = Task { await model.run() }
    try? await Task.sleep(for: .milliseconds(5))
    await model.run()   // must return immediately, not start a second pass
    await first.value

    #expect(client.callCount == 1)
}

@MainActor @Test func aFinishedFileRecordsWhereItWasSaved() async {
    let client = QueueClient(replies: ["перевод"])
    let model = makeQueueModel(client, prefix: "queue-saved")
    model.add([queueJob("a.md", "first")])

    await model.run()

    #expect(model.jobs[0].saveProblem == nil)
    #expect(model.jobs[0].result?.savedTo?.lastPathComponent == "a.md.ru")
}

@MainActor @Test func aWriteThatFailsLeavesTheTranslationFinishedAndSaysSoSeparately() async {
    // The задание finished; the bytes did not land. Reporting it as a failed translation
    // would be a lie about text that is in memory and copyable.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "queue-save-problem"))
    let model = FileQueueModel(translator: Translator(client: QueueClient(replies: ["перевод"])),
                               settings: settings, glossary: scratchGlossary(),
                               save: { _, _ in .refused("Не удалось сохранить перевод.") })
    model.add([queueJob("a.md", "first")])

    await model.run()

    #expect(model.jobs[0].state == .finished)
    #expect(model.jobs[0].result?.final == "перевод")
    #expect(model.jobs[0].saveProblem == "Не удалось сохранить перевод.")
    #expect(model.jobs[0].result?.savedTo == nil)
}

/// A source whose markup the reply drops, so `MarkupSkeleton` reports a diff. Checked
/// against the engine rather than assumed — see `theWarningFixtureActuallyProducesAWarning`.
private let sourceWithALink = "See the [guide](https://example.org/g) for more."
private let replyWithoutTheLink = "Смотрите руководство."

@MainActor @Test func theWarningFixtureActuallyProducesAWarning() async {
    // Pins the fixture itself. Without this, a change in MarkupSkeleton could make the
    // three stopOnWarnings tests below pass for the wrong reason — a queue that never
    // pauses looks identical to a queue with nothing to pause on.
    let model = makeQueueModel(QueueClient(replies: [replyWithoutTheLink]), prefix: "queue-fixture")
    model.add([queueJob("a.md", sourceWithALink)])

    await model.run()

    #expect(model.jobs[0].result?.hasWarnings == true)
}

@MainActor @Test func stopOnWarningsHaltsTheQueueButStillFinishesTheFileThatEarnedIt() async {
    let client = QueueClient(replies: [replyWithoutTheLink, "второй"])
    let model = makeQueueModel(client, prefix: "queue-stop") { $0.stopOnWarnings = true }
    model.add([queueJob("a.md", sourceWithALink), queueJob("b.md", "second")])

    await model.run()

    #expect(model.jobs[0].state == .finished)   // it finished; the pause is not a rollback
    #expect(model.jobs[1].state == .queued)
    #expect(model.pausedAfterWarnings)
    #expect(!model.isRunning)
}

@MainActor @Test func clearingThePauseLetsTheQueueCarryOn() async {
    let client = QueueClient(replies: [replyWithoutTheLink, "второй"])
    let model = makeQueueModel(client, prefix: "queue-unpause") { $0.stopOnWarnings = true }
    model.add([queueJob("a.md", sourceWithALink), queueJob("b.md", "second")])
    await model.run()
    #expect(model.pausedAfterWarnings)

    await model.run()

    #expect(!model.pausedAfterWarnings)
    #expect(model.jobs[1].state == .finished)
}

@MainActor @Test func aCleanFileDoesNotPauseAQueueThatStopsOnWarnings() async {
    let client = QueueClient(replies: ["первый", "второй"])
    let model = makeQueueModel(client, prefix: "queue-clean") { $0.stopOnWarnings = true }
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])

    await model.run()

    #expect(!model.pausedAfterWarnings)
    #expect(model.jobs.allSatisfy { $0.state == .finished })
}

@MainActor @Test func theModeSwitchIsLockedWhileTheQueueRuns() async {
    // One window, one primary button. If the mode could change mid-run the user could
    // switch to «Текст» and press «Перевести», putting two runs behind one toolbar.
    let client = QueueClient(replies: ["один"], paced: true)
    let model = makeQueueModel(client, prefix: "queue-mode-lock")
    model.add([queueJob("a.md", "first")])
    #expect(model.canChangeMode)

    let run = Task { await model.run() }
    try? await Task.sleep(for: .milliseconds(5))
    #expect(!model.canChangeMode)
    await run.value

    #expect(model.canChangeMode)
}

@MainActor @Test func aDroppedFileIsPlannedWithTheUsersChunkSizeAndNotThe900Default() async {
    // The queued row promises «N частей» before anything runs. Planning with the 900 that
    // happens to be the default would promise four to a user who set 500 and serve seven.
    let model = makeQueueModel(QueueClient(replies: []), prefix: "queue-chunk-size") {
        $0.chunkSize = 120
    }
    let text = String(repeating: "Одно предложение про ресурс и сервер. ", count: 20)

    await model.add(dropped: [QueueDrop.Item(url: URL(fileURLWithPath: "/tmp/a.md"), text: text)])

    let expected = Chunker.plan(text, maxCharacters: 120).chunks.count
    #expect(expected > 1)                       // the fixture actually exercises the split
    #expect(model.jobs[0].partsTotal == expected)
}

@MainActor @Test func anUnreadableItemBecomesARowRatherThanBeingDropped() async {
    let model = makeQueueModel(QueueClient(replies: []), prefix: "queue-unreadable-row")

    await model.add(dropped: [
        QueueDrop.Item(url: URL(fileURLWithPath: "/tmp/a.md"), text: "текст"),
        QueueDrop.Item(url: URL(fileURLWithPath: "/tmp/b.pdf"), text: nil),
    ])

    #expect(model.jobs.map(\.state) == [.queued, .unreadable])
    #expect(model.jobs[1].partsTotal == 0)
}
