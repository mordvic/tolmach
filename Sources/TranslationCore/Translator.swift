// Sources/TranslationCore/Translator.swift
import Foundation

public struct TranslationOutcome: Sendable {
    public let final: String
    public let chunks: [Chunk]
    /// Cleaned translation of each chunk, index-aligned with `chunks`. Needed to measure
    /// whether a term renders the same way in every chunk — see the acceptance task.
    public let translatedChunks: [String]
    public let documentGlossary: [GlossaryEntry]
    public let detectedSource: Language?
    public let checks: [GlossaryCheck]
    public let markupDiffs: [MarkupDiff]
    public let stats: [ChatStats]
    public let timeToFirstTokenMS: Double
    public let totalMS: Double
}

// Every other public value type in this API is already Sendable; the entry point
// was the one omission. `any LLMClient` is already Sendable (see LLMClient.swift),
// so this costs nothing — but without it, a Swift 6 consumer (the coming macOS UI,
// which owns a Translator from a @MainActor view model) fails to compile with
// "sending 'self.translator' risks causing data races". The package still pins
// Swift 5 language mode, which hides this today.
public struct Translator: Sendable {
    let client: LLMClient
    public init(client: LLMClient) { self.client = client }

    public func translate(
        text: String, target: Language, tone: Tone, userGlossary: Glossary?,
        options: ChatOptions, maxChunkCharacters: Int,
        ignoredTerms: Set<String> = [],
        onToken: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TranslationOutcome {
        let started = Date()
        var firstTokenAt: Date? = nil
        var stats: [ChatStats] = []

        let detected = LanguageDetector.detect(text)
        let chunks = Chunker.chunk(text, maxCharacters: maxChunkCharacters)

        func stream(_ messages: [ChatMessage], isTranslationOutput: Bool) async throws -> String {
            var buffer = ""
            for try await event in client.chat(messages: messages, options: options) {
                switch event {
                case .token(let token):
                    buffer += token
                    // The term-list call is internal scaffolding: its tokens must never
                    // reach the consumer, and must not set the first-token timestamp.
                    // The timestamp is taken here, from the first *raw* token off the
                    // wire, because it measures perceived latency — cleaning happens
                    // only after the chunk finishes (see onToken below) and must not
                    // push this mark later.
                    guard isTranslationOutput else { continue }
                    if firstTokenAt == nil { firstTokenAt = Date() }
                case .done(let s): stats.append(s)
                }
            }
            return buffer
        }

        // Document glossary. Needs more than one chunk to be worth anything, and a known
        // source language — parsing the source with the target's tagger yields garbage
        // terms that would then be forced into every chunk.
        var documentEntries: [GlossaryEntry] = []
        if chunks.count > 1, let source = detected {
            let terms = TermExtractor.extract(from: text, language: source)
            if !terms.isEmpty {
                do {
                    try Task.checkCancellation()
                    let raw = try await stream(PromptBuilder.termListMessages(terms: terms, target: target),
                                               isTranslationOutput: false)
                    // AsyncThrowingStream's iterator finishes silently on task cancellation
                    // rather than throwing, so `stream()` can return a partial (or empty)
                    // buffer instead of surfacing the cancellation. Check explicitly right
                    // after it returns so a cancellation that landed mid-stream is not
                    // mistaken for a completed — if truncated — response.
                    try Task.checkCancellation()
                    documentEntries = DocumentGlossary.parse(raw, knownTerms: terms, target: target)
                } catch let cancellation as CancellationError {
                    // Cancellation must still propagate — CC-2 depends on `translate`
                    // throwing when cancelled, and this preparatory call is exactly the
                    // kind of place a cancellation would otherwise land unnoticed.
                    throw cancellation
                } catch {
                    // Everything else is a hiccup on an enhancement, not a requirement:
                    // the document glossary improves cross-chunk consistency but the
                    // translation is still useful without it. Leave `documentEntries`
                    // empty and let the per-chunk loop proceed, instead of losing the
                    // whole document over one failed preparatory call.
                    documentEntries = []
                }
            }
        }

        // Per-chunk translation. The user glossary is filtered by occurrence; the document
        // glossary is not — see the task notes for why the two rules differ.
        var translatedChunks: [String] = []
        for chunk in chunks {
            // Checked at the top of every iteration, not just after `stream()` returns,
            // so a cancellation that lands in the synchronous work between chunks (or
            // before the very first request) is caught too, instead of issuing one more
            // request it will just throw away.
            try Task.checkCancellation()
            // Chunks are joined with a blank line in `final`; the stream must carry the
            // same separator, or a consumer rendering tokens live reconstructs a
            // different document from the one `final` describes.
            if !translatedChunks.isEmpty { onToken("\n\n") }
            // Filter over code-stripped text, not the raw chunk. `Glossary.relevantEntries`
            // is a plain occurrence check, so a term that only ever appears inside a fenced
            // or inline code span still matched — and the system prompt would then carry
            // both "reproduce fenced code byte for byte" and "translate this term" for the
            // very same span. ADR 0001 (docs/adr/0001-two-glossaries-opposite-injection-rules.md)
            // is about *whether* the user glossary is filtered by occurrence at all (it is;
            // the document glossary deliberately is not) — this is orthogonal to that: code
            // was never prose to filter *by* in the first place.
            let relevantUser = userGlossary?.relevantEntries(for: TermExtractor.strippingCode(chunk.text)) ?? []
            let merged = GlossaryMerge.merge(user: relevantUser, document: documentEntries)
            let request = TranslationRequest(text: chunk.text, source: detected, target: target,
                                             tone: tone, glossaryEntries: merged)
            let raw = try await stream(PromptBuilder.messages(for: request), isTranslationOutput: true)
            // See the comment on the term-list call above: `stream()` can return a
            // truncated buffer instead of throwing when cancellation lands mid-stream,
            // so this must be checked explicitly rather than trusted to propagate.
            try Task.checkCancellation()
            // Forward the *cleaned* chunk, not the raw tokens as they arrive. Streaming
            // raw tokens let the live feed and `final` disagree whenever ResponseCleaner
            // had to strip a preamble or unwrap a whole-answer code fence — the consumer
            // would render the preamble live and then see it vanish when `final` replaced
            // it. That recurred more than once when patched at the join instead of here,
            // at the source. This trades token-by-token streaming for chunk-by-chunk
            // delivery; that is the right trade, since the chunk is the unit the engine
            // actually reasons about, and a contract the consumer can rely on (stream
            // content == final content, always) is worth more than finer-grained updates.
            let cleaned = ResponseCleaner.clean(raw).text
            translatedChunks.append(cleaned)
            onToken(cleaned)
        }
        let final = translatedChunks.joined(separator: "\n\n")

        // Same code-stripping as the per-chunk filter above, for the same reason: without
        // it, a user term appearing only inside code reaches GlossaryVerifier too, and a
        // *correctly* untranslated code block is then reported `.missing` — the model
        // punished for obeying the higher-priority "reproduce code verbatim" rule.
        let allEntries = GlossaryMerge.merge(user: userGlossary?.relevantEntries(for: TermExtractor.strippingCode(text)) ?? [],
                                             document: documentEntries)
        return TranslationOutcome(
            final: final,
            chunks: chunks,
            translatedChunks: translatedChunks,
            documentGlossary: documentEntries,
            detectedSource: detected,
            checks: GlossaryVerifier.check(translation: final, entries: allEntries,
                                           target: target, ignored: ignoredTerms),
            // Diff against what the model actually saw, not the raw source. `Chunker`
            // normalises whitespace when it assembles chunks — blocks are joined with
            // exactly "\n\n" and a block's trailing whitespace is trimmed — so the
            // model's input already differs from `text` before translation even starts.
            // Diffing against `text` compared the translation to a document nobody was
            // asked to reproduce, producing phantom paragraph/hard-line-break diffs on
            // decorated whitespace that a perfect translation could never match. This is
            // the "cry wolf" failure the whole diff feature exists to avoid.
            markupDiffs: MarkupSkeleton.diff(source: chunks.map(\.text).joined(separator: "\n\n"),
                                             translation: final),
            stats: stats,
            timeToFirstTokenMS: (firstTokenAt ?? Date()).timeIntervalSince(started) * 1000,
            totalMS: Date().timeIntervalSince(started) * 1000)
    }
}
