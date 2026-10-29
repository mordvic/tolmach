// Tests/TranslatorAppTests/ChangeBarsTests.swift
//
// What a правка leaves to see beyond the underline (openspec improve-change-mark-legibility):
// change bars in the pane's gutter, carets under pure removals, the gutter's click, the
// announcement a removal makes — driven against a real TextKit 1 view built the way the pane
// builds it, `CodeBlockTextView(textKit1Inset:)` at {3, 8}, so the gutter is the pane's own.
import AppKit
import Foundation
import MarkupKit
import Testing
@testable import TranslationCore
@testable import TranslatorApp

@MainActor
private func paneView(source: String, result: String, detail: Bool = false,
                      width: CGFloat = 400) -> (view: CodeBlockTextView, changes: ChangeSet) {
    let changes = TextDiff.changes(source: source, result: result)
    let view = CodeBlockTextView(textKit1Inset: NSSize(width: 3, height: 8))
    view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, showsChangeDetail: detail, to: view)
    view.layoutManager?.ensureLayout(for: view.textContainer!)
    return (view, changes)
}

/// The line fragment (container coordinates) the first occurrence of `text` sits on.
@MainActor
private func line(of text: String, in view: CodeBlockTextView) -> NSRect {
    let range = (view.textStorage!.string as NSString).range(of: text)
    let glyph = view.layoutManager!.glyphIndexForCharacter(at: range.location)
    return view.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
}

@MainActor
private func covered(_ rect: NSRect, by bars: [ChangeBars.Bar]) -> Bool {
    bars.contains { $0.top <= rect.minY && rect.maxY <= $0.bottom }
}

private let barsSource = """
    Первая строка без изменений.

    Если что-то непонятно пишите в чат.

    Короче говоря проект идёт нормально но есть проблемы с тестами которые надо решить \
    побыстрее, и ещё нужно обновить документацию к выпуску.
    """
private let barsResult = """
    Первая строка без изменений.

    Если что-то непонятно, пишите в чат.

    В целом проект идёт по плану, но тесты пока нестабильны, их нужно исправить в первую \
    очередь, а документацию к выпуску обновить до пятницы.
    """

// MARK: - Bars

@MainActor @Test func aLineWhoseOnlyChangeIsACommaGetsABar() {
    let (view, changes) = paneView(source: barsSource, result: barsResult)
    #expect(changes.changes.contains { $0.inserted == "," })
    #expect(covered(line(of: "Если что-то", in: view), by: view.changeBars()))
}

@MainActor @Test func anUnchangedLineGetsNoBar() {
    let (view, _) = paneView(source: barsSource, result: barsResult)
    #expect(!covered(line(of: "Первая строка", in: view), by: view.changeBars()))
}

@MainActor @Test func aRewrittenBlockGetsOneContinuousBarOverAllItsLines() {
    let (view, changes) = paneView(source: barsSource, result: barsResult)
    guard let block = changes.changes.firstIndex(where: { $0.scope == .block }) else {
        Issue.record("the fixture's last paragraph must be rewritten past the threshold"); return
    }
    let first = line(of: "В целом", in: view)
    let last = line(of: "пятницы", in: view)
    #expect(last.minY > first.minY, "the rewritten paragraph must wrap for this to mean anything")
    let spanning = view.changeBars().filter { $0.firstChange == block }
    #expect(spanning.count == 1)
    #expect(spanning.first.map { $0.top <= first.minY && last.maxY <= $0.bottom } == true)
}

@MainActor @Test func theRemovedParagraphInChangesGetsItsOwnContinuousBar() {
    let (view, _) = paneView(source: barsSource, result: barsResult, detail: true)
    let old = line(of: "Короче", in: view)
    let new = line(of: "В целом", in: view)
    let bars = view.changeBars()
    #expect(covered(old, by: bars) && covered(new, by: bars))
    // Two spans, not one bar over both: the struck paragraph and its replacement are drawn as
    // two blocks, and a bar that ran through both would hide where one ends.
    #expect(bars.filter { $0.top <= old.minY && new.maxY <= $0.bottom }.isEmpty)
}

@MainActor @Test func theBarsDoNotMoveTheText() {
    // The bars are drawn in the gutter, not laid out: the first glyph sits where it does in the
    // same view with no change set at all.
    let (marked, _) = paneView(source: barsSource, result: barsResult)
    let clean = CodeBlockTextView(textKit1Inset: NSSize(width: 3, height: 8))
    clean.frame = marked.frame
    RenderedTextView.Coordinator().apply(text: barsResult, font: .default, rendersMarkup: true,
                                         isStreaming: false, to: clean)
    clean.layoutManager?.ensureLayout(for: clean.textContainer!)
    let markedX = marked.layoutManager!.location(forGlyphAt: 0).x + marked.textContainerOrigin.x
    let cleanX = clean.layoutManager!.location(forGlyphAt: 0).x + clean.textContainerOrigin.x
    #expect(markedX == cleanX)
    #expect(marked.changeBarX == 1)
}

@MainActor @Test func theBarsAreDrawnInTheGutter() {
    // `drawsBackground` is false on this view, as in the app; a pixel of the bar's colour in the
    // gutter is what proves `drawBackground(in:)` runs anyway and draws there.
    let (view, _) = paneView(source: barsSource, result: barsResult)
    view.appearance = NSAppearance(named: .aqua)
    guard let bar = view.changeBars().first,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        Issue.record("no bar or no bitmap"); return
    }
    view.appearance!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let x = Int((view.changeBarX + CodeBlockTextView.changeBarWidth / 2) * scale)
    let y = Int((view.textContainerOrigin.y + (bar.top + bar.bottom) / 2) * scale)
    let pixel = rep.colorAt(x: x, y: y)
    #expect((pixel?.alphaComponent ?? 0) > 0.5)
    // And nothing to the right of the gutter at that height but the text's own glyphs.
    #expect(view.changeBarX + CodeBlockTextView.changeBarWidth
            < view.textContainerOrigin.x + view.textContainer!.lineFragmentPadding)
}

// MARK: - The gutter's click

@MainActor @Test func aClickOnABarOpensItsLinesFirstChange() {
    let (view, changes) = paneView(source: barsSource, result: barsResult)
    let comma = changes.changes.firstIndex { $0.inserted == "," }!
    let fragment = line(of: "Если что-то", in: view)
    let point = NSPoint(x: view.changeBarX + 1, y: view.textContainerOrigin.y + fragment.midY)
    #expect(view.changeIndex(inGutterAt: point) == comma)
    // Off the gutter the same height is text, and the gutter answers nothing.
    #expect(view.changeIndex(inGutterAt: NSPoint(x: 40, y: point.y)) == nil)
    let unchanged = line(of: "Первая строка", in: view)
    #expect(view.changeIndex(inGutterAt: NSPoint(x: point.x,
                                                 y: view.textContainerOrigin.y + unchanged.midY)) == nil)
}

@MainActor @Test func aClickOnARewrittenBlocksTextDoesNotOpenItsCard() {
    let (view, changes) = paneView(source: barsSource, result: barsResult)
    let block = changes.changes.first { $0.scope == .block }!
    let words = changes.changes.first { $0.scope == .words }!
    #expect(!ChangeBars.clickOnTextOpensCard(for: block))
    #expect(ChangeBars.clickOnTextOpensCard(for: words))
    // Driven through the view: the cursor does not move for a click on the block's text.
    var selected: [Int] = []
    view.onChangeSelected = { selected.append($0) }
    let fragment = line(of: "В целом", in: view)
    view.reportClick(at: NSPoint(x: view.textContainerOrigin.x + 30,
                                 y: view.textContainerOrigin.y + fragment.midY))
    #expect(selected.isEmpty)
}

// MARK: - Pure removals

private let removalSource = "Мы закончили закончили миграцию базы."
private let removalResult = "Мы закончили миграцию базы."

@MainActor @Test func steppingToAPureRemovalSelectsTheGap() {
    let (view, _) = paneView(source: removalSource, result: removalResult)
    let range = RenderedTextView.Coordinator.range(ofChange: 0, in: view)
    #expect(range.map { (view.textStorage!.string as NSString).substring(with: $0) } == " ")
}

@MainActor @Test func steppingToAPureRemovalInChangesSelectsTheStruckWords() {
    let (view, _) = paneView(source: removalSource, result: removalResult, detail: true)
    let range = RenderedTextView.Coordinator.range(ofChange: 0, in: view)
    #expect(range.map { (view.textStorage!.string as NSString).substring(with: $0) } == "закончили")
}

@MainActor @Test func aPureRemovalGetsOneCaretUnderItsGapInResultAndNoneInChanges() {
    let (view, _) = paneView(source: removalSource, result: removalResult)
    let carets = view.removalCarets()
    #expect(carets.count == 1)
    let layout = view.layoutManager!
    let gap = (view.textStorage!.string as NSString).range(of: " миграцию")
    let box = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange:
        NSRange(location: gap.location, length: 1), actualCharacterRange: nil),
        in: view.textContainer!)
    #expect(abs((carets.first?.apex.x ?? 0) - (view.textContainerOrigin.x + box.midX)) < 0.5)
    let (detail, _) = paneView(source: removalSource, result: removalResult, detail: true)
    #expect(detail.removalCarets().isEmpty)
}

@Test func theCaretIsAChevronUnderTheBaselineWeightedLikeTheUnderline() {
    let small = ChangeBars.caret(gapMidX: 10, baseline: 20, fontSize: 13)
    #expect(small.apex == NSPoint(x: 10, y: 21.5))
    #expect(abs((small.right.x - small.left.x) - 13 * 0.42) < 0.001)
    #expect(small.left.y > small.apex.y, "the arms hang below the apex: it points up at the gap")
    #expect(small.lineWidth == 1.4)
    #expect(ChangeBars.caret(gapMidX: 0, baseline: 0, fontSize: 22).lineWidth == 2)
    #expect(ChangeBars.caret(gapMidX: 0, baseline: 0, fontSize: 13, increasedContrast: true)
        .lineWidth == 2)
    // Never narrower than 5 pt, which is what keeps it findable at 11 pt.
    let tiny = ChangeBars.caret(gapMidX: 0, baseline: 0, fontSize: 11)
    #expect(tiny.right.x - tiny.left.x == 5)
}

@Test func aPureRemovalIsAnnouncedWithTheRemovedWordsAndNothingElseIs() {
    let changes = TextDiff.changes(source: removalSource, result: removalResult).changes
    #expect(ChangeAnnouncement.text(for: changes[0]) == "Удалено: закончили")
    #expect(ChangeCard.of(changes[0]) == ChangeCard(removed: "закончили", inserted: nil))
    let substitution = TextDiff.changes(source: "Отчет готов.", result: "Отчёт готов.").changes[0]
    #expect(ChangeAnnouncement.text(for: substitution) == nil)
}

// MARK: - The copy path

@MainActor @Test func theMarkedResultHoldsExactlyTheCleanRenderingsCharacters() {
    // Bars and carets are drawn, the gap anchor is an attribute: «Результат» adds no character,
    // so a drag-selection copy of it carries the result's own text and nothing the marks drew.
    let (view, _) = paneView(source: barsSource, result: barsResult)
    let clean = MarkdownToAttributed.rendering(of: barsResult, config: ContentFont.default.markdownConfig)
    #expect(view.textStorage!.string == clean.attributed.string)
}

// MARK: - The panel

@MainActor
private func panelView(source: String, result: String) -> (view: PanelReplyTextView, changes: ChangeSet) {
    let changes = TextDiff.changes(source: source, result: result)
    let view = PanelReplyTextView(textKit1Inset: RenderedReplyView.inset,
                                  lineFragmentPadding: RenderedReplyView.lineFragmentPadding)
    view.clipsToBounds = false
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    let rendering = RenderedReplyView.Coordinator().rendering(
        of: result, config: ContentFont.default.markdownConfig, rendersMarkup: true,
        changes: changes, detail: .result)
    view.textStorage?.setAttributedString(rendering.attributed)
    view.changeSet = changes
    view.layoutManager?.ensureLayout(for: view.textContainer!)
    return (view, changes)
}

@MainActor @Test func thePanelsBarsStandLeftOfItsTextAndTheTextDoesNotMove() {
    // The reply's inset and padding are zero by measurement (`RenderedReplyView.inset`): the
    // rendered reply starts on the pixel the streamed text did. The bars must not change that —
    // they stand at x = −7, in the panel's padding.
    let (view, _) = panelView(source: barsSource, result: barsResult)
    #expect(RenderedReplyView.inset == .zero && RenderedReplyView.lineFragmentPadding == 0)
    #expect(view.drawsChangeBarsOutsideBounds)
    #expect(view.changeBarX == -7)
    #expect(view.changeBarX + CodeBlockTextView.changeBarWidth < 0)
    #expect(!view.changeBars().isEmpty)
    #expect(view.layoutManager!.location(forGlyphAt: 0).x + view.textContainerOrigin.x == 0)
    // The bar is as far from the text in the panel as in the window: 4.5 pt from its right edge.
    let (pane, _) = paneView(source: barsSource, result: barsResult)
    let paneGap = pane.textContainerOrigin.x + pane.textContainer!.lineFragmentPadding
        - (pane.changeBarX + CodeBlockTextView.changeBarWidth)
    let panelGap = 0 - (view.changeBarX + CodeBlockTextView.changeBarWidth)
    #expect(paneGap == panelGap)
}

@MainActor @Test func inThePanelARewrittenBlocksTextStillOpensItsCard() {
    // The panel's bars are outside the reply's view, where no click reaches it, so the text is
    // the only route to a rewritten block's card there — the window's rule would leave it none.
    let (view, changes) = panelView(source: barsSource, result: barsResult)
    let block = changes.changes.firstIndex { $0.scope == .block }!
    #expect(ChangeBars.clickOnTextOpensCard(for: changes.changes[block], barsAreClickable: false))
    #expect(view.changeIndex(inGutterAt: NSPoint(x: -5, y: 10)) == nil)
    var selected: [Int] = []
    view.onChangeSelected = { selected.append($0) }
    let fragment = line(of: "В целом", in: view)
    view.reportClick(at: NSPoint(x: 30, y: view.textContainerOrigin.y + fragment.midY))
    #expect(selected == [block])
}
