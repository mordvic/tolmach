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
