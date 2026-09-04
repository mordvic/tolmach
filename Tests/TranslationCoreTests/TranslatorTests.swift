import Foundation
import Testing
@testable import TranslationCore

private let multiChunkText = """
The resource is valid and the resource is published by the server. \
The server validates the resource before publishing the resource.

Another paragraph about the resource and the server, long enough to force a split \
so the resource and the server both recur across chunks.
"""

// CC-3 fixture: no blank line separates the list from the fence, which is legal
// Markdown, but `Chunker` still forces a chunk boundary at the fence — the
// boundary's `"\n"` separator is restored verbatim, so the model never sees
// fabricated blank lines that the source never had.
private let listWithIndentedFence = """
- First item in the list.
- Second item leads into a code sample below.
    ```bash
    profile-server publish --strict
    ```
- Third item after the code.
"""

@Test func singleChunkSkipsTermExtractionAndReturnsCleanedText() async throws {
    let fake = FakeLLMClient(responses: ["Here is the translation:\nПривет, мир."])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.final == "Привет, мир.")
    #expect(fake.receivedMessages.count == 1) // no term-list call for a single chunk
    #expect(outcome.detectedSource == .en)
    #expect(outcome.documentGlossary.isEmpty)
    // Nil, and not an empty change set: «Hello, world.» and «Привет, мир.» share no token, so
    // a word diff between them would report every word as changed and every surface reading
    // the count would say «4 изменения» about a faithful translation. Правка is the only
    // route where the two texts are comparable.
    #expect(outcome.changes == nil)
}

@Test func multiChunkRunsTermListCallFirst() async throws {
    // response 0 = the term list, then one response per chunk
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.chunks.count > 1)
    #expect(fake.receivedMessages.count == outcome.chunks.count + 1) // +1 term-list call
    #expect(outcome.documentGlossary.contains { $0.term.lowercased() == "resource" })
}

private struct FakeTermListFailure: Error {}

@Test func aFailedTermListCallLeavesDocumentGlossaryEmptyButTranslationProceeds() async throws {
    // The document glossary is an enhancement built from a *preparatory* call; a
    // hiccup on it (model returned garbage, connection dropped mid-request) must
    // not lose the whole document.
    let fake = FakeLLMClient(responses: [
        "never read — the term-list call fails before its response would be used",
        "один", "два",
    ], errors: [FakeTermListFailure()])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.chunks.count > 1)
    #expect(outcome.documentGlossary.isEmpty)
    #expect(outcome.final == "один\n\nдва")
    // The chunk loop still ran once per chunk, on top of the failed term-list call.
    #expect(fake.receivedMessages.count == outcome.chunks.count + 1)
}

@Test func everyDocumentTermGoesIntoEveryChunkPrompt() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "один", "два", "три", "четыре",
    ])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    // Skip index 0 (the term-list call); every remaining prompt carries every term.
    let chunkPrompts = fake.receivedMessages.dropFirst().map { $0.first!.content }
    #expect(chunkPrompts.count == outcome.chunks.count)
    for prompt in chunkPrompts {
        #expect(prompt.contains("ресурс"))
        #expect(prompt.contains("сервер"))
    }
}

@Test func statsExcludesTheInternalTermListCall() async throws {
    // Fix 5: `stats` means "the translation calls" — one entry per chunk, not one
    // per chunk plus the internal term-list scaffolding call.
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "один", "два", "три", "четыре",
    ])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(fake.receivedMessages.count == outcome.chunks.count + 1) // term-list call did happen
    #expect(outcome.stats.count == outcome.chunks.count) // but its stats are excluded
}

@Test func unrecognisedSourceLanguageSkipsTheGlossaryButStillTranslates() async throws {
    // Ukrainian: recognised by NLLanguageRecognizer, absent from our nine targets.
    let ukrainian = String(repeating: "Сервер перевіряє ресурс перед публікацією ресурсу. ", count: 12)
        + "\n\n" + String(repeating: "Ще один абзац про ресурс і сервер для поділу. ", count: 12)
    let fake = FakeLLMClient(responses: ["one", "two", "three", "four", "five"])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: ukrainian, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.detectedSource == nil)
    #expect(outcome.documentGlossary.isEmpty)
    #expect(fake.receivedMessages.count == outcome.chunks.count) // no term-list call
    #expect(!outcome.final.isEmpty)
}

@Test func aChunkConsistingSolelyOfAFenceSurvivesWithMarkersIntact() async throws {
    // Reachability case from the review, from before CP Task 2: Chunker flushes a fence
    // alone into its own chunk whenever the preceding prose already fills the budget, and
    // (then) the model reproducing that chunk verbatim was indistinguishable, to
    // ResponseCleaner, from the "model over-wrapped a plain prose reply" case it exists to
    // fix. CP Task 2 makes the guarantee structural instead: a passthrough chunk never
    // reaches the model at all, so this test now pins the stronger property — the markers
    // survive because there was never a request to garble them, and the fence's own
    // fake response is never even offered to `FakeLLMClient` (see the single-element
    // `responses` below; a second element here would sit unconsumed).
    //
    // Ukrainian: recognised by NLLanguageRecognizer but absent from the nine
    // supported targets (see unrecognisedSourceLanguageSkipsTheGlossaryButStillTranslates),
    // so `detected` comes back nil and the term-list call is skipped — keeping the
    // FakeLLMClient response order simple, one response for the one model-bound chunk.
    let prose = String(repeating: "Сервер перевіряє ресурс перед публікацією ресурсу. ", count: 12)
    let fence = "```bash\nprofile-server publish --strict --out ./dist\n```"
    let doc = prose + "\n\n" + fence
    // Chosen so the fence doesn't fit alongside the prose in one chunk, forcing
    // Chunker to flush the prose as chunk 0 and the fence alone as chunk 1 — the
    // exact shape that made ResponseCleaner strip a real code block's markers, before
    // the passthrough skip removed the model call for chunk 1 entirely.
    let maxCharacters = prose.trimmingCharacters(in: .whitespacesAndNewlines).count + 20
    let chunks = Chunker.plan(doc, maxCharacters: maxCharacters).chunks
    #expect(chunks.count == 2)
    #expect(chunks[1].passthrough)
    #expect(chunks[1].text == fence)

    let fake = FakeLLMClient(responses: ["переклад абзацу"])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: doc, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: maxCharacters)
    #expect(outcome.chunks.count == 2)
    #expect(fake.receivedMessages.count == 1) // the passthrough chunk never reaches the model
    #expect(outcome.modelChunkCount == 1)
    #expect(outcome.translatedChunks[1] == fence)
    #expect(outcome.translatedChunks[1].hasPrefix("```"))
    #expect(outcome.translatedChunks[1].hasSuffix("```"))
}

@Test func anEmptyModelReplyLeavesTimeToFirstTokenNil() async throws {
    // Fix 4: an absent response must read as "no data", not be measured as elapsed
    // time so far — that previously made TTFT read as roughly equal to totalMS,
    // reporting an absent response as a slow one.
    let fake = FakeLLMClient(responses: [""])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.timeToFirstTokenMS == nil)
    #expect(outcome.totalMS >= 0)
}

@Test func aNonEmptyModelReplyStillReportsATimeToFirstToken() async throws {
    let fake = FakeLLMClient(responses: ["Привет, мир."])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.timeToFirstTokenMS != nil)
}

@Test func reportsGlossaryAndMarkupChecks() async throws {
    let fake = FakeLLMClient(responses: ["See https://x.org here."]) // URL kept bare, matches source
    let translator = Translator(client: fake)
    let glossary = Glossary(entries: [GlossaryEntry(term: "x", translations: ["en": "x"])])
    let outcome = try await translator.translate(
        text: "See https://x.org here.", target: .en, tone: .neutral, userGlossary: glossary,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.markupDiffs.isEmpty)
    #expect(outcome.checks.allSatisfy { $0.status != .missing })
}

@Test func aUserGlossaryTermInsideInlineCodeIsNotInjectedOrChecked() async throws {
    // CC-4: a user term that occurs only inside code must not reach the prompt —
    // it would contradict the "reproduce code byte for byte" rule in the same
    // prompt — and must not surface as a GlossaryVerifier check either, since a
    // model that correctly leaves the code untranslated would otherwise be
    // reported `.missing` for obeying the higher-priority rule.
    //
    // Was a fenced block until CP Task 2: a document that is *nothing but* a fenced
    // block is now a passthrough chunk (spec §2.1) and never reaches the model at
    // all, which proves this exact guarantee even more strongly but no longer
    // exercises the per-chunk code-stripping filter this test exists to pin — there
    // is no prompt left to inspect. Inline code does not force a chunk boundary
    // (only a whole fenced block does, per CP Task 1), so it still reaches
    // `PromptBuilder` inside an ordinary model-bound chunk, which is what this test
    // uses instead.
    let text = "Run `run --strict` please."
    let glossary = Glossary(entries: [GlossaryEntry(term: "strict", translations: ["ru": "строгий"])])
    let fake = FakeLLMClient(responses: [text]) // model reproduces the inline code verbatim
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: glossary,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    let systemPrompt = fake.receivedMessages[0][0].content
    #expect(!systemPrompt.contains("строгий"))
    #expect(!systemPrompt.contains("Terminology you MUST follow"))
    #expect(outcome.checks.isEmpty)
}

@Test func onTokenNeverReceivesTermListOutput() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "один", "два", "три", "четыре",
    ])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onToken: collector.onToken)
    #expect(outcome.chunks.count > 1)
    #expect(outcome.documentGlossary.isEmpty == false)
    // The glossary was built, yet none of its raw wire format reached the consumer.
    #expect(!collector.text.contains("=>"))
    #expect(!collector.text.contains("ресурс"))
}

@Test func theStreamReconstructsExactlyWhatFinalContains() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        // A preamble on one reply is the whole point of this test: forwarding raw
        // tokens through onToken would let the stream carry "Here is the
        // translation:\n" while `final` (cleaned) does not, breaking the invariant
        // below. Revert the chunk-level cleaning in Translator to see this fail.
        "Here is the translation:\nпервый", "второй", "третий", "четвёртый",
    ])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onToken: collector.onToken)
    #expect(outcome.chunks.count > 1)
    #expect(collector.text == outcome.final)
}

// MARK: - Fix 1: incremental delivery restores a TTFT a consumer can actually observe.
//
// `Translator` used to buffer a whole chunk, clean it, and hand the result to
// `onToken` in one call — so `timeToFirstTokenMS`, stamped at the first *raw*
// token off the wire, measured an event nobody watching `onToken` could ever
// see. These tests pin the replacement design: a chunk streams incrementally
// once its first line is settled (buffering only until then), unless that
// first line opens a code fence — in which case the whole-answer unwrap might
// apply and deciding it needs the end of the response, so the chunk falls back
// to the pre-existing buffer-then-clean-then-emit-once behaviour. A reply with
// no newline at all falls back the same way once the stream ends.
//
// The concatenation-equals-`final` invariant these tests also check was
// already true under the pre-Fix-1 design (which called `onToken` exactly
// once, with the fully cleaned chunk) — so on its own it does not distinguish
// old from new. What DOES distinguish them is call *count*: the old design
// always called `onToken` exactly once per chunk; true incremental delivery
// must call it more than once. Every test below that claims the incremental
// path asserts `callCount > 1` for exactly that reason — asserted to fail
// against the pre-Fix-1 implementation, see the report for the revert
// evidence.
/// Collects everything `Translator.translate` hands to `onToken`.
///
/// `onToken` is `@escaping @Sendable` because the translator genuinely calls it
/// from a concurrent context, so a collector shared across that boundary has to
/// be safe to touch from either side. Every access here goes through the lock,
/// which is what makes the `@unchecked Sendable` conformance true rather than
/// merely asserted — a box with unguarded stored properties satisfies the
/// compiler and still races.
///
/// `onToken` is a property yielding an already-`@Sendable` closure rather than a
/// method: a partially applied method reference (`collector.onToken` where
/// `onToken` is a `func`) produces a *non*-`@Sendable` function value, and
/// passing one into a `@Sendable` parameter is exactly the conversion the
/// compiler warns about. A closure literal infers `@Sendable` from this
/// property's declared type, so call sites can keep passing `collector.onToken`
/// directly.
private final class TokenCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedText = ""
    private var storedCallCount = 0

    var onToken: @Sendable (String) -> Void {
        { token in
            self.lock.withLock {
                self.storedText += token
                self.storedCallCount += 1
            }
        }
    }

    /// Everything handed to `onToken`, in arrival order.
    var text: String { lock.withLock { storedText } }
    /// How many times `onToken` was called — what distinguishes true incremental
    /// delivery from a single buffered emit that reconstructs the same text.
    var callCount: Int { lock.withLock { storedCallCount } }
}

@Test func theStreamReconstructsExactlyWhatFinalContainsOnTheIncrementalPathWithNoPreamble() async throws {
    // No preamble, no fence, multiple lines: the chunk settles into incremental
    // delivery on its first line and every subsequent token streams straight
    // through — proven by `callCount > 1`, not just by the reconstructed text,
    // since a single buffered emit would reconstruct the same text too. This is
    // also the exact shape that regressed during development when the first
    // line was dropped instead of being included in the first emission.
    let fake = FakeLLMClient(responses: ["First line of content.\nSecond line of content.\nThird line."])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(outcome.final == "First line of content.\nSecond line of content.\nThird line.")
    #expect(collector.text == outcome.final)
    #expect(collector.callCount > 1)
}

@Test func aPreambleIsStrippedOnTheIncrementalPathAndNeverReachesOnToken() async throws {
    // Multi-line, so this genuinely exercises the incremental path (not the
    // single-line fallback, confirmed by `callCount > 1`): the preamble
    // decision is made on the first line before anything is emitted, using the
    // same `ResponseCleaner.isPreambleLine` rule the buffered cleaner uses, and
    // the dropped line must never reach `onToken` — not even fleetingly, the
    // way forwarding raw tokens would.
    let fake = FakeLLMClient(responses: [
        "Here is the translation:\nFirst line of content.\nSecond line of content.",
    ])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(!collector.text.contains("Here is the translation"))
    #expect(outcome.final == "First line of content.\nSecond line of content.")
    #expect(collector.text == outcome.final)
    #expect(collector.callCount > 1)
}

@Test func theStreamReconstructsExactlyWhatFinalContainsOnTheBufferedFencePath() async throws {
    // The model over-wrapped a plain-prose reply in a spurious code fence. The
    // first line opens a fence, so — per the design — this chunk abandons
    // incremental delivery entirely and falls back to buffering to the end,
    // then one full `ResponseCleaner.clean` call (which unwraps the spurious
    // fence) emitted in a single `onToken` call (`callCount == 1`), exactly as
    // before incremental delivery existed. The source chunk itself contains no
    // fence, so the unwrap is allowed.
    let fake = FakeLLMClient(responses: [
        "```\nHello there, this spans multiple lines.\nSecond line here.\n```",
    ])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(outcome.final == "Hello there, this spans multiple lines.\nSecond line here.")
    #expect(collector.text == outcome.final)
    #expect(collector.callCount == 1)
}

@Test func theStreamReconstructsExactlyWhatFinalContainsForASingleLineReply() async throws {
    // No "\n" ever appears in the reply, so the chunk never leaves buffering
    // and the stream ends before a delivery decision was ever made — the third
    // fallback path (alongside the buffered-fence path above), one `onToken`
    // call, and the third shape the invariant must hold on.
    let fake = FakeLLMClient(responses: ["Привет, мир."])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(outcome.final == "Привет, мир.")
    #expect(collector.text == outcome.final)
    #expect(collector.callCount == 1)
}

@Test func timeToFirstTokenIsMeasuredFromTheFirstEmissionNotChunkCompletion() async throws {
    // The first line is long enough that its arrival is a meaningfully late,
    // measurable event (not indistinguishable from "the first token"), and the
    // tail that follows is longer still, so completion is later again. Under
    // the old design TTFT is stamped at the very first raw wire token
    // regardless of chunk shape — near-zero here, and near-zero as a fraction
    // of `totalMS`. Under the fixed design it is stamped when the first line's
    // content is actually handed to `onToken`, landing at a real, non-trivial
    // fraction of `totalMS` — closer to that first emission than to
    // completion, but decisively far from zero. Both bounds below are needed
    // to pin the exact stamp point: the lower bound fails against the old
    // wire-token stamp (see the revert evidence in the report), the upper
    // bound fails if TTFT were instead smeared out to chunk completion.
    let firstLine = String(repeating: "A", count: 20)
    let tail = String(repeating: "x", count: 60)
    let fake = FakeLLMClient(responses: ["\(firstLine)\n\(tail)"], delayPerToken: .milliseconds(4))
    let translator = Translator(client: fake)
    let clock = EmissionClock()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: { _ in clock.stamp() })
    let ttft = try #require(outcome.timeToFirstTokenMS)
    // Compared against the moment a consumer of `onToken` actually saw the first character,
    // measured by this test on the same run — which is the event the stamp is *defined* as,
    // so the two must agree whatever the machine is doing. Both failure modes the comment
    // above describes are still caught: the old wire-token stamp puts `ttft` near zero
    // against a first emission after twenty tokens, and a stamp smeared out to chunk
    // completion puts it at `totalMS`, several times the first emission.
    let firstEmission = try #require(clock.firstEmissionMS)
    #expect(ttft >= firstEmission * 0.5)
    #expect(ttft <= firstEmission * 1.5)
}

// MARK: - Fix 1 refinement: flush on normalised length too, not only on "\n".
//
// Buffering only until the first "\n" made a single-paragraph, newline-free
// chunk — the most hotkey-like input there is — wait for a newline that never
// arrives, so it fell all the way back to the buffered path and TTFT read as
// full generation time. `ResponseCleaner.isPreambleLine` rejects anything
// whose normalised length exceeds `ResponseCleaner.preambleLineMaxLength`
// before it even checks patterns, and normalisation only ever removes
// characters — so once the buffered text's normalised length crosses that
// threshold, the first line can no longer turn out to be a preamble no matter
// what arrives next, and it's safe to flush immediately rather than wait for
// a "\n".

@Test func aNewlineFreeReplyOverTheLengthThresholdEmitsBeforeTheStreamEnds() async throws {
    // No "\n" anywhere in this reply, and its length passes
    // ResponseCleaner.preambleLineMaxLength (60) well before the stream ends.
    // `callCount > 1` (not wall-clock) is what proves the flush happened
    // mid-stream — a single buffered emit at the end would also reconstruct
    // the same text, so call count is the only thing that actually
    // distinguishes "flushed early" from "fell back to the end".
    let reply = String(repeating: "x", count: 90)
    let fake = FakeLLMClient(responses: [reply])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(outcome.final == reply)
    #expect(collector.text == outcome.final)
    #expect(collector.callCount > 1)
}

@Test func aShortPreambleFollowedByANewlineIsStillStrippedWithTheLengthConditionInPlace() async throws {
    // The case the length condition must not break: a short preamble line,
    // comfortably under the 60-character threshold, followed by a newline
    // that arrives long before the buffer could ever cross it. The
    // newline-triggered preamble decision (condition 1) must still win.
    let fake = FakeLLMClient(responses: ["Translation:\nActual content of the reply."])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(!collector.text.contains("Translation:"))
    #expect(outcome.final == "Actual content of the reply.")
    #expect(collector.text == outcome.final)
}

@Test func aReplyUnderTheLengthThresholdWithNoNewlineStillTakesTheEndOfStreamFallback() async throws {
    // Below the 60-character threshold and with no "\n" ever appearing,
    // neither flush condition fires — the reply must still fall back to the
    // pre-existing end-of-stream path: buffered to completion and emitted
    // once (`callCount == 1`), not flushed early.
    let reply = String(repeating: "y", count: 40)
    let fake = FakeLLMClient(responses: [reply])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(outcome.final == reply)
    #expect(collector.text == outcome.final)
    #expect(collector.callCount == 1)
}

// Both tests below synchronize on `FakeLLMClient.onCallStart` rather than a sleep
// duration: cancelling is triggered the instant a *specific* call begins, so which
// call cancellation lands inside is a fact about which call index the test picked,
// not a race against how fast this machine happens to stream 35 characters at 20ms
// per token. A sleep-based version of this test previously always landed the
// cancellation inside the term-list call — its ~700ms stream dwarfed the 80ms
// sleep — leaving the per-chunk `Task.checkCancellation()` calls fully unexercised.
//
// A per-token delay is still essential on the call being cancelled: a
// fully-synchronous fake never suspends, so cancel() would have no window in which
// to land before every response is already buffered and consumed.

/// Waits for exactly one `onCallStart` signal, then lets the caller resume past it.
/// Backed by an unbounded `AsyncStream`, so the signal is captured even if it fires
/// before anyone starts awaiting it.
private func makeCallStartSignal() -> (onCallStart: @Sendable (Int) -> Void, waitFor: @Sendable (Int) async -> Void) {
    let (stream, continuation) = AsyncStream<Int>.makeStream()
    let onCallStart: @Sendable (Int) -> Void = { continuation.yield($0) }
    // `first(where:)` makes its own iterator internally, so there is no mutable
    // state captured across suspension points — each test calls `waitFor` only
    // once, so a single fresh iteration is all this ever needs.
    let waitFor: @Sendable (Int) async -> Void = { target in
        _ = await stream.first(where: { $0 == target })
    }
    return (onCallStart, waitFor)
}

@Test func cancellingDuringTheTermListCallThrowsInsteadOfReturningATruncatedDocument() async throws {
    let (onCallStart, waitFor) = makeCallStartSignal()
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "первый", "второй", "третий", "четвёртый",
    ], delayPerToken: .milliseconds(20), onCallStart: onCallStart)
    let translator = Translator(client: fake)
    let collector = TokenCollector()

    let task = Task {
        try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            onToken: collector.onToken)
    }
    await waitFor(0) // call 0: the term-list call has just started
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    // Only the term-list call was ever issued: cancellation was caught by the
    // `Task.checkCancellation()` right after it, before the per-chunk loop began.
    #expect(fake.receivedMessages.count == 1)
    #expect(collector.text.isEmpty)
}

@Test func cancellingDuringThePerChunkLoopThrowsInsteadOfReturningATruncatedDocument() async throws {
    let (onCallStart, waitFor) = makeCallStartSignal()
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "первый", "второй", "третий", "четвёртый",
    ], delayPerToken: .milliseconds(20), onCallStart: onCallStart)
    let translator = Translator(client: fake)
    let collector = TokenCollector()

    let task = Task {
        try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            onToken: collector.onToken)
    }
    await waitFor(1) // call 1: the first per-chunk translation call has just started
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    // A completed run issues 1 (term-list) call + one call per chunk. Computed
    // rather than hard-coded so this doesn't silently stop meaning anything if the
    // fixture or the chunker's split points change.
    let chunkCount = Chunker.plan(multiChunkText, maxCharacters: 200).chunks.count
    #expect(chunkCount > 1) // otherwise call 1 wouldn't be a per-chunk call at all
    // Exactly 2 calls were made: the term-list call ran to completion, and the
    // second call — the first per-chunk translation, the one cancellation landed
    // inside — was the last one issued. None of the remaining chunk calls a
    // completed run would make ever happened, proving the loop stopped at the call
    // cancellation landed in rather than running to completion.
    #expect(fake.receivedMessages.count == 2)
    #expect(fake.receivedMessages.count < 1 + chunkCount)
    #expect(collector.text.isEmpty) // no chunk had finished, so onToken never fired
}

// MARK: - CC-3: markupDiffs must compare against what the model was actually shown.
//
// Lossless chunking removed `Chunker`'s old whitespace normalisation: `ChunkPlan`'s
// separators reassemble byte for byte, so the text the model was shown and the raw
// source are the same document again. `Translator` diffs `final` against `text`
// directly (see the comment above `markupDiffs:` in `Translator.swift`).
//
// Each helper call below feeds a model that echoes its input back perfectly. A
// perfect echo of a byte-for-byte-preserved source can only produce a non-empty
// diff if reassembly itself is wrong — which is exactly what these pin.
private func assertPerfectEchoProducesNoMarkupDiffs(_ text: String, maxChunkCharacters: Int = 2000) async throws {
    let translator = Translator(client: EchoLLMClient())
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: maxChunkCharacters)
    #expect(outcome.markupDiffs.isEmpty)
}

@Test func perfectEchoOfFenceWithNoSurroundingBlankLinesProducesNoMarkupDiffs() async throws {
    // No blank line around the fence in the source. The fence still forces a chunk
    // boundary, but the boundary's separator is restored verbatim — no blank lines
    // are fabricated, so a perfect echo matches the source exactly.
    try await assertPerfectEchoProducesNoMarkupDiffs("Run the command below.\n```bash\nls -la\n```\nDone.\n")
}

@Test func perfectEchoOfExtraBlankLinesBetweenParagraphsProducesNoMarkupDiffs() async throws {
    // Three blank lines between paragraphs are no longer collapsed to one: the
    // whole run is captured verbatim as `separatorBefore` and restored in `final`,
    // so a perfect echo reproduces the source exactly, extra blank lines included.
    try await assertPerfectEchoProducesNoMarkupDiffs("First paragraph.\n\n\nSecond paragraph.\n")
}

@Test func perfectEchoOfHardLineBreaksProducesNoMarkupDiffs() async throws {
    // This used to describe a real, separate content-loss bug: a block's trailing
    // whitespace was trimmed before the model ever saw it, so "Line two"'s two
    // trailing spaces (a hard line break) were destroyed ahead of translation, not
    // merely hidden by the diff baseline. This wave fixes that: a block-final hard
    // break's spaces are part of `separatorBefore` on the next chunk (or the plan's
    // `trailingSeparator`), so they survive into `final` untouched, and this test
    // now pins the fix rather than documenting the limitation.
    try await assertPerfectEchoProducesNoMarkupDiffs("Line one  \nLine two  \n\nNext paragraph.\n")
}

@Test func perfectEchoOfAListWithAnIndentedFenceProducesNoMarkupDiffs() async throws {
    // Same boundary-preservation as the first case, on a list: the fence forces a
    // chunk split with no blank line in the source, and the split's separator is
    // restored verbatim — so the list is never fragmented by fabricated blank lines.
    try await assertPerfectEchoProducesNoMarkupDiffs(listWithIndentedFence)
}

// MARK: - Lossless assembly: final restores the source's separators byte for byte.

/// A "perfect translator": echoes back exactly the text the user prompt hands over —
/// everything after the closing line's colon and the two blank lines that follow it
/// (`PromptBuilder.userPrompt(for:)`). The term-list call's prompt has no such line and
/// echoes nothing, which parses as an empty document glossary — so this fake never needs
/// its response queue aligned with the unpredictable presence of that call.
private struct EchoLLMClient: LLMClient {
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        let user = messages.last?.content ?? ""
        let payload: String
        if user.hasPrefix("Please translate the following "), let start = user.range(of: ":\n\n\n") {
            payload = String(user[start.upperBound...])
        } else {
            payload = ""
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(payload))
            continuation.yield(.done(ChatStats(loadDurationMS: 0, promptEvalCount: 0,
                promptEvalDurationMS: 0, evalCount: 0, evalDurationMS: 0)))
            continuation.finish()
        }
    }
}

private let structuredDocuments: [String] = [
    "First paragraph up top.\n\n\n\nSecond paragraph after three blank lines.",
    "First paragraph.\r\n\r\nSecond paragraph, CRLF separated.",
    "Run the command below.\n```bash\nls -la\n```\nDone.",
    "Line one  \nLine two  \n\nNext paragraph.\n",
    String(repeating: "The server validates the resource before publishing it to every client. ",
           count: 12),
]

@Test(arguments: structuredDocuments)
func aPerfectEchoReproducesTheSourceByteForByte(_ text: String) async throws {
    let translator = Translator(client: EchoLLMClient())
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 120)
    #expect(outcome.final == text)
    #expect(outcome.markupDiffs.isEmpty)
}

@Test func theStreamCarriesTheVerbatimSeparatorsAndStillReconstructsFinal() async throws {
    let text = "First paragraph up top.\n\n\n\nSecond paragraph after three blank lines."
    let translator = Translator(client: EchoLLMClient())
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 120,
        onToken: collector.onToken)
    #expect(collector.text == outcome.final)
    #expect(outcome.final.contains("\n\n\n\n"))
}

@Test func aSeparatorTheModelNeverSeesSurvivesInFinalRegardlessOfTheModel() async throws {
    // Separator restoration is unconditional: "\n\n\n" is not the canonical
    // separator, so it forces a chunk boundary and is never shown to the model at
    // all — the model's reply cannot affect it. The responses below are deliberately
    // nothing like the source and are provisioned for the actual call pattern (one
    // term-list call, then one per chunk), so no call silently falls back to the
    // empty reply an exhausted queue returns.
    let fake = FakeLLMClient(responses: ["", "Ответ один.", "Ответ два."])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: "First paragraph.\n\n\nSecond paragraph.", target: .ru, tone: .neutral,
        userGlossary: nil, options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.chunks.count == 2)
    #expect(outcome.final.contains("\n\n\n"))
}

// MARK: - Indented text is translated like any other prose.

@Test func everyChunkOfADocumentWithIndentedTextIsSentToTheModel() async throws {
    // An indented line was briefly reproduced by the engine with no model call. In a
    // selection translator that has no format context, that returned tab-indented
    // plain text and Markdown loose-list continuations untranslated, with a success
    // state. Every chunk goes to the model again; the indentation survives through
    // the verbatim separators, not by withholding the text.
    let text = "Intro.\n\n    let a = compute(1)\n\nAfter."
    // Two chunks — the indented block merges with the prose after it across the
    // blank line — and no term-list call, so the queue is exactly one reply per chunk.
    let fake = FakeLLMClient(responses: ["Введение.", "После."])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(outcome.chunks.count == 2)
    #expect(fake.receivedMessages.count == outcome.chunks.count) // no term-list call
    // The «Please translate the following …» closing line opens the per-chunk translation
    // prompt and nothing else — the term-list prompt has no such line.
    let chunkPrompts = fake.receivedMessages.filter { $0.last?.content.hasPrefix("Please translate the following ") == true }
    #expect(chunkPrompts.count == outcome.chunks.count)
    for chunk in outcome.chunks {
        #expect(chunkPrompts.contains { $0.last?.content.contains(chunk.text) == true })
    }
    #expect(fake.receivedMessages.contains { $0.contains { $0.content.contains("let a = compute(1)") } })
    #expect(outcome.stats.count == outcome.chunks.count) // one entry per translation call
    #expect(collector.text == outcome.final) // stream and final still agree
    // The source's indentation is still restored byte for byte around the translation:
    // the indented line's own four spaces live in the second chunk's separator.
    #expect(outcome.final == "Введение.\n\n    После.")
}

@Test func aDocumentOfOnlyIndentedTextIsStillTranslated() async throws {
    let text = "    let a = 1\n    let b = 2\n"
    let fake = FakeLLMClient(responses: ["Перевод."])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(fake.receivedMessages.count == 1) // one chunk, so no term-list call
    #expect(outcome.final == "    Перевод.\n")
    #expect(collector.text == outcome.final)
    #expect(outcome.stats.count == 1)
    #expect(outcome.timeToFirstTokenMS != nil)
}

@Test func progressIsReportedAsSoonAsThePartCountIsKnownAndAgainWhenTheTermsAre() async throws {
    // Two reports before the first часть, and they say different things.
    //
    // The first goes out the moment `Chunker` has planned, before anything is asked of the
    // model — a consumer waiting for the term-list call (seconds, or minutes with the terms
    // gate on) otherwise has nothing but whatever it seeded its row with, which for the
    // queue is the drop-time estimate. The second carries the term count once the review has
    // settled it, and is skipped when there is no документный глоссарий, because it would
    // then repeat the first word for word.
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)
    let box = ProgressBox()
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onProgress: { box.append($0) })

    let seen = box.values
    #expect(seen.count == outcome.chunks.count + 2)
    #expect(seen.map(\.partsDone) == [0] + Array(0...outcome.chunks.count))
    #expect(seen.allSatisfy { $0.partsTotal == outcome.chunks.count })
    // Zero until the terms are known, then the real count for the rest of the run.
    #expect(seen.first?.documentTermCount == 0)
    #expect(seen.dropFirst().allSatisfy { $0.documentTermCount == outcome.documentGlossary.count })
    #expect(outcome.documentGlossary.count == 2)
}

@Test func aSingleChunkRunStillReportsProgressWithNoDocumentTerms() async throws {
    let fake = FakeLLMClient(responses: ["Привет, мир."])
    let translator = Translator(client: fake)
    let box = ProgressBox()
    _ = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onProgress: { box.append($0) })

    #expect(box.values == [
        TranslationProgress(partsDone: 0, partsTotal: 1, documentTermCount: 0),
        TranslationProgress(partsDone: 1, partsTotal: 1, documentTermCount: 0),
    ])
}

/// `onProgress` is `@Sendable` and is called from the engine's task, so a bare local
/// array cannot collect it under Swift 6's checking. A lock is the smallest thing that
/// is actually correct here; an actor would force the assertions to be `await`ed and
/// buy nothing.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranslationProgress] = []
    func append(_ value: TranslationProgress) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [TranslationProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Test func theReviewHookSeesTheParsedTermsAndTheirPartCount() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)
    let box = DraftBox()

    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral,
        userGlossary: Glossary(entries: [GlossaryEntry(term: "server", doNotTranslate: true)]),
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { draft in box.record(draft); return draft.documentEntries })

    #expect(box.count == 1)   // once per run, never once per часть
    let draft = try #require(box.value)
    #expect(draft.documentEntries.contains { $0.term.lowercased() == "resource" })
    // The user's own entry travels alongside, because the review shows a «откуда» column
    // and cannot tell the two apart without being told.
    #expect(draft.userEntries.map(\.term) == ["server"])
    #expect(draft.chunkCount == outcome.chunks.count)
    // The language the «перевод» column is keyed by. The view used to re-derive it from
    // the *window's* last outcome, which for a queue- or panel-raised sheet belongs to an
    // unrelated document — every field blank, and every correction written to a key the
    // engine never looks up. The engine is the only place that knows.
    #expect(draft.target == .ru)
}

@Test func editsMadeInTheReviewReachThePrompt() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)

    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { _ in
            [GlossaryEntry(term: "resource", translations: ["ru": "объект"])]
        })

    // The whole point: what the user typed is what the model is told, for every часть.
    let chunkPrompts = fake.receivedMessages.dropFirst()   // drop the term-list call
    #expect(chunkPrompts.allSatisfy { messages in
        messages.contains { $0.content.contains("объект") }
    })
    #expect(!chunkPrompts.contains { messages in
        messages.contains { $0.content.contains("ресурс") }
    })
    #expect(outcome.documentGlossary.first?.translations["ru"] == "объект")
}

@Test func refusingTheReviewCancelsTheRunRatherThanFailingIt() async throws {
    let fake = FakeLLMClient(responses: ["resource => ресурс", "не должно быть запрошено"])
    let translator = Translator(client: fake)

    await #expect(throws: CancellationError.self) {
        _ = try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            reviewDocumentTerms: { _ in throw CancellationError() })
    }
    // One call made — the term list — and not a single часть requested afterwards.
    #expect(fake.receivedMessages.count == 1)
}

private struct ReviewExploded: Error {}

@Test func anErrorFromTheReviewFailsTheRunRatherThanBeingSwallowed() async throws {
    // The sharpest edit in this task: the review must sit *outside* the catch that
    // swallows a failed term-list call. Inside it, this throw would become an empty
    // glossary and the run would carry on as though nothing had happened.
    let fake = FakeLLMClient(responses: ["resource => ресурс", "не должно быть запрошено"])
    let translator = Translator(client: fake)

    await #expect(throws: ReviewExploded.self) {
        _ = try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            reviewDocumentTerms: { _ in throw ReviewExploded() })
    }
    #expect(fake.receivedMessages.count == 1)
}

@Test func aSingleChunkRunNeverAsksForAReview() async throws {
    let fake = FakeLLMClient(responses: ["Привет, мир."])
    let translator = Translator(client: fake)
    let box = DraftBox()

    _ = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        reviewDocumentTerms: { draft in box.record(draft); return draft.documentEntries })

    // No документный глоссарий is built here, so there is nothing to review and a table
    // of nothing would read as a failure.
    #expect(box.count == 0)
}

@Test func aFailedTermListCallSkipsTheReviewInsteadOfShowingAnEmptyTable() async throws {
    let fake = FakeLLMClient(
        responses: ["ignored", "перевод один", "перевод два", "перевод три", "перевод четыре"],
        errors: [FakeTermListFailure()])
    let translator = Translator(client: fake)
    let box = DraftBox()

    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { draft in box.record(draft); return draft.documentEntries })

    #expect(box.count == 0)
    // Still swallowed and still recorded — the app is what has to stop being silent about
    // it when the user asked for a gate.
    #expect(outcome.documentGlossaryFailure != nil)
}

@Test func aHookThatChangesNothingChangesNothing() async throws {
    // The pinning test. Two runs of the same input, one with no hook and one with a hook
    // that returns its draft untouched, must agree on everything observable. Comparing the
    // two runs rather than against literals is what makes this survive a change to the
    // fixture: a literal would have to be regenerated and would then pin whatever the code
    // did that day.
    // Typed explicitly: a ternary infers a non-`@Sendable` closure, which Swift 6 refuses
    // to convert to the parameter's `@Sendable` type.
    let identity: (@Sendable (DocumentTermsDraft) async throws -> [GlossaryEntry]) = { $0.documentEntries }
    func run(withHook: Bool) async throws -> TranslationOutcome {
        let fake = FakeLLMClient(responses: [
            "resource => ресурс\nserver => сервер",
            "перевод один", "перевод два", "перевод три", "перевод четыре",
        ])
        return try await Translator(client: fake).translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            reviewDocumentTerms: withHook ? identity : nil)
    }

    let without = try await run(withHook: false)
    let with = try await run(withHook: true)

    #expect(without.final == with.final)
    #expect(without.translatedChunks == with.translatedChunks)
    #expect(without.chunks.map(\.text) == with.chunks.map(\.text))
    #expect(without.documentGlossary == with.documentGlossary)
    #expect(without.checks == with.checks)
    #expect(without.markupDiffs == with.markupDiffs)
    #expect(without.detectedSource == with.detectedSource)
}

/// See `ProgressBox` for why a lock and not a bare array: the hook is `@Sendable`.
private final class DraftBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DocumentTermsDraft] = []
    func record(_ draft: DocumentTermsDraft) { lock.lock(); storage.append(draft); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    var value: DocumentTermsDraft? { lock.lock(); defer { lock.unlock() }; return storage.first }
}

@Test func aTermTheUserEmptiedInTheReviewNeverReachesAPrompt() async throws {
    // Clearing a «перевод» field means «do not force this term». An entry that survived
    // with an empty translation reached PromptBuilder, which gates on the key being present
    // rather than on it having a value — so every часть was told to translate the term as
    // the empty string, and the warnings panel listed it as «resource → ».
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)

    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { draft in
            draft.documentEntries.map { entry in
                var cleared = entry
                if entry.term.lowercased() == "resource" { cleared.translations["ru"] = "" }
                return cleared
            }
        })

    #expect(!outcome.documentGlossary.contains { $0.term.lowercased() == "resource" })
    #expect(outcome.documentGlossary.contains { $0.term.lowercased() == "server" })
    // The word itself is in the document being translated, so the check is on the glossary
    // *instruction* PromptBuilder emits — which is what an empty translation corrupted:
    // `- "resource" — translate as "".`
    let chunkPrompts = fake.receivedMessages.dropFirst()
    #expect(!chunkPrompts.contains { messages in
        messages.contains { $0.content.contains("\"resource\" — translate as") }
    })
    #expect(chunkPrompts.allSatisfy { messages in
        messages.contains { $0.content.contains("\"server\" — translate as \"сервер\".") }
    })
    #expect(!chunkPrompts.contains { messages in
        messages.contains { $0.content.contains("translate as \"\".") }
    })
}

@Test func aRunCancelledJustAsTheTermListLandsNeverRaisesItsSheet() async throws {
    // The engine's last cancellation check is before `DocumentGlossary.parse`. A hook that
    // did not check again brought the window forward and put up a sheet for a run the user
    // had already stopped.
    let fake = FakeLLMClient(responses: ["resource => ресурс", "не должно быть запрошено"])
    let translator = Translator(client: fake)
    let box = DraftBox()

    let task = Task {
        try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            reviewDocumentTerms: { draft in
                try Task.checkCancellation()
                box.record(draft)
                return draft.documentEntries
            })
    }
    task.cancel()
    _ = try? await task.value

    #expect(box.count == 0)
}

@Test func aDocumentWithNoTermCandidatesNeverAsksTheModelForATermList() async throws {
    // «The sheet never appeared» has two causes and only one of them is a failure. Without
    // this the app told a user who had turned the gate on that terms «не удалось
    // подготовить» for every prose document whose tagger yields no candidates — asserting a
    // failure that never happened.
    let fake = FakeLLMClient(responses: ["перевод один", "перевод два", "перевод три"])
    let translator = Translator(client: fake)

    // Digits and punctuation: more than one часть, a recognised language, no nouns to take.
    let outcome = try await translator.translate(
        text: "1 2 3 4 5 6 7 8 9 10.\n\n11 12 13 14 15 16 17 18 19 20.",
        target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 20)

    #expect(outcome.chunks.count > 1)
    #expect(!outcome.documentGlossaryAttempted)
    #expect(outcome.documentGlossaryFailure == nil)
}

@Test func aRunThatAsksForATermListSaysSoWhateverComesBack() async throws {
    let fake = FakeLLMClient(responses: [
        "не список вовсе",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let outcome = try await Translator(client: fake).translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)

    // Asked, answered, parsed to nothing: attempted, and no failure recorded — which is
    // exactly the case that still owes the user a word when the gate was on.
    #expect(outcome.documentGlossaryAttempted)
    #expect(outcome.documentGlossary.isEmpty)
    #expect(outcome.documentGlossaryFailure == nil)
}

@Test func aSingleChunkRunNeverAsksForATermListEither() async throws {
    let outcome = try await Translator(client: FakeLLMClient(responses: ["Привет."])).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(!outcome.documentGlossaryAttempted)
}

/// Wall-clock milliseconds around a call, and the moment `onToken` first fired.
///
/// Every timing assertion in this file compares two measurements **of the same run** rather
/// than one measurement against a constant. A constant measures the machine: the three tests
/// below asserted «< 300» against a 300 ms sleep and «< totalMS * 0.5» against a fixed token
/// delay, which held on this laptop and failed on a shared CI runner three times in eight
/// runs — 386 against 300, 334 against 300, and a ratio of 0.57 against 0.5. Both sides of a
/// comparison taken from one run grow together when the runner is loaded, so the arithmetic
/// survives it while still failing on the behaviour each test names.
final class EmissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private var first: Date?

    /// Called from `onToken`; only the first call is kept.
    func stamp() {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = Date() }
    }

    /// Milliseconds from construction to the first `onToken`, or nil if none ever came.
    var firstEmissionMS: Double? {
        lock.lock(); defer { lock.unlock() }
        return first.map { $0.timeIntervalSince(start) * 1000 }
    }

    /// Milliseconds from construction to now.
    var elapsedMS: Double { Date().timeIntervalSince(start) * 1000 }
}

@Test func timeSpentInTheReviewSheetIsNotCountedAsTranslationTime() async throws {
    // «Готово за N мс» and a queue row's «✓ готово за …» are read as how long the machine
    // took. With the gate on, a file the model translated in a moment while its reader
    // deliberated reported the deliberation.
    let fake = FakeLLMClient(responses: [
        "resource => ресурс",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)

    let clock = EmissionClock()
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { draft in
            try await Task.sleep(for: .milliseconds(300))   // the human, thinking
            return draft.documentEntries
        })

    // The deliberation really happened — it is in the wall clock — and really is not in
    // `totalMS`. Stated as the gap between the two, which is what «not counted» means; the
    // 250 is the 300 ms sleep less the slop a `Task.sleep` is allowed. Asserting
    // «totalMS < 300» instead measured the runner: it says everything *except* the sleep
    // must fit inside the sleep's own duration, which is a claim about the machine.
    #expect(clock.elapsedMS - outcome.totalMS >= 250)
}

@Test func theTwoTimingsAreMeasuredOnOneClock() async throws {
    // The review point is before the per-часть loop, so a reader's deliberation lies
    // between the start and the first token. Taking it off `totalMS` alone left TTFT
    // reporting 248 000 ms against a total of 8 000 — the inverse of what the outcome says
    // the two mean.
    let fake = FakeLLMClient(responses: [
        "resource => ресурс",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let clock = EmissionClock()
    let outcome = try await Translator(client: fake).translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { draft in
            try await Task.sleep(for: .milliseconds(300))
            return draft.documentEntries
        })

    let ttft = try #require(outcome.timeToFirstTokenMS)
    // Same subtraction as above, on the other timing: the reader's deliberation lies between
    // the start and the first token, so a TTFT that still carried it would leave no gap.
    #expect(clock.elapsedMS - ttft >= 250)
    #expect(ttft <= outcome.totalMS)
}

@Test func aTermClearedWithASpaceNeverReachesAPrompt() async throws {
    // The other door. `" "` is not empty, so it passed the filter and PromptBuilder emitted
    // `- "resource" — translate as " ".` for every часть.
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)

    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { draft in
            draft.documentEntries.map { entry in
                var cleared = entry
                if entry.term.lowercased() == "resource" { cleared.translations["ru"] = "   " }
                return cleared
            }
        })

    #expect(!outcome.documentGlossary.contains { $0.term.lowercased() == "resource" })
    let chunkPrompts = fake.receivedMessages.dropFirst()
    #expect(!chunkPrompts.contains { messages in
        messages.contains { $0.content.contains("\"resource\" — translate as") }
    })
}

@Test func aStatedSourceLanguageGovernsThePromptAndTheTermsAndNotJustTheTarget() async throws {
    // It used to be resolved in the app to choose a target and then dropped: the engine
    // detected the language again for the prompt, for TermExtractor's tagger and for
    // `detectedSource`. A user correcting a misdetection changed where the text went and
    // nothing about how it was read.
    let fake = FakeLLMClient(responses: ["перевод"])
    let outcome = try await Translator(client: fake).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        source: .de,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)

    #expect(outcome.detectedSource == .de)
    #expect(fake.receivedMessages.first?.contains { $0.content.contains("German") } == true)
}

@Test func aStatedSourceIsTheLanguageTermsAreExtractedWith() async throws {
    // The «and the terms» half of the test above, which that one could not reach: its
    // fixture is one часть, and `TermExtractor` is only consulted when there is more than
    // one. So a regression that re-detected the language for the tagger alone passed.
    //
    // Observable because the tagger's language decides what it finds at all. Measured, on
    // this text: the English tagger yields 6 terms («database», «request», «resource»,
    // «resource server», «result», «server») and the German tagger yields **none**. So a
    // stated `.de` means no term list is worth asking for, and the term-list call — call 0
    // for a multi-часть file — does not happen. The call count is the assertion.
    let text = String(
        repeating: "The resource server validates the request and the database stores the result. ",
        count: 20)

    // Both runs **state** their language, so the only thing that differs between them is
    // which tagger `TermExtractor` was handed. (Detection is no use as the control here:
    // measured, `LanguageDetector.detect` returns nil on this deliberately repetitive text,
    // so a run that relied on it would build no document glossary for a reason that has
    // nothing to do with the tagger — and that is itself worth knowing, because a stated
    // source makes a документный глоссарий possible where detection gives up.)
    let english = FakeLLMClient(responses: ["термины", "часть-1", "часть-2"])
    let byEnglish = try await Translator(client: english).translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        source: .en,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(byEnglish.chunks.count > 1, "the fixture must split, or TermExtractor is never asked")
    #expect(byEnglish.documentGlossaryAttempted, "the English tagger finds terms here")

    let stating = FakeLLMClient(responses: ["часть-1", "часть-2"])
    let byStatement = try await Translator(client: stating).translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        source: .de,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(byStatement.documentGlossaryAttempted == false,
            "the German tagger finds nothing here, so the stated language must be the one used")
    // One call per часть and no term-list call at all.
    #expect(stating.receivedMessages.count == byStatement.chunks.count)
    #expect(english.receivedMessages.count == byEnglish.chunks.count + 1)
}

@Test func withNoStatedSourceTheEngineStillDetectsItsOwn() async throws {
    let fake = FakeLLMClient(responses: ["перевод"])
    let outcome = try await Translator(client: fake).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.detectedSource == .en)
}

// MARK: - CP Task 2: passthrough chunks skip the model; modelChunkCount

@Test func aPassthroughChunkNeverReachesTheModelAndItsBytesArriveVerbatim() async throws {
    let source = "Пролог.\n\n```swift\nlet зц = 1 // нарочно с опечаткой\n```\n\nЭпилог."
    let fake = FakeLLMClient(responses: ["Prologue.", "Epilogue."])
    let translator = Translator(client: fake)
    // `var streamed = ""` mutated directly from the `@Sendable` `onToken` closure is a
    // Swift 6 capture error (mutation of a captured var in concurrently-executing code) —
    // `TokenCollector` is this file's existing answer to exactly that, used by every other
    // streaming test below.
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: source, target: .en, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    // The strong pin (docs/reference/TESTING.md shape): not merely «two calls», but «no message
    // ever sent to the model contains the fenced bytes» — a call-count pin alone
    // survives the defect «called, with the wrong chunk».
    for messages in fake.receivedMessages {
        for message in messages {
            #expect(!message.content.contains("let зц = 1"))
        }
    }
    #expect(fake.receivedMessages.count == 2)
    #expect(outcome.final.contains("```swift\nlet зц = 1 // нарочно с опечаткой\n```"))
    #expect(collector.text == outcome.final)
    #expect(outcome.modelChunkCount == 2)
}

@Test func anAllCodeDocumentSucceedsWithoutAModelCallAndNilTTFT() async throws {
    let source = "```sh\nls -la\n```"
    let fake = FakeLLMClient(responses: [])
    let translator = Translator(client: fake)
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: source, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(fake.receivedMessages.isEmpty)
    #expect(outcome.final == source)
    #expect(collector.text == source)
    #expect(outcome.modelChunkCount == 0)
    #expect(outcome.timeToFirstTokenMS == nil)   // nil keeps meaning «no model emission»
    #expect(outcome.stats.isEmpty)
}

@Test func aDocumentGlossaryIsNeverAttemptedBelowTwoModelBoundChunks() async throws {
    // Fence + one paragraph = 2 chunks but only 1 model-bound: no term-list call may
    // fire (Translator.swift's glossary trigger counts model-bound chunks, not raw ones).
    let source = "```sh\nls\n```\n\nParagraph about the listing command and its flags."
    let fake = FakeLLMClient(responses: ["Абзац про команду вывода списка."])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: source, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900)
    #expect(fake.receivedMessages.count == 1)   // per-chunk call only, no term-list call
    #expect(outcome.documentGlossaryAttempted == false)
    #expect(outcome.modelChunkCount == 1)
}

// MARK: - CP Task 4: inline-code positional restore

@Test func anInlineSpanEditedByTheModelIsRestoredInFinalAndStreamAlike() async throws {
    let source = "Выполните комманду `git comit --amend` сейчас."
    let fake = FakeLLMClient(responses: ["Выполните команду `git commit --amend` сейчас."])
    let translator = Translator(client: fake)
    // `var streamed = ""` mutated directly from the `@Sendable` `onToken` closure is a
    // Swift 6 capture error — `TokenCollector` is this file's existing answer, used by
    // every other streaming test in this file.
    let collector = TokenCollector()
    let outcome = try await translator.proofread(
        text: source, level: .errorsOnly,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: collector.onToken)
    #expect(outcome.final == "Выполните команду `git comit --amend` сейчас.")
    #expect(collector.text == outcome.final)
}

// MARK: - `isEmptyReply`: one rule, one place

/// The rule `modelChunkCount`'s doc comment states in prose, made into a value both the window
/// and the queue read. It was written twice instead, and the queue's copy — which checked only
/// the nil — failed every all-code document (see `FileQueueModelTests`).
@Test func anAllCodeDocumentIsNotAnEmptyReplyEvenThoughNothingWasEverEmitted() async throws {
    let translator = Translator(client: FakeLLMClient(responses: []))
    let outcome = try await translator.translate(
        text: "```sh\nls -la\n```", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900)
    #expect(outcome.timeToFirstTokenMS == nil)   // the signal on its own says «nothing emitted»
    #expect(outcome.modelChunkCount == 0)        // …but nothing was ever asked of the model
    #expect(outcome.isEmptyReply == false)
}

/// The other half, so the property cannot be satisfied by a constant `false`: a document the
/// model *was* asked about, which answered nothing, is an empty reply.
@Test func aModelBoundChunkThatEmittedNothingIsAnEmptyReply() async throws {
    let translator = Translator(client: FakeLLMClient(responses: [""]))
    let outcome = try await translator.translate(
        text: "Одна строка прозы.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900)
    #expect(outcome.timeToFirstTokenMS == nil)
    #expect(outcome.modelChunkCount == 1)
    #expect(outcome.isEmptyReply)
}

/// And an ordinary run is neither.
@Test func anOrdinaryRunIsNotAnEmptyReply() async throws {
    let translator = Translator(client: FakeLLMClient(responses: ["Перевод."]))
    let outcome = try await translator.translate(
        text: "Одна строка прозы.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900)
    #expect(outcome.isEmptyReply == false)
}

// MARK: - The streaming twin reads lines the way `clean()` does

/// The fence check ran on `trimmingCharacters(in: .whitespaces)`, and that set excludes line
/// terminators — so a reply arriving as `"\n```"` did not look like a fence, the whole-answer
/// unwrap was skipped, and literal fence markers shipped into the translation along with a
/// phantom `codeBlock` diff. The buffered `clean()` path trims first and got this right.
///
/// The reply is cut into two events on purpose. Per character, the leading `"\n"` completes a
/// first line before the backticks arrive, and the decision is taken elsewhere — that is the
/// *other* half of the same finding (the streaming decision runs on the untrimmed buffer) and
/// it is not fixed here. Multi-character events are what the `LLMClient` contract actually
/// allows, so this is the shape the fence check has to survive.
@Test func aReplyOpeningWithANewlineAndAFenceIsStillUnwrapped() async throws {
    let fake = FakeLLMClient(responses: ["\n```\nПривет, мир.\n```"],
                             tokenizer: { _ in ["\n```", "\nПривет, мир.\n```"] })
    let collector = TokenCollector()
    let outcome = try await Translator(client: fake).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: collector.onToken)

    #expect(outcome.final == "Привет, мир.")
    #expect(!outcome.final.contains("```"), "fence markers reached the translation")
    #expect(outcome.markupDiffs.isEmpty, "a phantom codeBlock diff was reported")
    #expect(collector.text == outcome.final)
}

/// The same reply without the leading newline, so the test above is about the newline and not
/// about the unwrap.
@Test func aReplyOpeningWithAFenceIsUnwrapped() async throws {
    let fake = FakeLLMClient(responses: ["```\nПривет, мир.\n```"])
    let outcome = try await Translator(client: fake).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900)
    #expect(outcome.final == "Привет, мир.")
}

/// A CRLF reply's preamble, through the streaming path rather than through `clean()` directly.
/// `firstIndex(of: "\n")` never matched the single `Character` `"\r\n"`, so the decision was
/// never taken and the preamble streamed as content — into `final`, and into the pane.
@Test func aCRLFPreambleIsStrippedOnTheStreamingPathToo() async throws {
    let fake = FakeLLMClient(responses: ["Here is the translation:\r\nПривет, мир."])
    let collector = TokenCollector()
    let outcome = try await Translator(client: fake).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: collector.onToken)

    #expect(outcome.final == "Привет, мир.")
    #expect(!outcome.final.contains("Here is"), "the preamble reached the translation")
    #expect(collector.text == outcome.final)
}

// MARK: - The stream and the buffered path agree at the edges

/// The defect. Every buffered path ends at `ResponseCleaner.clean`, which trims both edges; the
/// incremental path returned `collected` untrimmed. So a chunk reply ending in a newline kept
/// it, and `final` gained a blank line the same reply produced nowhere else — with the markup
/// diff then reporting a phantom «added paragraphBreak» on a faithful translation. Which path a
/// chunk took depended on token timing, so the output bytes did too.
@Test func achunkReplyEndingInANewlineDoesNotAddABlankLineToFinal() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс",                       // the term-list call
        "Первый абзац.\nВторая строка.\n",          // multi-line, no preamble → incremental
        "Второй абзац.",
    ])
    let collector = TokenCollector()
    let outcome = try await Translator(client: fake).translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onToken: collector.onToken)

    #expect(outcome.final == "Первый абзац.\nВторая строка.\n\nВторой абзац.")
    #expect(!outcome.final.contains("\n\n\n"), "a blank line was added that the reply never had")
    #expect(outcome.markupDiffs.isEmpty, "a phantom paragraph break was reported")
    #expect(collector.text == outcome.final)
}

/// The same reply on a *buffered* path, so the assertion above is about the edges and not about
/// the reply. A single-line reply never goes incremental, and `clean()` has always trimmed it.
@Test func aBufferedChunkReplyEndingInANewlineIsTrimmedAsItAlwaysWas() async throws {
    let fake = FakeLLMClient(responses: ["resource => ресурс", "Первый.\n", "Второй."])
    let outcome = try await Translator(client: fake).translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.final == "Первый.\n\nВторой.")
}

/// Interior whitespace is *not* the trailing edge and must survive. The preamble branch trimmed
/// `rest` at both ends, so a single event spanning the preamble's newline and ending in a space
/// lost that space — legal per the `LLMClient` contract, impossible to reach with a
/// character-per-token fake, and delivered for real by any batching server or proxy.
@Test func aSpaceAtTheEndOfAnEventIsKeptWhenMoreContentFollows() async throws {
    let fake = FakeLLMClient(
        responses: ["Here is the translation:\nПривет мир"],
        tokenizer: { _ in ["Here is the translation:\nПривет ", "мир"] })
    let collector = TokenCollector()
    let outcome = try await Translator(client: fake).translate(
        text: "Hello world", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: collector.onToken)

    #expect(outcome.final == "Привет мир")
    #expect(collector.text == outcome.final)
}

/// The leading edge, character by character — the shape the fake produces by default and the
/// one the streaming decision actually got wrong. `clean()` trims before it decides anything;
/// the twin did not, so `"\n"` gave `firstLine == ""`, which is not a preamble, and the whole
/// buffer streamed as content with the preamble in it.
@Test func areplyBeginningWithANewlineStillHasItsPreambleStripped() async throws {
    let fake = FakeLLMClient(responses: ["\nHere is the translation:\nПривет, мир."])
    let collector = TokenCollector()
    let outcome = try await Translator(client: fake).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: collector.onToken)

    #expect(outcome.final == "Привет, мир.")
    #expect(collector.text == outcome.final)
}

/// The fence half of the same finding, now reachable character by character rather than only
/// with a hand-cut event.
@Test func areplyBeginningWithANewlineAndAFenceIsUnwrappedCharacterByCharacter() async throws {
    let fake = FakeLLMClient(responses: ["\n```\nПривет, мир.\n```"])
    let outcome = try await Translator(client: fake).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900)
    #expect(outcome.final == "Привет, мир.")
    #expect(outcome.markupDiffs.isEmpty)
}

/// `emit` filtered only `isEmpty`, so a whitespace-only first emission stamped
/// `timeToFirstTokenMS`. The pane stayed blank — `TranslationViewModel` reads a whitespace-only
/// piece as a chunk separator and writes nothing — while the empty-reply guard, which is that
/// stamp, passed. «Готово» over an empty pane.
@Test func awhitespaceOnlyReplyLeavesTimeToFirstTokenNil() async throws {
    let fake = FakeLLMClient(responses: ["   \n  \n "])
    let collector = TokenCollector()
    let outcome = try await Translator(client: fake).translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: collector.onToken)

    #expect(outcome.timeToFirstTokenMS == nil, "invisible content must not read as an answer")
    #expect(outcome.isEmptyReply, "and the models must be able to call it what it is")
    #expect(collector.text.isEmpty)
}

// MARK: - Cancellation, between the loop and the post-loop emit

/// A cancelled run must not deliver the chunk it was cancelled inside.
///
/// `AsyncThrowingStream` *finishes* on cancellation instead of throwing — this project's rule —
/// so the token loop exited normally with a partial buffer, and the code after it cleaned that
/// buffer, restored inline spans into it, and handed it to `onToken` as a completed chunk. Only
/// then did the caller's own check throw. The existing cancellation test passes without this
/// guard because its cancel lands before the first token ever arrives: true of that fixture,
/// not of the mechanism it names.
///
/// The cancel is triggered from the fake's own per-token hook rather than from a sleep, so
/// «after the first token» is a fact and not a guess — and the hook then **holds the stream
/// open** until it is cancelled, so the run cannot finish out from under the assertion.
///
/// The hold is not belt-and-braces. An earlier version signalled and returned, leaving the
/// remaining 200 ms-per-token pieces to race the test's own resumption; it was green locally and
/// **red on CI**, where the run completed first and the cancellation landed on nothing.
/// `QueueClient.holdCallAtIndex` records the same lesson from the other model.
@MainActor @Test func cancellingAfterTheFirstTokenDeliversNoChunkAtAll() async throws {
    let firstToken = AsyncStream<Int>.makeStream()
    let fake = FakeLLMClient(
        // Single-line and short, so the chunk stays on the buffered path all the way to the
        // post-loop emit — the code this guard protects.
        responses: ["Привет, мир"],
        delayPerToken: .milliseconds(1),
        onTokenYielded: { index in
            guard index == 0 else { return }
            firstToken.continuation.yield(index)
            // Held until the cancellation aborts it. A minute cannot be lost — the consumer
            // stops the moment the run is cancelled — and cannot be raced either.
            try? await Task.sleep(for: .seconds(60))
        })

    let received = TokenCollector()
    let run = Task {
        try await Translator(client: fake).translate(
            text: "Hello, world", target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
            onToken: received.onToken)
    }

    var iterator = firstToken.stream.makeAsyncIterator()
    _ = await iterator.next()
    run.cancel()

    await #expect(throws: CancellationError.self) { _ = try await run.value }
    #expect(received.text.isEmpty, "a cancelled chunk was handed to onToken as if it had finished")
}
