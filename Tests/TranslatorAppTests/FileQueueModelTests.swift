import Foundation
import AppKit
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

    /// Which call, by zero-based index, fails instead of answering. The term-list call is
    /// call 0 for a multi-часть file, which is what the gate's failure test needs to break.
    private let failCallAtIndex: Int?

    init(replies: [String], paced: Bool = false, failCallAtIndex: Int? = nil) {
        self.replies = replies; self.paced = paced; self.failCallAtIndex = failCallAtIndex
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        let index = _callCount
        _callCount += 1
        // Deliberately does **not** run out: a queue that re-scanned its work list would
        // loop forever here, and a fixture that exhausted itself would turn that hang
        // into a different, misleading failure. The call count is what the test asserts.
        let reply = replies.isEmpty ? "перевод" : replies.removeFirst()
        lock.unlock()
        let paced = self.paced
        if index == failCallAtIndex {
            return AsyncThrowingStream { $0.finish(throwing: ScriptedFailure()) }
        }
        return AsyncThrowingStream { continuation in
            let producer = Task {
                if paced { try? await Task.sleep(for: .milliseconds(60)) }
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
                          save: { source, _, _ in .saved(source.appendingPathExtension("ru")) },
                          saveAs: { _, url in .saved(url) },
                          pasteboard: NSPasteboard(name: .init("queue-\(prefix)")))
}

func queueJob(_ name: String, _ text: String) -> FileJob {
    FileJob(url: URL(fileURLWithPath: "/tmp/\(name)"), text: text, partsTotal: 1)
}

/// Waits until the model has actually been asked for something.
///
/// Stronger than `waitUntilRunning`, which returns as soon as the row's state flips —
/// before `chat` has been entered. A cancel sent in that window is a different test from
/// the one intended.
@MainActor
private func waitUntilCalled(_ client: QueueClient, _ count: Int = 1) async {
    for _ in 0..<20_000 {
        if client.callCount >= count { return }
        await Task.yield()
    }
    Issue.record("the model was never asked")
}

/// Waits until a задание is actually in flight, then returns.
///
/// **State, not a sleep.** These tests used `try? await Task.sleep(for: .milliseconds(10))`
/// and cancelled afterwards, on the assumption that a 60 ms paced reply would still be in
/// the air. Under a full 510-test run that sleep overshoots — measured: roughly one run in
/// five, `cancel()` arrived after the whole three-file queue had finished and every
/// assertion about `.interrupted` failed. `FakeLLMClient.onCallStart` carries the same
/// lesson in its own doc comment: racing a cancellation against a guessed duration only
/// ever pins the timing on one machine.
///
/// The gap between observing `.running` and the caller's `cancel()` is a single yield on
/// the main actor, so the paced reply cannot have landed in it.
@MainActor
private func waitUntilRunning(_ model: FileQueueModel, _ index: Int,
                              _ comment: Comment = "the задание never started") async {
    for _ in 0..<20_000 {
        if case .running = model.jobs[index].state { return }
        await Task.yield()
    }
    Issue.record(comment)
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
    await waitUntilRunning(model, 0)
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
    await waitUntilRunning(model, 0)
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
    await waitUntilRunning(model, 0)
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
                               save: { _, _, _ in .refused("Не удалось сохранить перевод.") },
                               saveAs: { _, url in .saved(url) })
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
    await waitUntilRunning(model, 0)
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

@MainActor
private func makeTextModel(_ prefix: String) -> TranslationViewModel {
    TranslationViewModel(translator: Translator(client: QueueClient(replies: [])),
                         settings: AppSettings(defaults: InMemoryDefaults(prefix: prefix)),
                         glossary: scratchGlossary(),
                         pasteboard: NSPasteboard(name: .init("primary-\(prefix)")))
}

@MainActor @Test func thePrimaryActionInFilesModeDrivesTheQueueAndNotTheTextModel() async {
    let client = QueueClient(replies: ["один"])
    let queue = makeQueueModel(client, prefix: "primary-files")
    queue.add([queueJob("a.md", "first")])
    let text = makeTextModel("primary-files-text")

    let action = PrimaryAction.forMode(.files, text: text, queue: queue)
    #expect(action.canStart)
    await action.start()

    #expect(queue.jobs[0].state == .finished)
    #expect(text.state == .idle)   // the text model was never touched
}

@MainActor @Test func thePrimaryActionSaysThereIsNothingToStartWhenTheQueueIsEmpty() {
    let queue = makeQueueModel(QueueClient(replies: []), prefix: "primary-empty")
    let text = makeTextModel("primary-empty-text")

    // An empty queue and an empty source pane are the same statement to the user: there is
    // nothing to translate. The button says so in both modes rather than only one.
    #expect(!PrimaryAction.forMode(.files, text: text, queue: queue).canStart)
    #expect(!PrimaryAction.forMode(.text, text: text, queue: queue).canStart)
}

@MainActor @Test func anUnreadableFileAloneDoesNotLightThePrimaryButton() {
    let queue = makeQueueModel(QueueClient(replies: []), prefix: "primary-unreadable")
    var refused = queueJob("broken.pdf", "")
    refused.state = .unreadable
    queue.add([refused])

    // There is nothing to translate: the queue would skip it, so offering to start is a
    // button that does nothing when pressed.
    #expect(!PrimaryAction.forMode(.files, text: makeTextModel("primary-unreadable-text"),
                                   queue: queue).canStart)
}

@MainActor @Test func cancellingInFilesModeStopsTheQueueAndNotTheTextModel() async {
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let queue = makeQueueModel(client, prefix: "primary-cancel")
    queue.add([queueJob("a.md", "first"), queueJob("b.md", "second")])
    let text = makeTextModel("primary-cancel-text")
    let action = PrimaryAction.forMode(.files, text: text, queue: queue)

    let run = Task { await action.start() }
    await waitUntilRunning(queue, 0)
    action.cancel()
    await run.value

    #expect(queue.jobs[0].state == .interrupted)
}

@MainActor @Test func thePrimaryActionReportsWhicheverModelIsRunning() async {
    let client = QueueClient(replies: ["один"], paced: true)
    let queue = makeQueueModel(client, prefix: "primary-running")
    queue.add([queueJob("a.md", "first")])
    let text = makeTextModel("primary-running-text")

    #expect(!PrimaryAction.forMode(.files, text: text, queue: queue).isRunning)
    let run = Task { await queue.run() }
    await waitUntilRunning(queue, 0)
    #expect(PrimaryAction.forMode(.files, text: text, queue: queue).isRunning)
    // ...and the text mode is unaffected, which is what stops one toolbar showing
    // «Отмена» for a run the visible pane knows nothing about.
    #expect(!PrimaryAction.forMode(.text, text: text, queue: queue).isRunning)
    await run.value
}

@MainActor @Test func theRightPaneShowsTheSelectedFileAndNotWhicheverIsStreaming() async {
    // Wiring the pane straight to the running file's stream means selecting a finished
    // задание shows somebody else's document under its name — visible the moment it is
    // wrong, and invisible in any test that only ever selects the running file.
    let client = QueueClient(replies: ["первый перевод", "второй перевод"])
    let model = makeQueueModel(client, prefix: "queue-right-pane")
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])
    await model.run()

    model.selection = model.jobs[0].id
    #expect(model.selectedText == "первый перевод")
    #expect(model.selectedTitle == "Перевод · a.md")

    model.selection = model.jobs[1].id
    #expect(model.selectedText == "второй перевод")
    #expect(model.selectedTitle == "Перевод · b.md")
}

@MainActor @Test func theRightPaneFallsBackToTheHeaderWithNothingSelected() {
    let model = makeQueueModel(QueueClient(replies: []), prefix: "queue-right-pane-empty")
    #expect(model.selectedText.isEmpty)
    #expect(model.selectedTitle == "Перевод")
}

@MainActor @Test func theStatusLineCountsFilesAndPartsAcrossTheWholeQueue() async {
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let model = makeQueueModel(client, prefix: "queue-status")
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])
    // Nothing has run: there is nothing to say, and an empty row is better than a «0 из 2»
    // that implies work is under way.
    #expect(model.statusLine == nil)

    let run = Task { await model.run() }
    await waitUntilRunning(model, 0)
    let line = model.statusLine
    await run.value

    #expect(line?.contains("Перевожу 1-й файл из 2") == true)
}

@MainActor @Test func thePauseSaysWhyTheQueueStopped() async {
    let client = QueueClient(replies: [replyWithoutTheLink, "второй"])
    let model = makeQueueModel(client, prefix: "queue-status-paused") { $0.stopOnWarnings = true }
    model.add([queueJob("a.md", sourceWithALink), queueJob("b.md", "second")])
    await model.run()

    #expect(model.statusLine == "Очередь остановлена на предупреждениях — нажмите «Перевести», чтобы продолжить")
}

// MARK: - The document-terms gate

/// Long enough for `Chunker` to split at the default size, so a документный глоссарий is
/// actually built and there is something to review.
private let longEnoughForTwoParts = String(
    repeating: "The resource is published by the server and the resource is validated. ", count: 20)

/// Waits for the sheet, with a ceiling.
///
/// An unbounded `while model.pendingTermsRequest == nil { await Task.yield() }` turns «the
/// sheet never appeared» into a hung suite instead of a failed test — which is exactly what
/// happened when this file's fixtures were first written, and is the same rule
/// `aFileThatFailsIsNotRetriedWithinTheSameRun` exists to keep.
@MainActor
private func waitForSheet(_ model: FileQueueModel,
                          _ comment: Comment = "the terms sheet never appeared") async -> DocumentTermsRequest? {
    for _ in 0..<400 {
        if let request = model.pendingTermsRequest { return request }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record(comment)
    return nil
}

@MainActor @Test func aQueueAsksOnceWhenTheUserSaysNotToAskAgain() async {
    // Thirteen files would otherwise mean thirteen sheets, in exactly the scenario the gate
    // was designed for.
    // Each file is one term-list call plus its части, so the second file's term list is
    // call 3. It is a parseable list too — with the default reply the gate would have
    // nothing to open on and the wait below would fail rather than the assertion.
    let client = QueueClient(replies: ["resource => ресурс", "первый", "первый-2",
                                       "resource => ресурс", "второй", "второй-2"])
    let model = makeQueueModel(client, prefix: "queue-gate-once") { $0.reviewDocumentTerms = true }
    model.add([queueJob("a.md", longEnoughForTwoParts), queueJob("b.md", longEnoughForTwoParts)])

    let run = Task { await model.run() }
    let sheet = await waitForSheet(model)
    sheet?.suppressForRun = true
    sheet?.proceed()
    await run.value

    #expect(model.jobs.allSatisfy { $0.state == .finished })
    #expect(model.pendingTermsRequest == nil)
}

@MainActor @Test func theSuppressionIsForgottenWhenTheNextRunStarts() async {
    // A statement about this sitting, not a preference.
    let client = QueueClient(replies: ["resource => ресурс", "первый", "первый-2",
                                       "resource => ресурс", "второй", "второй-2"])
    let model = makeQueueModel(client, prefix: "queue-gate-forget") { $0.reviewDocumentTerms = true }
    model.add([queueJob("a.md", longEnoughForTwoParts)])

    let first = Task { await model.run() }
    let sheet = await waitForSheet(model)
    sheet?.suppressForRun = true
    sheet?.proceed()
    await first.value

    model.add([queueJob("b.md", longEnoughForTwoParts)])
    let second = Task { await model.run() }
    // It asks again: the suppression was about that sitting, not a preference.
    let again = await waitForSheet(model, "the gate did not come back for the next run")
    again?.proceed()
    await second.value

    #expect(model.jobs.allSatisfy { $0.state == .finished })
}

@MainActor @Test func cancellingTheQueueReachesASheetItIsWaitingOn() async {
    let client = QueueClient(replies: ["resource => ресурс", "первый", "первый-2"])
    let model = makeQueueModel(client, prefix: "queue-gate-cancel") { $0.reviewDocumentTerms = true }
    model.add([queueJob("a.md", longEnoughForTwoParts)])

    let run = Task { await model.run() }
    _ = await waitForSheet(model)
    model.cancel()
    await run.value

    #expect(model.jobs[0].state == .interrupted)
    #expect(model.pendingTermsRequest == nil)
}

@MainActor @Test func theQueueSaysWhenTheTermsItPromisedCouldNotBePrepared() async {
    // §6.6, the queue's half. The flag is per задание and not per queue: thirteen files can
    // hit the failure on three of them, and one flag on the model would report the last
    // file's luck for all of them.
    let client = QueueClient(replies: ["", "перевод"], failCallAtIndex: 0)
    let model = makeQueueModel(client, prefix: "queue-gate-unavailable") {
        $0.reviewDocumentTerms = true
    }
    model.add([queueJob("a.md", longEnoughForTwoParts)])

    await model.run()

    #expect(model.jobs[0].state == .finished)
    #expect(model.jobs[0].documentTermsUnavailable)
}

// MARK: - Saving on demand

@MainActor
private func savingModel(_ prefix: String,
                         besideSource: @escaping (URL, String, Language) -> SaveOutcome,
                         configure: (AppSettings) -> Void = { _ in }) -> FileQueueModel {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: prefix))
    configure(settings)
    return FileQueueModel(translator: Translator(client: QueueClient(replies: ["перевод"])),
                          settings: settings, glossary: scratchGlossary(),
                          save: besideSource,
                          saveAs: { _, url in .saved(url) })
}

@MainActor @Test func aFinishedFileThatWasNotSavedIsOfferedForSaving() async {
    // With «Рядом с исходником» off, nothing is written automatically — so every finished
    // задание has to offer it, or the queue produces translations that can only be copied.
    let model = savingModel("save-on-demand", besideSource: { source, _, _ in
        .saved(source.appendingPathExtension("ru"))
    }) { $0.saveNextToSource = false }
    model.add([queueJob("a.md", "first")])
    await model.run()

    #expect(model.jobs[0].result?.savedTo == nil)
    #expect(model.needsSaving(model.jobs[0]))

    model.saveBesideSource(model.jobs[0].id)

    #expect(model.jobs[0].result?.savedTo?.lastPathComponent == "a.md.ru")
    #expect(!model.needsSaving(model.jobs[0]))
    #expect(model.jobs[0].saveProblem == nil)
}

@MainActor @Test func aSavedFileIsNotOfferedForSavingAgain() async {
    let model = savingModel("save-already", besideSource: { source, _, _ in
        .saved(source.appendingPathExtension("ru"))
    })
    model.add([queueJob("a.md", "first")])
    await model.run()

    #expect(model.jobs[0].result?.savedTo != nil)
    #expect(!model.needsSaving(model.jobs[0]))
}

@MainActor @Test func aRefusedWriteLeavesTheFileOfferedForSavingWithItsProblemShown() async {
    let model = savingModel("save-refused", besideSource: { _, _, _ in .refused("Нет доступа.") })
    model.add([queueJob("a.md", "first")])
    await model.run()

    #expect(model.jobs[0].state == .finished)
    #expect(model.jobs[0].saveProblem == "Нет доступа.")
    // Still offered: the refusal is what «Сохранить как…» exists to get past, and a retry
    // beside the source is legitimate once the user has granted access.
    #expect(model.needsSaving(model.jobs[0]))
}

@MainActor @Test func savingSomewhereElseRecordsWhereItActuallyWent() async {
    let model = savingModel("save-as", besideSource: { _, _, _ in .refused("Нет доступа.") })
    model.add([queueJob("a.md", "first")])
    await model.run()

    let chosen = URL(fileURLWithPath: "/tmp/куда-нибудь/a.ru.md")
    model.save(model.jobs[0].id, to: chosen)

    #expect(model.jobs[0].result?.savedTo == chosen)
    // The problem goes with the failure it described: the file is saved now.
    #expect(model.jobs[0].saveProblem == nil)
    #expect(!model.needsSaving(model.jobs[0]))
}

@MainActor @Test func theSuggestedNameIsTheOneTheAutomaticSaveWouldHaveUsed() async {
    let model = savingModel("save-suggested", besideSource: { _, _, _ in .refused("Нет доступа.") })
    model.add([queueJob("a.md", "first")])
    await model.run()

    // «а.md» is English text translated into Russian by the default rule, so «.ru».
    #expect(model.suggestedName(for: model.jobs[0].id) == "a.ru.md")
}

@MainActor @Test func nothingUnfinishedIsOfferedForSaving() {
    let model = savingModel("save-unfinished", besideSource: { _, _, _ in .refused("x") })
    var refused = queueJob("broken.pdf", "")
    refused.state = .unreadable
    model.add([queueJob("a.md", "first"), refused])

    #expect(!model.needsSaving(model.jobs[0]))   // queued
    #expect(!model.needsSaving(model.jobs[1]))   // unreadable
}

@MainActor @Test func aQueueHeldOnTheSheetSaysItIsWaitingAndNotTranslating() async {
    let client = QueueClient(replies: ["resource => ресурс", "первый", "первый-2"])
    let model = makeQueueModel(client, prefix: "queue-awaiting") { $0.reviewDocumentTerms = true }
    model.add([queueJob("a.md", longEnoughForTwoParts)])

    let run = Task { await model.run() }
    let sheet = await waitForSheet(model)
    #expect(model.isAwaitingTerms)
    sheet?.proceed()
    await run.value

    #expect(!model.isAwaitingTerms)
}

// MARK: - The controls that were blind to the mode

@MainActor @Test func theQueueTranslatesIntoTheToolbarsTargetAndNotTheSettingsRule() async {
    // Three pickers are drawn on the batch screen. Before this they configured nothing: the
    // queue read settings.targetLanguage(forDetected:) and settings.defaultTone, so a user
    // who chose «В: немецкий» got Russian and had no way to find out why.
    let client = QueueClient(replies: ["перевод"])
    let model = makeQueueModel(client, prefix: "queue-override-target")
    model.add([queueJob("a.md", "The resource is published.")])

    await model.run(source: nil, target: .de, tone: .technical)

    #expect(model.jobs[0].resolvedTarget == .de)
}

@MainActor @Test func withNoOverrideTheQueueStillFollowsTheSettingsRule() async {
    let client = QueueClient(replies: ["перевод"])
    let model = makeQueueModel(client, prefix: "queue-override-none")
    model.add([queueJob("a.md", "The resource is published.")])

    await model.run()

    // English text, default settings: into the primary language.
    #expect(model.jobs[0].resolvedTarget == .ru)
}

@MainActor @Test func theNameASavedFileGetsFollowsTheTargetTheRunActuallyUsed() async {
    // Otherwise «Сохранить как…» would suggest «a.ru.md» for a file translated into German.
    let client = QueueClient(replies: ["перевод"])
    let model = makeQueueModel(client, prefix: "queue-override-name")
    model.add([queueJob("a.md", "The resource is published.")])

    await model.run(source: nil, target: .de, tone: nil)

    #expect(model.suggestedName(for: model.jobs[0].id) == "a.de.md")
}

@MainActor @Test func copyingInFilesModePutsTheSelectedFilesTranslationOnTheBoard() async {
    let board = NSPasteboard(name: .init("queue-copy-\(UUID().uuidString)"))
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "queue-copy"))
    let model = FileQueueModel(translator: Translator(client: QueueClient(replies: ["первый", "второй"])),
                               settings: settings, glossary: scratchGlossary(),
                               save: { source, _, _ in .saved(source) },
                               saveAs: { _, url in .saved(url) },
                               pasteboard: board)
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])
    await model.run()

    model.selection = model.jobs[1].id
    await model.copySelection()

    #expect(board.string(forType: .string) == "второй")
}

@MainActor @Test func thePrimaryActionCopiesWhateverTheVisibleModeIsShowing() async {
    let client = QueueClient(replies: ["перевод файла"])
    let queue = makeQueueModel(client, prefix: "primary-copy")
    queue.add([queueJob("a.md", "first")])
    await queue.run()
    let text = makeTextModel("primary-copy-text")

    // The text pane is empty and the queue has a translation on screen: «Скопировать» must
    // be lit in «Файлы» and dark in «Текст». It used to be lit in both and act on the text
    // model in both, so pressing it in «Файлы» was a silent no-op.
    #expect(PrimaryAction.forMode(.files, text: text, queue: queue).canCopy)
    #expect(!PrimaryAction.forMode(.text, text: text, queue: queue).canCopy)
}

@MainActor @Test func clearingTheSourceIsOfferedOnlyWhereThereIsASourceToClear() async {
    let queue = makeQueueModel(QueueClient(replies: []), prefix: "primary-clear")
    let text = makeTextModel("primary-clear-text")
    text.sourceText = "что-то"

    #expect(PrimaryAction.forMode(.text, text: text, queue: queue).canClear)
    // «Очистить исходник» names the text pane. In «Файлы» that pane is not on screen, and
    // repurposing the item to empty the queue would throw away translations that may not
    // be saved yet — without a visible control saying so.
    #expect(!PrimaryAction.forMode(.files, text: text, queue: queue).canClear)
}

@MainActor @Test func aRowCanBeTakenOutOfTheQueue() async {
    let model = makeQueueModel(QueueClient(replies: []), prefix: "queue-remove")
    var refused = queueJob("broken.pdf", "")
    refused.state = .unreadable
    model.add([queueJob("a.md", "first"), refused])

    // The spec promises an unreadable file «can be removed», and until now nothing could
    // remove anything: `remove(_:)` existed and no view called it.
    model.remove(model.jobs[1].id)

    #expect(model.jobs.map { $0.url.lastPathComponent } == ["a.md"])
}

// MARK: - Review round 1

@MainActor @Test func theAutomaticSaveUsesTheTargetTheRunActuallyUsed() async {
    // The defect this pins: the app's save closure re-detected the language and consulted
    // the settings rule, so a file translated into German under a toolbar override was
    // written as «a.ru.md». `suggestedName` did it right, so the two save paths disagreed
    // about one file's name — and the test that existed only checked the suggestion.
    let seen = SaveCall()
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "save-target"))
    let model = FileQueueModel(translator: Translator(client: QueueClient(replies: ["перевод"])),
                               settings: settings, glossary: scratchGlossary(),
                               save: { url, _, target in
                                   seen.record(target)
                                   return .saved(url)
                               },
                               saveAs: { _, url in .saved(url) })
    model.add([queueJob("a.md", "The resource is published.")])

    await model.run(source: nil, target: .de, tone: nil)

    #expect(seen.target == .de)
}

@MainActor @Test func savingOnDemandAlsoUsesTheTargetTheRunUsed() async {
    let seen = SaveCall()
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "save-target-later"))
    settings.saveNextToSource = false
    let model = FileQueueModel(translator: Translator(client: QueueClient(replies: ["перевод"])),
                               settings: settings, glossary: scratchGlossary(),
                               save: { url, _, target in
                                   seen.record(target)
                                   return .saved(url)
                               },
                               saveAs: { _, url in .saved(url) })
    model.add([queueJob("a.md", "The resource is published.")])
    await model.run(source: nil, target: .de, tone: nil)

    model.saveBesideSource(model.jobs[0].id)

    #expect(seen.target == .de)
}

@MainActor private final class SaveCall {
    private(set) var target: Language?
    func record(_ language: Language) { target = language }
}

/// Holds the model so a closure the model owns can call back into it. Needed because the
/// closure has to exist before the model does.
@MainActor private final class ModelBox { var model: FileQueueModel? }

@MainActor @Test func cancellingBetweenTwoFilesStopsTheQueueRatherThanStartingTheNextOne() async {
    // The gap `cancel()` did not cover: `translate(at:)` reports «carry on» for a файл that
    // finished normally, so a cancel landing after it and before the next one starts has no
    // task to reach and nothing else stopped the loop.
    //
    // The save closure runs at exactly that instant, on the main actor, which makes the
    // window reproducible instead of a race against a sleep.
    let box = ModelBox()
    let client = QueueClient(replies: ["один", "два"])
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "queue-cancel-between"))
    box.model = FileQueueModel(translator: Translator(client: client),
                               settings: settings, glossary: scratchGlossary(),
                               save: { source, _, _ in
                                   box.model?.cancel()
                                   return .saved(source)
                               },
                               saveAs: { _, url in .saved(url) })
    let model = box.model!
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])

    await model.run()

    #expect(model.jobs[0].state == .finished)
    #expect(model.jobs[1].state == .queued)   // never started
    #expect(client.callCount == 1)
}

@MainActor @Test func aQueueStoppedBetweenFilesCarriesOnWhenAskedAgain() async {
    // The flag is about *this* run: pressing «Перевести» again must not find it still set.
    let box = ModelBox()
    let client = QueueClient(replies: ["один", "два"])
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "queue-cancel-between-resume"))
    let stopOnce = CancelOnce()
    box.model = FileQueueModel(translator: Translator(client: client),
                               settings: settings, glossary: scratchGlossary(),
                               save: { source, _, _ in
                                   if stopOnce.fire() { box.model?.cancel() }
                                   return .saved(source)
                               },
                               saveAs: { _, url in .saved(url) })
    let model = box.model!
    model.add([queueJob("a.md", "first"), queueJob("b.md", "second")])
    await model.run()
    #expect(model.jobs[1].state == .queued)

    await model.run()

    #expect(model.jobs.allSatisfy { $0.state == .finished })
}

@MainActor private final class CancelOnce {
    private var fired = false
    func fire() -> Bool { defer { fired = true }; return !fired }
}

// MARK: - Review round 2

@MainActor @Test func aPauseEarnedByTheLastFileDoesNotStickWithNoWayToDismissIt() async {
    // «Нажмите "Перевести", чтобы продолжить» over a disabled button. `canStart` is false
    // once nothing is unfinished, so the sentence could never be cleared.
    let client = QueueClient(replies: [replyWithoutTheLink])
    let model = makeQueueModel(client, prefix: "queue-pause-last") { $0.stopOnWarnings = true }
    model.add([queueJob("a.md", sourceWithALink)])

    await model.run()

    #expect(model.jobs[0].result?.hasWarnings == true)   // it really did warn
    #expect(!model.hasWorkLeft)
    #expect(!model.pausedAfterWarnings)
    #expect(model.statusLine == nil)
}

@MainActor @Test func aPauseWithFilesStillWaitingIsKept() async {
    let client = QueueClient(replies: [replyWithoutTheLink, "второй"])
    let model = makeQueueModel(client, prefix: "queue-pause-more") { $0.stopOnWarnings = true }
    model.add([queueJob("a.md", sourceWithALink), queueJob("b.md", "second")])

    await model.run()

    #expect(model.hasWorkLeft)
    #expect(model.pausedAfterWarnings)
}

@MainActor @Test func aFailedRetryDoesNotLeaveThePreviousAttemptsTextOnScreen() async {
    // The row would read «Модель вернула пустой ответ.» while the right pane still showed
    // the partial text of the attempt before it, as though it belonged to the failed one.
    let client = QueueClient(replies: ["частичный перевод", ""], paced: true)
    let model = makeQueueModel(client, prefix: "queue-stale-result")
    model.add([queueJob("a.md", "first")])

    let run = Task { await model.run() }
    await waitUntilCalled(client)
    model.cancel()
    await run.value
    #expect(model.jobs[0].state == .interrupted)
    #expect(model.jobs[0].result != nil)          // the partial text is kept, deliberately

    await model.run()                              // retried; this attempt returns nothing

    if case .failed = model.jobs[0].state {} else { Issue.record("expected the retry to fail") }
    #expect(model.jobs[0].result == nil)
    model.selection = model.jobs[0].id
    #expect(model.selectedText.isEmpty)
}

@MainActor @Test func aGateThatNeverOpensSaysSoWhateverTheReason() async {
    // documentGlossaryFailure is nil when the term-list call *succeeds* and parses to
    // nothing — so keying the notice on it left the user waiting for a table that never
    // came, with nothing on screen to say why.
    let client = QueueClient(replies: ["ничего похожего на список", "перевод", "перевод"])
    let model = makeQueueModel(client, prefix: "queue-gate-empty") { $0.reviewDocumentTerms = true }
    model.add([queueJob("a.md", longEnoughForTwoParts)])

    await model.run()

    #expect(model.jobs[0].state == .finished)
    #expect(model.jobs[0].documentTermsUnavailable)
}

@MainActor @Test func aRunThatOpenedItsGateSaysNothingAboutIt() async {
    let client = QueueClient(replies: ["resource => ресурс", "перевод", "перевод"])
    let model = makeQueueModel(client, prefix: "queue-gate-fine") { $0.reviewDocumentTerms = true }
    model.add([queueJob("a.md", longEnoughForTwoParts)])

    let run = Task { await model.run() }
    await waitForSheet(model)?.proceed()
    await run.value

    #expect(!model.jobs[0].documentTermsUnavailable)
}

@MainActor @Test func aSingleParagraphNeverPromisesAGateAndNeverApologisesForOne() async {
    // One часть builds no документный глоссарий at all, so there was never a table to show
    // and saying «не удалось подготовить» would be noise.
    let client = QueueClient(replies: ["перевод"])
    let model = makeQueueModel(client, prefix: "queue-gate-short") { $0.reviewDocumentTerms = true }
    model.add([queueJob("a.md", "Short.")])

    await model.run()

    #expect(!model.jobs[0].documentTermsUnavailable)
}
