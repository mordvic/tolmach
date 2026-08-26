import Foundation
import Testing
@testable import TranslationCore

@Test func anEditedSpanIsRestoredToTheSourceBytes() {
    let source = "Выполните комманду `git comit --amend` и живите."
    let reply  = "Выполните команду `git commit --amend` и живите."
    #expect(InlineCodeRestorer.restore(reply: reply, source: source)
            == "Выполните команду `git comit --amend` и живите.")
}

@Test func anAddedSpanRestoresNothingBecauseAlignmentIsUnknowable() {
    // The model wrapped a word in backticks. Greedy N↔N would inject source content
    // into the wrong span — worse than no restore (spec §2.2, the equal-count gate).
    let source = "Run `npm instal` first."
    let reply  = "Run `npm` `install` first."
    #expect(InlineCodeRestorer.restore(reply: reply, source: source) == reply)
}

@Test func aLoneBacktickIsNotASpanInSourceOrReply() {
    // Parity is per line and unterminated openers emit nothing — the shared
    // definition (MarkupSkeleton.inlineCodeSpans), not a new regex.
    let source = "Don't use ` alone. Use `git status` here."
    let reply  = "Do not use ` alone. Use `git status!` here."
    // Source spans: [" alone. Use "]? — no: the FIRST backtick opens, the second
    // closes, so span 1 is " alone. Use " and "git status" sits outside. Whatever
    // the shared scan says, restore must follow it exactly — this test pins the
    // two agreeing, not a particular reading:
    let sourceSpans = source.split(separator: "\n", omittingEmptySubsequences: false)
        .flatMap { MarkupSkeleton.inlineCodeSpans(in: String($0)) }.map(\.content)
    let replySpans = reply.split(separator: "\n", omittingEmptySubsequences: false)
        .flatMap { MarkupSkeleton.inlineCodeSpans(in: String($0)) }.map(\.content)
    let restored = InlineCodeRestorer.restore(reply: reply, source: source)
    if sourceSpans.count == replySpans.count {
        let restoredSpans = restored.split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { MarkupSkeleton.inlineCodeSpans(in: String($0)) }.map(\.content)
        #expect(restoredSpans == sourceSpans)
    } else {
        #expect(restored == reply)
    }
}

@Test func multiLineRepliesRestoreAcrossLinesInDocumentOrder() {
    let source = "Первый `a b` спан.\nВторой `c d` спан."
    let reply  = "Первый `A-B` спан.\nВторой `C-D` спан."
    #expect(InlineCodeRestorer.restore(reply: reply, source: source)
            == "Первый `a b` спан.\nВторой `c d` спан.")
}

// MARK: - A lone CR inside a chunk is a line break, not a character

/// The defect, end to end. Splitting on `"\n"` alone made this chunk read as one long line, and
/// the backticks then paired *across* the CR into a span — `" tall\r"` — that exists in no other
/// layer. The reply's own span count happened to match, so the equal-count gate passed and the
/// real `` `code` `` span was overwritten with those bytes: the code destroyed, and a CR
/// injected into `final`.
///
/// `Chunker` produces such a chunk legitimately — only a blank line ends one, so a lone CR
/// inside a paragraph stays inside the chunk — and `MarkupSkeleton`, which shares `LineScanner`,
/// read the same bytes as one `inlineCode("code")` token. The two layers disagreed about the
/// document they were both looking at.
@Test func aLoneCarriageReturnInsideAChunkDoesNotPairBackticksAcrossIt() {
    let source = "Version 5` tall\r`code` here"
    // Two lines: `Version 5\` tall` carries an unterminated opener and yields nothing;
    // `` `code` here `` yields one span. One span in total, and it is the real one.
    #expect(InlineCodeRestorer.spans(of: source) == ["code"])
    // The layer that reports structure agrees, which is the property that was broken.
    #expect(MarkupSkeleton.tokens(of: source) == [.inlineCode("code")])
}

@Test func aLoneCarriageReturnChunkRestoresTheRealSpanAndNotTheSourcesLineBreak() {
    let source = "Version 5` tall\r`code` here"
    // The model normalised the CR to LF, which the rest of the pipeline expects, and edited the
    // span's contents — the measured failure mode the restore exists for.
    let reply = "Версия 5` высокая\n`код` здесь"

    let restored = InlineCodeRestorer.restore(reply: reply, source: source)

    #expect(restored == "Версия 5` высокая\n`code` здесь")
    #expect(!restored.contains("\r"), "no source line terminator may be spliced into a span")
    #expect(!restored.contains("tall"), "the phantom span's bytes must not reach the reply")
}

/// The other half of sharing the scanner: the reply is taken apart with the same discipline and
/// put back with its **own** terminators. Rejoining with `"\n"` would normalise a reply that
/// used CRLF — a byte change in `final`, which is what gets written to disk.
@Test func theReplysOwnLineTerminatorsSurviveARestore() {
    // Every terminator the engine recognises, and each one on a line that actually carries a
    // span — a reply with no spans returns early and would pin nothing about the rejoin.
    for terminator in ["\r\n", "\n", "\r", "\u{2028}", "\u{85}"] {
        let source = "первый `a` тут\(terminator)второй `b` там"
        let reply = "first `x` here\(terminator)second `y` there"

        let restored = InlineCodeRestorer.restore(reply: reply, source: source)

        #expect(restored == "first `a` here\(terminator)second `b` there",
                "the reply's own \(terminator.debugDescription) was not put back")
    }
}

/// And a restore that has nothing to do returns the reply byte for byte, terminators included.
@Test func aReplyWithNoSpansComesBackUntouched() {
    let reply = "первый\r\nвторой\rтретий\u{2028}четвёртый"
    #expect(InlineCodeRestorer.restore(reply: reply, source: "без кода") == reply)
}
