import Testing
import Foundation
@testable import TranslationCore

// `Translator.explain` is the fourth route, in `format`'s shape: one call, the whole reply
// buffered, cleaned the way every other route's is, then judged whole by `ExplanationGate`.
// These tests pin the route's shape through the same `FakeLLMClient` the other three routes are
// pinned with — never a live model, per this phase's offline scope.

private let source = """
    Wold text here.

    Adress is unclear.
    """
private let result = """
    World text here.

    Address is unclear.
    """

@Test func explainMakesExactlyOneCallCarryingEveryChangeAndTheLanguage() async throws {
    let changes = TextDiff.changes(source: source, result: result)
    #expect(changes.changes.count == 2)
    let fake = FakeLLMClient(responses: ["1: Fixed a typo.\n2: Fixed a typo."])
    let outcome = try await Translator(client: fake).explain(
        source: source, result: result, changes: changes, language: .en,
        options: ChatOptions(model: "test"))
    #expect(outcome == .accepted([1: "Fixed a typo.", 2: "Fixed a typo."]))
    #expect(fake.receivedMessages.count == 1)
    let system = fake.receivedMessages[0].first!.content
    let user = fake.receivedMessages[0].last!.content
    #expect(system.contains("English"))
    for change in changes.changes {
        #expect(user.contains(change.removed))
        #expect(user.contains(change.inserted))
    }
}

/// `userPrompt(for:)`'s measured shape: the material is handed over plainly under one closing
/// line, never wrapped in `<text>…</text>` markers.
@Test func theUserTurnCarriesNoTextMarkers() async throws {
    let changes = TextDiff.changes(source: source, result: result)
    let fake = FakeLLMClient(responses: ["1: Fixed a typo.\n2: Fixed a typo."])
    _ = try await Translator(client: fake).explain(
        source: source, result: result, changes: changes, language: .en,
        options: ChatOptions(model: "test"))
    let user = fake.receivedMessages[0].last!.content
    #expect(!user.contains("<text>"))
}

/// A reply that fails the gate on any line loses the whole set — never a partial dictionary,
/// even though the first entry alone parsed cleanly.
@Test func aRejectedReplyYieldsRejectedNeverAPartialDictionary() async throws {
    let changes = TextDiff.changes(source: source, result: result)
    let fake = FakeLLMClient(responses: ["1: Fixed a typo.\nsome stray remark"])
    let outcome = try await Translator(client: fake).explain(
        source: source, result: result, changes: changes, language: .en,
        options: ChatOptions(model: "test"))
    #expect(outcome == .rejected(.extraProse))
}

@Test func noChangesSkipsWithoutEverCallingTheModel() async throws {
    let empty = ChangeSet(changes: [], blocks: [], notCompared: nil)
    let fake = FakeLLMClient(responses: ["should never be read"])
    let outcome = try await Translator(client: fake).explain(
        source: "Text.", result: "Text.", changes: empty, language: .en,
        options: ChatOptions(model: "test"))
    #expect(outcome == .skipped(.noChanges))
    #expect(fake.receivedMessages.isEmpty)
}

@Test func moreChangesThanTheCapSkipsWithoutEverCallingTheModel() async throws {
    let many = (0..<(ExplanationGate.maxChangeCount + 1)).map { _ in
        TextChange(scope: .words, block: 0, insertedTokens: 0..<1, removed: "a", inserted: "b")
    }
    let changes = ChangeSet(changes: many, blocks: [], notCompared: nil)
    let fake = FakeLLMClient(responses: ["should never be read"])
    let outcome = try await Translator(client: fake).explain(
        source: "Text.", result: "Text.", changes: changes, language: .en,
        options: ChatOptions(model: "test"))
    #expect(outcome == .skipped(.tooManyChanges(count: ExplanationGate.maxChangeCount + 1,
                                                cap: ExplanationGate.maxChangeCount)))
    #expect(fake.receivedMessages.isEmpty)
}

/// `TranslationOutcome` gains no field for this route — explanations travel beside it
/// (`ExplanationOutcome`), never inside it. Every current field is named here with nothing
/// defaulted, so a future field added without a default stops this compiling, and a field
/// removed does too: the same "construction site as a pin" shape `TranslatorTests` already
/// gives `changes: nil` for a translation.
@Test func translationOutcomeGainsNoFieldForExplanations() {
    let outcome = TranslationOutcome(
        final: "text", chunks: [], translatedChunks: ["text"], documentGlossary: [],
        detectedSource: .en, checks: [], markupDiffs: [], markupNotCompared: false,
        stats: [], timeToFirstTokenMS: nil, totalMS: 0, documentGlossaryFailure: nil,
        documentGlossaryAttempted: false, modelChunkCount: 0, changes: nil)
    #expect(outcome.changes == nil)
}

/// `AsyncThrowingStream` finishes on cancellation rather than throwing, so without an explicit
/// check a cancelled call would hand a truncated buffer to the gate — and a short truncated
/// reply can pass it by accident.
@Test func aCancelledCallSurfacesCancellationRatherThanAnOutcome() async {
    let changes = TextDiff.changes(source: source, result: result)
    let fake = FakeLLMClient(responses: ["1: Fixed a typo.\n2: Fixed a typo."],
                             delayPerToken: .milliseconds(20))
    let task = Task {
        try await Translator(client: fake).explain(
            source: source, result: result, changes: changes, language: .en,
            options: ChatOptions(model: "test"))
    }
    try? await Task.sleep(for: .milliseconds(40))
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("a cancelled call returned an outcome")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
