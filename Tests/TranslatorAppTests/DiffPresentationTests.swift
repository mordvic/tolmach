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
    // The hash is meaningless to a reader and differs between runs, so it must not leak.
    let block = DiffPresentation.label(for: .codeBlock(hash: 12345, lang: "bash"))
    #expect(block == "блок кода (bash)")
    #expect(!block.contains("12345"))
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
