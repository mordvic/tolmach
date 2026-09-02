// Tests/MarkupKitTests/MarkdownToAttributedTests.swift
import AppKit
import Testing
@testable import MarkupKit
@testable import TranslationCore

private let config = MarkdownFontConfig(baseSize: 13, typeface: .system)

/// Every `(text, font)` pair of the rendering, in document order — the shape most assertions
/// below need and the one AppKit makes awkward to ask for.
private func runs(_ attributed: NSAttributedString) -> [(text: String, font: NSFont?)] {
    var result: [(String, NSFont?)] = []
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length),
                                  options: []) { value, range, _ in
        result.append(((attributed.string as NSString).substring(with: range),
                       value as? NSFont))
    }
    return result
}

/// The font in force where `needle` starts.
///
/// Located by character offset rather than by «the first run whose text contains this»: whether
/// two runs carrying equal-looking fonts are coalesced into one is AppKit's business, and a
/// lookup that assumed they were failed once under load with the needle split across two runs.
/// An offset cannot be split.
private func fontOf(_ attributed: NSAttributedString, containing needle: String) -> NSFont? {
    let range = (attributed.string as NSString).range(of: needle)
    guard range.location != NSNotFound else { return nil }
    return attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
}

private func traits(_ font: NSFont?) -> NSFontDescriptor.SymbolicTraits {
    font?.fontDescriptor.symbolicTraits ?? []
}

/// What actually got rendered, for the one flaky assertion above — see its comment.
private func runDump(_ attributed: NSAttributedString) -> String {
    var lines = ["string=\(attributed.string.debugDescription)"]
    attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
        let text = (attributed.string as NSString).substring(with: range)
        lines.append("\(text.debugDescription) font=\(String(describing: attrs[.font]))")
    }
    return lines.joined(separator: " · ")
}

@Test func headingsScaleBySizeAndAreSemibold() {
    let text = "# Первый\n\n## Второй\n\n### Третий\n\n#### Четвёртый\n\nАбзац.\n"
    let rendered = MarkdownToAttributed.rendering(of: text, config: config).attributed
    let sizes = ["Первый", "Второй", "Третий", "Четвёртый", "Абзац."].map {
        fontOf(rendered, containing: $0)?.pointSize ?? 0
    }
    // The design's ladder against the 13 pt base, each level asserted on its own: a single
    // «h1 is bigger than the body» would pass with every level collapsed onto one size.
    #expect(sizes == [21, 18, 16, 14, 13])
    #expect(traits(fontOf(rendered, containing: "Первый")).contains(.bold))
    #expect(!traits(fontOf(rendered, containing: "Абзац.")).contains(.bold))
}

@Test func headingsScaleWithTheContentFontRatherThanWithAConstant() {
    // `docs/adr/0008`: «Шрифт текста» governs every rendered run, headings included. A
    // heading built from a literal point size would keep 21 pt here.
    let large = MarkdownFontConfig(baseSize: 26, typeface: .system)
    let rendered = MarkdownToAttributed.rendering(of: "# Первый\n\nАбзац.\n", config: large)
    #expect(fontOf(rendered.attributed, containing: "Первый")?.pointSize == 42)
    #expect(fontOf(rendered.attributed, containing: "Абзац.")?.pointSize == 26)
}

@Test func inlineBoldItalicAndCodeReachTheirRuns() {
    let rendered = MarkdownToAttributed.rendering(
        of: "Абзац с **жирным**, *курсивом* и `кодом` внутри.\n", config: config).attributed
    #expect(traits(fontOf(rendered, containing: "жирным")).contains(.bold))
    #expect(traits(fontOf(rendered, containing: "курсивом")).contains(.italic))
    // Flaky, and deliberately made loud rather than quiet: ~1 in 50 full-suite runs on this
    // machine (2026-08-31; 4/20 under heavy concurrent load on the same commit, 0 in 200 000
    // standalone concurrent runs of the distilled `inline` path, 0 in 30 instrumented suite
    // runs), always as `fontOf(…, "кодом")` answering nil. MarkupKit holds no mutable statics,
    // so the race — if it is one — sits inside Foundation's Markdown parser or AppKit's font
    // machinery under load, and was never isolated. The dump in the comment below is what
    // turns the NEXT firing from «nil» into the actual runs; do not delete it as tidying.
    #expect(fontOf(rendered, containing: "кодом")?.isFixedPitch == true,
            Comment(rawValue: runDump(rendered)))
    // Not bold and not italic where the source said neither — otherwise the assertions above
    // would pass under a converter that made everything bold.
    #expect(!traits(fontOf(rendered, containing: "Абзац с ")).contains(.bold))
    #expect(!traits(fontOf(rendered, containing: "Абзац с ")).contains(.italic))
    // And the markers are gone from the characters, which is the visible half of the defect
    // this whole phase is about.
    #expect(!rendered.string.contains("**"))
}

@Test func aLinkCarriesItsDestination() {
    let rendered = MarkdownToAttributed.rendering(
        of: "Смотри [тут](https://x.org) внимательно.\n", config: config).attributed
    var found: URL?
    rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length),
                                options: []) { value, _, _ in
        if let url = value as? NSURL { found = url as URL }
    }
    #expect(found?.absoluteString == "https://x.org")
    #expect(rendered.string.contains("тут"))
    #expect(!rendered.string.contains("https://x.org"))
}

@Test func aCodeBlockCarriesItsSourceBytesVerbatim() {
    let text = "Текст\n\n```swift\nlet a = 1\n\tlet b = 2\n```\n\nЕщё.\n"
    let rendered = MarkdownToAttributed.rendering(of: text, config: config)
    #expect(rendered.codeRegions.count == 1)
    let region = rendered.codeRegions[0]
    // The bytes of the block, tab and all — this string is what the per-block «Скопировать»
    // hands over.
    #expect(region.source == "let a = 1\n\tlet b = 2")
    // …and the region really points at those bytes inside the attributed string, so the
    // overlay button is measured against the code and not against the paragraph above it.
    #expect((rendered.attributed.string as NSString).substring(with: region.range)
            == region.source)
    #expect(fontOf(rendered.attributed, containing: "let a = 1")?.isFixedPitch == true)
    // The fence lines are not in the output at all.
    #expect(!rendered.attributed.string.contains("```"))
}

@Test func aCodeBlockIsNeverHandedToTheInlineParser() {
    // Measured (`Scripts/markup-render.swift` §4): `inlineOnlyPreservingWhitespace` reads a
    // ``` line as one inline code run, so a fence routed through `inline` comes back with its
    // markers eaten and its content restyled. Emphasis markers inside code are the cheapest
    // observable proof: an inline parse would consume them, and code that says `**` must keep
    // saying `**`.
    let text = "```\nprintf(\"**%s**\", s);\n_underscored_ = 1;\n```\n"
    let rendered = MarkdownToAttributed.rendering(of: text, config: config)
    #expect(rendered.attributed.string.contains("**%s**"))
    #expect(rendered.attributed.string.contains("_underscored_"))
    #expect(rendered.codeRegions.first?.source
            == "printf(\"**%s**\", s);\n_underscored_ = 1;")
}

@Test func tableCellsBecomeTextTableBlocksAtTheirOwnRowAndColumn() {
    let text = "| Колонка | Значение |\n|:---|---:|\n| a | 1 |\n\nПосле.\n"
    let rendered = MarkdownToAttributed.rendering(of: text, config: config).attributed
    var cells: [(row: Int, column: Int, text: String, alignment: NSTextAlignment)] = []
    rendered.enumerateAttribute(.paragraphStyle,
                                in: NSRange(location: 0, length: rendered.length),
                                options: []) { value, range, _ in
        guard let style = value as? NSParagraphStyle,
              let block = style.textBlocks.first as? NSTextTableBlock else { return }
        cells.append((block.startingRow, block.startingColumn,
                      (rendered.string as NSString).substring(with: range)
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      style.alignment))
    }
    #expect(cells.map(\.row) == [0, 0, 1, 1])
    #expect(cells.map(\.column) == [0, 1, 0, 1])
    #expect(cells.map(\.text) == ["Колонка", "Значение", "a", "1"])
    // Per-column alignment from the delimiter row, each column read separately — the whole
    // array compared at once would pass with the two columns swapped if they matched.
    #expect(cells[0].alignment == .left)
    #expect(cells[1].alignment == .right)
    // The header row is semibold and the data row is not.
    #expect(traits(fontOf(rendered, containing: "Колонка")).contains(.bold))
    #expect(!traits(fontOf(rendered, containing: "a")).contains(.bold))
    // The pipes and dashes never reach the screen.
    #expect(!rendered.string.contains("|"))
    #expect(!rendered.string.contains("---"))
}

@Test func listItemsCarryATextListAndAHangingIndent() {
    let text = "- первый\n- второй\n  - вложенный\n\nПосле.\n"
    let rendered = MarkdownToAttributed.rendering(of: text, config: config).attributed
    var styles: [NSParagraphStyle] = []
    rendered.enumerateAttribute(.paragraphStyle,
                                in: NSRange(location: 0, length: rendered.length),
                                options: []) { value, _, _ in
        if let style = value as? NSParagraphStyle, !style.textLists.isEmpty {
            styles.append(style)
        }
    }
    #expect(styles.count >= 3)
    // The hanging indent: the body of an item is indented further than its marker, or a
    // wrapped line would sit under the bullet.
    #expect(styles[0].headIndent > styles[0].firstLineHeadIndent)
    // …and the nested item is indented past the top-level one, which is what `depth` is for.
    #expect(styles.last!.firstLineHeadIndent > styles[0].firstLineHeadIndent)
    #expect(rendered.string.contains("•\tпервый"))
}

@Test func anOrderedListKeepsItsOwnNumbers() {
    let rendered = MarkdownToAttributed.rendering(of: "3. третий\n4. четвёртый\n\nx\n",
                                                  config: config).attributed
    // The document's numbers, not a renumbering from one: a translation that starts a list at
    // 3 says 3 because its source did.
    #expect(rendered.string.contains("3.\tтретий"))
    #expect(rendered.string.contains("4.\tчетвёртый"))
}

@Test func aBlockquoteWearsALeftBarAndIsSecondary() {
    let rendered = MarkdownToAttributed.rendering(of: "> цитата\n\n> > глубже\n\nАбзац.\n",
                                                  config: config).attributed
    var quoteColour: NSColor?
    var bars: [(left: CGFloat, indent: CGFloat)] = []
    rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length),
                                 options: []) { attrs, range, _ in
        let text = (rendered.string as NSString).substring(with: range)
        guard text.contains("цитата") || text.contains("глубже") else { return }
        quoteColour = attrs[.foregroundColor] as? NSColor
        guard let block = (attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first
                as? NSTextTableBlock else { return }
        bars.append((block.width(for: .border, edge: .minX), block.width(for: .margin, edge: .minX)))
    }
    // Semantic, so both appearances hold with no second palette.
    #expect(quoteColour == NSColor.secondaryLabelColor)
    // The bar every reader knows a quote by — a border on the leading edge only, in the
    // paragraph style so the RTF flavour carries it — and depth as an indent of the whole block.
    #expect(bars.count == 2)
    #expect(bars.allSatisfy { $0.left > 0 })
    #expect(bars[1].indent > bars[0].indent)
    // The marker is not drawn.
    #expect(!rendered.string.contains(">"))
}

/// Rules between rows and a filled header, not a grid: how GitHub, ChatGPT and Claude draw a
/// table, and the reason a full grid was replaced — it read as a spreadsheet.
@Test func aTableHasAFilledHeaderRowAndHorizontalRulesOnly() {
    let rendered = MarkdownToAttributed.rendering(of: "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nПосле.",
                                                  config: config).attributed
    var header: [NSTextTableBlock] = []
    var body: [NSTextTableBlock] = []
    rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length),
                                options: []) { value, _, _ in
        guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
              block.table.numberOfColumns == 2 else { return }
        (block.startingRow == 0 ? header : body).isEmpty ? () : ()
        if block.startingRow == 0 { header.append(block) } else { body.append(block) }
    }
    #expect(header.count == 2)
    #expect(body.count == 4)
    #expect(header.allSatisfy { $0.backgroundColor != nil })
    #expect(body.allSatisfy { $0.backgroundColor == nil })
    for block in header + body {
        #expect(block.width(for: .border, edge: .minX) == 0)
        #expect(block.width(for: .border, edge: .maxX) == 0)
        #expect(block.width(for: .border, edge: .maxY) > 0)
    }
    // The table's bottom margin sits on its last row alone, so rows stay tight and the
    // paragraph after the table does not touch it.
    let lastRow = body.filter { $0.startingRow == 2 }
    #expect(lastRow.allSatisfy { $0.width(for: .margin, edge: .maxY) > 0 })
    #expect(body.filter { $0.startingRow == 1 }.allSatisfy { $0.width(for: .margin, edge: .maxY) == 0 })
}

/// The newline that ends a block carries no run decoration. It used to copy the last run's
/// background, and a list item ending in inline code wore a grey bar to the right edge of the
/// pane — AppKit paints a newline's background from the last glyph to the line's end.
@Test func theBlockTerminatorCarriesNoBackgroundOrLinkFromTheLastRun() {
    let rendered = MarkdownToAttributed.rendering(of: "- пункт с `кодом`\n\nсм. [сайт](https://x.org)\n",
                                                  config: config).attributed
    let string = rendered.string as NSString
    var index = 0
    while index < string.length {
        if string.character(at: index) == 0x0A {
            let attrs = rendered.attributes(at: index, effectiveRange: nil)
            #expect(attrs[.backgroundColor] == nil, "newline at \(index) carries a background")
            #expect(attrs[.link] == nil)
            #expect(attrs[.underlineStyle] == nil)
        }
        index += 1
    }
}

@Test func renderingSomeBlocksConcatenatesIntoTheSameDocumentAsRenderingAllOfThem() {
    // The property the streaming path rests on: the pane renders the settled prefix now and
    // the rest later, and the result must be what one call would have produced. A block whose
    // spacing came from a blank line of text instead of a paragraph style would break it.
    let text = "# Заголовок\n\nАбзац один.\n\n- пункт\n\nАбзац два.\n"
    let blocks = MarkdownBlockScanner.blocks(of: text)
    let whole = MarkdownToAttributed.rendering(blocks: blocks, in: text, config: config)
    let head = MarkdownToAttributed.rendering(blocks: Array(blocks.prefix(2)), in: text,
                                              config: config)
    let tail = MarkdownToAttributed.rendering(blocks: Array(blocks.dropFirst(2)), in: text,
                                              config: config)
    let joined = NSMutableAttributedString(attributedString: head.attributed)
    joined.append(tail.attributed)
    // Characters first — that is where a spacing blank line would show up — then the fonts run
    // by run. **Not `isEqual(to:)`**: every list item builds its own `NSTextList` and every
    // table its own `NSTextTable`, and `NSParagraphStyle` compares those by identity, so two
    // renderings of the same document are never `isEqual` however identical they look.
    #expect(joined.string == whole.attributed.string)
    let shape: (NSAttributedString) -> [String] = { attributed in
        runs(attributed).map { "\($0.text)|\($0.font?.fontName ?? "")|\($0.font?.pointSize ?? 0)" }
    }
    #expect(shape(joined) == shape(whole.attributed))
}

@Test func aCodeRegionShiftsWithTheTextItIsAppendedAfter() {
    let region = MarkdownToAttributed.CodeRegion(range: NSRange(location: 4, length: 9),
                                                 source: "let x = 1")
    #expect(region.offset(by: 100).range == NSRange(location: 104, length: 9))
    #expect(region.offset(by: 100).source == "let x = 1")
}

@Test func theSourceModeIsTheSameCharactersInOneFont() {
    // «Исходник»: the same string, no conversion — today's pane, byte for byte.
    let text = "# Заголовок\n\nАбзац с **жирным**.\n"
    let plain = MarkdownToAttributed.plain(text, config: config)
    #expect(plain.string == text)
    #expect(runs(plain).count == 1)
    #expect(runs(plain)[0].font?.pointSize == 13)
}

@Test func theRenderedDocumentSurvivesTheRTFRoundTripTheCopyPathUses() {
    let text = "# Заголовок\n\nАбзац с **жирным**.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
    let rendered = MarkdownToAttributed.rendering(of: text, config: config)
    guard let rtf = rendered.rtf else { Issue.record("no rtf produced"); return }
    guard let reread = NSAttributedString(rtf: rtf, documentAttributes: nil) else {
        Issue.record("the rtf did not read back"); return
    }
    // What matters about the flavour is that the structure the pane shows is in it: the bold
    // run, the heading's larger face and the table's cells.
    #expect(traits(fontOf(reread, containing: "жирным")).contains(.bold))
    #expect((fontOf(reread, containing: "Заголовок")?.pointSize ?? 0) > 13)
    var tableCells = 0
    reread.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: reread.length),
                              options: []) { value, _, _ in
        if let style = value as? NSParagraphStyle,
           style.textBlocks.first is NSTextTableBlock { tableCells += 1 }
    }
    #expect(tableCells == 4)
}

@Test func aHalfArrivedBlockRendersRatherThanThrowing() {
    // `returnPartiallyParsedIfPossible` plus a `try?`: half a heading is the normal state of a
    // stream, and the pane may not lose its text to it.
    for fragment in ["# Заголово", "Текст с **незакрытым", "| a | b", "```swift\nlet x = 1"] {
        let rendered = MarkdownToAttributed.rendering(of: fragment, config: config)
        #expect(rendered.attributed.length > 0, "\(fragment.debugDescription) rendered nothing")
    }
}

// MARK: - The code card (spec #72, step 5)

/// A code block is a card: a bordered text block, the way every table cell already is, so the
/// frame is part of the attributed string and rides into the RTF flavour — and the language the
/// fence named travels on the region, for the overlay label, never as characters.
@Test func aCodeBlockIsABorderedCardAndItsLanguageRidesOnTheRegionNotInTheText() {
    let text = "Текст\n\n```swift\nlet a = 1\n```\n\n```\nплоский\n```\n"
    let rendered = MarkdownToAttributed.rendering(of: text, config: config)
    #expect(rendered.codeRegions.map(\.language) == ["swift", nil])
    // The language is an overlay's business. In the text — and therefore in the RTF and in a
    // drag-selection copy — it must not appear.
    #expect(!rendered.attributed.string.contains("swift"))
    let style = rendered.attributed.attribute(.paragraphStyle, at: rendered.codeRegions[0].range.location,
                                              effectiveRange: nil) as? NSParagraphStyle
    guard let block = style?.textBlocks.first as? NSTextTableBlock else {
        Issue.record("the code paragraph carries no text block"); return
    }
    #expect(block.width(for: .border, edge: .minX) > 0)
    #expect(block.width(for: .border, edge: .maxY) > 0)
    // Room above the code for the header the overlays sit in — a constant, not a multiple of
    // the font, because the header holds a system-sized control (`docs/adr/0008`).
    #expect(block.width(for: .padding, edge: .minY) >= MarkdownToAttributed.codeCardHeaderHeight)
}

@Test func theCodeCardSurvivesTheRTFRoundTrip() {
    let rendered = MarkdownToAttributed.rendering(of: "```sh\nswift build\n```\n", config: config)
    guard let rtf = rendered.rtf,
          let reread = NSAttributedString(rtf: rtf, documentAttributes: nil) else {
        Issue.record("no rtf, or it did not read back"); return
    }
    #expect(reread.string.contains("swift build"))
    #expect(!reread.string.contains("sh\n"))
    var bordered = 0
    reread.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: reread.length),
                              options: []) { value, _, _ in
        if let style = value as? NSParagraphStyle,
           let block = style.textBlocks.first as? NSTextTableBlock,
           block.width(for: .border, edge: .minX) > 0 { bordered += 1 }
    }
    #expect(bordered >= 1)
}

// MARK: - Plain bullets (spec #72, step 6)

/// The renderer draws «•»-lines as the list they are, through the same `listItem` path a
/// Markdown list takes; «Исходник» — `plain` — still shows the characters the user gave.
@Test func plainBulletLinesAreDrawnAsAListAndLeftAloneInTheSourceMode() {
    let text = "Список:\n\n• раз\n• два\n\nПосле."
    let rendered = MarkdownToAttributed.rendering(of: text, config: config).attributed
    var listed = 0
    rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length),
                                options: []) { value, _, _ in
        if let style = value as? NSParagraphStyle, !style.textLists.isEmpty { listed += 1 }
    }
    #expect(listed >= 2)
    #expect(rendered.string.contains("•\tраз"))
    #expect(!rendered.string.contains("• раз"))
    #expect(MarkdownToAttributed.plain(text, config: config).string == text)
}

// MARK: - Syntax colours in the card

/// A fence that names a language gets its keywords, strings and comments coloured; a bare fence
/// stays in the label colour. The bytes are untouched either way — `CodeRegion.source` is the
/// promise the per-block «Скопировать» rests on.
@Test func aNamedFenceIsColouredAndABareOneIsNot() {
    let named = MarkdownToAttributed.rendering(of: "```swift\nlet x = \"a\" // c\n```\n", config: config)
    let bare = MarkdownToAttributed.rendering(of: "```\nlet x = \"a\" // c\n```\n", config: config)
    #expect(named.codeRegions.first?.source == "let x = \"a\" // c")
    #expect(bare.codeRegions.first?.source == named.codeRegions.first?.source)
    func colour(_ rendering: MarkdownToAttributed.Rendering, of needle: String) -> NSColor? {
        let range = (rendering.attributed.string as NSString).range(of: needle)
        return rendering.attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }
    #expect(colour(named, of: "let") == SyntaxPalette.color(for: .keyword))
    #expect(colour(named, of: "\"a\"") == SyntaxPalette.color(for: .string))
    #expect(colour(named, of: "// c") == SyntaxPalette.color(for: .comment))
    // `x` is an identifier — nothing the lexer colours.
    #expect(colour(named, of: "x") == NSColor.labelColor)
    #expect(colour(bare, of: "let") == NSColor.labelColor)
}
