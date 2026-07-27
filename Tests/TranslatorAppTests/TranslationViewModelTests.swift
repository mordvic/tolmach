import Testing
import Foundation
@testable import TranslatorApp
@testable import TranslationCore

private final class ScriptedClient: LLMClient, @unchecked Sendable {
    private var responses: [String]
    let delayPerToken: Duration
    init(responses: [String], delayPerToken: Duration = .zero) {
        self.responses = responses; self.delayPerToken = delayPerToken
    }
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
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

@MainActor
private func makeModel(_ client: LLMClient) -> TranslationViewModel {
    let defaults = UserDefaults(suiteName: "vm-\(UUID().uuidString)")!
    return TranslationViewModel(translator: Translator(client: client),
                                settings: AppSettings(defaults: defaults),
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
@Test func theExpectedChunkCountIsKnownBeforeTheRunStarts() {
    let model = makeModel(ScriptedClient(responses: []))
    model.sourceText = String(repeating: "Sentence here. ", count: 200)
    #expect(model.expectedChunkCount > 1)
}
