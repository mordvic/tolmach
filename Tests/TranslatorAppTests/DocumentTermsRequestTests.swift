import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

@MainActor
private func makeRequest() -> DocumentTermsRequest {
    DocumentTermsRequest(draft: DocumentTermsDraft(
        documentEntries: [GlossaryEntry(term: "resource", translations: ["ru": "ресурс"])],
        userEntries: [],
        chunkCount: 7))
}

@MainActor @Test func proceedingHandsBackWhateverTheUserEdited() async throws {
    let request = makeRequest()
    let waiting = Task { try await request.answer() }
    request.entries = [GlossaryEntry(term: "resource", translations: ["ru": "объект"])]
    request.proceed()

    let answer = try await waiting.value
    #expect(answer.first?.translations["ru"] == "объект")
}

@MainActor @Test func cancellingThrowsCancellationRatherThanReturningNothing() async {
    let request = makeRequest()
    let waiting = Task { try await request.answer() }
    request.cancel()

    await #expect(throws: CancellationError.self) { try await waiting.value }
}

@MainActor @Test func aSecondAnswerAfterProceedingIsIgnoredRatherThanCrashing() async throws {
    // A checked continuation resumed twice traps the process. The sheet's button, Esc and
    // an external cancel can all arrive within one run loop turn, so «at most once» has to
    // be a property of this type and not of the callers' discipline.
    let request = makeRequest()
    let waiting = Task { try await request.answer() }
    request.proceed()
    request.cancel()
    request.proceed()

    _ = try await waiting.value   // must not trap
}

@MainActor @Test func aSecondAnswerAfterCancellingIsIgnoredRatherThanCrashing() async {
    let request = makeRequest()
    let waiting = Task { try await request.answer() }
    request.cancel()
    request.proceed()
    request.cancel()

    await #expect(throws: CancellationError.self) { try await waiting.value }
}

@MainActor @Test func anAnswerThatArrivedBeforeAnyoneWaitedIsNotLost() async {
    // The queue can cancel a run before the sheet's `answer()` has even been reached.
    // Without this, the continuation is created after the decision and nobody ever resumes
    // it — the exact hang this type exists to make impossible.
    let request = makeRequest()
    request.cancel()

    await #expect(throws: CancellationError.self) { try await request.answer() }
}

@MainActor @Test func aDecisionMadeBeforeAnyoneWaitedStillHandsBackTheEdits() async throws {
    let request = makeRequest()
    request.entries = [GlossaryEntry(term: "resource", translations: ["ru": "объект"])]
    request.proceed()

    let answer = try await request.answer()
    #expect(answer.first?.translations["ru"] == "объект")
}

@MainActor @Test func suppressingForTheRunIsCarriedOnTheRequestAndDefaultsOff() {
    let request = makeRequest()
    #expect(!request.suppressForRun)
    request.suppressForRun = true
    #expect(request.suppressForRun)
}

@MainActor @Test func theRequestStartsWithTheModelsEntriesReadyToEdit() {
    let request = makeRequest()
    #expect(request.entries.map(\.term) == ["resource"])
    #expect(request.draft.chunkCount == 7)
}
