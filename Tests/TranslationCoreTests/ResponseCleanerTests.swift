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
