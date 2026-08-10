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
    // The one formula, not a restatement of it (docs/TESTING.md).
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
