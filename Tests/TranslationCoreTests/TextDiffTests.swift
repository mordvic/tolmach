import Foundation
import Testing
@testable import TranslationCore

// The change count is shown to a user as a promise about their own text — «6 изменений» over a
// правка they are about to accept — so every rule below is pinned by a test that dies under a
// named mutation rather than by the doc comment that states it.

// MARK: - The tokenizer

@Test func aHyphenInsideAWordDoesNotCutItInTwo() {
    let joined = TextTokenizer.tokens(of: "кто-нибудь")
    #expect(joined.map(\.text) == ["кто-нибудь"])
    // The mutation: drop the joiner rule and this becomes three tokens, which would report a
    // hyphen the model never touched as two changes around it.
    #expect(joined.map(\.kind) == [.word])
}

@Test func aDashBetweenSpacedWordsIsItsOwnToken() {
    // The other side of the joiner rule: «between two word characters» is the whole of it, and
    // a dash with spaces around it is punctuation.
    #expect(TextTokenizer.tokens(of: "кто — нибудь").map(\.text) == ["кто", "—", "нибудь"])
    // A run of dashes is punctuation too — only a *single* joiner is swallowed.
    #expect(TextTokenizer.tokens(of: "кто--нибудь").map(\.text) == ["кто", "-", "-", "нибудь"])
}

@Test func anApostropheIsAWordCharacterInBothOfItsSpellings() {
    #expect(TextTokenizer.tokens(of: "don’t").map(\.text) == ["don’t"])
    #expect(TextTokenizer.tokens(of: "don't").map(\.text) == ["don't"])
}

@Test func whitespaceIsABoundaryAndNeverATokenOfItsOwn() {
    // What makes a rewrapped paragraph and a collapsed double space *not* a change: the model
    // reflows whitespace on every run, and a diff that counted it would fire every time.
    let single = TextTokenizer.tokens(of: "два слова").map(\.text)
    #expect(TextTokenizer.tokens(of: "два  слова").map(\.text) == single)
    #expect(TextTokenizer.tokens(of: "два\n\tслова").map(\.text) == single)
    #expect(single == ["два", "слова"])
}

@Test func everyTokenSRangeSlicesItsOwnTextBackOut() {
    // The property the mark locator in `MarkupKit` will stand on: an off-by-one here would put
    // an underline under the wrong word rather than fail anything visible.
    let text = "Отчёт: «кто-нибудь» — 12 don’t.\nВторая строка."
    for token in TextTokenizer.tokens(of: text) {
        #expect(String(text[token.range]) == token.text)
    }
}

@Test func punctuationIsOneTokenPerCharacterAndWordsAreMaximalRuns() {
    #expect(TextTokenizer.tokens(of: "да, — 12!").map(\.text) == ["да", ",", "—", "12", "!"])
    #expect(TextTokenizer.tokens(of: "да, — 12!").map(\.kind) == [.word, .mark, .mark, .word, .mark])
}

// MARK: - One word

@Test func aRestoredYoIsExactlyOneWordsChange() throws {
    let set = TextDiff.changes(source: "отчет за август", result: "отчёт за август")
    #expect(set.count == 1)
    let change = try #require(set.changes.first)
    #expect(change.scope == .words)
    #expect(change.block == 0)
    #expect(change.removed == "отчет")
    #expect(change.inserted == "отчёт")
    #expect(change.insertedTokens == 0..<1)
    // The mutation this dies under: folding «е»/«ё» — or case — in the tokenizer. Both are
    // corrections users ask for by name, and both would come back as «изменений нет».
    #expect(TextDiff.changes(source: "Отчет", result: "отчет").count == 1)
}

@Test func anUnchangedTextHasNoChangesAndStillReportsItsBlocks() {
    let text = "Первый абзац.\n\nВторой абзац."
    let set = TextDiff.changes(source: text, result: text)
    #expect(set.changes.isEmpty)
    #expect(set.notCompared == nil)
    // Empty because nothing changed, not because nothing was looked at — the two are told
    // apart by `notCompared`, and the block census proves both blocks were compared.
    #expect(set.blocks.count == 2)
    #expect(set.blocks.allSatisfy { $0.similarity == 1 && $0.changedTokens == 0 })
}

@Test func aPureRemovalPointsAtTheTokenItSatBefore() throws {
    let set = TextDiff.changes(source: "раз два три", result: "раз три")
    let change = try #require(set.changes.first)
    #expect(set.count == 1)
    #expect(change.removed == "два")
    #expect(change.inserted == "")
    // Empty, and its lower bound is the index of «три» in the result — the anchor a mark is
    // drawn before. An off-by-one would anchor the deletion to the wrong word.
    #expect(change.insertedTokens == 1..<1)
}

@Test func aRemovalAtTheEndOfABlockAnchorsPastItsLastToken() throws {
    let set = TextDiff.changes(source: "раз два", result: "раз")
    let change = try #require(set.changes.first)
    #expect(change.removed == "два")
    #expect(change.insertedTokens == 1..<1)
    // == the result block's token count: there is no token after it to anchor to, which is the
    // documented convention and what the locator has to handle separately.
    #expect(change.insertedTokens.lowerBound == TextTokenizer.tokens(of: "раз").count)
}

// MARK: - mergeGap

@Test func twoCommasAroundOneWordAreOneChangeAtTheDefaultGap() throws {
    let source = "посмотрите пожалуйста до пятницы"
    let result = "посмотрите, пожалуйста, до пятницы"
    let merged = TextDiff.changes(source: source, result: result, mergeGap: 1)
    #expect(merged.count == 1)
    let change = try #require(merged.changes.first)
    // The merged change spans both edits and the unchanged token between them, quoted with the
    // text's own spacing rather than the tokens joined by a space.
    #expect(change.removed == "пожалуйста")
    #expect(change.inserted == ", пожалуйста,")
    #expect(change.insertedTokens == 1..<4)

    // The constant is exercised, not restated: at gap 0 the same edit is two changes.
    let unmerged = TextDiff.changes(source: source, result: result, mergeGap: 0)
    #expect(unmerged.count == 2)
    #expect(unmerged.changes.map(\.inserted) == [",", ","])
    #expect(unmerged.changes.allSatisfy { $0.removed.isEmpty })
}

// MARK: - The density rule

/// Eight words, so that «every second word» is four edits and one word is one.
private let eightWords = "один два три четыре пять шесть семь восемь"
private let everySecondChanged = "один дважды три четырежды пять шестью семь восьмью"
private let oneWordChanged = "один два три четыре пять шесть семь девять"

@Test func aParagraphChangedThroughoutCollapsesToOneBlockChange() {
    // Four of eight words replaced: eight of sixteen tokens, a ratio of 0.5, which is past a
    // threshold of 0.4. The threshold is a parameter here rather than a number restated from
    // the source — a test that spelled 0.5 again would pass whatever the code did with it.
    let set = TextDiff.changes(source: eightWords, result: everySecondChanged,
                               densityThreshold: 0.4)
    #expect(set.count == 1)
    #expect(set.changes.first?.scope == .block)
    #expect(set.changes.first?.removed == eightWords)
    #expect(set.changes.first?.inserted == everySecondChanged)
    #expect(set.changes.first?.insertedTokens == 0..<8)
}

@Test func aParagraphWithOneWordChangedStaysOneWordsChange() {
    let set = TextDiff.changes(source: eightWords, result: oneWordChanged,
                               densityThreshold: 0.4)
    #expect(set.count == 1)
    #expect(set.changes.first?.scope == .words)
    #expect(set.changes.first?.inserted == "девять")
}

@Test func aBlockExactlyAtTheDensityThresholdIsNotCollapsed() throws {
    // The boundary, pinned on the side the code takes: the check is `ratio > threshold`, so a
    // ratio of exactly 0.5 leaves the block word-marked. Flipping either comparison to `>=`
    // moves this test, which is the point of writing it at the boundary.
    let set = TextDiff.changes(source: eightWords, result: everySecondChanged,
                               densityThreshold: 0.5)
    #expect(set.changes.allSatisfy { $0.scope == .words })
    let pair = try #require(set.blocks.first)
    #expect(pair.changedTokens == 8)
    #expect(pair.sourceTokens + pair.resultTokens == 16)
}

@Test func aReorderedSentenceCollapsesThroughThePostDiffCheck() throws {
    // Similarity 1 — the same words in a different order — so the pre-check waves it through
    // and only the check *after* the diff can see that it is a rewrite. The mutation: delete
    // the post-diff collapse and this comes back as word-level marks over the whole sentence.
    let source = "альфа бета гамма дельта эпсилон"
    let result = "эпсилон дельта гамма бета альфа"
    let set = TextDiff.changes(source: source, result: result)
    let pair = try #require(set.blocks.first)
    #expect(pair.similarity == 1)
    #expect(set.count == 1)
    #expect(set.changes.first?.scope == .block)
}

@Test func aWhollyRewrittenParagraphIsRefusedByThePreCheckBeforeTheDiffRuns() throws {
    let source = "Договор подписан вчера утром в московском офисе."
    let result = "Вечером стороны завершили сделку совсем другими словами."
    let set = TextDiff.changes(source: source, result: result)
    let pair = try #require(set.blocks.first)
    #expect(pair.similarity < 0.5)
    #expect(set.count == 1)
    #expect(set.changes.first?.scope == .block)
    // The discriminating assertion, and the reason this test is not a duplicate of the one
    // above: the *scope* would be `.block` either way — the post-diff check would collapse
    // this pair too. Only the census says which gate answered. The pre-check never ran the
    // diff, so it reports the whole pair as changed; a token-level count of 14 out of 16 is
    // what the same fixture measures when the pre-check is taken out.
    #expect(pair.changedTokens == pair.sourceTokens + pair.resultTokens)
}

// MARK: - Bounds

@Test func aBlockOverTheTokenLimitIsComparedByEqualityAlone() {
    // Past the limit the quadratic diff never runs: equal projections are no change at all,
    // and unequal ones are one block change however small the edit was.
    let source = "один два три четыре"
    #expect(TextDiff.changes(source: source, result: source, blockTokenLimit: 3).changes.isEmpty)
    let set = TextDiff.changes(source: source, result: "один два три пять", blockTokenLimit: 3)
    #expect(set.count == 1)
    #expect(set.changes.first?.scope == .block)
    // The same edit under a limit that admits the block is a word-level change — the constant
    // is exercised rather than restated.
    #expect(TextDiff.changes(source: source, result: "один два три пять",
                             blockTokenLimit: 4).changes.first?.scope == .words)
}

@Test func aTextOverTheInspectionLimitIsNotComparedAtAll() {
    let source = "один два три четыре"
    let result = "один два три пять"
    let expected = TextTokenizer.tokens(of: source).count + TextTokenizer.tokens(of: result).count
    let refused = TextDiff.changes(source: source, result: result, inspectionLimit: expected - 1)
    #expect(refused.notCompared == .tooLong(tokens: expected))
    #expect(refused.changes.isEmpty)
    // Empty and refused must be distinguishable, or «изменений нет» becomes the quietest
    // possible lie about a document nothing looked at.
    #expect(refused.blocks.isEmpty)

    let compared = TextDiff.changes(source: source, result: result, inspectionLimit: expected)
    #expect(compared.notCompared == nil)
    #expect(compared.count == 1)
}

// MARK: - Blocks

@Test func aFencedBlockIsNeverDiffedHoweverMuchItsContentsDiffer() {
    // The bytes went through `Chunk.passthrough` and the model never saw them, so a change
    // inside one cannot exist. The mutation: diff every block kind, and this reports one.
    let source = "Текст с ошибкой.\n\n```py\nprint('helo')\n```"
    let result = "Текст без ошибки.\n\n```py\nprint('hello, world')\n```"
    let set = TextDiff.changes(source: source, result: result)
    #expect(set.count == 1)
    #expect(set.changes.first?.block == 0)
    // No `BlockPair` for the code block either: it was not compared, and a census entry
    // claiming otherwise would poison the density measurement.
    #expect(set.blocks.count == 1)
}

@Test func aThematicBreakIsNotABlockAChangeCanBeReportedIn() {
    let source = "Первый.\n\n---\n\nВторой."
    let result = "Первый.\n\n---\n\nТретий."
    let set = TextDiff.changes(source: source, result: result)
    #expect(set.blocks.count == 2)
    #expect(set.count == 1)
    // Block 2 in the result's list — the break is block 1 and is skipped, not renumbered.
    #expect(set.changes.first?.block == 2)
}

@Test func equalBlockCountsPairByIndexEvenWhenAMiddleBlockIsRewritten() throws {
    let source = "Первый абзац.\n\nСовершенно другой текст здесь.\n\nТретий абзац."
    let result = "Первый абзац.\n\nЗдесь теперь написано иное.\n\nТретий абзац."
    let set = TextDiff.changes(source: source, result: result)
    // The middle block reported as itself: one change, at index 1, carrying both texts. The
    // mutation is an off-by-one in `block` or a slice taken from the wrong document — both
    // would leave the count right and the mark in the wrong paragraph.
    #expect(set.count == 1)
    let change = try #require(set.changes.first)
    #expect(change.scope == .block)
    #expect(change.block == 1)
    #expect(change.removed == "Совершенно другой текст здесь.")
    #expect(change.inserted == "Здесь теперь написано иное.")
    #expect(set.blocks.count == 3)
    #expect(set.blocks.map(\.source) == [0, 1, 2])
    #expect(set.blocks.map(\.result) == [0, 1, 2])
}

@Test func anInsertedParagraphIsOneBlockChangeAndTheRestStillPairs() throws {
    let source = "Первый абзац.\n\nВторой абзац.\n\nТретий абзац."
    let result = "Первый абзац.\n\nСовсем новый абзац.\n\nВторой абзац.\n\nТретий абзац."
    let set = TextDiff.changes(source: source, result: result)
    // The mutation: pair by index regardless of the counts, and the tail misaligns — every
    // block after the insertion is reported as rewritten.
    #expect(set.count == 1)
    let change = try #require(set.changes.first)
    #expect(change.scope == .block)
    #expect(change.block == 1)
    #expect(change.removed == "")
    #expect(change.inserted == "Совсем новый абзац.")
    #expect(set.blocks.first(where: { $0.source == nil })?.result == 1)
    #expect(set.blocks.filter { $0.source != nil && $0.result != nil }.count == 3)
}

@Test func aRemovedParagraphIsAnchoredToTheBlockItSatBefore() throws {
    let source = "Первый абзац.\n\nЛишний абзац.\n\nТретий абзац."
    let result = "Первый абзац.\n\nТретий абзац."
    let set = TextDiff.changes(source: source, result: result)
    #expect(set.count == 1)
    let change = try #require(set.changes.first)
    #expect(change.scope == .block)
    #expect(change.removed == "Лишний абзац.")
    #expect(change.inserted == "")
    // Index into the RESULT's block list: the block the removed one sat in front of.
    #expect(change.block == 1)
    #expect(set.blocks.first(where: { $0.result == nil })?.source == 1)
}

@Test func aChangeInsideAListItemIsReportedWithoutItsBulletLabel() {
    // The projection keeps «• » so that a list does not read as glued prose, and the diff runs
    // on it — so the label had better be identical on both sides rather than a change of its
    // own. This is what pins that.
    let set = TextDiff.changes(source: "- раз\n- дфа", result: "- раз\n- два")
    #expect(set.count == 1)
    #expect(set.changes.first?.block == 1)
    #expect(set.changes.first?.removed == "дфа")
    #expect(set.changes.first?.inserted == "два")
}

@Test func aChangeInsideATableCellIsReportedInItsOwnBlock() {
    let source = "| Ключ | Значение |\n| --- | --- |\n| раз | адин |"
    let result = "| Ключ | Значение |\n| --- | --- |\n| раз | один |"
    let set = TextDiff.changes(source: source, result: result)
    #expect(set.count == 1)
    #expect(set.changes.first?.removed == "адин")
    #expect(set.changes.first?.inserted == "один")
}

@Test func aChangedRunBetweenTwoAnchorsIsPairedByIndexRatherThanLeftOver() {
    // Four source blocks against five: the first and the last come through untouched and
    // anchor the alignment, the two rewritten ones between them are paired off against each
    // other, and only the genuinely new block at the end is left over. The mutation: leave the
    // run to the leftovers (`shared = 0`) and a text with three changes is reported as five —
    // two deletions and three insertions.
    let source = """
        Первый абзац.

        Совершенно другой текст здесь.

        И ещё один посторонний текст.

        Последний абзац.
        """
    let result = """
        Первый абзац.

        Здесь теперь написано иное.

        А тут написано нечто другое.

        Последний абзац.

        Совсем новый абзац.
        """
    let set = TextDiff.changes(source: source, result: result)
    #expect(set.count == 3)
    #expect(set.changes.allSatisfy { $0.scope == .block })
    #expect(set.changes.map(\.block) == [1, 2, 4])
    // The two paired rewrites carry both texts; only the leftover carries an empty `removed`.
    #expect(set.changes.map { $0.removed.isEmpty } == [false, false, true])
    #expect(set.blocks.map(\.source) == [0, 1, 2, 3, nil])
    #expect(set.blocks.map(\.result) == [0, 1, 2, 3, 4])
}

@Test func anEqualBlockCountPairsByIndexRatherThanLookingForMovedBlocks() {
    // Three blocks against three, where a difference over the projections would read «the
    // first was deleted and a new last one added» and report two changes. Правка demands
    // structure preservation, so equal counts mean the blocks correspond and all three
    // changed — reading a move into an equal-count document is a guess, and the guess leaves
    // the blocks it moved unmarked.
    let source = "Первое.\n\nВторое.\n\nТретье."
    let result = "Второе.\n\nТретье.\n\nЧетвёртое."
    let set = TextDiff.changes(source: source, result: result)
    // The mutation: delete the equal-count branch and let `difference(from:)` align these two,
    // and the count drops to 2.
    #expect(set.count == 3)
    #expect(set.changes.map(\.block) == [0, 1, 2])
    #expect(set.blocks.count == 3)
}

// MARK: - The wire

@Test func aChangeSetSurvivesAJsonRoundTrip() {
    // `translate-cli --changes-json` is how the density threshold gets measured, so the value
    // types are `Codable` rather than serialised by hand in the CLI — a second spelling of the
    // shape is a second thing to keep true.
    let set = TextDiff.changes(source: "отчет за август\n\nЛишний абзац.",
                               result: "отчёт за август")
    let data = try! JSONEncoder().encode(set)
    #expect(try! JSONDecoder().decode(ChangeSet.self, from: data) == set)

    let refused = TextDiff.changes(source: "один два", result: "один три", inspectionLimit: 1)
    let refusedData = try! JSONEncoder().encode(refused)
    #expect(try! JSONDecoder().decode(ChangeSet.self, from: refusedData) == refused)
    #expect(String(data: refusedData, encoding: .utf8)?.contains("tooLong") == true)
}
