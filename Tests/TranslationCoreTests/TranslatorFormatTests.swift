import Testing
import Foundation
@testable import TranslationCore

// `Translator.format` is the «Оформить» pass: one model call that may add structure to a flat
// text and may change nothing else. These tests pin the route's shape — one call, the whole
// text, no glossary — and the two ways it ends, through the same `FakeLLMClient` the other two
// routes are pinned with.

private let flat = "Folder\nSource repository\n/nova\nprofile-nova\n/server\nprofile-server"
private let table = """
    | Folder | Source repository |
    | --- | --- |
    | /nova | profile-nova |
    | /server | profile-server |
    """

@Test func aReconstructedTableIsAcceptedAndReturned() async throws {
    let fake = FakeLLMClient(responses: [table])
    let outcome = try await Translator(client: fake).format(
        text: flat, source: .en, options: ChatOptions(model: "test"))
    #expect(outcome.verdict == .accepted(table))
    // One call, carrying the whole text, and nothing else: no term list, no per-chunk split.
    #expect(fake.receivedMessages.count == 1)
    #expect(fake.receivedMessages[0].last?.content.hasSuffix(flat) == true)
}

/// The text is handed over under one closing line with no markers around it — the same shape
/// `PromptBuilder.userPrompt(for:)` measured for translation: markers were echoed back around
/// 7/15 replies and a question inside them was answered 5/5.
@Test func theTextIsHandedOverPlainlyAndTheLanguageIsNamed() async throws {
    let fake = FakeLLMClient(responses: [table])
    _ = try await Translator(client: fake).format(
        text: flat, source: .de, options: ChatOptions(model: "test"))
    let system = fake.receivedMessages[0].first!.content
    let user = fake.receivedMessages[0].last!.content
    #expect(system.contains("German"))
    #expect(!user.contains("<text>"))
    #expect(user.hasSuffix(":\n\n\n" + flat))
}

/// The four allowed forms are named and the three forbidden ones are forbidden by name —
/// the design's series B is why bold and italic are on the wrong side of that line.
@Test func thePromptNamesTheAllowedFormsForbidsTheOthersByNameAndForbidsRewriting() async throws {
    let fake = FakeLLMClient(responses: [table])
    _ = try await Translator(client: fake).format(
        text: flat, source: nil, options: ChatOptions(model: "test"))
    let system = fake.receivedMessages[0].first!.content
    for allowed in ["heading", "table", "list", "code"] { #expect(system.contains(allowed)) }
    // The sentence, not the words: a prompt saying «add bold» would contain «bold» too.
    #expect(system.contains("Do not add bold, italic or links."))
    #expect(system.contains("Do not change, add, remove or reorder any word"))
}

@Test func aReplyThatChangedAWordIsRejectedNotReturned() async throws {
    let fake = FakeLLMClient(responses: ["# Folder\n\nSource repositories\n/nova"])
    let outcome = try await Translator(client: fake).format(
        text: "Folder\nSource repository\n/nova", source: .en, options: ChatOptions(model: "test"))
    #expect(outcome.verdict == .rejected(.wordsChanged))
}

/// Emphasis the model added anyway is taken off before the gate, so the words survive and the
/// caller gets the structure it asked for without the markers it forbade.
@Test func emphasisAddedByTheModelIsStrippedBeforeTheVerdict() async throws {
    let fake = FakeLLMClient(responses: ["# Title\n\nThe **staging** build."])
    let outcome = try await Translator(client: fake).format(
        text: "Title\nThe staging build.", source: .en, options: ChatOptions(model: "test"))
    #expect(outcome.verdict == .accepted("# Title\n\nThe staging build."))
}

/// A preamble («Here is the formatted text:») is cleaned off the way every other route cleans
/// it, and a whole-answer fence is unwrapped — so a chatty model does not fail the gate on
/// words it added *about* the text.
@Test func aPreambleLineIsCleanedOffBeforeTheGate() async throws {
    let fake = FakeLLMClient(responses: ["Formatted text:\n# Title\n\nBody."])
    let outcome = try await Translator(client: fake).format(
        text: "Title\nBody.", source: .en, options: ChatOptions(model: "test"))
    #expect(outcome.verdict == .accepted("# Title\n\nBody."))
}

@Test func anEmptyReplyIsRejectedAsEmpty() async throws {
    let fake = FakeLLMClient(responses: [""])
    let outcome = try await Translator(client: fake).format(
        text: "Title\nBody.", source: .en, options: ChatOptions(model: "test"))
    #expect(outcome.verdict == .rejected(.empty))
}

/// `AsyncThrowingStream` finishes on cancellation rather than throwing, so without an explicit
/// check a cancelled pass would hand a truncated reply to the gate — and a truncated reply of
/// a short text can pass it.
@Test func aCancelledPassSurfacesCancellationRatherThanAVerdict() async {
    let fake = FakeLLMClient(responses: [table], delayPerToken: .milliseconds(20))
    let task = Task {
        try await Translator(client: fake).format(text: flat, source: .en,
                                                  options: ChatOptions(model: "test"))
    }
    try? await Task.sleep(for: .milliseconds(40))
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("a cancelled pass returned a verdict")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
