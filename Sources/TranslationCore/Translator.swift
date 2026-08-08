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
    /// measure an event nobody watching `onToken` can ever observe. The chunk
    /// separator (the source's own bytes, restored verbatim) and the internal
    /// term-list call never count either: the separator carries no content, and
    /// the term-list call never reaches `onToken` at all.
    /// Nil when no translation token was ever emitted (an empty model reply, or
    /// every chunk's cleaned output was empty). Treating the absence as a
    /// sentinel — e.g. measuring elapsed time up to `Date()` instead — made TTFT
    /// read as roughly equal to `totalMS`, which blamed latency for what was
    /// actually an absent response. `totalMS` still covers wall-clock time
    /// regardless, so no information is lost by making this optional.
    public let timeToFirstTokenMS: Double?
    public let totalMS: Double
    /// Why the document-glossary call was abandoned, or nil if it was not — either because it
    /// succeeded or because this run never needed one.
    ///
    /// The failure itself is still swallowed, and must be: the document glossary is an
    /// enhancement to cross-chunk consistency, not the result, so losing a whole document
    /// over one failed preparatory call would be the worse trade. What was wrong is that
    /// swallowing it left **no trace at all** — a run that quietly translated a long document
    /// without the terminology pass is indistinguishable, from outside, from one that did not
    /// need it. Terminology drift was measured at 64–68% against 88% with the pass
    /// (`docs/adr/0001-…`), so the difference is the whole reason the call exists.
    ///
    /// Carried on the outcome rather than logged from here, because `TranslationCore` depends
    /// on nothing but Foundation and NaturalLanguage and that rule is worth more than the
    /// convenience — see `CLAUDE.md`'s architecture note. The app logs it (`Log.engine`),
    /// `translate-cli` prints it, and the acceptance harness can read it. Nothing renders it
    /// to the user: it is a diagnostic about an enhancement, not a warning about the result.
    public let documentGlossaryFailure: String?
}

// Every other public value type in this API is already Sendable; the entry point
// was the one omission. `any LLMClient` is already Sendable (see LLMClient.swift),
// so this costs nothing — but without it, a Swift 6 consumer (the coming macOS UI,
// which owns a Translator from a @MainActor view model) fails to compile with
// "sending 'self.translator' risks causing data races". The package still pins
// Swift 5 language mode, which hides this today.
/// What a long-running consumer needs to draw a progress row, reported from inside the
/// run because that is the only place all three numbers exist at once.
///
/// `documentTermCount` travels here rather than being read off `TranslationOutcome`
/// because a queue row says «12 терминов документа» *while* the run is going, and the
/// outcome does not exist until it is over.
public struct TranslationProgress: Sendable, Equatable {
    /// Parts whose translation has been received in full.
    public let partsDone: Int
    /// Fixed for the whole run: chunking depends on the input alone.
    public let partsTotal: Int
    /// Terms the документный глоссарий is holding constant. Zero when there is none —
    /// a single-part run, an unrecognised source language, or an empty term list.
    public let documentTermCount: Int

    public init(partsDone: Int, partsTotal: Int, documentTermCount: Int) {
        self.partsDone = partsDone
        self.partsTotal = partsTotal
        self.documentTermCount = documentTermCount
    }
}

/// What a human is shown before the translation that will use it.
///
/// Carries the user's own matching entries as well as the model's, because the review
/// draws a «откуда» column and cannot distinguish the two sources by looking at a
/// `GlossaryEntry`. The user's are context only: `GlossaryMerge.merge(user:document:)`
/// lets a user entry win over a document one, so an edit to a user row would be discarded
/// by the very next thing the engine does.
public struct DocumentTermsDraft: Sendable {
    /// The term-list call's result, parsed. This is what the review edits.
    public let documentEntries: [GlossaryEntry]
    /// `Glossary.relevantEntries(for:)` — the user's entries that occur in this text.
    public let userEntries: [GlossaryEntry]
    /// How many частей these terms will be held constant across. The review says this
    /// number out loud, so it comes from the engine that planned them.
    public let chunkCount: Int
    /// The language `documentEntries` is keyed by, and the one an edit must be written to.
    ///
    /// Carried rather than re-derived, because the view has no honest way to work it out:
    /// the run that raised this sheet may belong to the queue or to the hotkey panel, and a
    /// window re-deriving it from *its own* last outcome answers about a different
    /// document. `GlossaryEntry.translations` is keyed by language, so a wrong answer there
    /// is not a cosmetic one — every field renders blank and every correction is written to
    /// a key the engine never looks up. The same failure the glossary pane's language
    /// column already cost this project once.
    public let target: Language

    public init(documentEntries: [GlossaryEntry], userEntries: [GlossaryEntry],
                chunkCount: Int, target: Language) {
        self.documentEntries = documentEntries
        self.userEntries = userEntries
        self.chunkCount = chunkCount
        self.target = target
    }
}

public struct Translator: Sendable {
    let client: LLMClient
    public init(client: LLMClient) { self.client = client }

    public func translate(
        text: String, target: Language, tone: Tone, userGlossary: Glossary?,
        options: ChatOptions, maxChunkCharacters: Int,
        ignoredTerms: Set<String> = [],
        onToken: @escaping @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (TranslationProgress) -> Void = { _ in },
        reviewDocumentTerms: (@Sendable (DocumentTermsDraft) async throws -> [GlossaryEntry])? = nil
    ) async throws -> TranslationOutcome {
        let started = Date()
        var firstTokenAt: Date? = nil
        var stats: [ChatStats] = []

        let detected = LanguageDetector.detect(text)
        let plan = Chunker.plan(text, maxCharacters: maxChunkCharacters)
        let chunks = plan.chunks

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
        // Tokens are buffered in `.buffering` mode, on every token, checked in
        // this order:
        //   - ahead of everything else: does the buffer open a fence ("```...")?
        //     The whole-answer unwrap might apply, and deciding it needs the
        //     *end* of the response — so this wins regardless of length or
        //     whether a "\n" has appeared, and the chunk abandons incremental
        //     delivery entirely, falling back to buffering to the end and then a
        //     single full `ResponseCleaner.clean` call, exactly as before
        //     incremental delivery existed.
        // Absent a fence, buffering ends the moment any of these three holds:
        //   1. a "\n" appears — the preamble decision is made right there, on
        //      the completed first line, using the same
        //      `ResponseCleaner.isPreambleLine` rule the buffered cleaner uses
        //      (so the two can't drift) — the line is dropped if it's a
        //      preamble, and everything from here on is forwarded to `onToken`
        //      as it arrives;
        //   2. the buffer's normalised length (`ResponseCleaner.normalizedForPreambleCheck`)
        //      exceeds `ResponseCleaner.preambleLineMaxLength` before condition 1
        //      has fired: `isPreambleLine` rejects anything past that length
        //      before it even checks patterns, and normalisation only ever
        //      removes characters, so once the buffered text crosses the
        //      threshold no later token can turn it back into something that
        //      length would still accept — the buffer can no longer be a
        //      preamble no matter what follows, so it's safe to flush
        //      immediately rather than wait for a "\n" that a single long,
        //      newline-free chunk (the most hotkey-like input there is) might
        //      never produce at all;
        //   3. the stream ends without either of the above ever firing (a
        //      short, single-line reply) — falls back to the same buffered
        //      path used for the fence case.
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
                    guard mode == .buffering else { continue } // .bufferedFence: keep accumulating only

                    // Ahead of the three conditions below, on every token: once the
                    // buffer opens a fence, the whole-answer unwrap might apply,
                    // and that can only be decided at the end of the response — so
                    // this must win regardless of how long the buffer is or
                    // whether a "\n" has appeared yet.
                    if buffer.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        mode = .bufferedFence
                        continue
                    }

                    if let newline = buffer.firstIndex(of: "\n") {
                        // Condition 1: the first line is complete — decide the
                        // preamble on it. Only a genuine preamble line is dropped.
                        // Anything else on the first line is real content and must
                        // be emitted along with it — not just the text after the
                        // newline, which would silently lose the first line
                        // whenever it wasn't a preamble.
                        mode = .incremental
                        let firstLine = String(buffer[buffer.startIndex..<newline])
                        let rest: String
                        if ResponseCleaner.isPreambleLine(firstLine) {
                            rest = String(buffer[buffer.index(after: newline)...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            rest = buffer
                        }
                        emit(rest)
                    } else if ResponseCleaner.normalizedForPreambleCheck(buffer).count
                                > ResponseCleaner.preambleLineMaxLength {
                        // Condition 2: no "\n" yet, but the buffer's normalised
                        // length has permanently ruled out a preamble (see the
                        // comment above `streamChunkTranslation`) — flush what's
                        // accumulated so far and go incremental, rather than
                        // waiting for a newline this chunk may never produce.
                        mode = .incremental
                        emit(buffer)
                    }
                    // Condition 3 (the stream ends without either firing) is
                    // handled after the loop, below.
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
        /// Set only on the swallowed path below. See `TranslationOutcome.documentGlossaryFailure`.
        var documentGlossaryFailure: String?
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
                    //
                    // Recorded on the way past, which is the only thing that changed here:
                    // still swallowed, no longer invisible. See
                    // `TranslationOutcome.documentGlossaryFailure`.
                    documentEntries = []
                    documentGlossaryFailure = error.localizedDescription
                }
            }
        }

        // The review point, and the only correct one: the term-list stream has finished
        // and no per-часть request has been issued, so **no HTTP request is in flight**
        // while this waits for a human. Any earlier and there is nothing to show; any
        // later and the terms have already reached a prompt.
        //
        // Deliberately **outside** the `do`/`catch` above. That block turns any
        // non-cancellation error into an empty glossary and a recorded
        // `documentGlossaryFailure` — correct for a failed *model* call, wrong for a hook
        // the app supplied: a throw from the review would be swallowed and the run would
        // carry on as though the user had approved it.
        // `anErrorFromTheReviewFailsTheRunRatherThanBeingSwallowed` is the guard.
        //
        // Skipped when there is nothing to review — no документный глоссарий was built, or
        // the term-list call failed. An empty table reads as a failure, and the app is what
        // has to speak up about the failed call.
        if let reviewDocumentTerms, !documentEntries.isEmpty {
            let draft = DocumentTermsDraft(
                documentEntries: documentEntries,
                userEntries: userGlossary?.relevantEntries(for: text) ?? [],
                chunkCount: chunks.count,
                target: target)
            // A refusal is `CancellationError`, thrown by the hook and propagating from
            // here — the contract the engine already has, rather than a second refusal
            // path. The check after it covers a cancellation that landed while the human
            // was deciding but did not surface as a throw.
            // Filtered, and not taken as given. `DocumentGlossary.parse` refuses an empty
            // translation on the way in; the hook is a second door into the same data and
            // has to uphold the same invariant. A user who clears a field in the sheet means
            // «do not force this term», but an entry that survives with `translations[target]
            // == ""` reaches `PromptBuilder`, which gates on the key being present rather
            // than on it having a value — so every часть would be told to translate the term
            // as the empty string, and the warnings panel would list it as `API → `.
            // `GlossaryPromotion` already drops exactly this shape for the same reason.
            documentEntries = try await reviewDocumentTerms(draft).filter { entry in
                guard let required = entry.requiredTranslation(for: target) else { return false }
                return !required.isEmpty
            }
            try Task.checkCancellation()
        }

        // Reported before the first request, not after it, so a consumer drawing a
        // progress row has a row to draw while the first part is in flight rather than
        // a blank that fills in only once something has already finished.
        //
        // Counted after the review, so it reports what the run will actually hold constant.
        let documentTermCount = documentEntries.count
        onProgress(TranslationProgress(partsDone: 0, partsTotal: chunks.count,
                                       documentTermCount: documentTermCount))

        // Per-chunk translation. The user glossary is filtered by occurrence; the document
        // glossary is not — see the task notes for why the two rules differ.
        var translatedChunks: [String] = []
        for chunk in chunks {
            // Checked at the top of every iteration, not just after
            // `streamChunkTranslation` returns, so a cancellation that lands in the
            // synchronous work between chunks (or before the very first request) is
            // caught too, instead of issuing one more request it will just throw away.
            try Task.checkCancellation()
            // The separator is the source document's own bytes, restored verbatim — it
            // carries no model content, so it goes straight to `onToken` (never through
            // `emit`, which would stamp `timeToFirstTokenMS`) exactly as the old
            // hard-coded "\n\n" did. The consumer contract is unchanged: whitespace-only
            // pieces are not "output" (TranslationViewModel holds them in `pending`).
            if !chunk.separatorBefore.isEmpty { onToken(chunk.separatorBefore) }
            // Every chunk goes to the model. An indented chunk was briefly reproduced
            // here instead, with no call at all — which returned tab-indented plain
            // text and Markdown loose-list continuations untranslated (nothing in a
            // selection carries format context), and stamped `firstTokenAt` without a
            // single token of model content, defeating the "nil TTFT == empty reply"
            // contract this outcome documents. Indentation is preserved by the
            // verbatim separators instead; fenced and inline code stay the only forms
            // the prompt protects.
            //
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
            onProgress(TranslationProgress(partsDone: translatedChunks.count,
                                           partsTotal: chunks.count,
                                           documentTermCount: documentTermCount))
        }
        // `ChunkPlan.assembled` owns the reassembly formula — this used to restate it,
        // and so did the test that pins losslessness, which is how a restatement can
        // stay green while the shipped path drifts.
        let final = plan.assembled(from: translatedChunks)
        if !chunks.isEmpty, !plan.trailingSeparator.isEmpty {
            // The document's trailing whitespace is part of the byte-for-byte contract
            // (`ChunkPlan`), and the stream must carry it too or a consumer rendering
            // tokens live reconstructs a different document from the one `final`
            // describes. This condition is exactly when `assembled` appends it: a
            // whitespace-only input yields no chunks, no output and nothing to emit.
            onToken(plan.trailingSeparator)
        }

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
            // Diff against the raw source. This used to diff against the chunk-joined
            // text instead, because the old Chunker normalised whitespace (blocks
            // rejoined with exactly "\n\n", trailing whitespace trimmed) and a perfect
            // translation could never match the raw source — the "cry wolf" failure.
            // Lossless chunking removed the normalisation: `ChunkPlan`'s invariant is
            // that separators reassemble byte for byte, so the source the model saw
            // and the source on disk are the same document again.
            markupDiffs: MarkupSkeleton.diff(source: text, translation: final),
            stats: stats,
            timeToFirstTokenMS: firstTokenAt.map { $0.timeIntervalSince(started) * 1000 },
            totalMS: Date().timeIntervalSince(started) * 1000,
            documentGlossaryFailure: documentGlossaryFailure)
    }
}
