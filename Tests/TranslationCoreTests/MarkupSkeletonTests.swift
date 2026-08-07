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
    // through `Chunker.scanLines`, the same discipline the chunker itself uses.
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
