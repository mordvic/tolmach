// Tests/MarkupKitTests/ChangeMarksTests.swift
import AppKit
import Testing
@testable import MarkupKit
@testable import TranslationCore

private let config = MarkdownFontConfig(baseSize: 13, typeface: .system)

/// Every marked run: the change index the attribute carries and the characters it covers.
///
/// The whole point of reading it back this way rather than asserting a range literal is that
/// the sliced text is what a reader sees under the underline — an off-by-one in the token
/// offsets shows up as «тчёт» rather than as a number nobody can check by eye.
private func marks(_ rendering: MarkdownToAttributed.Rendering) -> [(index: Int, text: String)] {
    var found: [(Int, String)] = []
    let string = rendering.attributed.string as NSString
    rendering.attributed.enumerateAttribute(
        ChangeMarks.changeKey,
        in: NSRange(location: 0, length: rendering.attributed.length), options: []) { value, range, _ in
        guard let index = value as? Int else { return }
        found.append((index, string.substring(with: range)))
    }
    return found
}

private func underlineStyle(_ rendering: MarkdownToAttributed.Rendering,
                            under text: String) -> NSUnderlineStyle? {
    let range = (rendering.attributed.string as NSString).range(of: text)
    guard range.location != NSNotFound,
          let raw = rendering.attributed.attribute(.underlineStyle, at: range.location,
                                                   effectiveRange: nil) as? Int else { return nil }
    return NSUnderlineStyle(rawValue: raw)
}

/// The struck-through runs, in document order — the «Изменения» half of the view.
private func struck(_ rendering: MarkdownToAttributed.Rendering) -> [String] {
    var found: [String] = []
    let string = rendering.attributed.string as NSString
    rendering.attributed.enumerateAttribute(
        .strikethroughStyle,
        in: NSRange(location: 0, length: rendering.attributed.length), options: []) { value, range, _ in
        guard (value as? Int) == NSUnderlineStyle.single.rawValue else { return }
        found.append(string.substring(with: range))
    }
    return found
}

/// The set, the clean rendering and the marked one for one source/result pair — every fixture
/// below goes through the real `TextDiff`, so the two modules are exercised as they will run.
private func fixture(source: String, result: String, detail: ChangeMarks.Detail = .result,
                     raw: Bool = false)
    -> (set: ChangeSet, clean: MarkdownToAttributed.Rendering,
        marked: MarkdownToAttributed.Rendering) {
    let set = TextDiff.changes(source: source, result: result)
    let clean = raw
        ? MarkdownToAttributed.plainRendering(of: result, config: config)
        : MarkdownToAttributed.rendering(of: result, config: config)
    return (set, clean, ChangeMarks.apply(set, to: clean, resultMarkdown: result,
                                          detail: detail, config: config))
}

// MARK: - Block ranges

@Test func everyBlockGetsARangeAndTheRangesTileTheRenderedDocument() {
    let text = """
    # Заголовок

    Абзац с текстом.

    - первый
    - второй

    > Цитата.

    | Товар | Цена |
    | --- | --- |
    | Хлеб | 10 |

    ```swift
    let a = 1
    ```

    ---

    Последний абзац.
    """
    let blocks = MarkdownBlockScanner.blocks(of: text)
    let rendering = MarkdownToAttributed.rendering(of: text, config: config)
    #expect(rendering.blockRanges.count == blocks.count)
    // Tiling asserted end to end rather than as «they are in order»: a gap is exactly what a
    // block whose output was appended outside the measurement would leave, and an ordering
    // check would not see it.
    var next = 0
    for range in rendering.blockRanges {
        #expect(range.location == next)
        next = NSMaxRange(range)
    }
    #expect(next == rendering.attributed.length)
}

@Test func aBlockRangeOfTheRenderedDocumentCoversThatBlocksOwnCharacters() {
    let text = "# Заголовок\n\nАбзац с текстом.\n"
    let rendering = MarkdownToAttributed.rendering(of: text, config: config)
    let string = rendering.attributed.string as NSString
    #expect(rendering.blockRanges.count == 2)
    #expect(string.substring(with: rendering.blockRanges[0]) == "Заголовок\n")
    #expect(string.substring(with: rendering.blockRanges[1]) == "Абзац с текстом.\n")
}

@Test func thePlainRenderingLocatesEachBlockInTheDocumentsOwnCharacters() {
    let text = "# Заголовок\n\nАбзац с **текстом**.\n\n- пункт\n"
    let rendering = MarkdownToAttributed.plainRendering(of: text, config: config)
    #expect(rendering.attributed.string == text)
    let string = text as NSString
    // The block's own span, not a tiling: a heading without its «#», a list item without its
    // marker, and the separators between blocks belonging to nobody.
    #expect(rendering.blockRanges.map { string.substring(with: $0) }
        == ["Заголовок", "Абзац с **текстом**.", "пункт"])
}

// MARK: - «Результат»: the underlines

@Test func aCorrectedWordInAParagraphIsUnderlinedAndNothingIsInserted() {
    let (set, clean, marked) = fixture(source: "Отчет за август готов.",
                                       result: "Отчёт за август готов.")
    #expect(set.changes.count == 1)
    #expect(set.changes[0].inserted == "Отчёт")
    #expect(marked.attributed.string == clean.attributed.string)
    #expect(marks(marked).map(\.text) == ["Отчёт"])
    #expect(marks(marked).map(\.index) == [0])
    // Dotted in a paragraph too, since 2026-09-04: the solid line was the link's, measured
    // 1.49:1 apart from it in colour (`ChangeMarks.pattern` carries the figure).
    #expect(underlineStyle(marked, under: "Отчёт") == [.single, .patternDot])
}

@Test func aCorrectedWordInAHeadingIsUnderlinedInTheHeadingsOwnRun() {
    let (set, _, marked) = fixture(source: "# Отчет за август\n\nТекст.",
                                   result: "# Отчёт за август\n\nТекст.")
    #expect(set.changes.count == 1)
    #expect(set.changes[0].block == 0)
    #expect(marks(marked).map(\.text) == ["Отчёт"])
}

@Test func aCorrectedWordInAListItemIsUnderlinedWithADottedLine() {
    let (_, _, marked) = fixture(source: "- первый пункт\n- второй пункт\n",
                                 result: "- первый пункт\n- второй пунктик\n")
    #expect(marks(marked).map(\.text) == ["пунктик"])
    // Dotted, and still the base weight: the two are combined, not chosen between, so a
    // 32 pt list keeps its thick line and its dots. The dots are no longer the list's own —
    // every mark wears them — so what this pins is that a list item is located and marked
    // like a paragraph, bullet label and all.
    #expect(underlineStyle(marked, under: "пунктик") == [.single, .patternDot])
}

@Test func aCorrectedWordInATableCellIsUnderlinedWithADottedLine() {
    let source = "| Товар | Цена |\n| --- | --- |\n| Хлеб | 10 |\n"
    let result = "| Товар | Цена |\n| --- | --- |\n| Хлеба | 10 |\n"
    let (set, _, marked) = fixture(source: source, result: result)
    #expect(set.changes.count == 1)
    #expect(marks(marked).map(\.text) == ["Хлеба"])
    #expect(underlineStyle(marked, under: "Хлеба") == [.single, .patternDot])
}

@Test func aCorrectedWordIsUnderlinedInTheRawSourceRenderingPastItsMarkers() {
    // Story 6: «Исходник» must not cost the marks. The aligner has to walk past the `**` the
    // projection does not have, which is the whole reason it skips unmatched shown tokens.
    let (set, clean, marked) = fixture(source: "Отчет за **август** готов.",
                                       result: "Отчёт за **август** готов.",
                                       raw: true)
    #expect(set.changes.count == 1)
    #expect(clean.attributed.string == "Отчёт за **август** готов.")
    #expect(marks(marked).map(\.text) == ["Отчёт"])
}

@Test func aCorrectedWordInsideBoldMarkersIsUnderlinedInTheRawSourceRendering() {
    // Two changes far enough apart that `mergeGap` leaves them two, so the second one has to
    // be located past the `**` the projection does not have — a single merged change would
    // span the markers and prove nothing about the walk.
    let (set, _, marked) = fixture(source: "Отчет за месяц **авгус** готов.",
                                   result: "Отчёт за месяц **август** готов.", raw: true)
    #expect(set.changes.count == 2)
    #expect(marks(marked).map(\.text) == ["Отчёт", "август"])
}

@Test func aCorrectedWordInAPlainSourceListIsUnderlinedDespiteTheSynthesisedLabel() {
    // The projection gives a list item a «• » the source's own «- » never carries, so the
    // aligner's second attempt — the label skipped — is what keeps the raw view marked.
    let (_, _, marked) = fixture(source: "- первый пункт\n- второй пункт\n",
                                 result: "- первый пункт\n- второй пунктик\n", raw: true)
    #expect(marks(marked).map(\.text) == ["пунктик"])
}

@Test func aRewrittenBlockIsUnderlinedWholeRatherThanWordByWord() {
    let (set, _, marked) = fixture(
        source: "Первый абзац.\n\nСовершенно другой текст здесь.",
        result: "Первый абзац.\n\nПолностью иные слова тут.")
    #expect(set.changes.count == 1)
    #expect(set.changes[0].scope == .block)
    #expect(marks(marked).map(\.text) == ["Полностью иные слова тут."])
}

@Test func noMarkIsEverDrawnInsideACodeBlock() {
    // Story 17. The bytes went through `Chunk.passthrough` and the model never saw them, so
    // the mark would be a claim about a text nothing changed.
    let (set, _, marked) = fixture(source: "Отчет готов.\n\n```swift\nlet a = 1\n```\n",
                                   result: "Отчёт готов.\n\n```swift\nlet b = 2\n```\n")
    #expect(set.changes.count == 1)
    #expect(set.changes[0].block == 0)
    #expect(marks(marked).map(\.text) == ["Отчёт"])
    let code = marked.codeRegions[0].range
    #expect(marked.attributed.attribute(ChangeMarks.changeKey, at: code.location,
                                        effectiveRange: nil) == nil)
}

@Test func aBlockWhoseWordsTheRenderingDoesNotCarryIsLeftUnmarkedWhileItsNeighbourIsMarked() {
    // The projection and the rendering disagree on purpose: the marked rendering is built
    // from a text whose second block says something else. The first change is locatable in
    // both blocks — it is each block's first token — so an aligner that kept whatever it had
    // matched before it gave up would mark the second block too.
    let source = "Отчет за август.\n\nОтчет два три."
    let result = "Отчёт за август.\n\nОтчёт два три."
    let set = TextDiff.changes(source: source, result: result)
    #expect(set.changes.count == 2)
    let elsewhere = MarkdownToAttributed.rendering(of: "Отчёт за август.\n\nОтчёт четыре.",
                                                   config: config)
    let marked = ChangeMarks.apply(set, to: elsewhere, resultMarkdown: result,
                                   detail: .result, config: config)
    #expect(marks(marked).map(\.index) == [0])
    #expect(marks(marked).map(\.text) == ["Отчёт"])
    #expect(NSMaxRange((marked.attributed.string as NSString).range(of: "Отчёт"))
        <= NSMaxRange(marked.blockRanges[0]))
}

// MARK: - «Изменения»: the removed text

@Test func theRemovedWordAppearsStruckThroughImmediatelyBeforeTheWordThatReplacedIt() {
    let (_, _, marked) = fixture(source: "Отчет за август готов.",
                                 result: "Отчёт за август готов.", detail: .changes)
    #expect(marked.attributed.string == "Отчет Отчёт за август готов.\n")
    #expect(struck(marked) == ["Отчет "])
    #expect(marks(marked).map(\.text) == ["Отчёт"])
}

@Test func theRemovedTextIsSecondaryAndCarriesNoneOfTheAnchorsDecorations() {
    let (_, _, marked) = fixture(source: "Отчет за **август** готов.",
                                 result: "Отчёт за **август** готов.", detail: .changes)
    let colour = marked.attributed.attribute(.foregroundColor, at: 0,
                                             effectiveRange: nil) as? NSColor
    #expect(colour == .secondaryLabelColor)
    #expect(marked.attributed.attribute(ChangeMarks.changeKey, at: 0,
                                        effectiveRange: nil) == nil)
}

@Test func aRemovedWordIsStruckThroughWhereItStoodAndGluesToNeitherNeighbourNorPunctuation() {
    let (set, _, marked) = fixture(source: "Отчёт за август готов уже.",
                                   result: "Отчёт за август готов.", detail: .changes)
    #expect(set.changes.count == 1)
    #expect(set.changes[0].inserted.isEmpty)
    // The removal sat before the full stop, so it takes the space the document does not have
    // in front of it and not one behind: «готовуже .» is what the spec's fixed side produces.
    #expect(marked.attributed.string == "Отчёт за август готов уже.\n")
    #expect(struck(marked) == [" уже"])
}

@Test func aRemovedWordAtTheVeryEndOfABlockIsStruckThroughAfterItsLastWord() {
    // `insertedTokens.lowerBound == the block's token count` — the anchor that stands after
    // the last token rather than before the next one, and the one that indexes out of the map
    // if it is not special-cased.
    let (set, _, marked) = fixture(source: "Отчёт готов уже", result: "Отчёт готов",
                                   detail: .changes)
    #expect(set.changes.count == 1)
    #expect(set.changes[0].insertedTokens == 2..<2)
    #expect(marked.attributed.string == "Отчёт готов уже\n")
    #expect(struck(marked) == [" уже"])
}

@Test func everyCodeRegionAfterASplicedRemovalShiftsByExactlyItsLength() {
    let (_, clean, marked) = fixture(source: "Отчет готов.\n\n```swift\nlet a = 1\n```\n",
                                     result: "Отчёт готов.\n\n```swift\nlet a = 1\n```\n",
                                     detail: .changes)
    // «Отчет » — six characters spliced in front of the document's first word.
    #expect(marked.codeRegions[0].range.location == clean.codeRegions[0].range.location + 6)
    #expect(marked.codeRegions[0].range.length == clean.codeRegions[0].range.length)
    let code = marked.codeRegions[0].range
    #expect((marked.attributed.string as NSString).substring(with: code)
        == clean.codeRegions[0].source)
}

@Test func aRewrittenBlocksOldTextBecomesItsOwnParagraphAboveTheNewOne() {
    let (_, _, marked) = fixture(
        source: "Первый абзац.\n\nСовершенно другой текст здесь.",
        result: "Первый абзац.\n\nПолностью иные слова тут.", detail: .changes)
    #expect(marked.attributed.string
        == "Первый абзац.\nСовершенно другой текст здесь.\nПолностью иные слова тут.\n")
    #expect(struck(marked) == ["Совершенно другой текст здесь.\n"])
}

@Test func aBlockRemovedFromTheEndOfTheDocumentIsStruckThroughAfterTheLastBlock() {
    // `TextChange.block` is one past the last result block here — the one anchor that names no
    // block at all, and the case that indexes out of `blockRanges` if it is not special-cased.
    let (set, _, marked) = fixture(source: "Раз.\n\nДва.\n\nТри.", result: "Раз.\n\nДва.",
                                   detail: .changes)
    #expect(set.changes.count == 1)
    #expect(set.changes[0].block == 2)
    #expect(marked.attributed.string == "Раз.\nДва.\nТри.\n")
    #expect(struck(marked) == ["Три.\n"])
}

// MARK: - The copy path

@Test func theCleanRenderingsRTFIsUnaffectedByHavingBeenMarked() {
    // Story 10: a правка must never arrive in Word wearing review marks. The flavour is built
    // from the clean rendering and nothing in the copy path calls `apply` — pinned here by
    // taking the bytes before and after, because `PaneRendering` lives in the app target and
    // cannot be called from this one (TESTING.md shape 5: the coverage this test does *not*
    // have is that the app's button reads the clean rendering).
    let source = "# Отчет\n\nОтчет за август готов.\n"
    let result = "# Отчёт\n\nОтчёт за август готов.\n"
    let clean = MarkdownToAttributed.rendering(of: result, config: config)
    let before = clean.rtf
    let set = TextDiff.changes(source: source, result: result)
    let marked = ChangeMarks.apply(set, to: clean, resultMarkdown: result, detail: .changes,
                                   config: config)
    #expect(clean.rtf == before)
    let text = String(data: before ?? Data(), encoding: .utf8) ?? ""
    #expect(!text.contains("\\strike"))
    // And not vacuous: the marked rendering's own flavour does carry the strike, so the
    // assertion above is about which rendering the copy path takes and not about `\strike`
    // being unspellable in RTF.
    #expect(String(data: marked.rtf ?? Data(), encoding: .utf8)?.contains("\\strike") == true)
}

@Test func applyReturnsANewRenderingAndLeavesTheOneItWasGivenAlone() {
    let source = "Отчет за август готов."
    let result = "Отчёт за август готов."
    let clean = MarkdownToAttributed.rendering(of: result, config: config)
    let length = clean.attributed.length
    let set = TextDiff.changes(source: source, result: result)
    _ = ChangeMarks.apply(set, to: clean, resultMarkdown: result, detail: .changes,
                          config: config)
    #expect(clean.attributed.length == length)
    #expect(marks(clean).isEmpty)
}

// MARK: - The underline's weight

@Test func theUnderlineThickensAtSeventeenPoints() {
    #expect(ChangeMarks.underlineStyle(for: 16) == .single)
    #expect(ChangeMarks.underlineStyle(for: 17) == .thick)
    #expect(ChangeMarks.underlineStyle(for: 32) == .thick)
    #expect(ChangeMarks.underlineStyle(for: 11) == .single)
}

@Test func theMarkTakesItsWeightFromTheContentFont() {
    let large = MarkdownFontConfig(baseSize: 22, typeface: .system)
    let result = "Отчёт за август готов."
    let set = TextDiff.changes(source: "Отчет за август готов.", result: result)
    let marked = ChangeMarks.apply(set,
                                   to: MarkdownToAttributed.rendering(of: result, config: large),
                                   resultMarkdown: result, detail: .result, config: large)
    #expect(underlineStyle(marked, under: "Отчёт") == [.thick, .patternDot])
}

// MARK: - Refusals

@Test func aRenderingWithNoBlockRangesIsReturnedUnmarked() {
    // The app's hand-assembled plain rendering and the streaming tail have no block list to
    // name; marking them against one read from the text would put underlines under whatever
    // words happened to sit at those offsets.
    let result = "Отчёт за август готов."
    let set = TextDiff.changes(source: "Отчет за август готов.", result: result)
    let bare = MarkdownToAttributed.Rendering(
        attributed: MarkdownToAttributed.plain(result, config: config), codeRegions: [])
    let marked = ChangeMarks.apply(set, to: bare, resultMarkdown: result, detail: .changes,
                                   config: config)
    #expect(marked.attributed.string == result)
    #expect(marks(marked).isEmpty)
}

@Test func anEmptyChangeSetLeavesTheRenderingExactlyAsItWas() {
    let text = "Отчёт за август готов."
    let clean = MarkdownToAttributed.rendering(of: text, config: config)
    let marked = ChangeMarks.apply(TextDiff.changes(source: text, result: text), to: clean,
                                   resultMarkdown: text, detail: .changes, config: config)
    #expect(marked.attributed.isEqual(to: clean.attributed))
}
