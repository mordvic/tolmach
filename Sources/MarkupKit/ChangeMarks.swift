// Sources/MarkupKit/ChangeMarks.swift
import AppKit
import Foundation
import TranslationCore

/// What правка changed, drawn over the rendering it changed — an underline on every changed
/// range and, in «Изменения», the removed words struck through in front of the words that
/// replaced them.
///
/// Three properties are the whole of the design, and each is a decision:
///
/// - **The marks are located, not carried.** `TextChange` names a block and a run of tokens in
///   that block's *plain projection* (`MarkdownPlainText.plain(_:in:)`); the storage holds a
///   rendered document, or the raw Markdown, or plain prose. The two are reconciled here by
///   aligning `TextTokenizer` tokens — the same tokenizer the diff cut its own tokens with,
///   never a second one — so one change set marks every view of the same text. That is what
///   makes story 6 («the toggle must not cost me the marks») true rather than hoped for.
/// - **A mark that cannot be located is not drawn.** If the alignment does not consume the
///   whole projection, the block is left unmarked and the count is not touched. A guessed
///   range under a word that did not change is worse than no range: the user's only check on
///   this feature is that the underlines sit where they read a correction.
/// - **`apply` is pure, and the copy path never calls it.** It returns a new rendering, so the
///   clean one the RTF flavour is built from is still there, unmarked, byte for byte. That is
///   why «Скопировать» cannot put review marks in Word (story 10) — by construction, not by a
///   condition someone has to remember to restate.
public enum ChangeMarks {
    /// «Результат» or «Изменения»: the same underlines, and in the second the removed text
    /// spliced in as characters. Two documents, like «Разметка» and «Исходник» are.
    public enum Detail: String, Sendable, Equatable, CaseIterable {
        case result, changes
    }

    /// The change's index in `ChangeSet.changes`, on every character it marks — what the
    /// window's stepper enumerates to find the n-th change in the storage.
    ///
    /// A custom key rather than `.link` or a marker character: an attribute is invisible to
    /// the layout, survives the storage edits `.changes` makes, and is not something a copy
    /// can carry into another application.
    public static let changeKey = NSAttributedString.Key("tolmach.change")

    /// The change's index on the removed text «Изменения» splices in — and only there, never on
    /// the spaces around it.
    ///
    /// A key of its own rather than `changeKey`, because the stepper and the click read
    /// `changeKey` and must land on the *new* text of a substitution, not on the struck one
    /// before it; and rather than reading `.strikethroughStyle`, because the user's own
    /// `~~strike~~` is drawn with that attribute too and is not a change. The view reads it for
    /// the change bars, and the stepper falls back to it for a pure removal, which has nothing
    /// else in «Изменения».
    public static let removedKey = NSAttributedString.Key("tolmach.change.removed")

    /// Where the underline becomes `.thick`.
    ///
    /// 17 pt is the size at which the system's own text stops being «small», and a 1 pt line
    /// under 32 pt words is the failure story 16 names. **Looked at, not computed** (measurement
    /// protocol item 7, 2026-09-04): `renderChangesPreview` drew the marks at 13 and 22 pt in
    /// both appearances — `.single` under 13 pt text and `.thick` under 22 pt text each read as
    /// one line that belongs to its word, and a `.thick` line under 13 pt would be the weight of
    /// the strikethrough beside it. The break itself was not bisected; 17 stays as the system's
    /// own boundary.
    static let thickFromSize: CGFloat = 17

    /// The weight of every line a mark draws — the underline and, since 2026-10-29, the strike
    /// through removed text, so the two never disagree beside each other. `.thick` at every size
    /// under Increase Contrast: a hairline's weight is half of how visible it is, and the colour
    /// alone cannot give the «significantly higher» differentiation HIG asks of that setting.
    public static func underlineStyle(for baseSize: CGFloat,
                                      increasedContrast: Bool = false) -> NSUnderlineStyle {
        increasedContrast || baseSize >= thickFromSize ? .thick : .single
    }

    /// The pattern every change mark wears, on top of its weight: `.patternDot`.
    ///
    /// **Dotted everywhere, not only inside tables and lists — measured, 2026-09-04.** The
    /// design drew a solid accent line and reserved the dots for cells and list items, and
    /// named its own fallback: «if a screen says the mark and a link confuse, every mark becomes
    /// dotted». `Scripts/accent-contrast.swift` said it before a screen did — `linkColor`
    /// against the blue accent is **1.49:1** in the light appearance and **1.14:1** in the
    /// dark, i.e. the same colour to any eye — and `renderChangesPreview` showed «сайте» (a
    /// link) and «отчёт» (a change) in one sentence, told apart by nothing. A pattern is a
    /// shape, and shape is what this app lets carry meaning; the dots are what GitHub's
    /// rendered diffs use for the same «low-key, this changed» reading.
    static let pattern: NSUnderlineStyle = .patternDot

    // MARK: - Colour

    /// The grounds every mark is held against, per appearance — screen pixels, not resolved
    /// `NSColor`s, because the two differ.
    ///
    /// **Measured, `Scripts/change-grounds.swift`, 2026-10-29, two identical runs:** the window's
    /// pane #ffffff / #31302d; the hotkey panel's `.regularMaterial` over white, black, grey,
    /// blue and orange backdrops #edebea…#f1f0ee / #3c3937…#494845; the change card's glass
    /// popover #f5f5f5 / #4d4c48. The marks used to be held against white and #1e1e1e — what
    /// `windowBackgroundColor` resolves to offscreen — and on the dark panel and card they were
    /// 2.14–2.99:1, under the floor. One colour held against *all* of an appearance's grounds is
    /// what lets one dynamic colour serve the window, the panel and the card without knowing
    /// which it is drawn on; the darkest light ground and the lightest dark one decide it.
    static let lightGrounds: [Int] = [0xffffff, 0xedebea, 0xf1f0ee, 0xf5f5f5]
    static let darkGrounds: [Int] = [0x31302d, 0x494845, 0x3c3937, 0x4d4c48]

    /// What a mark must reach against every ground: 3.5:1, and 4.5:1 under Increase Contrast.
    ///
    /// 3:1 is WCAG's floor for a non-text indicator, which a hairline under a word is; 3.5 is one
    /// step of margin, `StatusColour`'s discipline. 4.5 is the text floor — the «significantly
    /// higher» differentiation HIG asks of a custom colour's increased-contrast variant.
    static let markFloor = 3.5
    static let markFloorIncreasedContrast = 4.5

    /// The colour under the mark: the user's accent, moved toward the ink only as far as it needs.
    ///
    /// **The rule is a floor, not a blend — measured, `Scripts/accent-contrast.swift`,
    /// 2026-10-29.** The 35 % blend toward black this replaced was sized so that жёлтый cleared
    /// 3:1 on white, and it darkened every accent by the same amount: синий became #0058a6, 2.12:1
    /// from the text above it, and фиолетовый 1.86:1 — a hairline in the tone of its own letters.
    /// In the dark it did nothing, where the panel needed the accent *lighter*. Moving each accent
    /// toward the ink (black in light, white in dark) in steps of 0.01 until it clears the floor
    /// against every ground leaves an accent that already clears it untouched (фиолетовый in light)
    /// and puts the others between the ground and the text: light 3.50–3.56:1 to the ground and
    /// 3.56–3.63:1 to the ink for all eight presets, dark ≥ 3.51:1 (синий #40adff). Under Increase
    /// Contrast every preset clears 4.50–4.64:1. `ChangeMarksColourTests` holds every preset in
    /// both appearances against every ground.
    ///
    /// A dynamic colour rather than literals, because the accent is the user's and can change under
    /// a running app; `NSColor(name:dynamicProvider:)` re-resolves per appearance and per draw. At
    /// most 95 steps of four contrasts per resolve — cheap enough that nothing caches it.
    ///
    /// - Parameter increasedContrast: `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`,
    ///   read by the caller. Not read from the appearance, because it cannot be:
    ///   `NSAppearance(named: .accessibilityHighContrastAqua)` answers `.aqua` to `bestMatch(from:)`
    ///   offscreen and resolves every system colour as `.aqua` does (measured 2026-10-29), so a
    ///   branch keyed on the name could be neither tested nor trusted.
    public static func markColour(increasedContrast: Bool = false) -> NSColor {
        NSColor(name: nil) { appearance in
            floored(.controlAccentColor, dark: isDark(appearance), increasedContrast: increasedContrast)
        }
    }

    /// The rule as a function over any colour, so a test can walk every accent preset rather than
    /// only the one this machine is set to — and so the script and the code cannot drift apart
    /// without one of them failing the other's figures.
    static func floored(_ accent: NSColor, dark: Bool, increasedContrast: Bool) -> NSColor {
        guard let c = accent.usingColorSpace(.sRGB) else { return accent }
        let m = moved(c, dark: dark,
                      by: floorFraction(c, dark: dark, increasedContrast: increasedContrast))
        return NSColor(srgbRed: m.0, green: m.1, blue: m.2, alpha: c.alphaComponent)
    }

    /// How far toward the ink `floored` moves an accent: the first step of 0.01 that clears the
    /// floor on every ground. Separate so a test can show one step less does not.
    static func floorFraction(_ accent: NSColor, dark: Bool, increasedContrast: Bool) -> CGFloat {
        guard let c = accent.usingColorSpace(.sRGB) else { return 0 }
        let grounds = (dark ? darkGrounds : lightGrounds).map(srgb)
        let floor = increasedContrast ? markFloorIncreasedContrast : markFloor
        var steps = 0
        while steps < 95,
              grounds.contains(where: { contrast(moved(c, dark: dark, by: CGFloat(steps) / 100), $0) < floor }) {
            steps += 1
        }
        return CGFloat(steps) / 100
    }

    static func moved(_ c: NSColor, dark: Bool, by fraction: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let ink: CGFloat = dark ? 1 : 0
        return (c.redComponent + (ink - c.redComponent) * fraction,
                c.greenComponent + (ink - c.greenComponent) * fraction,
                c.blueComponent + (ink - c.blueComponent) * fraction)
    }

    /// Removed text and the strike through it: the label's own hue at an alpha that clears 4.5:1
    /// on every ground — 6:1 under Increase Contrast — and stays under the body text's 0.85.
    ///
    /// **Measured, `Scripts/accent-contrast.swift`, 2026-10-29.** `secondaryLabelColor`, which
    /// this replaced, was 3.84–3.98:1 on every light ground and 3.89:1 on the dark card — under
    /// the 4.5:1 HIG sets for text up to 17 pt, and a strike through the middle of the letters
    /// costs more. The alphas are the smallest in steps of 0.05 that clear the floor on the worst
    /// ground by at least 0.2 — headroom for a material that moves with what is behind it, the
    /// way the mark's 3.5 sits over 3: 0.60 → 5.44:1 light, 0.65 → 4.74:1 dark; under Increase
    /// Contrast 0.65 → 6.54:1, 0.80 → 6.22:1. (0.55 in light is 4.56:1, inside that headroom.)
    public static func removedColour(increasedContrast: Bool = false) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = isDark(appearance)
            return (dark ? NSColor.white : NSColor.black)
                .withAlphaComponent(removedAlpha(dark: dark, increasedContrast: increasedContrast))
        }
    }

    static func removedAlpha(dark: Bool, increasedContrast: Bool) -> CGFloat {
        switch (dark, increasedContrast) {
        case (false, false): 0.60
        case (true, false): 0.65
        case (false, true): 0.65
        case (true, true): 0.80
        }
    }

    /// `bestMatch(from:)` rather than a comparison by name, for `StatusColour`'s reason: a view may
    /// draw in a vibrant or accessibility variant, and `bestMatch` maps each onto the nearer one.
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func srgb(_ hex: Int) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255)
    }

    /// WCAG relative luminance and contrast — the arithmetic `Scripts/accent-contrast.swift` and the
    /// tests use, so the three agree to the digit.
    static func contrast(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat)) -> Double {
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> Double {
            0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The marked rendering. The input is never mutated.
    ///
    /// - Parameters:
    ///   - set: what the diff found, over `resultMarkdown` as the result text.
    ///   - rendering: the clean rendering of that same text, with `blockRanges` filled —
    ///     `MarkdownToAttributed.rendering(of:config:)` or `plainRendering(of:config:)`.
    ///   - resultMarkdown: the text the rendering was built from. The block list is read from
    ///     it again here, because `TextChange.block` indexes exactly that list.
    ///   - detail: whether the removed text is spliced in.
    ///   - config: the same one the rendering was built with — the underline's weight and the
    ///     fallback font of a spliced removal come from it.
    ///   - increasedContrast: the system's Increase Contrast, read by the caller (see
    ///     `markColour(increasedContrast:)` for why it is passed rather than read from the
    ///     appearance). It decides the lines' weight, which is an attribute and not a dynamic
    ///     colour, so a change of the setting needs a new call — the views make one.
    public static func apply(_ set: ChangeSet, to rendering: MarkdownToAttributed.Rendering,
                             resultMarkdown: String, detail: Detail,
                             config: MarkdownFontConfig,
                             increasedContrast: Bool = false) -> MarkdownToAttributed.Rendering {
        guard !set.changes.isEmpty else { return rendering }
        let drawing = Drawing(config: config, increasedContrast: increasedContrast)
        let blocks = MarkdownBlockScanner.blocks(of: resultMarkdown)
        // A rendering of some other document, or one assembled without block ranges: there is
        // nothing to locate against, and marking it against a block list it does not match
        // would put underlines under arbitrary words.
        guard blocks.count == rendering.blockRanges.count else { return rendering }

        let storage = NSMutableAttributedString(attributedString: rendering.attributed)
        var codeRegions = rendering.codeRegions
        var blockRanges = rendering.blockRanges

        // Every alignment taken before anything is spliced. `.changes` inserts characters, and
        // a token offset measured after an insertion into the same block would be measured
        // against a string neither the diff nor the renderer ever saw.
        var alignments: [Int: Alignment] = [:]
        let rendered = rendering.attributed.string as NSString
        for index in Set(set.changes.map(\.block)) where index < blocks.count {
            alignments[index] = align(block: blocks[index], range: blockRanges[index],
                                      rendered: rendered, markdown: resultMarkdown)
        }

        // Last to first, by block and then within a block, so an insertion never shifts a
        // range still to be located. Blocks descending and, inside one block, the diff's own
        // order reversed — `TextDiff` emits a block's edits in token order and a removed
        // source block before the result block it sat in front of, so the reversal is exactly
        // «by position, descending».
        let order = set.changes.indices.sorted {
            set.changes[$0].block != set.changes[$1].block
                ? set.changes[$0].block > set.changes[$1].block
                : $0 > $1
        }

        for index in order {
            let change = set.changes[index]
            guard change.block <= blocks.count else { continue }
            if change.block == blocks.count {
                // The one anchor that names no block: a source block removed from the *end* of
                // the document, which `TextChange.block` documents as «one past the last
                // result block». Nothing to underline; in «Изменения» it is a struck paragraph
                // after everything else.
                if detail == .changes, !change.removed.isEmpty {
                    spliceParagraph(change.removed, index: index, at: storage.length,
                                    into: storage, codeRegions: &codeRegions,
                                    blockRanges: &blockRanges, drawing: drawing)
                } else if detail == .result {
                    // The removed paragraph sat after everything: its caret goes under the
                    // document's last character, the one place «after the end» can be shown.
                    anchorRemoval(index, at: storage.length, in: storage)
                }
                continue
            }
            guard !isCode(blocks[change.block]) else {
                // Step 1 guarantees this: a fenced block is `Chunk.passthrough`, the model
                // never saw its bytes, and a change inside one cannot exist. Asserted rather
                // than trusted, and skipped in release — story 17 is that no mark is ever
                // drawn inside code.
                assertionFailure("A change targets a code block; TextDiff must not produce one")
                continue
            }
            let blockRange = blockRanges[change.block]

            // A block with no counterpart in the result: nothing of it is in the storage, so
            // there is nothing to align and nothing to underline.
            if change.scope == .block, change.insertedTokens.isEmpty {
                if detail == .changes, !change.removed.isEmpty {
                    spliceParagraph(change.removed, index: index, at: blockRange.location,
                                    into: storage, codeRegions: &codeRegions,
                                    blockRanges: &blockRanges, drawing: drawing)
                } else if detail == .result {
                    // A removed paragraph sat in front of this block: its caret goes under the
                    // block's first character.
                    anchorRemoval(index, at: blockRange.location, in: storage)
                }
                continue
            }
            guard let alignment = alignments[change.block] else { continue }

            if change.insertedTokens.isEmpty {
                guard !change.removed.isEmpty,
                      let anchor = anchor(for: change, in: alignment,
                                          blockRange: blockRange) else { continue }
                if detail == .changes {
                    spliceRemoval(change.removed, index: index, at: anchor, into: storage,
                                  codeRegions: &codeRegions, blockRanges: &blockRanges,
                                  drawing: drawing)
                } else {
                    anchorRemoval(index, at: anchor, in: storage)
                }
                continue
            }

            guard let marked = located(change, in: alignment,
                                       blockRange: blockRange) else { continue }
            storage.addAttributes(
                marks(index: index, scope: change.scope, drawing: drawing),
                range: marked)
            if change.scope == .words, isPunctuationOnly(change.inserted) {
                // Two dots under a comma are not a mark anyone sees; the comma in the mark's
                // colour is. 3.5:1 is under the 4.5:1 text floor, accepted because a comma is
                // not running text — and Increase Contrast lifts it to 4.5.
                storage.addAttribute(.foregroundColor,
                                     value: markColour(increasedContrast: increasedContrast),
                                     range: marked)
            }
            guard detail == .changes, !change.removed.isEmpty else { continue }
            if change.scope == .block {
                // A rewritten block: the old one struck through above the new one, not word
                // by word inside it (story 5).
                spliceParagraph(change.removed, index: index, at: blockRange.location,
                                into: storage, codeRegions: &codeRegions,
                                blockRanges: &blockRanges, drawing: drawing)
            } else {
                spliceRemoval(change.removed, index: index, at: marked.location, into: storage,
                              codeRegions: &codeRegions, blockRanges: &blockRanges,
                              drawing: drawing)
            }
        }

        return MarkdownToAttributed.Rendering(attributed: storage, codeRegions: codeRegions,
                                              blockRanges: blockRanges)
    }

    // MARK: - «Вернуть»: locating one change's edit in the raw result

    /// What restoring `change`'s source text would do to `resultMarkdown` — a range to
    /// replace and the text to put there. Nil when the change cannot be located, which is
    /// when the caller must disable «Вернуть» rather than guess (issue #89).
    ///
    /// **Only a genuine substitution — something removed *and* something inserted — has a
    /// revert with nothing to guess.** Tried and measured, in
    /// `ChangeMarksTests.swift` under «Вернуть»: a pure removal (nothing in `resultMarkdown`
    /// stands where the source words did) and a pure insertion (deleting the inserted span
    /// alone) both leave the wrong whitespace behind — «Смотрите, пожалуйста, повнимательнее.»
    /// came back «Смотрите , пожалуйста, повнимательнее.» and «Готово.» came back «Готово .».
    /// The reason is structural, not a bug to fix with more padding: a token boundary is
    /// whitespace (`TextTokenizer`'s own rule), so neither `removed` nor `inserted` carries
    /// the separator that stood, or now stands, beside it, and `apply`'s `padded`/
    /// `spliceParagraph` only ever have to look *approximate* for the «Изменения» display —
    /// they splice the removed word in *beside* the reply that is still there, never in place
    /// of the only anchor a pure removal or a removed block has. A block with no counterpart
    /// (`TextChange.block == blocks.count`, or `scope == .block` with `insertedTokens` empty)
    /// is a pure removal at block scope for the same reason and refuses for it too. Reverting
    /// those shapes is therefore refused rather than guessed, matching the spec's own escape
    /// hatch — the popover disables «Вернуть» exactly where this returns nil.
    ///
    /// **A located substitution needs no padding at all.** The same token alignment `apply`
    /// locates a mark with, run directly against the raw Markdown instead of a rendering's
    /// storage — `MarkdownToAttributed.plainRendering(of:config:)`'s `blockRanges` are exactly
    /// a block's own source span and its `attributed.string` is `resultMarkdown` verbatim, so
    /// `align` needs no second implementation. The located range's neighbours are the same
    /// unchanged words on both documents, so replacing it outright with `change.removed`
    /// reproduces the source's own spacing by construction — proven by the tests beside this
    /// one that do pass.
    public struct RevertEdit: Equatable {
        /// Where to replace in `resultMarkdown` — always the located substitution's own span,
        /// never zero-length: an insertion with nothing to replace is one of the refused
        /// shapes above.
        public let range: NSRange
        /// What to put there — `change.removed`, verbatim.
        public let replacement: String
    }

    public static func revertEdit(for change: TextChange, in resultMarkdown: String) -> RevertEdit? {
        guard !change.removed.isEmpty, !change.inserted.isEmpty else { return nil }
        let blocks = MarkdownBlockScanner.blocks(of: resultMarkdown)
        let blockRanges = MarkdownToAttributed.plainRendering(of: resultMarkdown,
                                                               config: .default).blockRanges
        guard blockRanges.count == blocks.count, change.block < blocks.count,
              !isCode(blocks[change.block]) else { return nil }
        let blockRange = blockRanges[change.block]
        let rendered = resultMarkdown as NSString
        guard let alignment = align(block: blocks[change.block], range: blockRange,
                                    rendered: rendered, markdown: resultMarkdown),
              let located = located(change, in: alignment, blockRange: blockRange) else {
            return nil
        }
        return RevertEdit(range: located, replacement: change.removed)
    }

    // MARK: - Locating a change in the storage

    /// One block's characters as the storage holds them, and which of its projection's tokens
    /// each of them is.
    private struct Alignment {
        /// The block's own characters, cut out of the storage.
        let text: String
        /// `text`'s tokens — the markers, labels and cell terminators included, because those
        /// are what the projection does not have and what the walk skips.
        let tokens: [TextToken]
        /// Projection token index → `tokens` index. Nil for a projection token the walk was
        /// allowed to skip (see `align`); a change with a nil endpoint is not drawn.
        let map: [Int?]
    }

    /// The block's projection walked onto its rendering, or nil when it does not fit.
    ///
    /// The walk is greedy in one direction only: an unmatched *shown* token is skipped, an
    /// unmatched *projection* token ends the attempt. That asymmetry is the safety property —
    /// a shown token the projection lacks is always a marker (`**`, `#`, `|`), a list label or
    /// a cell terminator, while a projection token the rendering lacks would mean the two
    /// disagree about the words, and there is no sound way to guess a range then.
    ///
    /// **A second attempt with the list label skipped** is the one exception, and it exists
    /// for the raw «Исходник» rendering: `MarkdownPlainText` gives a list item a synthesised
    /// «• » or «12. » label that the source's own `- ` never contains. The full attempt runs
    /// first, so a rendered list — whose label *is* in the storage — still matches label to
    /// label, and «1. 1 января» cannot align its content's «1» to the label's.
    private static func align(block: MarkdownBlock, range: NSRange, rendered: NSString,
                              markdown: String) -> Alignment? {
        guard range.length > 0, NSMaxRange(range) <= rendered.length else { return nil }
        let text = rendered.substring(with: range)
        let shown = TextTokenizer.tokens(of: text)
        let plain = TextTokenizer.tokens(of: MarkdownPlainText.plain(block, in: markdown))
        guard !plain.isEmpty else { return nil }
        if let map = walk(shown: shown, plain: plain, from: 0) {
            return Alignment(text: text, tokens: shown, map: map)
        }
        let label = labelTokens(of: block)
        guard label > 0, label < plain.count,
              let map = walk(shown: shown, plain: plain, from: label) else { return nil }
        return Alignment(text: text, tokens: shown, map: map)
    }

    private static func walk(shown: [TextToken], plain: [TextToken], from start: Int) -> [Int?]? {
        var map = [Int?](repeating: nil, count: plain.count)
        var i = 0
        var j = start
        while i < shown.count, j < plain.count {
            if shown[i].text == plain[j].text {
                map[j] = i
                j += 1
            }
            i += 1
        }
        return j == plain.count ? map : nil
    }

    /// How many tokens of the projection are the label `MarkdownPlainText` puts in front of a
    /// list item: «• » is one mark, «12. » is a number and a full stop.
    private static func labelTokens(of block: MarkdownBlock) -> Int {
        guard case let .listItem(_, marker, _) = block else { return 0 }
        switch marker {
        case .bullet: return 1
        case .ordered: return 2
        }
    }

    /// The storage range of a change's inserted run: its first content token's start to its
    /// last one's end.
    private static func located(_ change: TextChange, in alignment: Alignment,
                                blockRange: NSRange) -> NSRange? {
        let lower = change.insertedTokens.lowerBound
        let upper = change.insertedTokens.upperBound
        guard lower >= 0, lower < upper, upper <= alignment.map.count,
              let first = alignment.map[lower], let last = alignment.map[upper - 1] else {
            return nil
        }
        let start = offset(alignment.tokens[first].range.lowerBound, in: alignment.text)
        let end = offset(alignment.tokens[last].range.upperBound, in: alignment.text)
        guard end > start else { return nil }
        return NSRange(location: blockRange.location + start, length: end - start)
    }

    /// Where a pure removal's struck text goes: in front of the token it sat before, or after
    /// the block's last content token when it sat at the block's end.
    private static func anchor(for change: TextChange, in alignment: Alignment,
                               blockRange: NSRange) -> Int? {
        let lower = change.insertedTokens.lowerBound
        if lower < alignment.map.count {
            guard lower >= 0, let shown = alignment.map[lower] else { return nil }
            return blockRange.location
                + offset(alignment.tokens[shown].range.lowerBound, in: alignment.text)
        }
        // `insertedTokens.lowerBound == the block's token count`: the removal sat at the end
        // of the block, so there is no token to stand before and the anchor is the last
        // content token's end (`TextChange.insertedTokens`).
        guard let last = alignment.map.compactMap({ $0 }).last else { return nil }
        return blockRange.location
            + offset(alignment.tokens[last].range.upperBound, in: alignment.text)
    }

    /// The removed text with the spaces the document does not already provide, and no others —
    /// and how many of each it added, because those spaces are separators, not removed text,
    /// and are not struck.
    ///
    /// The spec puts the space «after it when `inserted` is non-empty, before it when
    /// `inserted` is empty», which glues the struck word to whatever it stands in front of
    /// whenever a removal sat in the middle of a block: «готов» + «уже » + «.» is
    /// «готовуже .». The rule that holds in every case is that a splice must not create a
    /// word boundary the document does not have and must not double one it does — so a space
    /// goes in front only when the character before is not already whitespace, and behind only
    /// when the character after is alphanumeric, which is what «уже» needs before «готов» and
    /// what it must not get before «.».
    private static func padded(_ removed: String, at location: Int,
                               in string: NSString) -> (text: String, leading: Int, trailing: Int) {
        var text = removed
        var leading = 0
        var trailing = 0
        if location > 0, !isMember(.whitespacesAndNewlines, string.character(at: location - 1)) {
            text = " " + text
            leading = 1
        }
        if location < string.length, isMember(.alphanumerics, string.character(at: location)) {
            text += " "
            trailing = 1
        }
        return (text, leading, trailing)
    }

    /// The one character a pure removal's caret stands under in «Результат» and «Исходник».
    ///
    /// The separator in front of the token the removal sat before; that token's own first
    /// character when nothing separates it from what precedes it («неделю» + «.»); or, for a
    /// removal at the very end of a block, the block's last character. Internal so the tests can
    /// pin each of the three.
    static func removalGap(at anchor: Int, in string: NSString) -> NSRange? {
        guard string.length > 0 else { return nil }
        if anchor > 0, isMember(.whitespaces, string.character(at: anchor - 1)) {
            return NSRange(location: anchor - 1, length: 1)
        }
        if anchor < string.length, !isMember(.newlines, string.character(at: anchor)) {
            return NSRange(location: anchor, length: 1)
        }
        // The end of a block or of the document: the last character a reader can see, which a
        // rendering's trailing terminator is not.
        var last = anchor - 1
        while last > 0, isMember(.newlines, string.character(at: last)) { last -= 1 }
        return last >= 0 ? NSRange(location: last, length: 1) : nil
    }

    /// Nothing was inserted, so nothing can be underlined — and a change the reader cannot see
    /// is one ‹ › cannot reach either. The gap carries the index with no underline, and the view
    /// draws the caret under it. A gap another change already marks is left alone: overwriting
    /// it would take that change's own mark away.
    private static func anchorRemoval(_ index: Int, at anchor: Int,
                                      in storage: NSMutableAttributedString) {
        guard let gap = removalGap(at: anchor, in: storage.string as NSString),
              storage.attribute(changeKey, at: gap.location, effectiveRange: nil) == nil
        else { return }
        storage.addAttribute(changeKey, value: index, range: gap)
    }

    /// An insertion with no letter or digit in it — a comma, a dash, a quotation mark.
    static func isPunctuationOnly(_ inserted: String) -> Bool {
        !inserted.isEmpty
            && !inserted.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// One UTF-16 unit against a character set. A lone surrogate belongs to neither set the
    /// caller asks about, so it answers false rather than reconstructing a pair: the question
    /// is «does this splice need a space», and no astral character makes it need one.
    private static func isMember(_ set: CharacterSet, _ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return set.contains(scalar)
    }

    private static func offset(_ index: String.Index, in text: String) -> Int {
        index.utf16Offset(in: text)
    }

    // MARK: - The attributes

    /// What every private drawing function needs from `apply`'s arguments, so the contrast flag
    /// travels with the font configuration instead of beside it through five signatures.
    private struct Drawing {
        let config: MarkdownFontConfig
        let increasedContrast: Bool

        var lineStyle: NSUnderlineStyle {
            underlineStyle(for: config.baseSize, increasedContrast: increasedContrast)
        }
    }

    /// The weight from the size, the dots always, the colour from the appearance — see the
    /// declarations above for the measurement behind each.
    ///
    /// **A rewritten block carries the index and no underline.** `TextDiff` collapses a block it
    /// cannot read as word edits into one change, and ADR 0012 reads it as one candidate text;
    /// a dot under every word on every line said the opposite. The view draws one continuous
    /// bar beside it instead, reading the scope from the change set.
    private static func marks(index: Int, scope: TextChange.Scope,
                              drawing: Drawing) -> [NSAttributedString.Key: Any] {
        guard scope == .words else { return [changeKey: index] }
        var style = drawing.lineStyle
        style.insert(pattern)
        return [.underlineStyle: style.rawValue,
                .underlineColor: markColour(increasedContrast: drawing.increasedContrast),
                changeKey: index]
    }

    private static func isCode(_ block: MarkdownBlock) -> Bool {
        if case .codeBlock = block { return true }
        return false
    }

    // MARK: - Splicing the removed text in

    /// The removed text as its own paragraph before whatever is at `location`.
    ///
    /// A leading terminator when the character before it is not one, because a rendering's
    /// blocks each end in their own `"\n"` but the raw Markdown of «Исходник» need not.
    private static func spliceParagraph(_ removed: String, index: Int, at location: Int,
                                        into storage: NSMutableAttributedString,
                                        codeRegions: inout [MarkdownToAttributed.CodeRegion],
                                        blockRanges: inout [NSRange],
                                        drawing: Drawing) {
        let text = paragraphInsertionText(removed, at: location,
                                          in: storage.string as NSString)
        splice(text, index: index, at: location, into: storage, codeRegions: &codeRegions,
               blockRanges: &blockRanges, drawing: drawing)
    }

    /// The removed words inside a block, with the spaces `padded` adds left unstruck.
    private static func spliceRemoval(_ removed: String, index: Int, at location: Int,
                                      into storage: NSMutableAttributedString,
                                      codeRegions: inout [MarkdownToAttributed.CodeRegion],
                                      blockRanges: inout [NSRange], drawing: Drawing) {
        let pad = padded(removed, at: location, in: storage.string as NSString)
        splice(pad.text, index: index, at: location, into: storage, codeRegions: &codeRegions,
               blockRanges: &blockRanges, drawing: drawing,
               plainLeading: pad.leading, plainTrailing: pad.trailing)
    }

    /// The decision half of `spliceParagraph`, over a plain `NSString` rather than the storage
    /// it is about to be spliced into — so «Вернуть» can compute the identical insertion text
    /// against the raw Markdown result with nothing to splice into yet.
    ///
    /// A leading terminator when the character before it is not one, because a rendering's
    /// blocks each end in their own `"\n"` but the raw Markdown of «Исходник» need not.
    private static func paragraphInsertionText(_ removed: String, at location: Int,
                                               in string: NSString) -> String {
        var text = removed + "\n"
        if location > 0 {
            let before = string.character(at: location - 1)
            // 0x0A and 0x0D, the two line terminators a rendering or a raw document can end a
            // block with — `LineScanner`'s reading, in the one form an NSString offers.
            if before != 0x0A, before != 0x0D { text = "\n" + text }
        }
        return text
    }

    /// Insert characters and move everything that was at or after them.
    ///
    /// A range whose location is at or after the insertion point moves whole; a range the
    /// insertion lands strictly inside grows. A splice exactly on a block boundary therefore
    /// belongs to neither block — which is what a removed paragraph is, and why `blockRanges`
    /// tile in `.result` and merely bound each block in `.changes`.
    ///
    /// The first `plainLeading` and last `plainTrailing` characters are separators the splice
    /// needed, not removed text: they take the anchor's font and paragraph style and nothing
    /// else, so the strike ends at the last letter of the removed word (it used to run on into
    /// the space before the word that replaced it, and read as striking that word too).
    private static func splice(_ text: String, index: Int, at location: Int,
                               into storage: NSMutableAttributedString,
                               codeRegions: inout [MarkdownToAttributed.CodeRegion],
                               blockRanges: inout [NSRange], drawing: Drawing,
                               plainLeading: Int = 0, plainTrailing: Int = 0) {
        guard !text.isEmpty, location >= 0, location <= storage.length else { return }
        var removed = removedAttributes(at: location, in: storage, drawing: drawing)
        removed[removedKey] = index
        let attributed = NSMutableAttributedString(string: text, attributes: removed)
        let length = attributed.length
        let plain = plainAttributes(of: removed)
        if plainLeading > 0 {
            attributed.setAttributes(plain, range: NSRange(location: 0, length: plainLeading))
        }
        if plainTrailing > 0 {
            attributed.setAttributes(plain, range: NSRange(location: length - plainTrailing,
                                                           length: plainTrailing))
        }
        storage.insert(attributed, at: location)
        let delta = length
        codeRegions = codeRegions.map {
            $0.range.location >= location ? $0.offset(by: delta) : $0
        }
        blockRanges = blockRanges.map { range in
            if range.location >= location {
                return NSRange(location: range.location + delta, length: range.length)
            }
            if location < NSMaxRange(range) {
                return NSRange(location: range.location, length: range.length + delta)
            }
            return range
        }
    }

    /// The anchor run's `.font` and `.paragraphStyle` and nothing else of it, plus the strike
    /// and the removed colour.
    ///
    /// Only those two are taken because everything else a run carries is a claim about the
    /// text: a link's colour and underline, a code span's background, the change mark itself.
    /// The paragraph style is what keeps a removal inside its table cell, its quote bar and
    /// its list indent — it is where this converter puts every block frame it draws.
    private static func removedAttributes(at index: Int, in storage: NSAttributedString,
                                          drawing: Drawing)
        -> [NSAttributedString.Key: Any] {
        let colour = removedColour(increasedContrast: drawing.increasedContrast)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MarkdownToAttributed.font(size: drawing.config.baseSize, weight: .regular,
                                             config: drawing.config),
            .strikethroughStyle: drawing.lineStyle.rawValue,
            .strikethroughColor: colour,
            .foregroundColor: colour,
        ]
        guard storage.length > 0 else { return attributes }
        let probe = min(max(index, 0), storage.length - 1)
        let existing = storage.attributes(at: probe, effectiveRange: nil)
        if let font = existing[.font] { attributes[.font] = font }
        if let style = existing[.paragraphStyle] { attributes[.paragraphStyle] = style }
        return attributes
    }

    /// A separator's attributes: the removed text's font and paragraph style, nothing it claims.
    private static func plainAttributes(of removed: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any] {
        removed.filter { $0.key == .font || $0.key == .paragraphStyle }
    }
}
