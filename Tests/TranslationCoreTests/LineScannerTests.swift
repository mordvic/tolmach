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
