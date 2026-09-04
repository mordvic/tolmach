// Sources/MarkupKit/MarkdownToAttributed.swift
import AppKit
import Foundation
import TranslationCore

/// The one Markdown → `NSAttributedString` converter, and the reason the rendered pane is a
/// text view rather than a stack of SwiftUI views.
///
/// Rendering and rich copy are the *same* code here: the pane shows this attributed string and
/// «Скопировать» puts this attributed string on the pasteboard as `public.rtf`. A SwiftUI
/// renderer would have needed a second, separate Markdown → attributed serialiser for the copy
/// path, and «a second copy of this pane is how two surfaces come to disagree» is this repo's
/// own sentence for that shape (`TranslationPane`'s doc comment). The design records three
/// further measurements behind the choice — selection across the whole document, `NSTextTable`
/// laying out at 395 × 68 pt headless, 500 appends to an `NSTextStorage` costing 35 ms in
/// total — in `docs/design/specs/2026-08-31-formatting-design.md` §6.
///
/// Blocks come from `MarkdownBlockScanner`, so this draws the document the chunker and the
/// markup diff read. Inline spans come from Foundation, because a parser for them is the one
/// part of this nobody has to write.
///
/// Every colour is a semantic `NSColor`, so both appearances hold with no second palette and
/// no measurement of contrast: the system's own values move with the appearance. Nothing here
/// ever means «warning» — that word belongs to `StatusColour` in the app, which has the
/// measured light-appearance darkening.
public enum MarkdownToAttributed {
    /// A code block, and where it landed in the attributed string.
    ///
    /// `source` is the block's own bytes, taken from its `Range` — never a re-serialisation —
    /// so the pane's per-block «Скопировать» hands over exactly what the document holds.
    /// `range` is what the caller needs to ask the layout manager where to put the button.
    public struct CodeRegion: Sendable, Equatable {
        public let range: NSRange
        public let source: String
        /// What the fence named after its backticks, or nil for a bare fence. For the card's
        /// header label — an overlay, never characters in the storage, so the RTF flavour and a
        /// drag-selection copy carry the code and nothing else.
        public let language: String?

        public init(range: NSRange, source: String, language: String? = nil) {
            self.range = range
            self.source = source
            self.language = language
        }

        /// The same region, shifted — for a caller appending this rendering after something
        /// already in a text storage.
        public func offset(by delta: Int) -> CodeRegion {
            CodeRegion(range: NSRange(location: range.location + delta, length: range.length),
                       source: source, language: language)
        }
    }

    /// Room the card leaves above its first line of code for the header the text view draws
    /// over it — the language label and the always-visible «Скопировать». A constant and not a
    /// multiple of the base size: the header holds a system-sized control, and
    /// `docs/adr/0008` is that only the user's text scales.
    public static let codeCardHeaderHeight: CGFloat = 24

    public struct Rendering {
        public let attributed: NSAttributedString
        public let codeRegions: [CodeRegion]
        /// One range per block, in the order the blocks were rendered — the bridge between a
        /// `TextChange`, which names a block by its index in `MarkdownBlockScanner.blocks(of:)`,
        /// and the characters that block became. `ChangeMarks` is the only reader.
        ///
        /// From `rendering(blocks:in:config:)` these **tile** the output: each covers its
        /// block's own characters including the terminator, and they run end to end with no
        /// gaps, because that is how the blocks were appended. From `plainRendering(of:)` they
        /// do **not** — see that function; the locator needs a block's own characters and
        /// nothing about what lies between two blocks, so both shapes serve it.
        ///
        /// Empty from the two-argument init: a caller that assembled a rendering by hand (the
        /// app's plain path, the streaming tail) has no block list to name, and an empty array
        /// is what `ChangeMarks.apply` refuses to guess against.
        public let blockRanges: [NSRange]

        /// `blockRanges` defaults to empty so the app's hand-assembled renderings keep
        /// compiling unchanged; nothing that omits it can be marked.
        public init(attributed: NSAttributedString, codeRegions: [CodeRegion],
                    blockRanges: [NSRange] = []) {
            self.attributed = attributed
            self.codeRegions = codeRegions
            self.blockRanges = blockRanges
        }

        /// `public.rtf`, the flavour the pane's «Скопировать» writes beside the Markdown.
        public var rtf: Data? {
            attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                           documentAttributes: [:])
        }
    }

    /// The whole document.
    public static func rendering(of text: String, config: MarkdownFontConfig) -> Rendering {
        rendering(blocks: MarkdownBlockScanner.blocks(of: text), in: text, config: config)
    }

    /// Some of a document's blocks — the streaming path's settled prefix, or one block.
    ///
    /// Each block's output ends with its own paragraph terminator and carries its own spacing
    /// in a paragraph style, never as a blank line of text. That is what makes this
    /// concatenable: a caller can render blocks 0…n now and n+1… later and get the same
    /// document it would have got in one call, which is exactly what the settled-prefix rule
    /// needs.
    public static func rendering(blocks: [MarkdownBlock], in text: String,
                                config: MarkdownFontConfig) -> Rendering {
        let result = NSMutableAttributedString()
        var regions: [CodeRegion] = []
        var ranges: [NSRange] = []
        for block in blocks {
            let start = result.length
            switch block {
            case let .heading(level, range):
                result.append(heading(level: level, range, in: text, config: config))
            case let .paragraph(range):
                // «•»/«–» lines, drawn as the list they are — a display decision alone, which is
                // why the scanner handed this over as a paragraph. `PlainBulletList` says why.
                if let items = PlainBulletList.items(of: text[range]) {
                    for item in items {
                        result.append(listItem(depth: 0, marker: .bullet, item, in: text,
                                               config: config))
                    }
                } else {
                    result.append(paragraph(range, in: text, config: config))
                }
            case let .listItem(depth, marker, range):
                result.append(listItem(depth: depth, marker: marker, range, in: text,
                                       config: config))
            case let .blockquote(depth, range):
                result.append(blockquote(depth: depth, range, in: text, config: config))
            case let .codeBlock(language, range, _):
                let source = String(text[range])
                regions.append(CodeRegion(range: NSRange(location: result.length,
                                                         length: (source as NSString).length),
                                          source: source,
                                          language: language.isEmpty ? nil : language))
                result.append(codeBlock(source, language: language, config: config))
            case let .table(header, rows, alignments):
                result.append(table(header: header, rows: rows, alignments: alignments,
                                    in: text, config: config))
            case .thematicBreak:
                result.append(thematicBreak(config: config))
            }
            ranges.append(NSRange(location: start, length: result.length - start))
        }
        return Rendering(attributed: result, codeRegions: regions, blockRanges: ranges)
    }

    /// The document as itself, with its blocks located — «Исходник» and plain prose.
    ///
    /// `plain(_:config:)` is what draws it and is unchanged; what this adds is
    /// `blockRanges`, so a change set can be marked over the raw Markdown as well as over the
    /// rendered document (spec story 6: the toggle must not cost the marks).
    ///
    /// **The ranges are each block's own source span and do not tile the string**, unlike the
    /// rendered path's. `MarkdownBlock` carries the range of a block's *content* — a heading
    /// without its `#`s, a list item without its marker, a quote without its `>` — and the
    /// separators between blocks belong to no block at all (`Block.range` moves edge
    /// whitespace into them, `docs/design/specs/2026-08-07-lossless-chunking-design.md`).
    /// Reconstructing a tiling would mean inventing a rule for who owns a blank line, and the
    /// locator does not need one: it reads a block's own characters and never what lies
    /// between two of them.
    public static func plainRendering(of text: String,
                                      config: MarkdownFontConfig) -> Rendering {
        var ranges: [NSRange] = []
        var previousEnd = 0
        for block in MarkdownBlockScanner.blocks(of: text) {
            guard let span = sourceSpan(of: block) else {
                // A table the scanner found no cells in: nothing to locate, and a zero-length
                // range where the previous block ended rather than at 0, so a `.changes`
                // splice anchored on it cannot land at the top of an unrelated document.
                ranges.append(NSRange(location: previousEnd, length: 0))
                continue
            }
            let range = NSRange(span, in: text)
            ranges.append(range)
            previousEnd = range.location + range.length
        }
        return Rendering(attributed: plain(text, config: config), codeRegions: [],
                         blockRanges: ranges)
    }

    /// The span of the document a block was read from: its content range, or for a table the
    /// hull of its cells — the one case whose ranges are per cell rather than per block.
    ///
    /// Exhaustive with no `default:`, for `MarkdownPlainText.outputs`' reason: a new
    /// `MarkdownBlock` case has to be given a span here rather than silently losing its marks.
    static func sourceSpan(of block: MarkdownBlock) -> Range<String.Index>? {
        switch block {
        case let .heading(_, range): return range
        case let .paragraph(range): return range
        case let .listItem(_, _, range): return range
        case let .blockquote(_, range): return range
        case let .codeBlock(_, range, _): return range
        case let .thematicBreak(range): return range
        case let .table(header, rows, _):
            let cells = ([header] + rows).flatMap { $0 }
            guard let first = cells.map(\.lowerBound).min(),
                  let last = cells.map(\.upperBound).max() else { return nil }
            return first..<last
        }
    }

    /// The document as itself: «Исходник», and the unsettled tail of a stream.
    ///
    /// One font, one colour, no conversion — the same characters `Text(text)` used to draw, so
    /// the pane's second mode is today's behaviour byte for byte and a half-arrived block is
    /// shown as the Markdown it currently is.
    public static func plain(_ text: String, config: MarkdownFontConfig) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font(size: config.baseSize, weight: .regular, config: config),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    // MARK: - Blocks

    private static func heading(level: Int, _ range: Range<String.Index>, in text: String,
                                config: MarkdownFontConfig) -> NSAttributedString {
        let size = config.headingSize(level: level)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = size * 0.35
        style.paragraphSpacingBefore = size * 0.5
        return terminated(inline(String(text[range]),
                                 base: font(size: size, weight: .semibold, config: config),
                                 config: config,
                                 attributes: [.paragraphStyle: style,
                                              .foregroundColor: NSColor.labelColor]))
    }

    private static func paragraph(_ range: Range<String.Index>, in text: String,
                                  config: MarkdownFontConfig) -> NSAttributedString {
        terminated(inline(String(text[range]),
                          base: font(size: config.baseSize, weight: .regular, config: config),
                          config: config,
                          attributes: [.paragraphStyle: bodyStyle(config),
                                       .foregroundColor: NSColor.labelColor]))
    }

    private static func listItem(depth: Int, marker: MarkdownBlock.ListMarker,
                                 _ range: Range<String.Index>, in text: String,
                                 config: MarkdownFontConfig) -> NSAttributedString {
        let indent = config.baseSize * 1.4
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = config.baseSize * 0.2
        style.firstLineHeadIndent = indent * CGFloat(depth)
        style.headIndent = indent * CGFloat(depth + 1)
        style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
        // `NSTextList` is what makes this a list to everything downstream of the attributed
        // string — AppKit's own HTML/RTF writers read `textLists`, so a rich paste arrives as
        // a list rather than as a paragraph that happens to start with a bullet. The marker
        // characters are in the text besides, which is AppKit's own convention: its HTML
        // import produces exactly this pairing (`textLists` plus a literal "\t•\t").
        let list: NSTextList
        let label: String
        switch marker {
        case .bullet:
            list = NSTextList(markerFormat: .disc, options: 0)
            label = "•\t"
        case let .ordered(number):
            list = NSTextList(markerFormat: .decimal, options: 0)
            label = "\(number).\t"
        }
        style.textLists = [list]
        let body = font(size: config.baseSize, weight: .regular, config: config)
        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: style, .foregroundColor: NSColor.labelColor,
        ]
        let line = NSMutableAttributedString(
            string: label, attributes: attributes.merging([.font: body]) { $1 })
        line.append(inline(String(text[range]), base: body, config: config,
                           attributes: attributes))
        return terminated(line)
    }

    /// A quote wears the bar every reader knows it by: a one-column text block with a border on
    /// its leading edge only, the way the code card wears its frame — in the paragraph style,
    /// so the RTF flavour carries it too. Depth indents the whole block, bar included.
    private static func blockquote(depth: Int, _ range: Range<String.Index>, in text: String,
                                   config: MarkdownFontConfig) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                     startingColumn: 0, columnSpan: 1)
        block.setWidth(0, type: .absoluteValueType, for: .border)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(.tertiaryLabelColor)
        block.setWidth(config.baseSize * 0.9, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(config.baseSize * 0.25, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(config.baseSize * 0.25, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(config.baseSize * 1.4 * CGFloat(depth), type: .absoluteValueType,
                       for: .margin, edge: .minX)
        block.setWidth(config.baseSize * 0.5, type: .absoluteValueType, for: .margin, edge: .maxY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        return terminated(inline(String(text[range]),
                                 base: font(size: config.baseSize, weight: .regular,
                                            config: config),
                                 config: config,
                                 attributes: [.paragraphStyle: style,
                                              .foregroundColor: NSColor.secondaryLabelColor]))
    }

    /// The block's source bytes, verbatim, in the monospaced face, inside a bordered card.
    ///
    /// **The card is a one-column `NSTextTable` block, since 2026-09-02.** The first version
    /// was a run background alone, and its comment said a border «would need a table to hang
    /// on» — which is exactly what the thematic break already does one function down, and what
    /// every table cell does. Putting the frame in the paragraph style rather than in the view
    /// is what lets the RTF flavour carry it: the copy path and the pane are one converter, and
    /// a card drawn by the view would have been a second, invisible-to-copy rendering. The
    /// header room above the code is `codeCardHeaderHeight`, for the overlays the text view
    /// draws (`CodeBlockTextView`).
    ///
    /// **The range is never handed to the inline parser, and that is measured rather than
    /// stylistic**: `interpretedSyntax: .inlineOnlyPreservingWhitespace` reads a ``` fence line
    /// as one inline code run (`Scripts/markup-render.swift`, section 4), so a fence that
    /// reached `inline` would come back with its own markers eaten and its content restyled.
    /// The same all-or-nothing fence discipline `MarkupSkeleton.inlineCodeSpans` documents for
    /// its own fence-blind scan — and here, unlike there, the guarantee is local: this
    /// function is the only one a `codeBlock` is routed to.
    private static func codeBlock(_ source: String, language: String,
                                 config: MarkdownFontConfig) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                     startingColumn: 0, columnSpan: 1)
        block.setBorderColor(.separatorColor)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(config.baseSize * 0.6, type: .absoluteValueType, for: .padding)
        block.setWidth(codeCardHeaderHeight, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(config.baseSize * 0.6, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(config.baseSize * 0.6, type: .absoluteValueType, for: .margin, edge: .maxY)
        block.backgroundColor = .quaternaryLabelColor
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        let code = NSMutableAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: config.baseSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
        // Colour on top of the same bytes: the highlighter returns ranges into `source`, the
        // string is `source` verbatim, and only `.foregroundColor` changes — so `CodeRegion`'s
        // promise («the block's own bytes») and the RTF flavour both hold. No profile for the
        // language means no tokens and a block in the label colour, as before.
        for token in SyntaxHighlighter.tokens(in: source, language: language) {
            code.addAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.kind),
                              range: token.range)
        }
        return terminated(code)
    }

    private static func table(header: [Range<String.Index>], rows: [[Range<String.Index>]],
                              alignments: [MarkdownBlock.Alignment], in text: String,
                              config: MarkdownFontConfig) -> NSAttributedString {
        let columns = max(alignments.count,
                          max(header.count, rows.map(\.count).max() ?? 0))
        guard columns > 0 else { return NSAttributedString() }
        let table = NSTextTable()
        table.numberOfColumns = columns
        let result = NSMutableAttributedString()
        var row = 0
        let last = rows.count - 1 + (header.isEmpty ? 0 : 1)
        if !header.isEmpty {
            result.append(tableRow(header, table: table, row: 0, columns: columns,
                                   alignments: alignments, in: text, config: config,
                                   weight: .semibold, isHeader: true, isLast: last == 0))
            row = 1
        }
        for cells in rows {
            result.append(tableRow(cells, table: table, row: row, columns: columns,
                                   alignments: alignments, in: text, config: config,
                                   weight: .regular, isHeader: false, isLast: row == last))
            row += 1
        }
        return result
    }

    /// Rules between rows, not a grid: a 1 pt rule under every row and none between columns,
    /// which is how every reading surface this app is compared with draws a table (GitHub,
    /// ChatGPT, Claude) — a full grid reads as a spreadsheet. The header row is filled and
    /// semibold, so the eye finds it without a heavier rule; the last row carries the table's
    /// bottom margin, because a margin on every row would be a gap between rows.
    private static func tableRow(_ cells: [Range<String.Index>], table: NSTextTable, row: Int,
                                 columns: Int, alignments: [MarkdownBlock.Alignment],
                                 in text: String, config: MarkdownFontConfig,
                                 weight: NSFont.Weight, isHeader: Bool,
                                 isLast: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for column in 0..<columns {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                         startingColumn: column, columnSpan: 1)
            block.setBorderColor(.separatorColor)
            block.setWidth(0, type: .absoluteValueType, for: .border)
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            if row == 0 { block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY) }
            if isHeader { block.backgroundColor = .quaternaryLabelColor }
            if isLast {
                block.setWidth(config.baseSize * 0.6, type: .absoluteValueType, for: .margin,
                               edge: .maxY)
            }
            block.setWidth(config.baseSize * 0.4, type: .absoluteValueType, for: .padding)
            block.setWidth(config.baseSize * 0.6, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(config.baseSize * 0.6, type: .absoluteValueType, for: .padding, edge: .maxX)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            style.alignment = alignment(alignments.indices.contains(column)
                                            ? alignments[column] : .unspecified)
            let attributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: style, .foregroundColor: NSColor.labelColor,
            ]
            let cell = cells.indices.contains(column) ? String(text[cells[column]]) : ""
            result.append(terminated(inline(cell,
                                            base: font(size: config.baseSize, weight: weight,
                                                       config: config),
                                            config: config, attributes: attributes)))
        }
        return result
    }

    /// A 1 × 1 `NSTextTable` with a bottom border, because that is the one horizontal rule
    /// AppKit has been *measured* to lay out (`NSTextTable` 2 × 2 at 395 × 68 pt headless).
    /// A bare `NSTextBlock` on an otherwise empty paragraph draws nothing reliably, and a run
    /// of «—» would be a rule whose length is a function of the font.
    private static func thematicBreak(config: MarkdownFontConfig) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                     startingColumn: 0, columnSpan: 1)
        block.setBorderColor(.clear)
        block.setBorderColor(.separatorColor, for: .minY)
        block.setWidth(0, type: .absoluteValueType, for: .border)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.paragraphSpacing = config.baseSize * 0.3
        style.paragraphSpacingBefore = config.baseSize * 0.3
        return NSAttributedString(string: "\u{200B}\n", attributes: [
            .paragraphStyle: style,
            .font: font(size: config.baseSize, weight: .regular, config: config),
        ])
    }

    // MARK: - Inline spans

    /// Foundation's parse of one block's own text, mapped onto fonts and attributes.
    ///
    /// `inlineOnlyPreservingWhitespace` and not `.full`, measured: `.full` is not lossless
    /// (soft breaks collapse and a paragraph boundary disappears from the characters) and it
    /// reads a four-space indent as code, which contradicts this pipeline's rule that indented
    /// text is prose. This option is byte-lossless on the same string and yields the bold /
    /// italic / code intents plus `link` — which is all the block layer above needs from it.
    ///
    /// `returnPartiallyParsedIfPossible`, and a `try?` behind it, because half a heading is
    /// the normal state of a stream and a thrown error must not cost the pane its text.
    private static func inline(_ source: String, base: NSFont, config: MarkdownFontConfig,
                               attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard !source.isEmpty,
              let parsed = try? AttributedString(markdown: source, options: options) else {
            var plain = attributes
            plain[.font] = base
            return NSAttributedString(string: source, attributes: plain)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var attrs = attributes
            var font = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
            }
            if intent.contains(.stronglyEmphasized) { font = applying(.bold, to: font) }
            if intent.contains(.emphasized) { font = applying(.italic, to: font) }
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attrs[.link] = link as NSURL
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attrs[.font] = font
            result.append(NSAttributedString(string: String(parsed[run.range].characters),
                                             attributes: attrs))
        }
        return result
    }

    // MARK: - Fonts, styles and terminators

    private static func bodyStyle(_ config: MarkdownFontConfig) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = config.baseSize * 0.65
        return style
    }

    /// Every block ends with its own paragraph terminator, so block spacing is a paragraph
    /// style rather than blank lines of text. Two reasons: the renderings concatenate (the
    /// streaming path depends on it), and a rich paste carries the spacing rather than empty
    /// paragraphs the destination has to clean up.
    ///
    /// **The terminator takes the last run's paragraph style and font, not its decorations.**
    /// It used to copy every attribute, and a block ending in an inline code span then ended in
    /// a newline carrying `.backgroundColor` — which AppKit paints from the last glyph to the
    /// end of the line, so «второй пункт с `кодом`» wore a grey bar to the right edge of the
    /// pane (seen in the 2026-09-02 preview). A link's underline and a strike-through would do
    /// the same.
    private static func terminated(_ attributed: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        var attributes: [NSAttributedString.Key: Any] = [:]
        if result.length > 0 {
            attributes = result.attributes(at: result.length - 1, effectiveRange: nil)
            for decoration in [NSAttributedString.Key.backgroundColor, .link, .underlineStyle,
                               .strikethroughStyle, .foregroundColor] {
                attributes.removeValue(forKey: decoration)
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: attributes))
        return result
    }

    static func font(size: CGFloat, weight: NSFont.Weight,
                     config: MarkdownFontConfig) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = system.fontDescriptor.withDesign(config.typeface.design),
              let designed = NSFont(descriptor: descriptor, size: size) else { return system }
        return designed
    }

    /// Bold and italic through the descriptor's symbolic traits rather than `NSFontManager`,
    /// which is main-actor-bound: this converter runs wherever its caller does, and the copy
    /// path has no reason to be on the main actor.
    static func applying(_ trait: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor
            .withSymbolicTraits(descriptorTraits(of: font).union(trait))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func descriptorTraits(of font: NSFont) -> NSFontDescriptor.SymbolicTraits {
        font.fontDescriptor.symbolicTraits
    }

    private static func alignment(_ alignment: MarkdownBlock.Alignment) -> NSTextAlignment {
        switch alignment {
        case .unspecified, .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }
}
