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
    /// One entry per translation call — the per-chunk calls only. The internal
    /// term-list call's stats are deliberately excluded, so this means "the
    /// translation calls" consistently with the token forwarding and the
    /// first-token timestamp, which are gated the same way. `totalMS` already
    /// covers wall-clock time including that preparatory call, so nothing the
    /// consumer needs is lost by leaving it out here.
    public let stats: [ChatStats]
    /// Time from the start of the call to the first `onToken` call that carried
    /// actual chunk content — i.e. the first moment a consumer of `onToken`
    /// could have shown the user something. This is deliberately NOT the first
    /// raw token off the wire: a chunk whose whole-answer shape is undecided
    /// (see `Translator.streamChunkTranslation`) is buffered until its first
    /// line settles or its stream ends, so timing the wire instead would
    /// measure an event nobody watching `onToken` can ever observe. The "\n\n"
    /// chunk separator and the internal term-list call never count either: the
    /// separator carries no content, and the term-list call never reaches
    /// `onToken` at all.
    /// Nil when no translation token was ever emitted (an empty model reply, or
    /// every chunk's cleaned output was empty). Treating the absence as a
    /// sentinel — e.g. measuring elapsed time up to `Date()` instead — made TTFT
    /// read as roughly equal to `totalMS`, which blamed latency for what was
    /// actually an absent response. `totalMS` still covers wall-clock time
    /// regardless, so no information is lost by making this optional.
    public let timeToFirstTokenMS: Double?
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

        // The term-list call is internal scaffolding: its output must never reach
        // the consumer, so this never touches `onToken`, `firstTokenAt`, or `stats`
        // — it exists purely to accumulate the raw reply for `DocumentGlossary.parse`.
        func streamTermList(_ messages: [ChatMessage]) async throws -> String {
            var buffer = ""
            for try await event in client.chat(messages: messages, options: options) {
                if case .token(let token) = event { buffer += token }
            }
            return buffer
        }

        // Streams one chunk's translation call, delivering content to `onToken` as
        // early as it safely can instead of only after the whole chunk finishes.
        //
        // `ResponseCleaner` changes exactly two things about a raw reply: the first
        // line (a preamble) and the outermost fence markers (the whole-answer
        // unwrap, which only ever applies when the *entire* reply is one fenced
        // block). Everything between is passed through untouched — which is what
        // makes incremental delivery safe: once the first line is settled, nothing
        // later in the reply can change what should have already been sent.
        //
        // So tokens are buffered only until the first "\n" appears. At that point:
        //   - if the first line opens a fence ("```..."), the unwrap might apply,
        //     and deciding it needs the *end* of the response — so this chunk falls
        //     back to buffering to the end, then a single full `ResponseCleaner.clean`
        //     call, exactly as before incremental delivery existed;
        //   - otherwise, the preamble decision is made right there (the same
        //     `ResponseCleaner.isPreambleLine` rule the buffered cleaner uses, so
        //     the two can't drift), the line is dropped if it's a preamble, and
        //     everything from here on is forwarded to `onToken` as it arrives.
        // A reply that never produces a "\n" at all (a single-line reply) falls
        // back to the same buffered path once the stream ends.
        //
        // On the incremental path, no unwrap is ever applied — but that's not a
        // loss: a chunk that reaches the incremental path did not open with a
        // fence, so the unwrap could never have applied to it anyway. Its
        // contribution to `final` is therefore exactly what was sent to `onToken`,
        // which is the invariant `theStreamReconstructsExactlyWhatFinalContains`
        // pins for every path.
        func streamChunkTranslation(_ messages: [ChatMessage], chunk: Chunk) async throws -> String {
            enum Mode: Equatable { case buffering, bufferedFence, incremental }
            var mode = Mode.buffering
            var buffer = ""    // raw text seen so far; meaningful only outside .incremental
            var collected = "" // exactly what has been handed to `onToken` for this chunk

            func emit(_ text: String) {
                guard !text.isEmpty else { return }
                // Measures perceived latency, so it is stamped here — the moment
                // content actually reaches the consumer — not at the first raw
                // wire token, which on the buffered paths can arrive well before
                // anything is decided to be worth showing.
                if firstTokenAt == nil { firstTokenAt = Date() }
                onToken(text)
                collected += text
            }

            for try await event in client.chat(messages: messages, options: options) {
                switch event {
                case .token(let token):
                    if mode == .incremental { emit(token); continue }
                    buffer += token
                    guard mode == .buffering, let newline = buffer.firstIndex(of: "\n") else { continue }
                    let firstLine = String(buffer[buffer.startIndex..<newline])
                    if firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        mode = .bufferedFence
                    } else {
                        mode = .incremental
                        // Only a genuine preamble line is dropped. Anything else on
                        // the first line is real content and must be emitted along
                        // with it — not just the text after the newline, which
                        // would silently lose the first line whenever it wasn't a
                        // preamble.
                        let rest: String
                        if ResponseCleaner.isPreambleLine(firstLine) {
                            rest = String(buffer[buffer.index(after: newline)...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            rest = buffer
                        }
                        emit(rest)
                    }
                case .done(let chatStats):
                    // `streamChunkTranslation` is only ever used for the per-chunk
                    // translation calls, so — unlike the term-list call — every
                    // call here contributes to `stats`.
                    stats.append(chatStats)
                }
            }

            if mode == .incremental { return collected }
            // Either the reply's first line opened a fence (unwrap deferred to the
            // end, exactly as documented above), or the stream ended without ever
            // producing a "\n" (a single-line reply). Both fall back to the same
            // buffered path: one full clean, emitted in one `onToken` call.
            let cleaned = ResponseCleaner.clean(buffer, allowFenceUnwrap: !chunk.containsCodeFence).text
            emit(cleaned)
            return collected
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
                    let raw = try await streamTermList(PromptBuilder.termListMessages(terms: terms, target: target))
                    // AsyncThrowingStream's iterator finishes silently on task cancellation
                    // rather than throwing, so `streamTermList` can return a partial (or
                    // empty) buffer instead of surfacing the cancellation. Check explicitly
                    // right after it returns so a cancellation that landed mid-stream is not
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
            // Checked at the top of every iteration, not just after
            // `streamChunkTranslation` returns, so a cancellation that lands in the
            // synchronous work between chunks (or before the very first request) is
            // caught too, instead of issuing one more request it will just throw away.
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
            // `streamChunkTranslation` delivers this chunk's content to `onToken`
            // itself — incrementally once its first line is settled, or in one
            // call on the buffered paths (see its doc comment) — so `final` and
            // the stream agree by construction: whatever this returns IS what
            // `onToken` was just called with for this chunk, concatenated.
            let cleaned = try await streamChunkTranslation(PromptBuilder.messages(for: request), chunk: chunk)
            // See the comment on the term-list call above: the underlying stream
            // can end silently instead of throwing when cancellation lands
            // mid-stream, so this must be checked explicitly rather than trusted
            // to propagate. Content already forwarded to `onToken` before the
            // cancellation landed cannot be un-sent — see the report for what
            // that implies for a consumer racing a cancellation against
            // in-flight incremental output.
            try Task.checkCancellation()
            translatedChunks.append(cleaned)
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
            timeToFirstTokenMS: firstTokenAt.map { $0.timeIntervalSince(started) * 1000 },
            totalMS: Date().timeIntervalSince(started) * 1000)
    }
}
