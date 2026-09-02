// Tests/TranslationCoreTests/MarkdownBlocksTests.swift
import Testing
@testable import TranslationCore

/// The document every «what did it read» test below runs against, in one place so the LF, CRLF
/// and CR copies are provably the same document with three line-ending conventions.
private let sample = """
# Заголовок

Абзац с **жирным** и `кодом`.

- пункт один
- пункт два
  - вложенный

> цитата

| Колонка | Значение |
|:---|---:|
| a | 1 |

```swift
let x = 1
```

---

Последний абзац.
"""

private func kinds(_ blocks: [MarkdownBlock]) -> [String] {
    blocks.map { block in
        switch block {
        case .heading(let level, _): "heading\(level)"
        case .paragraph: "paragraph"
        case .listItem(let depth, _, _): "listItem\(depth)"
        case .blockquote(let depth, _): "blockquote\(depth)"
        case .codeBlock(_, _, let closed): closed ? "codeBlock" : "codeBlock(open)"
        case .table: "table"
        case .thematicBreak: "thematicBreak"
        }
    }
}

/// The document with every LF replaced by one other convention — the same *document*, not a
/// similar one, which is what makes the three readings comparable.
private func reEnded(_ text: String, with terminator: String) -> String {
    text.replacingOccurrences(of: "\n", with: terminator)
}

@Test func readsEveryBlockFormOfADocument() {
    #expect(kinds(MarkdownBlockScanner.blocks(of: sample)) == [
        "heading1", "paragraph", "listItem0", "listItem0", "listItem1", "blockquote1",
        "table", "codeBlock", "thematicBreak", "paragraph",
    ])
}

@Test func readsTheSameBlocksUnderEveryLineEndingConvention() {
    // `components(separatedBy: .newlines)` splits "\r\n" into two breaks and fabricates a
    // paragraph; `firstIndex(of: "\n")` never matches the single Character "\r\n". Both
    // defects are in this repo's history, which is why all three conventions are asserted
    // rather than only the exotic one.
    let lf = kinds(MarkdownBlockScanner.blocks(of: sample))
    for terminator in ["\r\n", "\r", "\u{2028}"] {
        #expect(kinds(MarkdownBlockScanner.blocks(of: reEnded(sample, with: terminator))) == lf,
                "line ending \(terminator.debugDescription) read a different document")
    }
}

@Test func aCodeBlocksRangeIsTheSourceBytesAndNothingElse() {
    let text = "Текст\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nЕщё.\n"
    let blocks = MarkdownBlockScanner.blocks(of: text)
    guard case let .codeBlock(lang, range, closed) = blocks[1] else {
        Issue.record("expected a code block, got \(kinds(blocks))"); return
    }
    #expect(lang == "swift")
    #expect(closed)
    // Byte-exact: no fence line, no leading or trailing terminator.
    #expect(String(text[range]) == "let x = 1\nlet y = 2")
}

@Test func aCodeBlocksRangeKeepsTheDocumentsOwnLineEndings() {
    let text = "```\r\nlet x = 1\r\nlet y = 2\r\n```\r\n"
    guard case let .codeBlock(_, range, _) = MarkdownBlockScanner.blocks(of: text)[0] else {
        Issue.record("expected a code block"); return
    }
    // Not "\n": a copy of this block must be the bytes the file held.
    #expect(String(text[range]) == "let x = 1\r\nlet y = 2")
}

@Test func anUnterminatedFenceIsAnOpenCodeBlockThatSwallowsTheRest() {
    let text = "Текст\n\n```swift\nlet x = 1\nlet y = 2\n"
    let blocks = MarkdownBlockScanner.blocks(of: text)
    guard case let .codeBlock(_, range, closed) = blocks[1] else {
        Issue.record("expected a code block, got \(kinds(blocks))"); return
    }
    #expect(!closed)
    #expect(String(text[range]) == "let x = 1\nlet y = 2")
}

@Test func indentedTextIsProseAndNeverCode() {
    // The pipeline's own rule, and the one place Foundation's `.full` parser disagrees with
    // it: measured, it reads a four-space indent as a code block and an indented quoted email
    // as one too. Either reading here would render text the engine cheerfully translated as
    // untranslatable code.
    let text = "Абзац:\n\n    отступ на четыре пробела\n\nещё абзац\n"
    #expect(kinds(MarkdownBlockScanner.blocks(of: text)) == ["paragraph", "paragraph", "paragraph"])
    let email = "Цитата письма:\n\n    > Здравствуйте, коллеги\n"
    // Indented, but still a quote — the indent contributes nothing either way.
    #expect(kinds(MarkdownBlockScanner.blocks(of: email)) == ["paragraph", "blockquote1"])
}

@Test func everyBlocksRangeCarriesItsOwnSourceBytes() {
    let text = "# Заголовок\n\nПервый абзац\nвторая строка.\n\n- пункт\n\n> цитата\n"
    let blocks = MarkdownBlockScanner.blocks(of: text)
    var seen: [String] = []
    for block in blocks {
        switch block {
        case .heading(_, let range), .paragraph(let range),
             .listItem(_, _, let range), .blockquote(_, let range):
            seen.append(String(text[range]))
        default: Issue.record("unexpected \(block)")
        }
    }
    // The markers are outside every range, the interior terminator is inside the paragraph's,
    // and nothing has been trimmed that the source did not put there.
    #expect(seen == ["Заголовок", "Первый абзац\nвторая строка.", "пункт", "цитата"])
}

@Test func aParagraphAndAFenceReassembleIntoTheSourceByteForByte() {
    // The looser half of the byte-exactness promise: for the two forms that carry no markers,
    // the ranges plus the blank lines between them *are* the document.
    let text = "Первый абзац.\n\n```\nкод\n```\n"
    let blocks = MarkdownBlockScanner.blocks(of: text)
    guard case let .paragraph(paragraph) = blocks[0],
          case let .codeBlock(_, code, _) = blocks[1] else {
        Issue.record("expected paragraph + codeBlock, got \(kinds(blocks))"); return
    }
    #expect(String(text[paragraph]) + "\n\n```\n" + String(text[code]) + "\n```\n" == text)
}

@Test func readsATablesHeaderRowsAndPerColumnAlignments() {
    let text = "| Колонка | Значение |\n|:---|---:|\n| a | 1 |\n| b | 2 |\n\nПосле.\n"
    guard case let .table(header, rows, alignments) = MarkdownBlockScanner.blocks(of: text)[0] else {
        Issue.record("expected a table"); return
    }
    #expect(header.map { String(text[$0]) } == ["Колонка", "Значение"])
    #expect(rows.map { $0.map { String(text[$0]) } } == [["a", "1"], ["b", "2"]])
    // Each alignment asserted on its own: `[.leading, .trailing]` compared as a whole would
    // pass with the two swapped only if both were the same, but a per-column read is what the
    // renderer does and what a swap must break.
    #expect(alignments[0] == .leading)
    #expect(alignments[1] == .trailing)
}

@Test func aTableWithoutADelimiterRowHasNoHeader() {
    let text = "| a | 1 |\n| b | 2 |\n\nПосле.\n"
    guard case let .table(header, rows, _) = MarkdownBlockScanner.blocks(of: text)[0] else {
        Issue.record("expected a table"); return
    }
    // Inventing a header here would draw the first row of data in semibold.
    #expect(header.isEmpty)
    #expect(rows.count == 2)
}

@Test func readsListDepthAndMarkerFromTheSameCodeTheDiffUses() {
    let text = "1. первый\n2. второй\n  - вложенный\n"
    let blocks = MarkdownBlockScanner.blocks(of: text)
    guard case let .listItem(_, first, _) = blocks[0],
          case let .listItem(_, second, _) = blocks[1],
          case let .listItem(depth, third, _) = blocks[2] else {
        Issue.record("expected three list items, got \(kinds(blocks))"); return
    }
    #expect(first == .ordered(1))
    #expect(second == .ordered(2))
    #expect(third == .bullet)
    #expect(depth == 1)
}

@Test func aLazyContinuationLineBelongsToItsListItem() {
    let text = "- пункт,\n  продолжение\n\nАбзац.\n"
    let blocks = MarkdownBlockScanner.blocks(of: text)
    guard case let .listItem(_, _, content) = blocks[0] else {
        Issue.record("expected a list item, got \(kinds(blocks))"); return
    }
    #expect(String(text[content]) == "пункт,\n  продолжение")
    #expect(kinds(blocks) == ["listItem0", "paragraph"])
}

@Test func aSetextUnderlineMakesTheParagraphAboveItAHeading() {
    // The same reading `MarkupSkeleton` has, through the same predicate: a "---" under
    // paragraph text is an H2 underline, not a thematic break.
    #expect(kinds(MarkdownBlockScanner.blocks(of: "Заголовок\n===\n\nАбзац.\n"))
            == ["heading1", "paragraph"])
    #expect(kinds(MarkdownBlockScanner.blocks(of: "Заголовок\n---\n\nАбзац.\n"))
            == ["heading2", "paragraph"])
    // …and with nothing above it, the same run is a break.
    #expect(kinds(MarkdownBlockScanner.blocks(of: "Абзац.\n\n---\n\nЕщё.\n"))
            == ["paragraph", "thematicBreak", "paragraph"])
}

// MARK: - settledPrefix

/// Every prefix of `text`, one character at a time — a stream arriving.
private func prefixes(of text: String) -> [String] {
    (0...text.count).map { String(text.prefix($0)) }
}

@Test func theSettledPrefixNeverShrinksAsTheDocumentGrows() {
    var previousTail = 0
    var previousKinds: [String] = []
    for arrived in prefixes(of: sample) {
        let (blocks, tail) = MarkdownBlockScanner.settledPrefix(of: arrived)
        let tailOffset = arrived.distance(from: arrived.startIndex, to: tail.lowerBound)
        #expect(tailOffset >= previousTail,
                "the settled prefix moved backwards at \(arrived.count) characters")
        #expect(blocks.count >= previousKinds.count,
                "a settled block was withdrawn at \(arrived.count) characters")
        // And the blocks that were already settled are the same blocks, in the same order.
        #expect(Array(kinds(blocks).prefix(previousKinds.count)) == previousKinds,
                "a settled block changed kind at \(arrived.count) characters")
        previousTail = tailOffset
        previousKinds = kinds(blocks)
    }
}

@Test func aSettledBlockNeverChangesItsRangeAsTheDocumentGrows() {
    // Kinds alone would pass under a scanner that kept the shape and moved the bytes, which is
    // the defect that would show as text jumping between two blocks on screen.
    var previous: [String] = []
    for arrived in prefixes(of: sample) {
        let (blocks, _) = MarkdownBlockScanner.settledPrefix(of: arrived)
        let contents: [String] = blocks.map { block in
            switch block {
            case .heading(_, let range), .paragraph(let range), .listItem(_, _, let range),
                 .blockquote(_, let range), .codeBlock(_, let range, _),
                 .thematicBreak(let range):
                return String(arrived[range])
            case .table(let header, let rows, _):
                return (header + rows.flatMap { $0 }).map { String(arrived[$0]) }
                    .joined(separator: "|")
            }
        }
        #expect(Array(contents.prefix(previous.count)) == previous,
                "a settled block's bytes changed at \(arrived.count) characters")
        previous = contents
    }
}

@Test func theTailIsExactlyWhatTheSettledBlocksDoNotAccountFor() {
    let text = "# Заголовок\n\nАбзац первый.\n\nАбзац вто"
    let (blocks, tail) = MarkdownBlockScanner.settledPrefix(of: text)
    #expect(kinds(blocks) == ["heading1", "paragraph"])
    // The unsettled tail starts at the first character of the unsettled block, so a renderer
    // can draw `text[..<tail.lowerBound]` from the blocks and the rest as plain characters
    // with nothing counted twice and nothing dropped.
    #expect(String(text[tail]) == "Абзац вто")
}

@Test func anUnclosedFenceIsNeverSettledAndItsClosingMarkerSettlesIt() {
    let open = "```swift\nlet x = 1\n"
    #expect(MarkdownBlockScanner.settledPrefix(of: open).blocks.isEmpty)
    // A blank line does not settle it — only the marker does, because an unclosed fence goes
    // on swallowing whatever arrives.
    #expect(MarkdownBlockScanner.settledPrefix(of: open + "\n").blocks.isEmpty)
    let closed = open + "```\n"
    #expect(kinds(MarkdownBlockScanner.settledPrefix(of: closed).blocks) == ["codeBlock"])
}

@Test func aTableIsNotSettledUntilANonPipeLineFollowsIt() {
    let rows = "| a | b |\n|---|---|\n| 1 | 2 |\n"
    #expect(MarkdownBlockScanner.settledPrefix(of: rows).blocks.isEmpty)
    // A fourth row could still arrive; a blank line proves none will.
    #expect(kinds(MarkdownBlockScanner.settledPrefix(of: rows + "\n").blocks) == ["table"])
}

@Test func aParagraphIsNotSettledWhileADashRunCouldStillUnderlineIt() {
    // The measured reason the rule is «a terminated line follows» and not «a blank line
    // follows»: after "-" the next byte can produce "--", which turns the paragraph above
    // into an H2. Settling the paragraph before that byte lands would draw it as a paragraph
    // and then have to redraw it as a heading.
    #expect(MarkdownBlockScanner.settledPrefix(of: "Заголовок\n-").blocks.isEmpty)
    #expect(kinds(MarkdownBlockScanner.settledPrefix(of: "Заголовок\n--\nx\n").blocks)
            == ["heading2"])
}

// MARK: - MarkdownPresence

@Test func proseThatMerelyContainsTheCharactersHasNoMarkup() {
    // The design's own probe string. Its single "*" is followed by a space, so it can open
    // nothing; "a_b_c.txt" is safe because "_" is deliberately not a signal; "#хэштег" is not
    // line-leading.
    #expect(!MarkdownPresence.hasMarkup("Цена 5 * 3 = 15, файл a_b_c.txt и #хэштег"))
    // A second, harder string: the first "*" is spaced and can open nothing, the second is
    // tight against its digits and *could* both open and close — but there is no third to
    // pair it with. Dropping either half of the flanking test turns this arithmetic into
    // «markup», and the design's own probe string above is too easy to catch that: it holds
    // one asterisk, so any pairing rule answers false for it.
    #expect(!MarkdownPresence.hasMarkup("Итого: 3 * 4 = 12, а 5*6 = 30"))
    // The closing half of the same rule, and a constructed string rather than observed prose:
    // the first run can open, the second cannot close because a space sits in front of it.
    // Without it the two halves of the flanking test are not separately pinned, which is
    // `docs/reference/TESTING.md`'s second shape — a flag that is a no-op in the combined value.
    #expect(!MarkdownPresence.hasMarkup("*звёздочка открывает, а закрыть нечем *"))
}

@Test func aLineLeadingHashIsMarkupAndAMidLineOneIsNot() {
    #expect(MarkdownPresence.hasMarkup("# Заголовок"))
    #expect(!MarkdownPresence.hasMarkup("Смотри пункт #3 и #4."))
}

@Test func pairedEmphasisAndInlineCodeAreMarkupInsidePlainProse() {
    #expect(MarkdownPresence.hasMarkup("Абзац с **жирным** словом."))
    #expect(MarkdownPresence.hasMarkup("Абзац с *курсивом* внутри."))
    #expect(MarkdownPresence.hasMarkup("Установите `keep_alive` в 30m."))
    // An unpaired marker is not markup, which is what keeps a half-arrived stream from
    // flipping the pane's toggle on and off.
    #expect(!MarkdownPresence.hasMarkup("Абзац с **незакрытым жирным"))
}

@Test func blockFormsAreMarkupEvenWithoutAnyInlineMarkers() {
    #expect(MarkdownPresence.hasMarkup("- пункт\n- пункт\n"))
    #expect(MarkdownPresence.hasMarkup("| a | b |\n|---|---|\n"))
    #expect(MarkdownPresence.hasMarkup("> цитата\n"))
    #expect(MarkdownPresence.hasMarkup("```\nкод\n```\n"))
    // …and two paragraphs of prose are not.
    #expect(!MarkdownPresence.hasMarkup("Первый абзац.\n\nВторой абзац.\n"))
}

@Test func presenceLooksAtABoundedPrefixOfTheDocument() {
    // Asked once per streamed token on documents up to 2 MB, so the scan is bounded. The
    // limitation is real: markup that begins past the bound is not seen, and the pane then
    // offers no toggle for it.
    let prose = String(repeating: "Обычная строка прозы без разметки.\n\n", count: 200)
    #expect(!MarkdownPresence.hasMarkup(prose))
    #expect(MarkdownPresence.hasMarkup(prose + "# Заголовок\n"))
    // …and with the bound cut short, the very same document reads as plain prose.
    #expect(!MarkdownPresence.hasMarkup(prose + "# Заголовок\n", inspecting: prose.count))
    // The bound errs safely: truncation can only remove markers, never pair two that were not
    // paired, so nothing inside the window becomes markup that was not.
    #expect(!MarkdownPresence.hasMarkup("Абзац с **жирным**.", inspecting: 12))
}

// MARK: - Plain bullets, for display only (spec #72, step 6)

/// «•» and «–» at line starts are the commonest flat list there is, and they are drawn as one —
/// on screen and nowhere else. The scanner still reads the paragraph as a paragraph, so the
/// chunker, the skeleton and the model see exactly the bytes the user gave.
@Test func plainBulletsStayAParagraphToTheScannerAndBecomeItemsOnlyForDisplay() {
    let text = "• раз\n• два\n– три"
    let blocks = MarkdownBlockScanner.blocks(of: text)
    guard case let .paragraph(range)? = blocks.first, blocks.count == 1 else {
        Issue.record("the bullets were not one paragraph: \(blocks)"); return
    }
    let items = PlainBulletList.items(of: text[range])
    #expect(items?.map { String(text[$0]) } == ["раз", "два", "три"])
}

@Test func aParagraphWithOneUnmarkedLineIsNotAPlainBulletList() {
    let text = "• раз\nпросто строка"
    guard case let .paragraph(range)? = MarkdownBlockScanner.blocks(of: text).first else {
        Issue.record("not a paragraph"); return
    }
    #expect(PlainBulletList.items(of: text[range]) == nil)
    // A bullet in the middle of a line is a character, not a marker; a marker with no space
    // after it is not a marker either.
    #expect(PlainBulletList.items(of: Substring("Цена • 5")) == nil)
    #expect(PlainBulletList.items(of: Substring("•раз")) == nil)
}

/// The toggle has to appear for such a text, or the raw form would be unreachable when the
/// guess is wrong — «Исходник» is the way out the display heuristic owes.
@Test func plainBulletsCountAsMarkupSoTheToggleAppears() {
    #expect(MarkdownPresence.hasMarkup("• раз\n• два"))
    #expect(!MarkdownPresence.hasMarkup("Цена • 5 и всё."))
}
