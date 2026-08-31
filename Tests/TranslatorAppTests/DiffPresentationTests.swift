import Testing
@testable import TranslatorApp
@testable import TranslationCore

@Test func tokenLabelsAreRussianAndCarryNoHashes() {
    #expect(DiffPresentation.label(for: .heading(level: 2)) == "заголовок 2-го уровня")
    #expect(DiffPresentation.label(for: .blockquote) == "цитата")
    #expect(DiffPresentation.label(for: .inlineCode("--strict")) == "код «--strict»")
    #expect(DiffPresentation.label(for: .url(bare: true)) == "ссылка без разметки")
    #expect(DiffPresentation.label(for: .url(bare: false)) == "ссылка в разметке")
    #expect(DiffPresentation.label(for: .hardLineBreak) == "жёсткий перенос строки")
    #expect(DiffPresentation.label(for: .tableRow) == "строка таблицы")
    // The hash is meaningless to a reader and differs between runs, so it must not leak.
    let block = DiffPresentation.label(for: .codeBlock(hash: 12345, lang: "bash"))
    #expect(block == "блок кода (bash)")
    #expect(!block.contains("12345"))
}

@Test func theTwoEmphasisStrengthsReadDifferently() {
    #expect(DiffPresentation.label(for: .emphasis(strong: true)) == "жирное выделение")
    #expect(DiffPresentation.label(for: .emphasis(strong: false)) == "курсив")
}

/// The count is the whole point of the token, so it has to survive into the label — and the
/// noun has to agree with it, or every warning about a table reads as a machine translation
/// of itself.
@Test func aCellCountReadsAsARowWithThatManyCells() {
    #expect(DiffPresentation.label(for: .tableCells(count: 4)) == "строка таблицы из 4 ячеек")
    #expect(DiffPresentation.label(for: .tableCells(count: 1)) == "строка таблицы из 1 ячейки")
    #expect(DiffPresentation.label(for: .tableCells(count: 2)) == "строка таблицы из 2 ячеек")
    // 11 is not 1, and 21 is: the rule is on the last digit, with the teens excepted.
    #expect(DiffPresentation.cellsGenitive(11) == "ячеек")
    #expect(DiffPresentation.cellsGenitive(21) == "ячейки")
    #expect(DiffPresentation.cellsGenitive(0) == "ячеек")
}

/// The sentence `.tableRow` alone could never say.
@Test func aRowThatLostCellsReadsAsBeforeAndAfter() {
    let diff = MarkupDiff(expected: .tableCells(count: 4), actual: .tableCells(count: 2), note: "")
    #expect(DiffPresentation.describe(diff)
        == "строка таблицы из 4 ячеек → строка таблицы из 2 ячеек")
}

@Test func aDroppedTokenReadsAsALoss() {
    let diff = MarkupDiff(expected: .blockquote, actual: nil, note: "dropped in translation")
    #expect(DiffPresentation.describe(diff) == "потеряно: цитата")
}

@Test func anAddedTokenReadsAsAnAddition() {
    let diff = MarkupDiff(expected: nil, actual: .url(bare: false), note: "added in translation")
    #expect(DiffPresentation.describe(diff) == "добавлено: ссылка в разметке")
}

@Test func aSubstitutionReadsAsBeforeAndAfter() {
    let diff = MarkupDiff(expected: .url(bare: true), actual: .url(bare: false), note: "")
    #expect(DiffPresentation.describe(diff) == "ссылка без разметки → ссылка в разметке")
}

@Test func onlyMissingChecksProduceAWarning() {
    // .unverifiable deliberately shows the user nothing — see spec 4.6.
    let missing = GlossaryCheck(term: "profile server", expected: "сервер профилей", status: .missing)
    #expect(DiffPresentation.describe(missing) == "«profile server» ожидалось как «сервер профилей»")
    #expect(DiffPresentation.describe(GlossaryCheck(term: "x", expected: "y", status: .satisfied)) == nil)
    #expect(DiffPresentation.describe(GlossaryCheck(term: "x", expected: "y", status: .unverifiable)) == nil)
}
