// Tests/TranslationCoreTests/ResponseCleanerTests.swift
import Testing
@testable import TranslationCore

@Test func stripsLeadingPreambleLine() {
    let cleaned = ResponseCleaner.clean("Here is the translation:\nПривет, мир.")
    #expect(cleaned.text == "Привет, мир.")
    #expect(cleaned.strippedPreamble != nil)
}

@Test func stripsMarkdownEmphasizedPreamble() {
    let cleaned = ResponseCleaner.clean("**Translation:**\nHallo Welt.")
    #expect(cleaned.text == "Hallo Welt.")
}

@Test func unwrapsWholeAnswerCodeFence() {
    let cleaned = ResponseCleaner.clean("```\nMerely wrapped prose.\n```")
    #expect(cleaned.text == "Merely wrapped prose.")
    #expect(cleaned.unwrappedCodeFence)
}

@Test func allowFenceUnwrapTrueStillUnwrapsWholeAnswerCodeFence() {
    // Same fixture as unwrapsWholeAnswerCodeFence, but with the parameter passed
    // explicitly, to pin that the default behaviour survives its introduction.
    let cleaned = ResponseCleaner.clean("```\nMerely wrapped prose.\n```", allowFenceUnwrap: true)
    #expect(cleaned.text == "Merely wrapped prose.")
    #expect(cleaned.unwrappedCodeFence)
}

@Test func aFenceOnlyChunkKeepsItsMarkersWhenUnwrapIsDisallowed() {
    // The chunk itself WAS a code block in its entirety (Chunker flushed the fence
    // alone to respect the character budget) — the model reproducing it verbatim
    // must not have its fence markers stripped, unlike the over-wrapped-prose case
    // above.
    let raw = "```bash\nprofile-server publish --strict\n```"
    let cleaned = ResponseCleaner.clean(raw, allowFenceUnwrap: false)
    #expect(cleaned.text == raw)
    #expect(cleaned.unwrappedCodeFence == false)
}

@Test func leavesLegitimateInnerCodeFenceAlone() {
    let raw = "Run this:\n\n```bash\nls -la\n```"
    let cleaned = ResponseCleaner.clean(raw)
    #expect(cleaned.text == raw)
    #expect(cleaned.unwrappedCodeFence == false)
}

@Test func aBareOneWordHeadingIsNotStrippedAsPreamble() {
    // A document may legitimately open with this word as a heading.
    let raw = "Перевод\n\nПервый абзац документа."
    let cleaned = ResponseCleaner.clean(raw)
    #expect(cleaned.text == raw)
    #expect(cleaned.strippedPreamble == nil)
}

@Test func aOneWordPreambleWithPunctuationIsStillStripped() {
    let cleaned = ResponseCleaner.clean("Перевод:\nПервый абзац документа.")
    #expect(cleaned.text == "Первый абзац документа.")
    #expect(cleaned.strippedPreamble != nil)
}

@Test func aReplyWrappedInTextMarkersIsContentNowThatThePromptsCarryNone() {
    // From 2026-08-10 to 2026-08-18 the cleaner unwrapped a whole-answer
    // <text>…</text> wrapper, because both user prompts handed the model its text
    // between those markers and the model sometimes echoed them back. The prompts
    // no longer carry markers (measured reason in `PromptBuilder.userPrompt(for:)`),
    // so a reply shaped like that can only be a verbatim reproduction of a source
    // that itself carries the lines — content, kept as written. This pins that the
    // unwrap is gone, not merely disabled.
    let cleaned = ResponseCleaner.clean("<text>\nGenuine content.\n</text>")
    #expect(cleaned.text == "<text>\nGenuine content.\n</text>")
}

// MARK: - CRLF replies

/// `firstIndex(of: "\n")` is a grapheme search, and the single `Character` `"\r\n"` is not
/// `"\n"` — so on a CRLF reply the search found nothing, the preamble was never even considered,
/// and «Here is the translation:» shipped in `final`.
@Test func apreambleIsStrippedFromACRLFReplyJustAsFromAnLFOne() {
    #expect(ResponseCleaner.clean("Here is the translation:\r\nПривет, мир.").text == "Привет, мир.")
    #expect(ResponseCleaner.clean("Here is the translation:\r\nПривет, мир.").strippedPreamble
            == "Here is the translation:")
    // Every terminator the engine recognises, not just the two common ones — the reply is the
    // model's bytes and `LineScanner` accepts the whole family.
    #expect(ResponseCleaner.clean("Вот перевод:\rПривет, мир.").text == "Привет, мир.")
    #expect(ResponseCleaner.clean("Вот перевод:\u{2028}Привет, мир.").text == "Привет, мир.")
}

/// `components(separatedBy: .newlines)` splits on unicode **scalars**, so `"\r\n"` came out as
/// two breaks with an empty line between them: the unwrap rejoined with `"\n"` and produced a
/// paragraph break that existed nowhere, plus a phantom «added» diff on a faithful translation.
@Test func theFenceUnwrapOfACRLFReplyInventsNoBlankLines() {
    let cleaned = ResponseCleaner.clean("```\r\nПервая строка\r\nВторая строка\r\n```")
    #expect(cleaned.unwrappedCodeFence)
    #expect(cleaned.text == "Первая строка\r\nВторая строка")
    #expect(!cleaned.text.contains("\n\n"), "a paragraph break was fabricated")
}

/// The LF case is unchanged, so the fix above is about the terminator and not about the unwrap.
@Test func theFenceUnwrapOfAnLFReplyIsUnchanged() {
    let cleaned = ResponseCleaner.clean("```\nПервая строка\nВторая строка\n```")
    #expect(cleaned.unwrappedCodeFence)
    #expect(cleaned.text == "Первая строка\nВторая строка")
}

/// A single-line reply is still never a preamble, whatever it says — the condition the old
/// `firstIndex` search expressed by failing to find a newline.
@Test func aSingleLineReplyIsNeverTreatedAsAPreamble() {
    #expect(ResponseCleaner.clean("Вот перевод:").text == "Вот перевод:")
    #expect(ResponseCleaner.clean("Вот перевод:").strippedPreamble == nil)
}
