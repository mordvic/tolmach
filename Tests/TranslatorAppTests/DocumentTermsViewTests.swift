import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

// Every test here is `@MainActor` for the reason `WarningsViewTests` records at length:
// `View` is `@MainActor @preconcurrency`, so a closure written inside one of its members
// inherits main-actor isolation, and under `.swiftLanguageMode(.v6)` that is checked at
// **run time** with a trap rather than a diagnostic. `rows(for:)`'s `filter` and `map` are
// exactly such closures. Calling them off the main actor crashed the suite with signal 5
// before this line was added — the build was clean either way.

private func draft(document: [GlossaryEntry], user: [GlossaryEntry]) -> DocumentTermsDraft {
    DocumentTermsDraft(documentEntries: document, userEntries: user, chunkCount: 7, target: .ru)
}

@MainActor @Test func theUsersOwnTermsComeFirstAndAreNotEditable() {
    let rows = DocumentTermsView.rows(for: draft(
        document: [GlossaryEntry(term: "profile", translations: ["ru": "профиль"])],
        user: [GlossaryEntry(term: "StructureDefinition", doNotTranslate: true)]))

    // Read-only first, because they are context for the editable ones below.
    guard case let .user(entry) = rows.first else { Issue.record("expected a user row first"); return }
    #expect(entry.term == "StructureDefinition")
    guard case .document = rows.last else { Issue.record("expected a document row last"); return }
}

@MainActor @Test func aTermTheGlossaryAlsoNamesIsStillOfferedForReview() {
    // It used to be hidden, on the reasoning that the engine would discard an edit to it
    // anyway. That holds only for a часть where the user's term *occurs*: the engine filters
    // the user side per часть over code-stripped text, while the документный глоссарий goes
    // into every часть whole. A term the glossary names in prose in one часть and that
    // appears only inside a fence in another has no user entry injected there — so the
    // model's version reaches that prompt, and hiding its row made it the one thing the gate
    // could not show.
    let rows = DocumentTermsView.rows(for: draft(
        document: [GlossaryEntry(term: "cache", translations: ["ru": "кэш-память"])],
        user: [GlossaryEntry(term: "CACHE", translations: ["ru": "кеш"])]))

    #expect(rows == [.user(GlossaryEntry(term: "CACHE", translations: ["ru": "кеш"])),
                     .document(0)])
}

@MainActor @Test func aDocumentRowCarriesTheIndexItEditsThrough() {
    // An index and not a copy: the field writes through a binding into the request's own
    // entries, and a copied entry would edit a value nobody reads.
    let rows = DocumentTermsView.rows(for: draft(
        document: [GlossaryEntry(term: "slice"), GlossaryEntry(term: "cardinality")],
        user: []))
    #expect(rows == [.document(0), .document(1)])
}

@MainActor @Test func theHeadlineNamesBothNumbersTheUserNeeds() {
    let d = draft(document: Array(repeating: GlossaryEntry(term: "x"), count: 12), user: [])
    #expect(DocumentTermsView.headline(for: d) == "Термины документа — 12")
    #expect(DocumentTermsView.explanation(for: d)
            == "Они переведены один раз и будут одинаковы во всех 7 частях. "
             + "Исправьте то, что переведено не так, — перевод ещё не начался.")
}

@MainActor @Test func theExplanationTakesTheRightRussianPluralForItsPartCount() {
    func explanation(chunks: Int) -> String {
        DocumentTermsView.explanation(for: DocumentTermsDraft(
            documentEntries: [], userEntries: [], chunkCount: chunks, target: .ru))
    }
    #expect(explanation(chunks: 2).contains("во всех 2 частях"))
    #expect(explanation(chunks: 5).contains("во всех 5 частях"))
    #expect(explanation(chunks: 21).contains("во всех 21 части"))
}

@MainActor @Test func theSourceColumnNamesWhereEachRowCameFrom() {
    #expect(DocumentTermsView.origin(.user(GlossaryEntry(term: "x"))) == "глоссарий")
    #expect(DocumentTermsView.origin(.document(0)) == "документ")
}

@MainActor @Test func theHeadlineCountsTheGlossaryItNamesAndNotEveryRow() {
    // Three surfaces describe one документный глоссарий: this heading, the queue row's
    // «N терминов документа» and WarningsView's «Термины документа (N)». Counting the
    // user's context rows here made this the only one of the three saying something else.
    let d = draft(document: [GlossaryEntry(term: "profile"), GlossaryEntry(term: "slice")],
                  user: [GlossaryEntry(term: "PROFILE", doNotTranslate: true)])
    #expect(DocumentTermsView.rows(for: d).count == 3)
    #expect(DocumentTermsView.headline(for: d) == "Термины документа — 2")
}

@MainActor @Test func theSheetsEscapeIsNamedForWhatItStops() {
    // Esc alone was filed by three review passes as a conventional gesture with an
    // unreadable effect: in a queue it abandons every file behind the one on screen. The
    // scope did not change — «Перевести» is already «skip this file's review» — but the
    // label now says which it is before it is pressed.
    #expect(DocumentTermsView.cancelLabel(inQueue: true) == "Остановить очередь")
    #expect(DocumentTermsView.cancelLabel(inQueue: false) == "Отмена")
}
