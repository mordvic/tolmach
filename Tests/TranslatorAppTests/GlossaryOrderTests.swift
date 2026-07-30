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
    let order = GlossaryOrder.visibleOrder(entries: entries("Толмач", "ЧАНК", "глоссарий"),
                                           query: "чан")
    #expect(order == [1])
}

@Test func theSearchAlsoMatchesTheTranslations() {
    // A user looking for the English side of a pair should not have to remember the Russian.
    var withTranslation = GlossaryEntry(term: "чанк")
    withTranslation.translations["en"] = "CHUNK"
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

@Test func equalTermsAreOrderedByTheirFilePosition() {
    // Equal terms must keep their file order. The tiebreaker makes the ordering total so the
    // result is uniquely determined by the input and does not depend on sort's unspecified
    // handling of equal elements.
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "чанк", "чанк"), query: "")
    #expect(order == [0, 1, 2])
}

@Test func aSelectionSurvivesASearchThatKeepsItsRow() {
    // Search never shifts or repurposes an index — it only narrows `order` — so a selected
    // row still present in the narrowed order must stay selected.
    let order = GlossaryOrder.visibleOrder(entries: entries("чанк", "тон"), query: "чан")
    let survived = GlossaryOrder.selection([0], survivingIn: order, indicesMayHaveShifted: false)
    #expect(survived == [0])
}

@Test func aSelectionDoesNotSurviveARemoval() {
    // A removal shifts every later index down by one, so a selected index that still
    // satisfies `order.contains(_:)` can now denote a different row. The caller declares
    // this with `indicesMayHaveShifted: true`, which must clear rather than filter.
    let survived = GlossaryOrder.selection([1], survivingIn: [0, 1], indicesMayHaveShifted: true)
    #expect(survived.isEmpty)
}

@Test func removingAnEarlierRowDoesNotLeaveTheFollowingRowSelected() {
    // The exact trace the defect was found from: select «бета» (index 1) out of
    // «альфа», «бета», «гамма», then delete «альфа» (index 0). Every later index shifts
    // down by one, so index 1 in the surviving file is «гамма» — a plain membership filter
    // against the new order would keep {1} selected and let «гамма» be deleted instead of
    // the row the user actually chose.
    let afterRemoval = GlossaryOrder.visibleOrder(entries: entries("бета", "гамма"), query: "")
    let survived = GlossaryOrder.selection([1], survivingIn: afterRemoval, indicesMayHaveShifted: true)
    #expect(survived.isEmpty)
}
