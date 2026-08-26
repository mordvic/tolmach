// Sources/OllamaKit/OllamaChatReader.swift
import Foundation
import TranslationCore

/// One chat response's lines, folded into `ChatEvent`s — and the rule for when that response
/// counts as complete.
///
/// **Separate from `OllamaClient.chat` so the completion rule can be tested without a server.**
/// Inside `chat` it was three lines wrapped around a `URLSession`, which is to say it was
/// untestable, which is how it came to be missing: the client read to the end of the stream and
/// called `finish()` whatever had arrived. `LMStudioEventReader` is the same job on the other
/// engine and is a type of its own for the same reason.
enum OllamaChatReader {
    /// - Parameter yield: called for every event, in wire order.
    /// - Throws: `OllamaError.truncatedStream` if the stream carried an `error` line
    ///   (`OllamaStreamParser.parse` throws it) or ended without its `done` frame. Whatever the
    ///   caller already yielded stays yielded — the throw is what stops it being called a
    ///   translation.
    static func read<Lines: AsyncSequence>(_ lines: Lines,
                                           yield: (ChatEvent) -> Void) async throws
        where Lines.Element == String {
        var sawDone = false
        for try await line in lines {
            for event in try OllamaStreamParser.parse(line: line) {
                if case .done = event { sawDone = true }
                yield(event)
            }
        }
        // **The `done` frame is what completion means, not the end of the bytes.** A stream that
        // simply stops — a killed runner, a dropped connection — reaches here with a fragment
        // already yielded, and returning quietly reports that fragment as the whole translation:
        // TTFT is non-nil because tokens did arrive, so even the empty-reply guards pass, and
        // «Файлы» writes the truncated document to disk as `.finished`.
        //
        // Safe to insist on. Measured 2026-08-26 against Ollama 0.32.14: a chat response carries
        // exactly one `"done":true` line and it is always the last one.
        guard sawDone else {
            throw OllamaError.truncatedStream("the stream ended without a done frame")
        }
    }
}
