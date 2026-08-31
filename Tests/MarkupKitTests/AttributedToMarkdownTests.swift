import Testing
import AppKit
import Foundation
@testable import MarkupKit
@testable import TranslationCore

// Two kinds of test here, and both are needed. The constructed attributed strings pin each
// heuristic on its own, with nothing between the assertion and the rule it is about. The RTF
// fixture at the bottom goes through AppKit's real importer, because what actually lands on a
// pasteboard is RTF and the importer decides what attributes this code ever sees — a heuristic
// that is right about an attributed string nobody produces is not right about anything.

// MARK: - Building attributed strings by hand

// **Named fonts, not the system font's synthesized family**, and that is a measured choice rather
// than a stylistic one. Two things pushed it: what an RTF flavour actually carries is a named face
// (`\fswiss Helvetica`, `\fmodern Courier` — the fixture at the bottom of this file goes through
// the importer and comes back with exactly those), and three tests written against
// `NSFont.boldSystemFont` failed twice in about fifteen suite runs with every inline marker
// missing, as though the runs had carried no font at all. That was never isolated: 9 600
// concurrent trait reads in a standalone probe and 400 conversions in a tight in-process loop
// never reproduced it, and the fixture built on Helvetica-Bold never once flaked. So the fixtures
// use the faces a document uses, and the flake — reproducible or not — has no purchase here. If it
// ever returns, it is `docs/reference/PLATFORM-TRAPS.md` material and not a test to weaken.
private func named(_ name: String, _ size: CGFloat) -> NSFont {
    NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
}

private func body(_ size: CGFloat = 12) -> NSFont { named("Helvetica", size) }

private func bold(_ size: CGFloat = 12) -> NSFont { named("Helvetica-Bold", size) }

private func italic(_ size: CGFloat = 12) -> NSFont { named("Helvetica-Oblique", size) }

private func mono(_ size: CGFloat = 12) -> NSFont { named("Courier", size) }

/// One paragraph, its runs given as `(text, attributes)`, with the terminator AppKit's own
/// paragraph ranges need.
private func paragraph(_ runs: [(String, [NSAttributedString.Key: Any])],
                       style: NSParagraphStyle? = nil) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for (text, attributes) in runs {
        var attributes = attributes
        if let style { attributes[.paragraphStyle] = style }
        result.append(NSAttributedString(string: text, attributes: attributes))
    }
    var terminator: [NSAttributedString.Key: Any] = [.font: body()]
    if let style { terminator[.paragraphStyle] = style }
    result.append(NSAttributedString(string: "\n", attributes: terminator))
    return result
}

private func document(_ paragraphs: [NSAttributedString]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for paragraph in paragraphs { result.append(paragraph) }
    return result
}

/// Enough body text that `bodySize` has something to count. Without it every test would be
/// measuring a document whose only size is the one under test, which is precisely the case the
/// heuristic cannot answer.
private func bodyParagraph() -> NSAttributedString {
    paragraph([("Обычный абзац, задающий размер основного текста документа.", [.font: body()])])
}

// MARK: - Inline runs

@Test func boldAndItalicRunsBecomeTheirMarkers() {
    let text = document([bodyParagraph(),
                         paragraph([("Совсем ", [.font: body()]),
                                    ("жирный", [.font: bold()]),
                                    (" и ", [.font: body()]),
                                    ("курсивный", [.font: italic()]),
                                    (" текст", [.font: body()])])])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix(
        "Совсем **жирный** и *курсивный* текст"))
}

@Test func adjacentRunsOfTheSameFormattingAreOneSpan() {
    // An importer splits a string at every attribute change of any kind — a kerning value, a
    // colour — and two adjacent bold runs written separately come out `**раз****два**`, four
    // literal asterisks in the text handed to the model.
    let text = document([bodyParagraph(),
                         paragraph([("раз", [.font: bold()]),
                                    ("два", [.font: bold(), .kern: 0.5])])])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix("**раздва**"))
}

@Test func aMonospacedRunBecomesInlineCode() {
    let text = document([bodyParagraph(),
                         paragraph([("Вызовите ", [.font: body()]),
                                    ("read()", [.font: mono()]),
                                    (" первым", [.font: body()])])])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix("Вызовите `read()` первым"))
}

@Test func aLinkBecomesAMarkdownLinkOnlyForAURLTarget() {
    let url = document([bodyParagraph(),
                        paragraph([("см. ", [.font: body()]),
                                   ("сайт", [.font: body(),
                                             .link: URL(string: "https://x.org")!])])])
    #expect(AttributedToMarkdown.markdown(from: url).hasSuffix("см. [сайт](https://x.org)"))

    // A `.link` may be a string, and an internal anchor is a link but not a URL — the same
    // filter `MarkupSkeleton.targetIsURL` applies to a Markdown link's target.
    let anchor = document([bodyParagraph(),
                           paragraph([("см. ", [.font: body()]),
                                      ("раздел", [.font: body(), .link: "#_Toc42"])])])
    #expect(AttributedToMarkdown.markdown(from: anchor).hasSuffix("см. раздел"))
}

// MARK: - Code blocks

@Test func aWhollyMonospacedParagraphBecomesAFenceAndConsecutiveOnesBecomeOne() {
    let text = document([bodyParagraph(),
                         paragraph([("let x = 1", [.font: mono()])]),
                         paragraph([("    return x", [.font: mono()])])])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix(
        "```\nlet x = 1\n    return x\n```"))
}

@Test func aCodeBlockKeepsItsIndentationAndTakesNoInlineMarkers() {
    // Verbatim: no collapsing, no trimming, and no backticks inside the fence — the whole
    // paragraph is already code.
    let text = document([bodyParagraph(),
                         paragraph([("if x {", [.font: mono()])]),
                         paragraph([("\t\treturn", [.font: mono(), .kern: 1.0])]),
                         paragraph([("}", [.font: mono()])])])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix(
        "```\nif x {\n\t\treturn\n}\n```"))
}

// MARK: - Lists

/// `NSTextList` plus the literal marker characters in the text: AppKit's own pairing, which
/// `MarkdownToAttributed.listItem` writes from the other direction because the HTML import
/// produces exactly it.
private func listStyle(_ formats: [NSTextList.MarkerFormat], indent: CGFloat = 0)
    -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.textLists = formats.map { NSTextList(markerFormat: $0, options: 0) }
    style.headIndent = indent
    return style
}

@Test func aTextListParagraphBecomesAListItemWithoutItsMarkerCharacters() {
    let text = document([bodyParagraph(),
                         paragraph([("\t•\tпервый", [.font: body()])],
                                   style: listStyle([.disc])),
                         paragraph([("\t•\tвторой", [.font: body()])],
                                   style: listStyle([.disc]))])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix("- первый\n- второй"))
}

@Test func nestingBecomesIndentation() {
    let text = document([bodyParagraph(),
                         paragraph([("\t•\tснаружи", [.font: body()])],
                                   style: listStyle([.disc])),
                         paragraph([("\t•\tвнутри", [.font: body()])],
                                   style: listStyle([.disc, .disc]))])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix("- снаружи\n  - внутри"))
}

@Test func anOrderedListKeepsTheDocumentsOwnNumbers() {
    // The document's numbers, not a counter kept here: an item numbered 4 in a list the user
    // selected from the middle is still item 4, and renumbering it from 1 edits their document.
    let text = document([bodyParagraph(),
                         paragraph([("\t4.\tчетвёртый", [.font: body()])],
                                   style: listStyle([.decimal])),
                         paragraph([("\t5.\tпятый", [.font: body()])],
                                   style: listStyle([.decimal]))])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix("4. четвёртый\n5. пятый"))
}

@Test func aListItemWithNoMarkerCharactersFallsBackToItsMarkerFormat() {
    let bullet = document([bodyParagraph(),
                           paragraph([("первый", [.font: body()])], style: listStyle([.disc]))])
    #expect(AttributedToMarkdown.markdown(from: bullet).hasSuffix("- первый"))

    let ordered = document([bodyParagraph(),
                            paragraph([("первый", [.font: body()])],
                                      style: listStyle([.decimal]))])
    #expect(AttributedToMarkdown.markdown(from: ordered).hasSuffix("1. первый"))
}

@Test func aTabFurtherIntoALineIsTheAuthorsOwnTab() {
    // Only the marker region is searched. A tab in the middle of the item's text belongs to the
    // user, and eating everything up to it would silently delete their words.
    let text = document([bodyParagraph(),
                         paragraph([("\t•\tключ:\tзначение", [.font: body()])],
                                   style: listStyle([.disc]))])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix("- ключ:\tзначение"))
}

// MARK: - Tables

private func cellStyle(_ table: NSTextTable, row: Int, column: Int) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.textBlocks = [NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                         startingColumn: column, columnSpan: 1)]
    return style
}

@Test func textTableBlocksBecomePipeRowsWithNoInventedHeader() {
    let table = NSTextTable()
    table.numberOfColumns = 2
    let text = document([bodyParagraph(),
                         paragraph([("Ключ", [.font: bold()])],
                                   style: cellStyle(table, row: 0, column: 0)),
                         paragraph([("Значение", [.font: bold()])],
                                   style: cellStyle(table, row: 0, column: 1)),
                         paragraph([("раз", [.font: body()])],
                                   style: cellStyle(table, row: 1, column: 0)),
                         paragraph([("1", [.font: body()])],
                                   style: cellStyle(table, row: 1, column: 1))])
    let markdown = AttributedToMarkdown.markdown(from: text)
    // No delimiter row: RTF carries no header flag, and `MarkdownBlockScanner`'s own rule is
    // that inventing one renders a row of data in semibold.
    #expect(markdown.hasSuffix("| **Ключ** | **Значение** |\n| раз | 1 |"))
    #expect(!markdown.contains("---"))
    // The rows still read back as a table — headerless, which is what it honestly is.
    guard case let .table(header, rows, _)? = MarkdownBlockScanner.blocks(of: markdown).last else {
        Issue.record("the rows did not parse back as a table")
        return
    }
    #expect(header.isEmpty)
    #expect(rows.count == 2)
}

@Test func aCellHoldingTwoParagraphsIsOneCellAndItsPipeIsEscaped() {
    let table = NSTextTable()
    table.numberOfColumns = 1
    let text = document([bodyParagraph(),
                         paragraph([("раз", [.font: body()])],
                                   style: cellStyle(table, row: 0, column: 0)),
                         paragraph([("два|три", [.font: body()])],
                                   style: cellStyle(table, row: 0, column: 0))])
    #expect(AttributedToMarkdown.markdown(from: text).hasSuffix("| раз два\\|три |"))
}

// MARK: - Headings, and what is deliberately not one

@Test func aHeadingsLevelComesFromItsSizeRelativeToTheBody() {
    // The ladder, at a 12 pt body: ×1.8 → h1, ×1.4 → h2, ×1.15 → h3.
    //
    // The last *line* is compared, not a suffix: `hasSuffix("# Отчёт")` is true of «## Отчёт»
    // too, so the suffix spelling passed with the h1 rung wired to return 2 — measured, by
    // making exactly that change and watching it stay green.
    for (size, level) in [(24.0, 1), (18.0, 2), (14.0, 3)] {
        let text = document([bodyParagraph(),
                             paragraph([("Отчёт", [.font: bold(size)])])])
        let markdown = AttributedToMarkdown.markdown(from: text)
        #expect(markdown.split(separator: "\n").last.map(String.init)
                    == String(repeating: "#", count: level) + " Отчёт")
        #expect(MarkupSkeleton.tokens(of: markdown).contains(.heading(level: level)))
    }
}

@Test func aBoldBodySizedParagraphStaysABoldParagraph() {
    // h4…h6 are at or below body size in AppKit's own rendering of HTML, so they cannot be told
    // from bold prose. The safe direction: the gate refuses a conversion that only added inline
    // markers, so a missed heading costs the capture its rich reading — a fabricated one would
    // ride into every chunk's prompt.
    let text = document([bodyParagraph(), paragraph([("Итоги", [.font: bold()])])])
    let markdown = AttributedToMarkdown.markdown(from: text)
    #expect(markdown.hasSuffix("**Итоги**"))
    #expect(!markdown.contains("#"))
}

@Test func aLongParagraphIsNeverAHeadingHoweverLargeItIsSet() {
    // A pull quote set at 1.5× body is a paragraph; `# ` in front of four lines of prose is a
    // worse error than a lost heading.
    //
    // **Six body paragraphs, and that is what makes the test about the limit.** With one, the long
    // paragraph's own 264 characters *are* the most-covered point size, so `bodySize` came back 18,
    // the ratio came back 1.0 and the paragraph was no heading for a reason that has nothing to do
    // with its length — measured, by deleting the limit and watching the test stay green.
    let long = String(repeating: "Очень длинная строка. ", count: 12)
    #expect(long.count > AttributedToMarkdown.headingCharacterLimit)
    let text = document(Array(repeating: bodyParagraph(), count: 6)
                            + [paragraph([(long, [.font: bold(18)])])])
    #expect(AttributedToMarkdown.bodySize(of: text) == 12)
    #expect(!AttributedToMarkdown.markdown(from: text).contains("#"))
}

@Test func aSelectionThatIsOnlyAHeadingHasNoBodySizeAndComesOutAsAParagraph() {
    // Stated as a limit rather than worked around: «relative to the body» has no answer when
    // there is no body, and the alternative — an absolute point-size ladder — makes every
    // paragraph of an 18 pt document a heading.
    let text = document([paragraph([("Отчёт", [.font: bold(24)])])])
    #expect(AttributedToMarkdown.markdown(from: text) == "**Отчёт**")
}

@Test func anIndentedParagraphIsNotReadAsAQuote() {
    // Indentation is prose everywhere in this pipeline — `PromptBuilder.protectionRules` carries
    // that rule with its history — and a `> ` this converter invented is exactly the kind of
    // block token the acceptance gate accepts on. So blockquotes are not derived from RTF at all.
    let style = NSMutableParagraphStyle()
    style.firstLineHeadIndent = 36
    style.headIndent = 36
    let text = document([bodyParagraph(),
                         paragraph([("Здравствуйте, коллеги", [.font: body()])], style: style)])
    let markdown = AttributedToMarkdown.markdown(from: text)
    #expect(markdown.hasSuffix("Здравствуйте, коллеги"))
    #expect(!markdown.contains(">"))
}

// MARK: - Through AppKit's own importer

/// A hand-written RTF document rather than a captured one: it is small enough to read, and every
/// attribute the assertions depend on is visible in it. What it proves is the part a constructed
/// attributed string cannot — that the importer produces attributes these heuristics recognise.
private let rtfFixture = #"""
{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier;}}
\f0\fs24 Plain body paragraph, long enough to set the body size of this document.\par
\b\fs36 Report\b0\fs24\par
Body with \b bold\b0  and \f1 code\f0  inside.\par
}
"""#

@Test func aRealRtfDocumentComesBackThroughTheImporterAsMarkdown() {
    let markdown = AttributedToMarkdown.markdown(fromRTF: Data(rtfFixture.utf8))
    guard let markdown else {
        Issue.record("AppKit refused the RTF fixture")
        return
    }
    // 18 pt against a 12 pt body is ×1.5 — h2 on the ladder.
    #expect(markdown.contains("## Report"))
    #expect(markdown.contains("**bold**"))
    #expect(markdown.contains("`code`"))
    // And the whole thing is one document with the blocks separated, not a run-together line.
    #expect(markdown.hasPrefix("Plain body paragraph"))
    let tokens = MarkupSkeleton.tokens(of: markdown)
    #expect(tokens.contains(.heading(level: 2)))
}

@Test func theImporterFaceRefusesDataThatIsNotRTF() {
    // A refusal costs the capture its markup and nothing else — the plain flavour is what gets
    // translated.
    #expect(AttributedToMarkdown.markdown(fromRTF: Data("не RTF".utf8)) == nil)
}
