import Testing
import Foundation
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
    let delayPerToken: Duration
    init(responses: [String], delayPerToken: Duration = .zero) {
        self.responses = responses; self.delayPerToken = delayPerToken
    }
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        callCount += 1
        let reply = responses.isEmpty ? "" : responses.removeFirst()
        let delay = delayPerToken
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

private final class ThrowingClient: LLMClient, @unchecked Sendable {
    private let error: any Error
    init(error: any Error) { self.error = error }
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        let error = self.error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

@MainActor
private func makeModel(_ client: LLMClient) -> TranslationViewModel {
    // In-memory rather than a real `UserDefaults` suite: nothing here writes a
    // setting today, but a suite that ever gets written to leaves a plist behind in
    // ~/Library/Preferences that nothing can reliably remove — see `InMemoryDefaults`.
    return TranslationViewModel(translator: Translator(client: client),
                                settings: AppSettings(defaults: InMemoryDefaults(prefix: "vm")),
                                glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("g-\(UUID().uuidString).json")))
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
    // (900) the source chunks, and `Translator` writes the "\n\n" chunk separator
    // straight to `onToken` without going through `emit` — so it reaches the consumer
    // while `timeToFirstTokenMS` stays nil. A consumer that treats any arriving piece as
    // "new output" clears the pane for a run that then reports an empty reply, leaving
    // the user staring at a blank result. Spec 8 requires the previous text to survive.
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
    try? await Task.sleep(for: .milliseconds(150))
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
    try? await Task.sleep(for: .milliseconds(500))
    model.cancel()
    await run.value

    #expect(model.state == .interrupted)
    // The ordering assertion. Because the tail is varied, pieces applied out of order do
    // not form a prefix of the reply, however many of them arrived.
    #expect(reply.hasPrefix(model.translatedText))
    #expect(model.translatedText.count < reply.count)   // genuinely interrupted mid-stream
    // Above the 15-character buffered flush by enough that only incremental delivery can
    // reach it: ~70 characters actually arrive in the 500 ms window (measured; the 5 ms
    // sleeps settle at ~7 ms each), so the effective per-token cost would have to more
    // than double before this floor is threatened, while a single buffered flush can
    // never exceed 15 no matter how the timing drifts.
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
    try? await Task.sleep(for: .milliseconds(300))
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
