import Testing
import TranslationCore
@testable import TranslatorApp

private func entries(_ terms: String...) -> [GlossaryEntry] {
    terms.map { GlossaryEntry(term: $0) }
}

@Test func theListIsShownInAlphabeticalOrderByIndex() {
    // Indices, not entries. Rows are identified by their position in the file because a
    // term is not unique — the file is hand-edited and «Добавить термин» appends a blank —
    // so the order has to be a permutation the caller can map back.
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "глоссарий", "тон"),
                                           query: "")
    #expect(order == [1, 2, 0])
}

@Test func aBlankTermSortsFirstSoANewRowIsWhereTheUserIsLooking() {
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", ""), query: "")
    #expect(order.first == 1)
}

@Test func theSearchMatchesTermsCaseInsensitively() {
    let order = GlossaryOrder.visibleOrder(entries: entries("Толмач", "чанк", "глоссарий"),
                                           query: "ЧАН")
    #expect(order == [1])
}

@Test func theSearchAlsoMatchesTheTranslations() {
    // A user looking for the English side of a pair should not have to remember the Russian.
    var withTranslation = GlossaryEntry(term: "чанк")
    withTranslation.translations["en"] = "chunk"
    let order = GlossaryOrder.visibleOrder(entries: [GlossaryEntry(term: "тон"), withTranslation],
                                           query: "chunk")
    #expect(order == [1])
}

@Test func anEmptyQueryHidesNothing() {
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "тон"), query: "   ")
    #expect(order.count == 2)
}

@Test func duplicateTermsBothSurviveInsteadOfCollapsingIntoOne() {
    // The failure index identity exists to prevent. Two hand-written rows with the same
    // term are two rows, and an order that returned one of them would silently drop the
    // other's translation.
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "чанк"), query: "")
    #expect(order.sorted() == [0, 1])
}

@Test func theOrderIsStableForTermsThatCompareEqual() {
    // Two equal terms must keep their file order, or the two rows swap places whenever the
    // list is recomputed and the user cannot tell which one they were editing.
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "чанк", "чанк"), query: "")
    #expect(order == [0, 1, 2])
}
