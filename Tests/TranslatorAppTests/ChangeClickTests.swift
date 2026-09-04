// Tests/TranslatorAppTests/ChangeClickTests.swift
//
// The popover's click side (issue #89, phase 2): `CodeBlockTextView.changeIndex(at:)` and
// `reportClick(at:)`, driven directly against a real, marked text view — this environment
// cannot simulate the mouse-drag gesture a genuine click-vs-drag distinction needs
// (`docs/reference/TESTING.md`), so these are exercised the way `mouseDown(with:)` would call
// them once it has confirmed a plain click, not through a synthetic `NSEvent`.
import AppKit
import Foundation
import MarkupKit
import Testing
@testable import TranslationCore
@testable import TranslatorApp

/// The same TextKit 1 triple `RenderedMarkupTests`/`ChangeMarksPaneTests` build by hand.
@MainActor
private func scratchTextView() -> CodeBlockTextView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: 400,
                                                 height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    return CodeBlockTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                             textContainer: container)
}

@MainActor
private func markedView(source: String, result: String) -> (view: CodeBlockTextView,
                                                              changes: ChangeSet) {
    let changes = TextDiff.changes(source: source, result: result)
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, showsChangeDetail: false, to: view)
    view.layout()
    return (view, changes)
}

/// The midpoint of where change `index` was actually drawn — read back the same way
/// `RenderedTextView.Coordinator.select(change:in:)` does, so this cannot disagree with what a
/// reader would click.
@MainActor
private func point(ofChange index: Int, in view: CodeBlockTextView) -> NSPoint? {
    guard let range = RenderedTextView.Coordinator.range(ofChange: index, in: view),
          let layoutManager = view.layoutManager, let container = view.textContainer else {
        return nil
    }
    let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    rect.origin.x += view.textContainerOrigin.x
    rect.origin.y += view.textContainerOrigin.y
    return NSPoint(x: rect.midX, y: rect.midY)
}

@MainActor @Test func changeIndexAtAPointInsideAMarkFindsThatChange() {
    let source = "Отчет за август готов."
    let result = "Отчёт за август готов."
    let (view, changes) = markedView(source: source, result: result)
    #expect(changes.count == 1)
    guard let point = point(ofChange: 0, in: view) else {
        Issue.record("expected the mark to be locatable")
        return
    }
    #expect(view.changeIndex(at: point) == 0)
}

@MainActor @Test func changeIndexAtAPointOutsideAnyMarkIsNil() {
    let source = "Отчет за август готов."
    let result = "Отчёт за август готов."
    let (view, _) = markedView(source: source, result: result)
    // The document's very last character — the trailing full stop, never part of a mark.
    let length = view.textStorage?.length ?? 0
    guard length > 0, let layoutManager = view.layoutManager,
          let container = view.textContainer else {
        Issue.record("expected a non-empty storage")
        return
    }
    let lastGlyph = layoutManager.glyphRange(
        forCharacterRange: NSRange(location: length - 1, length: 1), actualCharacterRange: nil)
    var rect = layoutManager.boundingRect(forGlyphRange: lastGlyph, in: container)
    rect.origin.x += view.textContainerOrigin.x
    rect.origin.y += view.textContainerOrigin.y
    #expect(view.changeIndex(at: NSPoint(x: rect.midX, y: rect.midY)) == nil)
}

@MainActor @Test func reportClickInvokesOnChangeSelectedWithTheChangesIndex() {
    let source = "Первый абзац неверен. Второй абзац неверен тоже."
    let result = "Первый абзац исправлен. Второй абзац исправлен тоже."
    let (view, changes) = markedView(source: source, result: result)
    #expect(changes.count == 2)
    var selected: [Int] = []
    view.onChangeSelected = { selected.append($0) }
    guard let firstPoint = point(ofChange: 0, in: view),
          let secondPoint = point(ofChange: 1, in: view) else {
        Issue.record("expected both marks to be locatable")
        return
    }
    view.reportClick(at: firstPoint)
    view.reportClick(at: secondPoint)
    #expect(selected == [0, 1])
}

@MainActor @Test func reportClickOffAnyMarkDoesNotInvokeTheCallback() {
    let source = "Отчет за август готов."
    let result = "Отчёт за август готов."
    let (view, _) = markedView(source: source, result: result)
    // The trailing full stop — never part of a mark, the same point
    // `changeIndexAtAPointOutsideAnyMarkIsNil` uses. `(0, 0)` would not do here: the change
    // this fixture marks is the document's very first word, so that point is *inside* it.
    guard let layoutManager = view.layoutManager, let container = view.textContainer,
          let length = view.textStorage?.length, length > 0 else {
        Issue.record("expected a non-empty storage")
        return
    }
    let lastGlyph = layoutManager.glyphRange(
        forCharacterRange: NSRange(location: length - 1, length: 1), actualCharacterRange: nil)
    var rect = layoutManager.boundingRect(forGlyphRange: lastGlyph, in: container)
    rect.origin.x += view.textContainerOrigin.x
    rect.origin.y += view.textContainerOrigin.y
    var selected: [Int] = []
    view.onChangeSelected = { selected.append($0) }
    view.reportClick(at: NSPoint(x: rect.midX, y: rect.midY))
    #expect(selected.isEmpty)
}
