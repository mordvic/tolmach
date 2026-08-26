import Testing
import Foundation
@testable import OllamaKit
import TranslationCore

/// An array as an `AsyncSequence`, so a reader written for a network stream can be exercised
/// without one. Yields on every element so a consumer's cancellation has somewhere to land.
struct AsyncLines: AsyncSequence {
    typealias Element = String
    let lines: [String]

    struct AsyncIterator: AsyncIteratorProtocol {
        var remaining: [String]
        mutating func next() async -> String? {
            await Task.yield()
            return remaining.isEmpty ? nil : remaining.removeFirst()
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(remaining: lines) }
}

private func token(_ text: String) -> String {
    #"{"message":{"role":"assistant","content":"\#(text)"},"done":false}"#
}
private let doneFrame = #"{"message":{"role":"assistant","content":""},"done":true,"eval_count":3}"#

private func read(_ lines: [String]) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    try await OllamaChatReader.read(AsyncLines(lines: lines)) { events.append($0) }
    return events
}

@Test func acompleteResponseYieldsItsTokensAndItsDoneFrame() async throws {
    let events = try await read([token("Прив"), token("ет"), doneFrame])
    #expect(events.count == 3)
    #expect(events[0] == .token("Прив"))
    #expect(events[1] == .token("ет"))
    if case .done = events[2] {} else { Issue.record("the last event should be .done") }
}

/// The defect. A runner that dies mid-generation writes an `{"error": …}` line into an
/// already-200 stream; the line carries no `message` and no `done`, so the parser returned `[]`
/// and it was dropped. The client then read to the end and reported half a document as a
/// success — with a non-nil TTFT, so even the empty-reply guards passed, and «Файлы» wrote the
/// truncated file to disk as `.finished`.
@Test func anErrorLineMidStreamIsThrownRatherThanDropped() async throws {
    await #expect(throws: OllamaError.self) {
        _ = try await read([token("Прив"), #"{"error":"llama runner process has terminated"}"#,
                            doneFrame])
    }
}

/// Whatever arrived before the error still reached the consumer — the throw is what stops it
/// being *called* a translation, not a promise that nothing was emitted. `Translator` discards
/// a chunk whose call threw; this pins that the reader does not pretend otherwise.
@Test func theTokensBeforeAnErrorAreStillDeliveredBeforeItThrows() async {
    var events: [ChatEvent] = []
    await #expect(throws: OllamaError.self) {
        try await OllamaChatReader.read(
            AsyncLines(lines: [token("Прив"), #"{"error":"boom"}"#])) { events.append($0) }
    }
    #expect(events == [.token("Прив")])
}

/// The other half of the same rule, and the one no parser could catch: nothing malformed
/// arrives at all, the connection simply stops. Measured 2026-08-26 against Ollama 0.32.14 — a
/// chat response carries exactly one `"done":true` line and it is always the last — so a stream
/// without one did not finish.
@Test func aStreamThatEndsWithoutItsDoneFrameIsAnError() async {
    await #expect(throws: OllamaError.self) {
        _ = try await read([token("Прив"), token("ет")])
    }
}

/// An empty response is not the same failure and must not be reported as one: it has its own
/// signal — a nil `timeToFirstTokenMS` — which the engine and both models already read.
@Test func aResponseThatIsNothingButADoneFrameIsComplete() async throws {
    let events = try await read([doneFrame])
    #expect(events.count == 1)
}

/// Blank and unparseable lines are still skipped. NDJSON streams carry them, and turning a
/// keep-alive newline into a failed translation would be the opposite defect.
@Test func blankAndUnparseableLinesAreSkippedRatherThanRefused() async throws {
    let events = try await read(["", "not json at all", token("да"), doneFrame])
    #expect(events.count == 2)
}
