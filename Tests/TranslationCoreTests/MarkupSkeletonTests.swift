// Tests/TranslationCoreTests/MarkupSkeletonTests.swift
import Testing
@testable import TranslationCore

@Test func distinguishesBareFromLinkedURL() {
    let bare = MarkupSkeleton.tokens(of: "See https://build.fhir.org/x.html for details.")
    #expect(bare.contains(.url(bare: true)))
    let linked = MarkupSkeleton.tokens(of: "See [https://build.fhir.org/x.html](https://build.fhir.org/x.html).")
    #expect(linked.contains(.url(bare: false)))
}

@Test func diffFlagsURLTurnedIntoLink() {
    let diffs = MarkupSkeleton.diff(source: "See https://x.org here.",
                                    translation: "Смотри [https://x.org](https://x.org) здесь.")
    #expect(!diffs.isEmpty)
}

@Test func preservesInlineCodeExactly() {
    let tokens = MarkupSkeleton.tokens(of: "Set `keep_alive` to `30m`.")
    #expect(tokens.contains(.inlineCode("keep_alive")))
    #expect(tokens.contains(.inlineCode("30m")))
}

@Test func diffFlagsDroppedInlineCode() {
    let diffs = MarkupSkeleton.diff(source: "Set `keep_alive` now.", translation: "Установите keep_alive сейчас.")
    #expect(diffs.contains { $0.expected == .inlineCode("keep_alive") })
}

@Test func identicalStructureProducesNoDiff() {
    let src = "## Title\n\nText with `code` and https://x.org bare."
    let tr = "## Заголовок\n\nТекст с `code` и https://x.org без ссылки."
    #expect(MarkupSkeleton.diff(source: src, translation: tr).isEmpty)
}

@Test func detectsHardLineBreaksAddedInsideAParagraph() {
    // The gpt-oss defect: trailing double-spaces shatter one paragraph into lines.
    let src = "One flowing paragraph that stays whole."
    let tr = "Одна строка,  \nразорванная  \nжёсткими переносами."
    let diffs = MarkupSkeleton.diff(source: src, translation: tr)
    #expect(diffs.contains { $0.actual == .hardLineBreak })
}

@Test func oneDroppedTokenProducesOneDiffNotACascade() {
    // Four inline codes, the second dropped. A positional comparison would report
    // three mismatches; alignment must report exactly one deletion.
    let src = "`alpha` then `beta` then `gamma` then `delta`."
    let tr = "`alpha` затем затем `gamma` затем `delta`."
    let diffs = MarkupSkeleton.diff(source: src, translation: tr)
    #expect(diffs.count == 1)
    #expect(diffs[0].expected == .inlineCode("beta"))
    #expect(diffs[0].actual == nil)
}

@Test func aParentheticalBareURLStaysBare() {
    let tokens = MarkupSkeleton.tokens(of: "See the spec (https://example.com) for more.")
    #expect(tokens.filter { $0 == .url(bare: true) }.count == 1)
    #expect(!tokens.contains(.url(bare: false)))
}

@Test func aLinkWhoseTextIsTheURLCountsOnce() {
    let tokens = MarkupSkeleton.tokens(of: "See [https://x.org](https://x.org).")
    #expect(tokens.filter { if case .url = $0 { return true }; return false }.count == 1)
    #expect(tokens.contains(.url(bare: false)))
}

@Test func parentheticalURLRewrittenAsALinkIsDetected() {
    // The defect this task exists to catch, in the shape that previously slipped through.
    let diffs = MarkupSkeleton.diff(source: "For details (https://example.com) see docs.",
                                    translation: "Подробности [источник](https://example.com) см. документацию.")
    #expect(!diffs.isEmpty)
}

@Test func aURLBeforeInlineCodeOnOneLineKeepsDocumentOrder() {
    // Inline code used to be appended straight into the result while URLs were
    // collected separately and sorted only among themselves, so document order
    // between the two kinds was lost whenever both landed on the same line.
    let tokens = MarkupSkeleton.tokens(of: "See https://x.org then run `cmd` now.")
    let relevant = tokens.filter {
        if case .url = $0 { return true }
        if case .inlineCode = $0 { return true }
        return false
    }
    #expect(relevant == [.url(bare: true), .inlineCode("cmd")])
}

@Test func mergingAURLLineAndAnInlineCodeLineIntoOnePreservesOrderSoNoDiffIsReported() {
    // Source has the URL and the inline code on separate lines; the model merging
    // them into a single line is ordinary behaviour. If inline-code and URL
    // positions don't share one coordinate system and sort together, the merged
    // line comes out as [inlineCode, url] instead of [url, inlineCode] and LCS
    // reports a spurious drop plus add — a phantom defect from a faithful merge.
    let source = "See https://x.org for details.\nRun `cmd` to apply it."
    let merged = "See https://x.org for details. Run `cmd` to apply it."
    #expect(MarkupSkeleton.diff(source: source, translation: merged).isEmpty)
}

@Test func urlTokensKeepDocumentOrder() {
    let tokens = MarkupSkeleton.tokens(of: "Bare https://a.org then [link](https://b.org) after.")
    let urls = tokens.compactMap { token -> Bool? in
        if case .url(let bare) = token { return bare }
        return nil
    }
    #expect(urls == [true, false])
}

@Test func aTitledLinkIsStillALink() {
    let tokens = MarkupSkeleton.tokens(of: #"See [source](https://x.org "The Title") here."#)
    #expect(tokens.filter { if case .url = $0 { return true }; return false }.count == 1)
    #expect(tokens.contains(.url(bare: false)))
}

@Test func bareURLRewrittenAsATitledLinkIsDetected() {
    let diffs = MarkupSkeleton.diff(
        source: "See https://x.org for more.",
        translation: #"Смотри [источник](https://x.org "Заголовок") для деталей."#)
    #expect(!diffs.isEmpty)
}

@Test func aSchemelessLinkTargetStillCountsAsALink() {
    let tokens = MarkupSkeleton.tokens(of: "Visit [our site](www.example.com) today.")
    #expect(tokens.contains(.url(bare: false)))
    #expect(!tokens.contains(.url(bare: true)))
}

@Test func aTrailingNewlineIsNotAStructuralChange() {
    // Source files end with a newline; ResponseCleaner strips it from the reply.
    let source = "## Заголовок\n\nАбзац текста.\n"
    let translation = "## Heading\n\nA paragraph of text."
    #expect(MarkupSkeleton.diff(source: source, translation: translation).isEmpty)
}

@Test func aRelativeLinkTargetContributesNoURLToken() {
    // targetIsURL must reject, not just accept: "./file.md" is a link but not a URL.
    // This exact invariant regressed twice during construction and was pinned by
    // nothing until now.
    let tokens = MarkupSkeleton.tokens(of: "See [the doc](./file.md) for details.")
    #expect(!tokens.contains(.url(bare: true)))
    #expect(!tokens.contains(.url(bare: false)))
}

@Test func anAnchorLinkTargetContributesNoURLToken() {
    let tokens = MarkupSkeleton.tokens(of: "See [the section](#section) for details.")
    #expect(!tokens.contains(.url(bare: true)))
    #expect(!tokens.contains(.url(bare: false)))
}

@Test func aStandardOrderedListItemIsDetected() {
    let tokens = MarkupSkeleton.tokens(of: "1. First item")
    #expect(tokens.contains(.listItem(depth: 0)))
}

@Test func prosePrefixedByADigitCountIsNotAListItem() {
    // First character is a digit and ". " appears mid-sentence, but the period does
    // not immediately follow the leading digits — this is prose, not a list marker.
    let tokens = MarkupSkeleton.tokens(of: "3 files changed. See the report.")
    #expect(!tokens.contains { if case .listItem = $0 { return true }; return false })
}

@Test func aYearFollowedByAPeriodIsStillReadAsAListItem() {
    // The period genuinely follows the leading digits immediately here, so this is
    // indistinguishable from a real ordered-list marker at this layer — accepted as
    // a known, harmless false positive rather than one worth special-casing.
    let tokens = MarkupSkeleton.tokens(of: "2024. Released.")
    #expect(tokens.contains(.listItem(depth: 0)))
}

@Test func aGenuineParagraphBreakDifferenceIsStillReported() {
    // The normalisation must not swallow a real structural change.
    let source = "One paragraph only."
    let translation = "First paragraph.\n\nSecond paragraph."
    #expect(!MarkupSkeleton.diff(source: source, translation: translation).isEmpty)
}

@Test func anIndentedRunAfterABlankLineIsProseNotACodeBlock() {
    // Indentation is not a code signal in either layer: the chunker translates
    // indented text, so the skeleton must not report a code block the chunker never
    // saw. Fenced code is the only block form. The backticks inside are an ordinary
    // inline-code span, exactly as they would be in unindented prose.
    let text = "Intro paragraph.\n\n    let a = `1`\n    let b = 2\n\nAfter."
    let tokens = MarkupSkeleton.tokens(of: text)
    #expect(!tokens.contains { if case .codeBlock = $0 { true } else { false } })
    #expect(tokens.contains(.inlineCode("1")))
}

@Test func tableRowsTokeniseAndADroppedRowSurfacesInTheDiff() {
    let source = "| Name | Value |\n|---|---|\n| a | 1 |"
    let translation = "| Имя | Значение |\n|---|---|"
    let diffs = MarkupSkeleton.diff(source: source, translation: translation)
    #expect(diffs.contains { $0.expected == .tableRow && $0.actual == nil })
}

@Test func setextHeadingsTokeniseAtTheirLevels() {
    let text = "Title\n=====\n\nSubtitle\n--------\n\nBody text."
    let tokens = MarkupSkeleton.tokens(of: text)
    #expect(tokens.contains(.heading(level: 1)))
    #expect(tokens.contains(.heading(level: 2)))
}

@Test func aDashRunAfterABlankLineIsNotASetextHeading() {
    // A thematic break, not an underline: nothing above it to be a heading of.
    let tokens = MarkupSkeleton.tokens(of: "Paragraph.\n\n---\n\nNext.")
    #expect(!tokens.contains { if case .heading = $0 { true } else { false } })
}

@Test func consecutiveDashRunsAfterABlankLineFabricateNoHeading() {
    // The first "---" is a thematic break (blank line above), so the second one has
    // no paragraph text above it either — CommonMark makes neither a heading. A
    // dash-run that FAILED the setext gate must not count as prose for the next line.
    let tokens = MarkupSkeleton.tokens(of: "Paragraph.\n\n---\n---\n\nNext.")
    #expect(!tokens.contains { if case .heading = $0 { true } else { false } })
}

@Test func aDashRunUnderAnATXHeadingFabricatesNoSecondHeading() {
    // "---" under "# Title" is a thematic break: CommonMark's setext underline needs a
    // *paragraph* above it, and a heading is not paragraph text. The gate armed on any
    // non-blank line, so this tokenised as [heading(1), heading(2)] — confirmed by
    // probe — and a translation that renders the break faithfully looked like a
    // dropped heading.
    let tokens = MarkupSkeleton.tokens(of: "# Title\n---")
    #expect(tokens == [.heading(level: 1)])
}

@Test func aDashRunUnderAListItemFabricatesNoHeading() {
    // Same gate, the list case — and the one a real document hits, since a "---"
    // closing a bulleted section is ordinary Markdown.
    let tokens = MarkupSkeleton.tokens(of: "- item\n---")
    #expect(!tokens.contains { if case .heading = $0 { true } else { false } })
    #expect(tokens.contains(.listItem(depth: 0)))
}

@Test func aDashRunUnderABlockquoteOrATableRowFabricatesNoHeading() {
    #expect(!MarkupSkeleton.tokens(of: "> quoted\n---")
        .contains { if case .heading = $0 { true } else { false } })
    #expect(!MarkupSkeleton.tokens(of: "| a | b |\n---")
        .contains { if case .heading = $0 { true } else { false } })
}

@Test func aDashRunUnderParagraphProseIsStillASetextHeading() {
    // The gate must still arm on the case it exists for.
    #expect(MarkupSkeleton.tokens(of: "Title\n---").contains(.heading(level: 2)))
}

// MARK: - Line discipline must match the chunker's, exactly.

@Test func aCRLFSourceDiffedAgainstAnLFTranslationReportsNothing() {
    // `components(separatedBy: .newlines)` splits on unicode scalars, so "\r\n"
    // became two line breaks with an empty line between them — a paragraph break
    // the document does not contain. A perfectly faithful LF translation of a CRLF
    // source was then reported as having lost one. The skeleton now scans lines
    // through `LineScanner.scanLines`, the same discipline the chunker itself uses.
    let source = "First paragraph.\r\n\r\nSecond paragraph."
    let translation = "Первый абзац.\n\nВторой абзац."
    #expect(MarkupSkeleton.diff(source: source, translation: translation).isEmpty)
}

@Test func aU2028SeparatedListDiffsCleanlyAgainstAnLFTranslation() {
    // U+2028 LINE SEPARATOR is a mandatory line break to Unicode, and a model
    // normalises it to "\n" in its reply. Recognising only LF and CR here read the
    // source as one line and the translation as two, and reported «добавлено: элемент
    // списка» on a faithful translation.
    let source = "- one\u{2028}- two"
    let translation = "- один\n- два"
    #expect(MarkupSkeleton.diff(source: source, translation: translation).isEmpty)
}

@Test func aU2029SeparatedPairOfParagraphsDiffsCleanlyAgainstAnLFTranslation() {
    // Same family, the paragraph case: U+2029 twice is one blank line.
    let source = "First paragraph.\u{2029}\u{2029}Second paragraph."
    let translation = "Первый абзац.\n\nВторой абзац."
    #expect(MarkupSkeleton.diff(source: source, translation: translation).isEmpty)
}

@Test func trailingBlankLinesUnderAnUnterminatedFenceAreNotCode() {
    // The chunker's unterminated fence runs to the end of the document with its
    // trailing blank lines trimmed off — they are document whitespace, not code. The
    // skeleton's EOF flush hashed them into the block, so the same code with and
    // without a blank tail produced two different `codeBlock` hashes and a faithful
    // translation that dropped the tail read as a changed code block.
    #expect(MarkupSkeleton.tokens(of: "```\ncode\n\n\n") == MarkupSkeleton.tokens(of: "```\ncode"))
}

@Test func anIndentedFenceMarkerOpensAFenceInBothLayers() {
    // An indented ``` is still a fence marker — the chunker's `isFenceMarker` trims
    // the line before testing it, so the two layers must agree here or the diff
    // reports a block one of them never saw. Both read one fenced block.
    let text = "Intro.\n\n    ```\n    let a = 1\n    ```\n\nAfter `cmd` runs."
    let tokens = MarkupSkeleton.tokens(of: text)
    #expect(tokens.filter { if case .codeBlock = $0 { true } else { false } }.count == 1)
    // Prose after the block still tokenises — the fence closed.
    #expect(tokens.contains(.inlineCode("cmd")))
    #expect(Chunker.blocks(in: text).filter { $0.kind == .fencedCode }.count == 1)
}

// MARK: - Emphasis is structure, and the losses it exists to make visible.

/// The measured defect, in the shape it was measured in: a model that drops one emphasis
/// span per document, systematically the same one. Before `.emphasis` existed the diff
/// reported nothing at all about it and every surface said the structure survived.
@Test func aDroppedStrongPairIsReportedByTheDiff() {
    let diffs = MarkupSkeleton.diff(source: "Deploy to the **staging** environment first.",
                                    translation: "Сначала разверните в среде staging.")
    #expect(diffs.contains { $0.expected == .emphasis(strong: true) && $0.actual == nil })
}

/// The other direction, and the reason no prompt rule ships with this: asked to preserve
/// emphasis, `aya-expanse:32b` invented it in 2 of 3 runs (`*пятницам*` for an unmarked «on
/// Fridays») — §2 series B. A fabrication must be as visible as a loss.
@Test func emphasisTheTranslationInventedIsReported() {
    let diffs = MarkupSkeleton.diff(source: "The script refuses to run on Fridays.",
                                    translation: "Скрипт отказывается работать по *пятницам*.")
    #expect(diffs.contains { $0.expected == nil && $0.actual == .emphasis(strong: false) })
}

/// The series-B degradation itself: `**staging**` came back as `*staging*` 5/5 on
/// translategemma:12b. Strong and italic must be different tokens or this is invisible.
@Test func boldDegradedToItalicIsReportedAsAChange() {
    let diffs = MarkupSkeleton.diff(source: "Deploy to **staging** now.",
                                    translation: "Разверните в *staging* сейчас.")
    #expect(diffs.contains { $0.expected == .emphasis(strong: true) && $0.actual == nil })
    #expect(diffs.contains { $0.expected == nil && $0.actual == .emphasis(strong: false) })
}

@Test func bothSpellingsOfBothStrengthsTokenise() {
    #expect(MarkupSkeleton.tokens(of: "A **bold** word.") == [.emphasis(strong: true)])
    #expect(MarkupSkeleton.tokens(of: "An *italic* word.") == [.emphasis(strong: false)])
    #expect(MarkupSkeleton.tokens(of: "A __bold__ word.") == [.emphasis(strong: true)])
    #expect(MarkupSkeleton.tokens(of: "An _italic_ word.") == [.emphasis(strong: false)])
}

/// The two claims `emphasisSpans`' doc comment makes about nesting, pinned so they cannot
/// rot into folklore: a triple marker reads as [strong, italic] and a strong inside an
/// italic reads as both, each token at its own opener. Neither comes from a nesting rule —
/// there is none, only two independent parity walks — and both are what a faithful
/// translation of the same span reproduces.
@Test func aTripleMarkerAndAStrongInsideAnItalicEachReadAsTwoTokens() {
    #expect(MarkupSkeleton.tokens(of: "A ***loud*** word.")
        == [.emphasis(strong: true), .emphasis(strong: false)])
    #expect(MarkupSkeleton.tokens(of: "*a **b** c*")
        == [.emphasis(strong: false), .emphasis(strong: true)])
}

/// The failure mode is a filename. Underscores inside a word are identifiers in this
/// project's own documents — `a_b_c.txt`, `keep_alive`, `snake_case` — and parity-pairing
/// them turns the second one into the close of an italic that was never written. The
/// outer-alphanumeric half of the flanking gate is what refuses them.
@Test func intrawordUnderscoresInAFilenameAreNotEmphasis() {
    let tokens = MarkupSkeleton.tokens(of: "Open the file a_b_c.txt in the editor.")
    #expect(!tokens.contains { if case .emphasis = $0 { true } else { false } })
    // And the shape this project actually writes, twice on one line.
    #expect(!MarkupSkeleton.tokens(of: "Set keep_alive and read max_chunk_characters.")
        .contains { if case .emphasis = $0 { true } else { false } })
}

/// §8's measured-safe prose, which contains an asterisk, an underscore-bearing filename
/// and a hash and is nothing but a paragraph. An asterisk with spaces on both sides can
/// neither open nor close, so arithmetic stays arithmetic.
@Test func arithmeticAsterisksAndAFilenameInProseCarryNoEmphasis() {
    let tokens = MarkupSkeleton.tokens(of: "Цена 5 * 3 = 15, файл a_b_c.txt и #хэштег")
    #expect(!tokens.contains { if case .emphasis = $0 { true } else { false } })
}

/// A bullet written with an asterisk offers a stray marker on a line that may well also
/// carry a real italic. Without the space half of the flanking gate that marker opens a
/// span at the bullet, the real opener is swallowed as its close, and the real closer is
/// left dangling — one token, in the wrong place, instead of one token in the right one.
@Test func aBulletWrittenWithAnAsteriskDoesNotStealTheItalicOnItsLine() {
    let tokens = MarkupSkeleton.tokens(of: "* the *read-only* replica is healthy")
    #expect(tokens == [.listItem(depth: 0), .emphasis(strong: false)])
}

/// A marker inside a protected span is code, not markup: the model never sees a fenced or
/// inline code span, so it cannot lose the emphasis inside one, and counting it would make
/// `InlineCodeRestorer`'s positional restore look like an emphasis change.
@Test func emphasisMarkersInsideAnInlineCodeSpanAreNotEmphasis() {
    let tokens = MarkupSkeleton.tokens(of: "Escape it as `*b*` in the pattern.")
    #expect(tokens == [.inlineCode("*b*")])
}

/// The `found` array's whole purpose, extended to a third kind. Emphasis sits *between* the
/// URL and the inline code here on purpose: a token kind appended after the sort — the
/// defect this array was created to fix for URLs and inline code — lands at the end.
@Test func emphasisInlineCodeAndAURLOnOneLineKeepDocumentOrder() {
    let tokens = MarkupSkeleton.tokens(of: "See https://x.org then **do** run `cmd` now.")
    #expect(tokens == [.url(bare: true), .emphasis(strong: true), .inlineCode("cmd")])
}

/// `inlineCodeSpans`' discipline, inherited verbatim: an unterminated opener emits nothing,
/// and an empty pair consumes both markers and emits nothing. Emitting on either would put
/// a token into the skeleton that no rendered emphasis corresponds to, on the source side
/// as readily as on the translation's.
@Test func anUnterminatedMarkerAndAnEmptyPairBothEmitNothing() {
    #expect(!MarkupSkeleton.tokens(of: "A lone **marker with no close")
        .contains { if case .emphasis = $0 { true } else { false } })
    #expect(!MarkupSkeleton.tokens(of: "Nothing between these: **** at all")
        .contains { if case .emphasis = $0 { true } else { false } })
}

/// A marker may not reach across a line break to find its pair — the 2026-08-26 family of
/// defects, where a lone CR let backticks pair across a line and spliced the wrong source
/// bytes over real code. Emphasis is scanned per line, through `LineScanner`, so a CR-only
/// source and its LF translation read the same; a scan over the whole string would pair the
/// CR document's two stray markers and leave the LF one's alone, reporting a phantom
/// italic on a faithful translation.
@Test func anEmphasisMarkerMayNotPairAcrossALineBreak() {
    let source = "Value *a\rb* value"
    let translation = "Значение *а\nб* значение"
    #expect(!MarkupSkeleton.tokens(of: source)
        .contains { if case .emphasis = $0 { true } else { false } })
    #expect(MarkupSkeleton.diff(source: source, translation: translation).isEmpty)
}

/// Line-ending parity for the new tokens, the property the file's older CRLF test pins for
/// the old ones: a CRLF source carrying emphasis and a table, diffed against a faithful LF
/// translation of it, must report nothing. A scan that split on "\n" alone, or on
/// `.newlines`, moves the emphasis and the rows relative to the paragraph breaks and the
/// perfect translation reads as a damaged one.
@Test func aCRLFSourceWithEmphasisAndATableDiffsCleanlyAgainstItsLFTranslation() {
    let source = "The **staging** copy.\r\n\r\n| Env | Auto |\r\n|---|---|\r\n| staging | *no* |\r\n"
    let translation = "Копия **staging**.\n\n| Среда | Авто |\n|---|---|\n| staging | *нет* |"
    #expect(MarkupSkeleton.diff(source: source, translation: translation).isEmpty)
}

// MARK: - A table row is not only a row.

/// What `.tableRow` alone could not see: every row survived as a row, and one of them came
/// back with two of its three cells. Without `.tableCells` this pair of documents produces
/// no diff at all.
@Test func aTableRowThatLostACellIsReported() {
    let source = "| Env | Replicas | Auto |\n|---|---|---|\n| staging | 2 | yes |"
    let translation = "| Среда | Реплики | Авто |\n|---|---|---|\n| staging | 2 |"
    let diffs = MarkupSkeleton.diff(source: source, translation: translation)
    #expect(diffs.contains { $0.expected == .tableCells(count: 3) && $0.actual == nil })
    #expect(diffs.contains { $0.actual == .tableCells(count: 2) && $0.expected == nil })
    // The rows themselves are all present, which is exactly why the loss was invisible.
    #expect(!diffs.contains { $0.expected == .tableRow || $0.actual == .tableRow })
}

@Test func cellsAreCountedBetweenThePipesAndNotAsPipes() {
    #expect(MarkupSkeleton.tableCellCount("| a | b |") == 2)
    // No closing pipe, and an empty middle cell: both are ordinary GFM.
    #expect(MarkupSkeleton.tableCellCount("| a | b") == 2)
    #expect(MarkupSkeleton.tableCellCount("| a |  | c |") == 3)
    // The delimiter row is a row like any other and gets its own count.
    #expect(MarkupSkeleton.tableCellCount("|---|---|") == 2)
}

/// The accepted cost, stated as a test so it cannot be discovered as a surprise: a row that
/// is gone entirely now reports two diffs. No consumer treats the number of diffs as a
/// threshold, and the alternative was not seeing a half-surviving row at all.
@Test func aWhollyDroppedRowReportsBothItsRowAndItsCells() {
    let diffs = MarkupSkeleton.diff(source: "| Name | Value |\n|---|---|\n| a | 1 |",
                                    translation: "| Имя | Значение |\n|---|---|")
    #expect(diffs.count == 2)
    #expect(diffs.contains { $0.expected == .tableRow && $0.actual == nil })
    #expect(diffs.contains { $0.expected == .tableCells(count: 2) && $0.actual == nil })
}
