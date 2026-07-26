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
