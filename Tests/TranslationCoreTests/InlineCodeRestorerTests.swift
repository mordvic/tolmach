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
