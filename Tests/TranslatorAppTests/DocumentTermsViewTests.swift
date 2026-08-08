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

@MainActor @Test func aDocumentTermThatTheUserGlossaryAlreadyCoversIsNotOfferedTwice() {
    // GlossaryMerge lets the user's entry win, so an editable duplicate would accept a
    // change the very next line of the engine discards.
    let rows = DocumentTermsView.rows(for: draft(
        document: [GlossaryEntry(term: "profile", translations: ["ru": "профиль"]),
                   GlossaryEntry(term: "Profile", translations: ["ru": "анкета"])],
        user: [GlossaryEntry(term: "PROFILE", doNotTranslate: true)]))

    #expect(rows.count == 1)
    guard case .user = rows.first else { Issue.record("expected only the user's row"); return }
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
