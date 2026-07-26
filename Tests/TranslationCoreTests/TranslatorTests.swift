import Testing
@testable import TranslationCore

private let multiChunkText = """
The resource is valid and the resource is published by the server. \
The server validates the resource before publishing the resource.

Another paragraph about the resource and the server, long enough to force a split \
so the resource and the server both recur across chunks.
"""

// CC-3 fixture: no blank line separates the list from the fence, which is legal
// Markdown, but `Chunker` always splits a fence into its own block regardless and
// rejoins every block with exactly "\n\n" — so the chunked text the model actually
// sees already has blank lines here that the source never had.
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
    #expect(outcome.final == outcome.translatedChunks.joined(separator: "\n\n"))
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
    // Reachability case from the review: Chunker flushes a fence alone into its own
    // chunk whenever the preceding prose already fills the budget. The model
    // reproducing that chunk verbatim is indistinguishable, to ResponseCleaner, from
    // the "model over-wrapped a plain prose reply" case it exists to fix — unless
    // Translator tells it the source chunk was itself entirely a fence.
    //
    // Ukrainian: recognised by NLLanguageRecognizer but absent from the nine
    // supported targets (see unrecognisedSourceLanguageSkipsTheGlossaryButStillTranslates),
    // so `detected` comes back nil and the term-list call is skipped — keeping the
    // FakeLLMClient response order simple, one response per chunk.
    let prose = String(repeating: "Сервер перевіряє ресурс перед публікацією ресурсу. ", count: 12)
    let fence = "```bash\nprofile-server publish --strict --out ./dist\n```"
    let doc = prose + "\n\n" + fence
    // Chosen so the fence doesn't fit alongside the prose in one chunk, forcing
    // Chunker to flush the prose as chunk 0 and the fence alone as chunk 1 — the
    // exact shape that made ResponseCleaner strip a real code block's markers.
    let maxCharacters = prose.trimmingCharacters(in: .whitespacesAndNewlines).count + 20
    let chunks = Chunker.chunk(doc, maxCharacters: maxCharacters)
    #expect(chunks.count == 2)
    #expect(chunks[1].containsCodeFence)
    #expect(chunks[1].text == fence)

    let fake = FakeLLMClient(responses: ["переклад абзацу", fence])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: doc, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: maxCharacters)
    #expect(outcome.chunks.count == 2)
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

@Test func aUserGlossaryTermInsideACodeFenceIsNotInjectedOrChecked() async throws {
    // CC-4: a user term that occurs only inside code must not reach the prompt —
    // it would contradict the "reproduce fenced code byte for byte" rule in the
    // same prompt — and must not surface as a GlossaryVerifier check either, since
    // a model that correctly leaves the fence untranslated would otherwise be
    // reported `.missing` for obeying the higher-priority rule.
    let text = "```bash\nrun --strict\n```"
    let glossary = Glossary(entries: [GlossaryEntry(term: "strict", translations: ["ru": "строгий"])])
    let fake = FakeLLMClient(responses: [text]) // model reproduces the fence verbatim
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
    // Collected from a @Sendable closure, so use a lock-free append via an actor-free box.
    final class Box: @unchecked Sendable { var text = "" }
    let box = Box()
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onToken: { box.text += $0 })
    #expect(outcome.chunks.count > 1)
    #expect(outcome.documentGlossary.isEmpty == false)
    // The glossary was built, yet none of its raw wire format reached the consumer.
    #expect(!box.text.contains("=>"))
    #expect(!box.text.contains("ресурс"))
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
    final class Box: @unchecked Sendable { var text = "" }
    let box = Box()
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onToken: { box.text += $0 })
    #expect(outcome.chunks.count > 1)
    #expect(box.text == outcome.final)
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
private final class TokenBox: @unchecked Sendable {
    var text = ""
    var callCount = 0
    func onToken(_ token: String) { text += token; callCount += 1 }
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
    let box = TokenBox()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: box.onToken)
    #expect(outcome.final == "First line of content.\nSecond line of content.\nThird line.")
    #expect(box.text == outcome.final)
    #expect(box.callCount > 1)
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
    let box = TokenBox()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: box.onToken)
    #expect(!box.text.contains("Here is the translation"))
    #expect(outcome.final == "First line of content.\nSecond line of content.")
    #expect(box.text == outcome.final)
    #expect(box.callCount > 1)
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
    let box = TokenBox()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: box.onToken)
    #expect(outcome.final == "Hello there, this spans multiple lines.\nSecond line here.")
    #expect(box.text == outcome.final)
    #expect(box.callCount == 1)
}

@Test func theStreamReconstructsExactlyWhatFinalContainsForASingleLineReply() async throws {
    // No "\n" ever appears in the reply, so the chunk never leaves buffering
    // and the stream ends before a delivery decision was ever made — the third
    // fallback path (alongside the buffered-fence path above), one `onToken`
    // call, and the third shape the invariant must hold on.
    let fake = FakeLLMClient(responses: ["Привет, мир."])
    let translator = Translator(client: fake)
    let box = TokenBox()
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onToken: box.onToken)
    #expect(outcome.final == "Привет, мир.")
    #expect(box.text == outcome.final)
    #expect(box.callCount == 1)
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
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.timeToFirstTokenMS != nil)
    let ttft = outcome.timeToFirstTokenMS ?? .infinity
    #expect(ttft > outcome.totalMS * 0.1)
    #expect(ttft < outcome.totalMS * 0.5)
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
    final class Box: @unchecked Sendable { var text = "" }
    let box = Box()

    let task = Task {
        try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            onToken: { box.text += $0 })
    }
    await waitFor(0) // call 0: the term-list call has just started
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    // Only the term-list call was ever issued: cancellation was caught by the
    // `Task.checkCancellation()` right after it, before the per-chunk loop began.
    #expect(fake.receivedMessages.count == 1)
    #expect(box.text.isEmpty)
}

@Test func cancellingDuringThePerChunkLoopThrowsInsteadOfReturningATruncatedDocument() async throws {
    let (onCallStart, waitFor) = makeCallStartSignal()
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "первый", "второй", "третий", "четвёртый",
    ], delayPerToken: .milliseconds(20), onCallStart: onCallStart)
    let translator = Translator(client: fake)
    final class Box: @unchecked Sendable { var text = "" }
    let box = Box()

    let task = Task {
        try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            onToken: { box.text += $0 })
    }
    await waitFor(1) // call 1: the first per-chunk translation call has just started
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    // A completed run issues 1 (term-list) call + one call per chunk. Computed
    // rather than hard-coded so this doesn't silently stop meaning anything if the
    // fixture or the chunker's split points change.
    let chunkCount = Chunker.chunk(multiChunkText, maxCharacters: 200).count
    #expect(chunkCount > 1) // otherwise call 1 wouldn't be a per-chunk call at all
    // Exactly 2 calls were made: the term-list call ran to completion, and the
    // second call — the first per-chunk translation, the one cancellation landed
    // inside — was the last one issued. None of the remaining chunk calls a
    // completed run would make ever happened, proving the loop stopped at the call
    // cancellation landed in rather than running to completion.
    #expect(fake.receivedMessages.count == 2)
    #expect(fake.receivedMessages.count < 1 + chunkCount)
    #expect(box.text.isEmpty) // no chunk had finished, so onToken never fired
}

// MARK: - CC-3: markupDiffs must compare against what the model was actually shown.
//
// `Chunker` normalises whitespace while assembling chunks — blocks are always
// rejoined with exactly "\n\n", and a block's trailing whitespace is trimmed away
// — so the text handed to the model already differs from the untouched source
// before translation even starts. A translation can only be judged against the
// document it was asked to reproduce, so `Translator` now diffs `final` against
// `chunks.map(\.text).joined(separator: "\n\n")`, not the raw source.
//
// Each helper call below feeds a model that echoes its input back perfectly. A
// perfect echo can produce a non-empty diff only if the baseline itself drifted
// from what the model saw — which is exactly the false-alarm bug being fixed.
private func assertPerfectEchoProducesNoMarkupDiffs(_ text: String, maxChunkCharacters: Int = 2000) async throws {
    let chunks = Chunker.chunk(text, maxCharacters: maxChunkCharacters)
    let fake = FakeLLMClient(responses: chunks.map(\.text))
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: maxChunkCharacters)
    #expect(outcome.markupDiffs.isEmpty)
}

@Test func perfectEchoOfFenceWithNoSurroundingBlankLinesProducesNoMarkupDiffs() async throws {
    // No blank line around the fence in the source; Chunker inserts one on both
    // sides when it rejoins blocks. Before the fix: 2 phantom paragraphBreak diffs.
    try await assertPerfectEchoProducesNoMarkupDiffs("Run the command below.\n```bash\nls -la\n```\nDone.\n")
}

@Test func perfectEchoOfExtraBlankLinesBetweenParagraphsProducesNoMarkupDiffs() async throws {
    // Chunker collapses any run of blank lines between blocks to exactly one, so a
    // source with two blank lines between paragraphs previously read as a dropped
    // paragraphBreak once compared to the (correctly) normalised chunk.
    try await assertPerfectEchoProducesNoMarkupDiffs("First paragraph.\n\n\nSecond paragraph.\n")
}

@Test func perfectEchoOfHardLineBreaksProducesNoMarkupDiffs() async throws {
    // Known, separate limitation recorded here rather than fixed in this round:
    // Chunker trims trailing whitespace off the *whole* assembled block, which
    // destroys the hard line break on a block's last line — "Line two" loses its
    // two trailing spaces before the model ever sees it. That is real content loss
    // in `final` relative to the original document, not merely a diffing artifact.
    // But a diff can only ever compare against what the model was shown, and once
    // the baseline is the (already lossy) chunked text, a perfect echo of it is
    // correctly not flagged as a translation-structure defect.
    try await assertPerfectEchoProducesNoMarkupDiffs("Line one  \nLine two  \n\nNext paragraph.\n")
}

@Test func perfectEchoOfAListWithAnIndentedFenceProducesNoMarkupDiffs() async throws {
    // Same block-boundary normalisation as the first case, on a list: the fence
    // forces a block split with no blank line in the source, which previously read
    // as the list itself being split apart by blank lines that were never there.
    try await assertPerfectEchoProducesNoMarkupDiffs(listWithIndentedFence)
}
