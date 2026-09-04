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

    public static func underlineStyle(for baseSize: CGFloat) -> NSUnderlineStyle {
        baseSize >= thickFromSize ? .thick : .single
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

    /// The colour under the mark: the accent, darkened in the light appearance.
    ///
    /// **The bare accent fails on the light pane — measured, `Scripts/accent-contrast.swift`,
    /// 2026-09-04.** A change mark is a hairline in the accent on the pane's own ground, and a
    /// non-text indicator wants 3:1 to be perceived. Against white, three of the eight accents
    /// macOS offers are under it: оранжевый 2.31:1, зелёный 2.22:1, жёлтый 1.51:1 (синий 3.52,
    /// графит 3.26 are the narrowest passes). On the dark pane every accent clears it (worst
    /// 4.59:1, фиолетовый), so the dark value is the accent itself.
    ///
    /// The light value is the accent blended **35 %** toward black: the same script walked the
    /// fraction in steps of 0.05 and 0.30 is the first that clears the floor for all eight
    /// (жёлтый 3.08:1); 0.35 (жёлтый 3.53:1) is one step of margin for an accent the user may
    /// have tinted, the way `StatusColour` keeps its light values a step past the line.
    /// `ChangeMarksColourTests` holds all sixteen cells to the floor, the same discipline as
    /// `SyntaxPaletteTests`.
    ///
    /// A dynamic colour rather than two literals, because the accent is the user's and can
    /// change under a running app; `NSColor(name:dynamicProvider:)` re-resolves per appearance
    /// and per draw.
    public static let lightBlend: CGFloat = 0.35

    public static var markColour: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? .controlAccentColor : blendedTowardBlack(.controlAccentColor, by: lightBlend)
        }
    }

    /// The light-appearance rule as a function over any colour, so the test can walk every
    /// accent preset the way the script does rather than only the one this machine is set to.
    static func blendedTowardBlack(_ colour: NSColor, by fraction: CGFloat) -> NSColor {
        guard let c = colour.usingColorSpace(.sRGB) else { return colour }
        return NSColor(srgbRed: c.redComponent * (1 - fraction),
                       green: c.greenComponent * (1 - fraction),
                       blue: c.blueComponent * (1 - fraction), alpha: c.alphaComponent)
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
    public static func apply(_ set: ChangeSet, to rendering: MarkdownToAttributed.Rendering,
                             resultMarkdown: String, detail: Detail,
                             config: MarkdownFontConfig) -> MarkdownToAttributed.Rendering {
        guard !set.changes.isEmpty else { return rendering }
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
                    spliceParagraph(change.removed, at: storage.length, into: storage,
                                    codeRegions: &codeRegions, blockRanges: &blockRanges,
                                    config: config)
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
                    spliceParagraph(change.removed, at: blockRange.location, into: storage,
                                    codeRegions: &codeRegions, blockRanges: &blockRanges,
                                    config: config)
                }
                continue
            }
            guard let alignment = alignments[change.block] else { continue }

            if change.insertedTokens.isEmpty {
                guard detail == .changes, !change.removed.isEmpty,
                      let anchor = anchor(for: change, in: alignment,
                                          blockRange: blockRange) else { continue }
                splice(padded(change.removed, at: anchor, in: storage.string as NSString),
                       at: anchor, into: storage, codeRegions: &codeRegions,
                       blockRanges: &blockRanges, config: config)
                continue
            }

            guard let marked = located(change, in: alignment,
                                       blockRange: blockRange) else { continue }
            storage.addAttributes(
                marks(index: index, config: config),
                range: marked)
            guard detail == .changes, !change.removed.isEmpty else { continue }
            if change.scope == .block {
                // A rewritten block: the old one struck through above the new one, not word
                // by word inside it (story 5).
                spliceParagraph(change.removed, at: blockRange.location, into: storage,
                                codeRegions: &codeRegions, blockRanges: &blockRanges,
                                config: config)
            } else {
                splice(padded(change.removed, at: marked.location,
                              in: storage.string as NSString),
                       at: marked.location, into: storage, codeRegions: &codeRegions,
                       blockRanges: &blockRanges, config: config)
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

    /// The removed text with the spaces the document does not already provide, and no others.
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
                               in string: NSString) -> String {
        var text = removed
        if location > 0, !isMember(.whitespacesAndNewlines, string.character(at: location - 1)) {
            text = " " + text
        }
        if location < string.length, isMember(.alphanumerics, string.character(at: location)) {
            text += " "
        }
        return text
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

    /// The weight from the size, the dots always, the colour from the appearance — see the
    /// three declarations above for the measurement behind each.
    private static func marks(index: Int,
                              config: MarkdownFontConfig) -> [NSAttributedString.Key: Any] {
        var style = underlineStyle(for: config.baseSize)
        style.insert(pattern)
        return [.underlineStyle: style.rawValue,
                .underlineColor: markColour,
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
    private static func spliceParagraph(_ removed: String, at location: Int,
                                        into storage: NSMutableAttributedString,
                                        codeRegions: inout [MarkdownToAttributed.CodeRegion],
                                        blockRanges: inout [NSRange],
                                        config: MarkdownFontConfig) {
        let text = paragraphInsertionText(removed, at: location,
                                          in: storage.string as NSString)
        splice(text, at: location, into: storage, codeRegions: &codeRegions,
               blockRanges: &blockRanges, config: config)
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
    private static func splice(_ text: String, at location: Int,
                               into storage: NSMutableAttributedString,
                               codeRegions: inout [MarkdownToAttributed.CodeRegion],
                               blockRanges: inout [NSRange], config: MarkdownFontConfig) {
        guard !text.isEmpty, location >= 0, location <= storage.length else { return }
        let attributed = NSAttributedString(string: text,
                                            attributes: removedAttributes(at: location,
                                                                          in: storage,
                                                                          config: config))
        storage.insert(attributed, at: location)
        let delta = attributed.length
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
    /// and the secondary colour.
    ///
    /// Only those two are taken because everything else a run carries is a claim about the
    /// text: a link's colour and underline, a code span's background, the change mark itself.
    /// The paragraph style is what keeps a removal inside its table cell, its quote bar and
    /// its list indent — it is where this converter puts every block frame it draws.
    private static func removedAttributes(at index: Int, in storage: NSAttributedString,
                                          config: MarkdownFontConfig)
        -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MarkdownToAttributed.font(size: config.baseSize, weight: .regular,
                                             config: config),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: NSColor.secondaryLabelColor,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        guard storage.length > 0 else { return attributes }
        let probe = min(max(index, 0), storage.length - 1)
        let existing = storage.attributes(at: probe, effectiveRange: nil)
        if let font = existing[.font] { attributes[.font] = font }
        if let style = existing[.paragraphStyle] { attributes[.paragraphStyle] = style }
        return attributes
    }
}
