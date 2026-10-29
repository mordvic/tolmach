// Tests/TranslatorAppTests/ChangeCardTests.swift
//
// `ChangeCard.of(_:)` — the popover's content, and its three shapes (issue #89).
import AppKit
import SwiftUI
import Testing
@testable import TranslationCore
@testable import TranslatorApp

private func change(removed: String, inserted: String,
                    scope: TextChange.Scope = .words) -> TextChange {
    TextChange(scope: scope, block: 0, insertedTokens: 0..<max(inserted.isEmpty ? 0 : 1, 0),
              removed: removed, inserted: inserted)
}

@Test func aSubstitutionShowsBothHalves() {
    let card = ChangeCard.of(change(removed: "Отчет", inserted: "Отчёт"))
    #expect(card.removed == "Отчет")
    #expect(card.inserted == "Отчёт")
}

@Test func aPureRemovalShowsOnlyWhatWasRemoved() {
    let card = ChangeCard.of(change(removed: ", пожалуйста,", inserted: ""))
    #expect(card.removed == ", пожалуйста,")
    #expect(card.inserted == nil)
}

@Test func aPureInsertionShowsOnlyWhatWasInserted() {
    let card = ChangeCard.of(change(removed: "", inserted: "уже"))
    #expect(card.removed == nil)
    #expect(card.inserted == "уже")
}

// MARK: - Size

private let rewrittenParagraph = String(repeating: "Короче говоря проект идёт нормально но есть "
    + "проблемы с тестами которые надо решить побыстрее. ", count: 4)

@MainActor
private func fitting(_ card: ChangeCard) -> CGSize {
    let host = NSHostingView(rootView: ChangeCardView(card: card))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
}

@MainActor @Test func aLongChangesCardWrapsAtThreeHundredTwentyPointsAndGrowsDown() {
    // Before 2026-10-29 `.fixedSize()` on both axes laid a 128-character change out on one line,
    // 733 pt wide; a 400-character rewrite would be wider than the screen.
    #expect(rewrittenParagraph.count > 350)
    let long = fitting(ChangeCard(removed: rewrittenParagraph, inserted: rewrittenParagraph))
    let short = fitting(ChangeCard(removed: "отчет", inserted: "отчёт"))
    #expect(long.width <= ChangeCardView.textWidth + 2 * ChangeCardView.padding + 1,
            "\(long)")
    // Wrapped, and the card grows to hold it: at 320 pt a 376-character half is eight or more
    // lines, so the two halves add at least fourteen lines' height to a one-word card's.
    let lineHeight = NSFont.systemFont(ofSize: NSFont.systemFontSize).boundingRectForFont.height
    #expect(long.height > short.height + 14 * lineHeight * 0.8, "\(long) against \(short)")
    // And a short change keeps a short card rather than a 320 pt one.
    #expect(short.width < ChangeCardView.textWidth)
}
