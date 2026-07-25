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
