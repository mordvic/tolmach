// Tests/TranslationCoreTests/LineScannerTests.swift
import Testing
@testable import TranslationCore

@Test(arguments: ["\n", "\r", "\r\n", "\u{85}", "\u{0B}", "\u{0C}", "\u{2028}", "\u{2029}"])
func everyMandatoryLineBreakEndsALine(_ terminator: String) {
    // The whole Unicode family, because a model normalises the exotic members to "\n"
    // in its reply: whichever one the source used, the two documents must scan into the
    // same lines or the markup diff invents a change. "\r\n" is one Swift `Character`
    // and must come out as ONE break, not two lines around an empty one.
    let text = "one\(terminator)two"
    let lines = LineScanner.scanLines(text)
    #expect(lines.map { String(text[$0.content]) } == ["one", "two"])
}

@Test func scannedLinesTileTheWholeStringWithNoBytesLost() {
    // Every consumer takes ranges into the source, so `end` must be the next line's
    // start with nothing skipped — that is what keeps the chunker byte-lossless.
    let text = "a\r\nb\n\nc\u{2028}"
    var cursor = text.startIndex
    for line in LineScanner.scanLines(text) {
        #expect(line.content.lowerBound == cursor)
        cursor = line.end
    }
    #expect(cursor == text.endIndex)
}

@Test(arguments: ["\n\n", "\r\n\r\n", "\r\r", "\r\n\n", "\n\r\n", "\u{2029}\u{2029}"])
func twoBareTerminatorsAreExactlyOneBlankLine(_ separator: String) {
    #expect(LineScanner.isExactlyOneBlankLine(separator))
}

@Test(arguments: ["", "\n", "\n\n\n", "\n   \n", " \n\n", "\n\n ", "\u{2028}"])
func anythingElseIsNotExactlyOneBlankLine(_ separator: String) {
    // A blank line carrying spaces is deliberately NOT one: merging across it would
    // have to reproduce those spaces from the model's reply instead of the source.
    #expect(!LineScanner.isExactlyOneBlankLine(separator))
}

// MARK: - Pieces: taking a document apart and putting it back

/// The property every caller of `pieces` depends on and none of them should have to check.
/// `InlineCodeRestorer` split on `"\n"` and rejoined with `"\n"`, which was lossless only by
/// accident — a lone `"\r"` survived because it stayed *inside* a line's content. Scanning
/// properly and rejoining with a chosen terminator would have normalised it, and `final` is
/// what gets written to the user's disk.
@Test func piecesPutBackTogetherAreTheDocumentTheyCameFrom() {
    for text in ["a\nb\nc", "a\nb\nc\n", "a\r\nb\r\nc\r\n", "a\rb\rc", "a\r\nb\nc\rd\u{2028}e",
                 "", "\n", "\r\n", "no terminator at all", "\n\n\n", "a\u{85}b\u{0C}c"] {
        let rebuilt = LineScanner.pieces(text).map { $0.content + $0.terminator }.joined()
        #expect(rebuilt == text, "round trip lost bytes for \(text.debugDescription)")
    }
}

/// The terminators come back as they were found, not as `"\n"`. Asserted separately from the
/// round trip because a `pieces` that returned one piece holding the whole document would pass
/// the round trip and be useless.
@Test func eachPieceCarriesTheTerminatorTheDocumentActuallyUsed() {
    #expect(LineScanner.pieces("a\r\nb\n") == [
        LineScanner.Piece(content: "a", terminator: "\r\n"),
        LineScanner.Piece(content: "b", terminator: "\n"),
    ])
    // The final line's terminator is empty rather than absent — that is how a caller tells a
    // document that ends with a break from one that does not.
    #expect(LineScanner.pieces("a\nb") == [
        LineScanner.Piece(content: "a", terminator: "\n"),
        LineScanner.Piece(content: "b", terminator: ""),
    ])
}

// MARK: - The first complete line, for a reader that has only part of one

/// `nil` means «not yet», which is the state a streaming buffer spends most of its time in.
@Test func thereIsNoFirstCompleteLineUntilATerminatorArrives() {
    #expect(LineScanner.firstCompleteLine("Here is the transl") == nil)
    #expect(LineScanner.firstCompleteLine("") == nil)
}

/// The reason this exists at all: `firstIndex(of: "\n")` is a grapheme search, and the single
/// `Character` `"\r\n"` is not `"\n"`. A CRLF reply therefore never reached the streaming
/// preamble decision and shipped its preamble as content.
@Test func aCarriageReturnLineFeedCompletesAFirstLineJustAsALineFeedDoes() {
    let crlf = LineScanner.firstCompleteLine("Here is the translation:\r\nПривет")
    #expect(crlf?.content == "Here is the translation:")
    #expect(crlf?.rest == "Привет")

    let lf = LineScanner.firstCompleteLine("Here is the translation:\nПривет")
    #expect(lf?.content == "Here is the translation:")
    #expect(lf?.rest == "Привет")

    // And the rest keeps its own bytes, so a caller rebuilding from it loses nothing.
    #expect(LineScanner.firstCompleteLine("a\rb\rc")?.rest == "b\rc")
}
