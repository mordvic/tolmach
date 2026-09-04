import Foundation
import Testing
@testable import TranslationCore

/// Long enough that a 200-character budget splits it at the blank line into two части.
private let twoParagraphs = """
Первый абзац достаточно длинный, чтобы вместе со вторым не поместиться в один запрос, \
и поэтому текст разрезается на две части по пустой строке между абзацами.

Второй абзац такой же длинный и говорит о том же самом, чтобы разрезание случилось \
наверняка и в каждой части оказался свой кусок исходного текста.
"""

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ piece: String) { lock.lock(); text += piece; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

@Test func proofreadMakesOneCallPerChunkAndNeverATermListCall() async throws {
    let fake = FakeLLMClient(responses: ["один", "два"])
    let translator = Translator(client: fake)
    let outcome = try await translator.proofread(
        text: twoParagraphs, level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.chunks.count == 2)
    #expect(fake.receivedMessages.count == outcome.chunks.count)
    #expect(outcome.documentGlossary.isEmpty)
    #expect(outcome.checks.isEmpty)
    #expect(outcome.documentGlossaryAttempted == false)
    #expect(outcome.documentGlossaryFailure == nil)
}

@Test func proofreadAssemblesByteForByteAndTheStreamReconstructsFinal() async throws {
    let fake = FakeLLMClient(responses: ["один", "два"])
    let translator = Translator(client: fake)
    let collector = StreamCollector()
    let outcome = try await translator.proofread(
        text: twoParagraphs, level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onToken: { collector.append($0) })
    // The one formula, not a restatement of it (docs/reference/TESTING.md).
    let plan = Chunker.plan(twoParagraphs, maxCharacters: 200)
    #expect(outcome.final == plan.assembled(from: ["один", "два"]))
    #expect(collector.value == outcome.final)
}

@Test func proofreadDetectsTheLanguageAndAStatedSourceGovernsThePrompt() async throws {
    let fake = FakeLLMClient(responses: ["исправлено"])
    let translator = Translator(client: fake)
    let outcome = try await translator.proofread(
        text: "Превет, мир — это короткий русский текст.", level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.detectedSource == .ru)
    #expect(fake.receivedMessages[0].first!.content.contains("Russian"))

    let stated = FakeLLMClient(responses: ["corrected"])
    _ = try await Translator(client: stated).proofread(
        text: "Short text.", level: .errorsOnly, source: .de,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(stated.receivedMessages[0].first!.content.contains("German"))
}

@Test func anEmptyReplyLeavesTimeToFirstTokenNil() async throws {
    let fake = FakeLLMClient(responses: ["", ""])
    let translator = Translator(client: fake)
    let outcome = try await translator.proofread(
        text: twoParagraphs, level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.timeToFirstTokenMS == nil)
}

@Test func aCancellationMidStreamSurfacesAsCancellationError() async throws {
    let fake = FakeLLMClient(responses: ["достаточно длинный ответ первой части", "вторая"],
                             delayPerToken: .milliseconds(5))
    let translator = Translator(client: fake)
    let run = Task {
        try await translator.proofread(text: twoParagraphs, level: .errorsOnly,
                                       options: ChatOptions(model: "test"),
                                       maxChunkCharacters: 200)
    }
    try await Task.sleep(for: .milliseconds(15))
    run.cancel()
    await #expect(throws: CancellationError.self) { try await run.value }
}

@Test func aSourceThatItselfOpensWithTheMarkerLineIsNotUnwrapped() async throws {
    // When the document being corrected starts with a literal <text> line, a
    // verbatim reproduction is content, and stripping it would destroy the user's
    // own text. This used to exercise the cleaner's suppression rule for its marker
    // unwrap; since 2026-08-18 there is no marker unwrap to suppress (the prompts
    // carry none — `PromptBuilder.userPrompt(for:)`), and the test now pins that the
    // route as a whole leaves such a document alone.
    let source = "<text>\nGenuine content.\n</text>"
    let fake = FakeLLMClient(responses: [source])
    let translator = Translator(client: fake)
    let outcome = try await translator.proofread(
        text: source, level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.final == source)
}

@Test func proofreadPassesFencedChunksThroughAndCountsModelChunks() async throws {
    let source = "Текст с ошибкой.\n\n```py\nprint('helo')\n```"
    let fake = FakeLLMClient(responses: ["Текст без ошибки."])
    let translator = Translator(client: fake)
    // A raw `var` mutated from the `@Sendable` `onToken` closure is a Swift 6 capture
    // error — `StreamCollector` (above) is this file's existing answer.
    let collector = StreamCollector()
    let outcome = try await translator.proofread(
        text: source, level: .errorsOnly,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: { collector.append($0) })
    for messages in fake.receivedMessages {
        for message in messages { #expect(!message.content.contains("print('helo')")) }
    }
    #expect(outcome.final.contains("```py\nprint('helo')\n```"))
    #expect(collector.value == outcome.final)
    #expect(outcome.modelChunkCount == 1)
}

@Test func proofreadReportsWhatItChangedWordByWord() async throws {
    let source = "Превет, мир. Это тестовый текст."
    let fake = FakeLLMClient(responses: ["Привет, мир. Это тестовый текст."])
    let outcome = try await Translator(client: fake).proofread(
        text: source, level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    let changes = try #require(outcome.changes,
                               "правка is the one route the diff applies to")
    #expect(changes.count == 1)
    #expect(changes.changes.first?.removed == "Превет")
    #expect(changes.changes.first?.inserted == "Привет")
    #expect(changes.notCompared == nil)
    // The правка marker is unchanged and is still the one to switch on: `changes != nil` says
    // «the diff ran», which is a different question.
    #expect(outcome.documentGlossaryAttempted == false)
}

@Test func aCancellationAfterTheLastChunkStillStopsBeforeTheDiff() async throws {
    // `aCancellationMidStreamSurfacesAsCancellationError` above covers the checks around the
    // model calls; this one reaches the *last* link. The run is cancelled from `onProgress` for the final часть,
    // which is the one instant at which every earlier `checkCancellation` has been passed and
    // only the one before `TextDiff.changes` is left. The mutation: delete that check and this
    // returns a finished outcome for a run the user cancelled.
    let fake = FakeLLMClient(responses: ["один", "два"], delayPerToken: .milliseconds(1))
    let translator = Translator(client: fake)
    let box = CancelWhenAdopted()
    let run = Task {
        try await translator.proofread(
            text: twoParagraphs, level: .errorsOnly,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            onProgress: { progress in
                if progress.partsDone == progress.partsTotal { box.cancel() }
            })
    }
    box.adopt(run)
    await #expect(throws: CancellationError.self) { try await run.value }
}

/// Cancels a task that may not exist yet.
///
/// `onProgress` can fire before the `Task` initialiser has returned, and a box that dropped a
/// cancellation arriving in that window would make the test above pass for the wrong reason on
/// a loaded machine. Remembering the request instead is what makes the ordering irrelevant.
private final class CancelWhenAdopted: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<TranslationOutcome, Error>?
    private var requested = false

    func adopt(_ task: Task<TranslationOutcome, Error>) {
        lock.lock()
        self.task = task
        let requested = self.requested
        lock.unlock()
        if requested { task.cancel() }
    }

    func cancel() {
        lock.lock()
        requested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
