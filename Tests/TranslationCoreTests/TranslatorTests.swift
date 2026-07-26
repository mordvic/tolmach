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

@Test func cancellingMidStreamThrowsInsteadOfReturningATruncatedDocument() async throws {
    // A per-token delay is essential here: a fully-synchronous fake never suspends,
    // so cancel() would have no window in which to land before every response is
    // already buffered and consumed.
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "первый", "второй", "третий", "четвёртый",
    ], delayPerToken: .milliseconds(20))
    let translator = Translator(client: fake)

    let task = Task {
        try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    }
    // Long enough to be mid-way through the (delayed) term-list call, well short
    // of the ~5 calls (1 term-list + 4 chunks) a completed run would issue.
    try await Task.sleep(for: .milliseconds(80))
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(fake.receivedMessages.count < 5)
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
