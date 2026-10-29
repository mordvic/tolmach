// Sources/TranslatorApp/ChangeBars.swift
import AppKit
import MarkupKit
import TranslationCore

/// Where a правка's change bars and removal carets go, read from a TextKit 1 layout.
///
/// **Values, not drawing.** `CodeBlockTextView` draws what this answers; a test lays out a storage
/// and asks. Both are read from the storage's own attributes — `ChangeMarks.changeKey` and
/// `ChangeMarks.removedKey` — so a bar can never stand beside a line the marks do not, and the
/// bars cost the storage nothing: they are not characters, so no copy of any kind carries them.
enum ChangeBars {
    /// One bar, in text-container coordinates, and the change a click on it opens.
    struct Bar: Equatable {
        /// The line fragments it spans: `minY` to `maxY`. Only the vertical extent is the bar's
        /// own — its x is the view's gutter, which the view knows and this does not.
        let top: CGFloat
        let bottom: CGFloat
        /// The change whose marked text starts earliest on the bar's first line.
        let firstChange: Int
    }

    /// Every bar the storage calls for.
    ///
    /// A line holding a changed, inserted or removed run, or a removal's caret, gets a bar of its
    /// own. A rewritten block (`TextChange.Scope.block`) and a removed paragraph spliced into
    /// «Изменения» get **one continuous** bar over all their lines — they are one change each,
    /// and a row of segments would read as several.
    static func bars(in storage: NSAttributedString, layoutManager: NSLayoutManager,
                     container: NSTextContainer, changes: ChangeSet?) -> [Bar] {
        guard storage.length > 0 else { return [] }
        var lines: [CGFloat: Bar] = [:]
        var spans: [Bar] = []
        let all = NSRange(location: 0, length: storage.length)

        func collect(_ key: NSAttributedString.Key) {
            storage.enumerateAttribute(key, in: all, options: []) { value, range, _ in
                guard let index = value as? Int else { return }
                let glyphs = layoutManager.glyphRange(forCharacterRange: range,
                                                      actualCharacterRange: nil)
                guard glyphs.length > 0 else { return }
                var fragments: [NSRect] = []
                layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    fragments.append(rect)
                }
                guard let first = fragments.first, let last = fragments.last else { return }
                let isBlock = index < (changes?.changes.count ?? 0)
                    && changes?.changes[index].scope == .block
                let isRemovedParagraph = key == ChangeMarks.removedKey && fragments.count > 1
                if isBlock || isRemovedParagraph {
                    spans.append(Bar(top: first.minY, bottom: last.maxY, firstChange: index))
                    return
                }
                for fragment in fragments {
                    // The earliest change on a line wins the click: enumeration runs in storage
                    // order, so the first one recorded for a line is it.
                    if lines[fragment.minY] == nil {
                        lines[fragment.minY] = Bar(top: fragment.minY, bottom: fragment.maxY,
                                                   firstChange: index)
                    }
                }
            }
        }
        collect(ChangeMarks.changeKey)
        collect(ChangeMarks.removedKey)
        // A line inside a span is the span's; its own segment would draw a second bar over it.
        let segments = lines.values.filter { line in
            !spans.contains { $0.top <= line.top && line.bottom <= $0.bottom }
        }
        return (segments + spans).sorted { $0.top < $1.top }
    }

    /// The change a click at `y` (text-container coordinates) in the gutter opens, if any.
    static func change(atY y: CGFloat, in bars: [Bar]) -> Int? {
        bars.first { $0.top <= y && y < $0.bottom }?.firstChange
    }

    /// The caret under a pure removal's gap: a chevron pointing up at the gap, its apex just below
    /// the baseline, in view coordinates (flipped: y grows downward).
    ///
    /// 0.42 × the font's size wide (at least 5 pt), a 1.4 pt stroke and 2 pt from 17 pt — the
    /// underline's own weight break — so it stays the weight of the marks beside it. Looked at in
    /// renders at 11, 13, 22 and 32 pt (2026-10-29), not computed.
    struct Caret: Equatable {
        let left: NSPoint
        let apex: NSPoint
        let right: NSPoint
        let lineWidth: CGFloat
    }

    static func caret(gapMidX: CGFloat, baseline: CGFloat, fontSize: CGFloat,
                      increasedContrast: Bool = false) -> Caret {
        let width = max(5, fontSize * 0.42)
        let height = width * 0.55
        let apexY = baseline + 1.5
        return Caret(left: NSPoint(x: gapMidX - width / 2, y: apexY + height),
                     apex: NSPoint(x: gapMidX, y: apexY),
                     right: NSPoint(x: gapMidX + width / 2, y: apexY + height),
                     lineWidth: increasedContrast || fontSize >= 17 ? 2 : 1.4)
    }

    /// Whether a click on change `change`'s text opens its card.
    ///
    /// Not for a rewritten block where its bar can be clicked: nothing on its text is visibly
    /// marked — its bar is — so a card opening under a click meant to place the selection would
    /// be a surprise, and the gutter and ‹ › reach it instead. **In the hotkey panel the bars are
    /// drawn in the panel's padding, outside the reply's view, where no click reaches the view**
    /// (measured, 2026-10-29: AppKit routes a click by the subview's frame) — so there the text
    /// is the only route to a rewritten block's card, and it stays open.
    static func clickOnTextOpensCard(for change: TextChange, barsAreClickable: Bool = true) -> Bool {
        change.scope == .words || !barsAreClickable
    }
}
