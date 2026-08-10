import Testing
import Foundation
import AppKit
@testable import TranslatorApp
@testable import TranslationCore

/// Internal rather than private, because `HotkeyCoordinatorTests` needs the same double and a
/// second copy would drift from this one.
final class ScriptedClient: LLMClient, @unchecked Sendable {
    private var responses: [String]
    /// How many times the model was actually asked. The coordinator's «do not translate an
    /// empty selection» claim is about a call that must *not* happen, and no view-model state
    /// distinguishes "refused before the call" from "called and given nothing".
    private(set) var callCount = 0
    /// Every prompt this client was handed, in order. Same reasoning as `QueueClient`'s
    /// property of the same name — recorded so a test can pin which operation's system
    /// prompt was actually sent, not just that the engine ran.
    private(set) var receivedMessages: [[ChatMessage]] = []
    let delayPerToken: Duration
    /// Which call, by zero-based index, should fail instead of answering. Same shape as
    /// `FakeLLMClient.errors` rather than a third mechanism — the term-list call is call 0,
    /// which is what the document-terms tests need to break.
    private let failCallAtIndex: Int?
    init(responses: [String], delayPerToken: Duration = .zero, failCallAtIndex: Int? = nil) {
        self.responses = responses; self.delayPerToken = delayPerToken
        self.failCallAtIndex = failCallAtIndex
    }
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        let index = callCount
        callCount += 1
        receivedMessages.append(messages)
        let reply = responses.isEmpty ? "" : responses.removeFirst()
        let delay = delayPerToken
        if index == failCallAtIndex {
            return AsyncThrowingStream { $0.finish(throwing: ScriptedFailure()) }
        }
        return AsyncThrowingStream { continuation in
            Task {
                for piece in reply.map(String.init) {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    continuation.yield(.token(piece))
                }
                continuation.yield(.done(ChatStats(loadDurationMS: 0, promptEvalCount: 0,
                                                   promptEvalDurationMS: 0, evalCount: reply.count,
                                                   evalDurationMS: 1)))
                continuation.finish()
            }
        }
    }
}

struct ScriptedFailure: Error {}

private final class ThrowingClient: LLMClient, @unchecked Sendable {
    private let error: any Error
    init(error: any Error) { self.error = error }
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        let error = self.error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

/// Wait until the stream has produced the state a test is about to assert on, rather than
/// waiting a fixed number of milliseconds and hoping it did.
///
/// The tests that use this cancel a run mid-flight and then assert that *some but not all* of
/// the reply arrived. Both halves used to rest on one wall-clock sleep, and only the lower half
/// was fragile: the upper half has seconds of margin, because these replies take two to three
/// seconds to stream, while the lower half needed the main actor to be free enough to apply a
/// token within the sleep. It usually was. **Measured after the panel-measuring tests were
/// added: 7 full-suite runs in 20 failed**, all of them here, all with `translatedText` still
/// empty at the moment of cancellation — the `@MainActor` tests share one actor, and roughly a
/// third of a second of synchronous layout work in another test is enough to starve the token
/// deliveries for the whole of a 150 ms sleep.
///
/// Waiting on the condition removes the assumption instead of widening it. A fixed sleep can
/// only ever be «long enough on the machines we tried»; this is long enough by construction,
/// and it also makes the tests faster, because they now stop as soon as they have what they
/// need rather than always paying the full sleep.
///
/// The deadline is not a disguised sleep: reaching it records an issue, so a genuine hang
/// fails the test loudly instead of passing quietly.
@MainActor
private func waitUntil(_ description: String, within timeout: Duration = .seconds(10),
                       _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out after \(timeout) waiting until \(description)")
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// Never `.general`: `copyToPasteboard()` writes for real, and the user's clipboard is not
/// the suite's to spend. A uniquely named board is also the only shape `NSPasteboard` is
/// safe in concurrently — see `GeneralPasteboard`'s own doc comment.
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.vm.\(UUID().uuidString)"))
}

@MainActor
private func makeModel(_ client: LLMClient, pasteboard: NSPasteboard? = nil) -> TranslationViewModel {
    // In-memory rather than a real `UserDefaults` suite: nothing here writes a
    // setting today, but a suite that ever gets written to leaves a plist behind in
    // ~/Library/Preferences that nothing can reliably remove — see `InMemoryDefaults`.
    return TranslationViewModel(translator: Translator(client: client),
                                settings: AppSettings(defaults: InMemoryDefaults(prefix: "vm")),
                                glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("g-\(UUID().uuidString).json")),
                                pasteboard: pasteboard ?? scratchPasteboard())
}

/// `run()`'s tests need the prompts the client actually received, which `ScriptedClient`
/// above does not record — `QueueClient` (from `FileQueueModelTests`) already does, so this
/// reuses that fixture rather than teaching a second client the same bookkeeping.
@MainActor
private func makeModel(responses: [String]) -> (TranslationViewModel, QueueClient) {
    let client = QueueClient(replies: responses)
    let model = TranslationViewModel(
        translator: Translator(client: client),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "vm-run")),
        glossary: scratchGlossary(),
        pasteboard: scratchPasteboard())
    return (model, client)
}

@MainActor
@Test func aSuccessfulRunFinishesAndKeepsTheOutcome() async {
    let model = makeModel(ScriptedClient(responses: ["Привет, мир."]))
    model.sourceText = "Hello, world."
    await model.translate()
    #expect(model.state == .finished)
    #expect(model.translatedText == "Привет, мир.")
    #expect(model.outcome != nil)
}

@MainActor
@Test func anEmptyReplyIsReportedAsAFailureNotAnEmptySuccess() async {
    // The model streamed nothing at all — spec section 8's "пустой ответ" row.
    let model = makeModel(ScriptedClient(responses: [""]))
    model.sourceText = "Hello, world."
    await model.translate()
    guard case .failed(let message) = model.state else {
        Issue.record("expected .failed, got \(model.state)"); return
    }
    #expect(message.contains("пуст"))
}

@MainActor
@Test func aFailureLeavesThePreviousTranslationOnScreen() async {
    let model = makeModel(ScriptedClient(responses: ["Первый перевод.", ""]))
    model.sourceText = "First."
    await model.translate()
    #expect(model.translatedText == "Первый перевод.")

    model.sourceText = "Second."
    await model.translate()   // empty reply -> failure
    #expect(model.translatedText == "Первый перевод.")  // spec 8: not clobbered
}

@MainActor
@Test func aMultiChunkEmptyReplyLeavesThePreviousTranslationOnScreen() async {
    // The single-chunk case above is not the whole story. Over `AppSettings.chunkSize`
    // (900) the source chunks, and `Translator` writes each chunk's `separatorBefore` —
    // the source document's own bytes, restored verbatim, and always whitespace-only;
    // single spaces here, since this source splits by sentence — straight to `onToken`
    // without going through `emit`, so it reaches the consumer while
    // `timeToFirstTokenMS` stays nil. A consumer that treats any arriving piece as "new
    // output" clears the pane for a run that then reports an empty reply, leaving the
    // user staring at a blank result. The model holds those pieces in `pending` until
    // real content arrives instead; spec 8 requires the previous text to survive.
    let model = makeModel(ScriptedClient(responses: ["Первый перевод."]))
    model.sourceText = "First."
    await model.translate()
    #expect(model.translatedText == "Первый перевод.")

    // Exhausted script: every later call — the term-list call and each chunk — replies "".
    model.sourceText = String(repeating: "Sentence here. ", count: 200)
    #expect(model.expectedChunkCount > 1)
    await model.translate()

    #expect(model.translatedText == "Первый перевод.")  // spec 8: not clobbered
    guard case .failed = model.state else {
        Issue.record("expected .failed, got \(model.state)"); return
    }
}

@MainActor
@Test func cancellingKeepsWhatWasRenderedAndMarksItInterrupted() async {
    let client = ScriptedClient(responses: [String(repeating: "а", count: 400)],
                                delayPerToken: .milliseconds(5))
    let model = makeModel(client)
    model.sourceText = String(repeating: "x ", count: 40)
    let run = Task { await model.translate() }
    // Cancel once something has actually been rendered, which is the precondition the last
    // assertion needs — not after a fixed 150 ms, which was only usually long enough. The
    // reply is 400 tokens at 5 ms, so cancelling at the first one leaves seconds of margin
    // before the run could finish on its own and the state stop being `.interrupted`.
    await waitUntil("the first token has been rendered") { !model.translatedText.isEmpty }
    model.cancel()
    await run.value
    #expect(model.state == .interrupted)
    // Incremental delivery means what arrived cannot be un-sent; it must not be
    // discarded, and it must not be presented as a complete translation either.
    #expect(!model.translatedText.isEmpty)
}

@MainActor
@Test func aSecondTranslateWhileOneIsRunningIsIgnored() async {
    // Task 8 wires `translate()` to a button, so a double-click is a real input. Without a
    // guard both runs share `translatedText` and `clearedPrevious`, `task = run` orphans
    // the first run so `cancel()` only stops the second, and whichever finishes last wins
    // — which can be the older request. The result must be one clean translation.
    let client = ScriptedClient(responses: ["Первый перевод.", "Второй перевод."],
                                delayPerToken: .milliseconds(10))
    let model = makeModel(client)
    model.sourceText = "First."
    let first = Task { await model.translate() }
    try? await Task.sleep(for: .milliseconds(30))   // first run is mid-flight (~150 ms total)
    #expect(model.state == .running)

    model.sourceText = "Second."
    await model.translate()   // must be a no-op while the first run holds the model
    await first.value

    #expect(model.state == .finished)
    #expect(model.translatedText == "Первый перевод.")
}

@MainActor
@Test func streamedPiecesAreAppliedInTheOrderTheyArrive() async {
    // Every other scripted reply in this file is short and newline-free, so `Translator`
    // never leaves `.buffering` and the consumer receives exactly one piece — which means
    // no other test can tell ordered assembly from scrambled assembly. This one forces
    // genuinely incremental delivery: plain prose, no code fence, and a first line both
    // shorter than `preambleLineMaxLength` (60) and unmatched by any preamble pattern, so
    // the "\n" flushes the first line and every subsequent token is forwarded on its own.
    let firstLine = "Первая строка.\n"   // 15 characters — the entire buffered-flush phase
    // The tail cycles digits rather than repeating one character on purpose. With 400
    // identical letters every permutation of the tail pieces is byte-identical, so
    // `hasPrefix` would hold even under scrambled assembly and the oracle below would
    // pin nothing but reversal. Varied content makes position observable.
    let reply = firstLine + (0..<400).map { String($0 % 10) }.joined()
    let client = ScriptedClient(responses: [reply], delayPerToken: .milliseconds(5))
    let model = makeModel(client)
    model.sourceText = String(repeating: "x ", count: 40)
    let run = Task { await model.translate() }
    // Cancel as soon as more than 30 characters are on screen, which is the floor the last
    // assertion checks. This used to be a flat 500 ms wait.
    await waitUntil("more than 30 characters have been rendered") { model.translatedText.count > 30 }
    model.cancel()
    await run.value

    #expect(model.state == .interrupted)
    // The ordering assertion. Because the tail is varied, pieces applied out of order do
    // not form a prefix of the reply, however many of them arrived.
    #expect(reply.hasPrefix(model.translatedText))
    #expect(model.translatedText.count < reply.count)   // genuinely interrupted mid-stream
    // Above the 15-character buffered flush, so only incremental delivery can reach it: a
    // single buffered flush can never exceed 15 no matter how the timing drifts.
    //
    // This floor used to be argued from the clock — ~70 characters were measured arriving in
    // the old 500 ms window, the 5 ms sleeps settling at ~7 ms each, leaving room for the
    // per-token cost to more than double. That argument is retired rather than disproved: the
    // wait above is now on the floor itself, so 31 characters is a precondition of reaching
    // this line rather than a prediction about how fast the machine is. The timing measurement
    // no longer applies because there is no longer a window for it to describe.
    #expect(model.translatedText.count > 30)
}

@MainActor
@Test func anInterruptedRunAfterASuccessfulOneDropsTheStaleOutcome() async {
    // Task 9 renders warnings out of `outcome`. Once the new run's partial text has
    // replaced the old translation on screen, the previous run's glossary checks and
    // markup diffs describe a document the user can no longer see — so `outcome` must be
    // dropped at the same instant `translatedText` is cleared, never left to outlive it.
    let reply = "Первая строка.\n" + String(repeating: "б", count: 400)
    let client = ScriptedClient(responses: ["Первый перевод.", reply],
                                delayPerToken: .milliseconds(5))
    let model = makeModel(client)
    model.sourceText = "First."
    await model.translate()
    #expect(model.state == .finished)
    #expect(model.outcome != nil)

    // A second run that streams real content, then is cancelled mid-flight.
    model.sourceText = String(repeating: "x ", count: 40)
    let run = Task { await model.translate() }
    // Waited on the **state**, not the clock. A fixed 300 ms race against a token stream is
    // the shape `waitUntilRunning`'s own doc comment warns against, and it lost: measured 3
    // failures in ~40 runs at 16× oversubscription, where the second run had not reached the
    // pane when the cancel landed and both assertions below fired on the *first* run's text.
    for _ in 0..<20_000 {
        if !model.translatedText.isEmpty, model.translatedText != "Первый перевод." { break }
        await Task.yield()
    }
    model.cancel()
    await run.value

    #expect(model.state == .interrupted)
    #expect(!model.translatedText.isEmpty)          // the new run's partial output
    #expect(model.translatedText != "Первый перевод.")
    #expect(model.outcome == nil)                   // not the previous run's
}

@MainActor
@Test func aTransportFailureOnAnUncancelledRunIsReportedAsFailed() async {
    // The general `catch` now consults `run.isCancelled` rather than trusting the error's
    // type, so that a `URLError(.cancelled)` losing the race with `CancellationError`
    // still reads as `.interrupted`. This pins the other side of that branch: a run that
    // was never cancelled must still surface as `.failed`, not be swallowed as an
    // interruption. It is also the only test that reaches `Self.message(for:)`.
    let model = makeModel(ThrowingClient(error: URLError(.cannotConnectToHost)))
    model.sourceText = "Hello, world."
    await model.translate()
    guard case .failed(let message) = model.state else {
        Issue.record("expected .failed, got \(model.state)"); return
    }
    #expect(!message.isEmpty)
}

@MainActor
@Test func theExpectedChunkCountIsKnownBeforeTheRunStarts() {
    let model = makeModel(ScriptedClient(responses: []))
    model.sourceText = String(repeating: "Sentence here. ", count: 200)
    #expect(model.expectedChunkCount > 1)
}

@MainActor
@Test func adoptingCarriesTheWholeRunNotJustItsText() async {
    // The window and the panel each own a view model, and «Открыть в окне» moves one run
    // between them. Moving only the two strings is what broke: a window that had already
    // finished a translation of its own kept that run's `outcome` and `.finished`, so it
    // went on rendering that run's elapsed time and its markup and glossary warnings
    // underneath the text it had just been handed — warnings about a document no longer on
    // screen.
    let window = makeModel(ScriptedClient(responses: ["Перевод окна."]))
    window.sourceText = "Window source."
    await window.translate()
    let windowOutcome = window.outcome
    #expect(windowOutcome != nil)

    let panel = makeModel(ScriptedClient(responses: ["Перевод панели."]))
    panel.sourceText = "Panel source."
    await panel.translate()

    #expect(window.adopt(from: panel))
    #expect(window.sourceText == "Panel source.")
    #expect(window.translatedText == "Перевод панели.")
    #expect(window.state == panel.state)
    #expect(window.resolvedTarget == panel.resolvedTarget)
    // The identity check is the point: the window must not still be holding the outcome it
    // arrived with, because that is what the warnings and the elapsed time are drawn from.
    #expect(window.outcome?.final == "Перевод панели.")
    #expect(window.outcome?.totalMS != windowOutcome?.totalMS)
}

@MainActor
@Test func adoptingIsRefusedWhileTheTargetIsMidTranslation() async {
    // Adopting under a running task loses the adoption: the task finishes and writes its own
    // result over it, and cancelling first does not help either — the cancellation lands
    // later and writes `.interrupted` on top. Refusing is what lets the caller keep the
    // panel on screen instead of throwing the result away for nothing.
    let window = makeModel(ScriptedClient(responses: [String(repeating: "а", count: 200)],
                                          delayPerToken: .milliseconds(5)))
    window.sourceText = String(repeating: "x ", count: 40)
    let run = Task { await window.translate() }
    try? await Task.sleep(for: .milliseconds(40))
    #expect(window.state == .running)

    let panel = makeModel(ScriptedClient(responses: ["Перевод панели."]))
    panel.sourceText = "Panel source."
    await panel.translate()

    #expect(window.adopt(from: panel) == false)
    #expect(window.sourceText != "Panel source.")
    window.cancel()
    await run.value
}


@MainActor
@Test func adoptingIsRefusedWhileTheSourceIsStillTranslating() async {
    // `state` moves with the text but the `Task` behind it cannot — it belongs to the other
    // model and keeps writing there. Adopting `.running` therefore hands this model a state
    // it has no way to leave: `cancel()` is `task?.cancel()` on a nil task, `translate()`
    // refuses while `.running`, and the window renders «Отмена» rather than «Перевести», so
    // the pane sits on a spinner until the app is quit.
    let panel = makeModel(ScriptedClient(responses: [String(repeating: "б", count: 200)],
                                         delayPerToken: .milliseconds(5)))
    panel.sourceText = String(repeating: "x ", count: 40)
    let run = Task { await panel.translate() }
    try? await Task.sleep(for: .milliseconds(40))
    #expect(panel.state == .running)

    let window = makeModel(ScriptedClient(responses: ["Перевод окна."]))
    #expect(window.adopt(from: panel) == false)
    #expect(window.state != .running)
    #expect(window.translatedText.isEmpty)

    panel.cancel()
    await run.value
}

@MainActor
@Test func theRefusalReasonNamesWhichSideIsBusy() async {
    // The panel asks this to decide both whether to offer «Открыть в окне» and what to say
    // when it does not. A Bool would answer the first question and leave the view to guess
    // at the second — which is how the button and the message drift apart.
    let window = makeModel(ScriptedClient(responses: ["Перевод окна."]))
    let panel = makeModel(ScriptedClient(responses: ["Перевод панели."]))
    #expect(window.adoptionRefusal(from: panel) == nil)
    #expect(window.adoptionRefusal(from: window) == .sameModel)

    let busy = makeModel(ScriptedClient(responses: [String(repeating: "б", count: 200)],
                                        delayPerToken: .milliseconds(5)))
    busy.sourceText = String(repeating: "x ", count: 40)
    let run = Task { await busy.translate() }
    try? await Task.sleep(for: .milliseconds(40))
    #expect(busy.state == .running)

    // Seen from the panel's end: the window is the one that is busy.
    #expect(busy.adoptionRefusal(from: panel) == .targetBusy)
    // Seen from the window's end: the panel's run is the one still going.
    #expect(window.adoptionRefusal(from: busy) == .sourceBusy)

    busy.cancel()
    await run.value
}

@MainActor
@Test func swappingIsRefusedUntilBothLanguagesAreActuallyKnown() {
    // Exchanging «определить» and «по правилу» exchanges two absences. The button has to be
    // able to say so before it is pressed, which is why this is a property and not a
    // `Bool` returned by the swap.
    let model = makeModel(ScriptedClient(responses: []))
    #expect(model.canSwapLanguages == false)
    model.sourceOverride = .en
    #expect(model.canSwapLanguages == false)   // the target is still «по правилу»
    model.targetOverride = .ru
    #expect(model.canSwapLanguages)
}

@MainActor
@Test func aFinishedRunSuppliesTheLanguagesTheOverridesDidNot() async {
    // The ordinary case: the user typed English, left both pickers alone, and pressed
    // translate. Both languages are now known — one detected, one resolved — so the swap
    // is available even though neither override was ever set.
    let model = makeModel(ScriptedClient(responses: ["Готово"]))
    model.sourceText = "Ready"
    await model.translate()
    #expect(model.canSwapLanguages)
}

@MainActor
@Test func swappingExchangesTheLanguagesAndMovesTheTranslationIntoTheSource() {
    let model = makeModel(ScriptedClient(responses: []))
    model.sourceOverride = .en
    model.targetOverride = .ru
    model.sourceText = "Ready"
    model.translatedText = "Готово"
    model.swapLanguages()
    #expect(model.sourceOverride == .ru)
    #expect(model.targetOverride == .en)
    #expect(model.sourceText == "Готово")
    #expect(model.translatedText.isEmpty)
}

@MainActor
@Test func swappingDropsTheOutcomeWithTheTextItDescribed() async {
    // `outcome` and `translatedText` are cleared as a pair everywhere else in this type,
    // and this is not the place to break that: an outcome left behind would render the old
    // run's markup diffs and glossary checks under an empty pane.
    let model = makeModel(ScriptedClient(responses: ["Готово"]))
    model.sourceText = "Ready"
    await model.translate()
    #expect(model.outcome != nil)
    model.swapLanguages()
    #expect(model.outcome == nil)
    // The other two lines of the same clearing, which nothing asserted until now: deleting
    // either `resolvedTarget = nil` or `state = .idle` from `swapLanguages()` used to pass
    // every test in this file. `resolvedTarget` is what `WarningsView` looks a term's
    // translation up by, and `state` is what the window's «Перевести» and this type's own
    // re-entrancy guard read — a swap that left `.finished` behind would describe a run whose
    // text has just been moved into the source pane.
    #expect(model.resolvedTarget == nil)
    #expect(model.state == .idle)
}

@MainActor
@Test func swappingWithNoTranslationYetLeavesTheSourceAlone() {
    // Pressing ⇄ before translating should exchange the pickers, not blank the text the
    // user has just typed.
    let model = makeModel(ScriptedClient(responses: []))
    model.sourceOverride = .en
    model.targetOverride = .ru
    model.sourceText = "Ready"
    model.swapLanguages()
    #expect(model.sourceText == "Ready")
    #expect(model.sourceOverride == .ru)
}

@MainActor
@Test func swappingIsRefusedWhileARunIsInFlight() async {
    // The running task writes into `translatedText`. Moving it out from under that task
    // would put half a translation into the source field. Waits on the state itself
    // (`waitUntil`) rather than a fixed sleep, for the reason recorded on that helper: a
    // wall-clock guess can only ever be "long enough on the machines we tried".
    let model = makeModel(ScriptedClient(responses: ["Готово"], delayPerToken: .milliseconds(5)))
    model.sourceOverride = .en
    model.targetOverride = .ru
    model.sourceText = "Ready"
    let run = Task { await model.translate() }
    await waitUntil("the run has started") { model.state == .running }
    #expect(model.canSwapLanguages == false)
    await run.value
}

@MainActor
@Test func adoptRefusesExactlyWhenTheReasonSaysItWill() async {
    // The two must not be able to disagree: `adopt` is defined as "no reason to refuse", and
    // this is what stops a later edit adding a guard to one and not the other.
    let window = makeModel(ScriptedClient(responses: ["Перевод окна."]))
    let panel = makeModel(ScriptedClient(responses: ["Перевод панели."]))
    panel.sourceText = "Panel source."
    await panel.translate()

    #expect(window.adoptionRefusal(from: window) != nil)
    #expect(window.adopt(from: window) == false)
    #expect(window.adoptionRefusal(from: panel) == nil)
    #expect(window.adopt(from: panel))
}

// MARK: - The pasteboard

@MainActor
@Test func theWindowsCopyPutsTheTranslationOnThePasteboardAndLeavesAnEmptyOneAlone() async {
    // Mirrors `HotkeyCoordinatorTests.copyingPutsTheTranslationOnThePasteboardAndLeavesAnEmptyOneAlone`
    // for the panel: the window's copy path shares `GeneralPasteboard.write` with the
    // panel's, so this is what became testable once that seam existed, rather than only
    // being reachable by hand through the real app.
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("буфер пользователя", forType: .string)

    let model = makeModel(ScriptedClient(responses: []), pasteboard: board)
    // Nothing translated yet: an empty result must not clear what the user already has.
    await model.copyToPasteboard()
    #expect(board.string(forType: .string) == "буфер пользователя")

    model.translatedText = "Привет."
    await model.copyToPasteboard()
    #expect(board.string(forType: .string) == "Привет.")
}

// MARK: - The document-terms gate

/// Long enough for `Chunker` to split at the default size, so a документный глоссарий is
/// actually built and there is something to review.
private let longEnoughForTwoParts = String(
    repeating: "The resource is published by the server and the resource is validated. ", count: 20)

@MainActor private func gateModel(_ client: LLMClient, _ prefix: String,
                                  review: Bool) -> TranslationViewModel {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: prefix))
    settings.reviewDocumentTerms = review
    return TranslationViewModel(
        translator: Translator(client: client), settings: settings,
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("glossary-\(UUID().uuidString).json")),
        pasteboard: NSPasteboard(name: .init("gate-\(prefix)")))
}

/// Waits for the sheet, with a ceiling.
///
/// An unbounded `while model.pendingTermsRequest == nil { await Task.yield() }` turns «the
/// sheet never appeared» into a hung suite instead of a failed test — and «never appeared»
/// is a real outcome here: a term-list reply that does not parse leaves no glossary to
/// review, so the hook is never called.
@MainActor
private func waitForSheet(_ model: TranslationViewModel,
                          _ comment: Comment = "the terms sheet never appeared") async -> DocumentTermsRequest? {
    for _ in 0..<400 {
        if let request = model.pendingTermsRequest { return request }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record(comment)
    return nil
}

@MainActor @Test func theTermsGateIsSkippedEntirelyWhenTheSettingIsOff() async {
    let model = gateModel(ScriptedClient(responses: ["resource => ресурс", "перевод", "перевод"]),
                          "gate-off", review: false)
    model.sourceText = longEnoughForTwoParts

    await model.translate()

    #expect(model.pendingTermsRequest == nil)
    #expect(model.state == .finished)
    #expect(!model.documentTermsUnavailable)
}

@MainActor @Test func theGateOpensWhenAskedForAndItsEditsSurvive() async {
    let model = gateModel(ScriptedClient(responses: ["resource => ресурс", "перевод", "перевод"]),
                          "gate-on", review: true)
    model.sourceText = longEnoughForTwoParts

    let run = Task { await model.translate() }
    let sheet = await waitForSheet(model)
    sheet?.entries = [GlossaryEntry(term: "resource", translations: ["ru": "объект"])]
    sheet?.proceed()
    await run.value

    #expect(model.state == .finished)
    #expect(model.outcome?.documentGlossary.first?.translations["ru"] == "объект")
    // The sheet goes away with the run that raised it.
    #expect(model.pendingTermsRequest == nil)
}

@MainActor @Test func cancellingTheSheetLeavesTheRunInterruptedAndNotWedged() async {
    let model = gateModel(ScriptedClient(responses: ["resource => ресурс", "перевод", "перевод"]),
                          "gate-cancel", review: true)
    model.sourceText = longEnoughForTwoParts

    let run = Task { await model.translate() }
    await waitForSheet(model)?.cancel()
    await run.value

    #expect(model.state == .interrupted)
    // The sheet must go away with the run that raised it, or the window keeps a modal over
    // a translation that is already over.
    #expect(model.pendingTermsRequest == nil)
}

@MainActor @Test func cancelReachesARunThatIsWaitingOnAHumanAndNotOnTheNetwork() async {
    // ⌘. while the sheet is open. Without `cancel()` reaching the request, the run would
    // sit on a continuation nobody resumes — forever, and invisibly.
    let model = gateModel(ScriptedClient(responses: ["resource => ресурс", "перевод", "перевод"]),
                          "gate-cmd-period", review: true)
    model.sourceText = longEnoughForTwoParts

    let run = Task { await model.translate() }
    _ = await waitForSheet(model)
    model.cancel()
    await run.value

    #expect(model.state == .interrupted)
}

@MainActor @Test func aFailedTermListStopsBeingSilentOnceTheUserAskedForTheGate() async {
    let model = gateModel(ScriptedClient(responses: ["", "перевод", "перевод"], failCallAtIndex: 0),
                          "gate-term-failure", review: true)
    model.sourceText = longEnoughForTwoParts

    await model.translate()

    // The user waited for a gate that never opened; staying quiet about it would let the
    // run's terminology differ from what they were promised, invisibly.
    #expect(model.documentTermsUnavailable)
    #expect(model.state == .finished)
}

@MainActor @Test func theUnavailableNoticeIsResetByTheNextRun() async {
    let model = gateModel(ScriptedClient(responses: ["", "перевод", "перевод",
                                                     "resource => ресурс", "перевод", "перевод"],
                                         failCallAtIndex: 0),
                          "gate-notice-reset", review: true)
    model.sourceText = longEnoughForTwoParts
    await model.translate()
    #expect(model.documentTermsUnavailable)

    let run = Task { await model.translate() }
    await waitForSheet(model)?.proceed()
    await run.value

    #expect(!model.documentTermsUnavailable)
}

@MainActor @Test func aWindowRunHeldOnTheSheetSaysItIsWaitingAndNotTranslating() async {
    let model = gateModel(ScriptedClient(responses: ["resource => ресурс", "перевод", "перевод"]),
                          "gate-awaiting", review: true)
    model.sourceText = longEnoughForTwoParts
    #expect(!model.isAwaitingTerms)

    let run = Task { await model.translate() }
    let sheet = await waitForSheet(model)
    #expect(model.isAwaitingTerms)
    sheet?.proceed()
    await run.value

    #expect(!model.isAwaitingTerms)
}

@MainActor @Test func theWindowsSourceLanguageReachesTheModelAndNotJustTheTarget() async {
    // The «Текст» half of the wiring. Its twin in FileQueueModelTests pins the queue's call
    // site, and the commit that added it claimed both — deleting `source: detected,` from
    // this one left all 593 tests green, so «both» was true of the fix and not of the
    // coverage. The same toolbar picker feeds both models and the ⌥⌘T panel shares this
    // path, so this is the call site more of the app goes through.
    let client = QueueClient(replies: ["перевод"])
    let model = TranslationViewModel(
        translator: Translator(client: client),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "vm-source-wiring")),
        glossary: scratchGlossary(),
        pasteboard: NSPasteboard(name: .init("vm-source-wiring")))
    model.sourceText = "The server validates the request."
    // Stated German over text the detector reads as English. `knownSource` reads the
    // override first, so the toolbar looks right whether or not the model is ever told —
    // which is exactly why this needs a test and not a glance.
    model.sourceOverride = .de

    await model.translate()

    let prompts = client.receivedMessages.flatMap { $0 }.map(\.content)
    #expect(prompts.contains { $0.contains("German") })
    #expect(prompts.contains { $0.contains("English") } == false)
}

@MainActor @Test func aShortWindowRunNeverApologisesForAGateItNeverNeeded() async {
    // `documentTermsUnavailable = gateRequested && result.documentGlossaryAttempted &&
    // !raisedTermsSheet`. The queue pins both halves of the middle conjunct; the window and
    // the ⌥⌘T panel pinned neither, so dropping `documentGlossaryAttempted` left the suite
    // green — and then every short translation with the gate on drew orange «Термины
    // документа не удалось подготовить» for a table that was never going to exist.
    //
    // One часть, so `TermExtractor` is never consulted: nothing was attempted and nothing
    // went wrong.
    let client = QueueClient(replies: ["перевод"])
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "vm-gate-short"))
    settings.reviewDocumentTerms = true
    let model = TranslationViewModel(
        translator: Translator(client: client), settings: settings,
        glossary: scratchGlossary(),
        pasteboard: NSPasteboard(name: .init("vm-gate-short")))
    model.sourceText = "Hello, world."

    await model.translate()

    #expect(model.state == .finished)
    #expect(model.documentTermsUnavailable == false)
}

@MainActor @Test func runUnderProofreadSendsTheCopyEditorPromptAndSetsResolvedValues() async {
    // Build with the file's helper; the fake must queue one reply: "Исправлено."
    let (model, fake) = makeModel(responses: ["Исправлено."])
    model.sourceText = "Превет, мир."
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsAndStyle
    model.rewriteStyleOverride = .friendly
    await model.run()
    #expect(model.state == .finished)
    #expect(model.translatedText == "Исправлено.")
    let system = fake.receivedMessages[0].first!.content
    #expect(system.contains("copy editor"))
    #expect(system.contains(RewriteStyle.friendly.instruction!))
    #expect(model.resolvedOperation == .proofread)
    #expect(model.resolvedProofreadingLevel == .errorsAndStyle)
    #expect(model.resolvedTarget == nil)
}

@MainActor @Test func runUnderTranslateStillTranslatesAndRecordsTheOperation() async {
    let (model, fake) = makeModel(responses: ["Hello, world."])
    model.sourceText = "Привет, мир."
    await model.run()
    #expect(model.state == .finished)
    #expect(fake.receivedMessages[0].first!.content.contains("translator"))
    #expect(model.resolvedOperation == .translate)
    #expect(model.resolvedProofreadingLevel == nil)
}

@MainActor @Test func anotherVariantIsOfferedOnlyForAFinishedErrorsAndStyleRun() async {
    let (model, _) = makeModel(responses: ["Исправлено.", "Исправлено."])
    model.sourceText = "Превет."
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsOnly
    await model.run()
    // «Ещё вариант» of a deterministic minimal diff is a contradiction (spec §2).
    #expect(!model.offersAnotherVariant)
    model.proofreadingLevelOverride = .errorsAndStyle
    await model.run()
    #expect(model.offersAnotherVariant)
}

@MainActor @Test func adoptMovesTheResolvedOperationWithTheRun() async {
    let (panel, _) = makeModel(responses: ["Исправлено."])
    panel.sourceText = "Превет."
    panel.operation = .proofread
    panel.proofreadingLevelOverride = .errorsAndStyle
    await panel.run()
    let (window, _) = makeModel(responses: [])
    #expect(window.adopt(from: panel))
    #expect(window.resolvedOperation == .proofread)
    #expect(window.resolvedProofreadingLevel == .errorsAndStyle)
    #expect(window.offersAnotherVariant)
}

@MainActor @Test func aProofreadRunIgnoresTheSourceOverrideLeftFromTranslateMode() async {
    // «Из: немецкий» set while translating must not tell правка the text is German:
    // the control is hidden in правка mode, so an invisible leftover would govern
    // the prompt with nothing on screen saying so.
    let (model, fake) = makeModel(responses: ["Исправлено."])
    model.sourceText = "Превет, мир — это русский текст."
    model.sourceOverride = .de
    model.operation = .proofread
    await model.run()
    #expect(!fake.receivedMessages[0].first!.content.contains("German"))
}
