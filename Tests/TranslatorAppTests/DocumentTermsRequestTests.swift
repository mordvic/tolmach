import Foundation
import AppKit
import Testing
import TranslationCore
@testable import TranslatorApp

@MainActor
private func makeRequest() -> DocumentTermsRequest {
    DocumentTermsRequest(draft: DocumentTermsDraft(
        documentEntries: [GlossaryEntry(term: "resource", translations: ["ru": "ресурс"])],
        userEntries: [],
        chunkCount: 7, target: .ru))
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

@MainActor @Test func raisingASheetAnnouncesItRatherThanWaitingToBeNoticed() async {
    // The escalation used to be an `.onChange` on the Window scene's content. This app is
    // LSUIElement with MenuBarExtra first, so that window is normally closed — the view did
    // not exist, the observer never ran, and a sheet raised by ⌥⌘T appeared nowhere while
    // the run sat waiting for an answer nobody could give.
    let announced = Announcement()
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "terms-announce"))
    settings.reviewDocumentTerms = true
    let model = TranslationViewModel(
        translator: Translator(client: ScriptedClient(responses: ["resource => ресурс", "п", "п"])),
        settings: settings,
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("g-\(UUID().uuidString).json")),
        pasteboard: NSPasteboard(name: .init("terms-announce")))
    model.onTermsRequested = { announced.fire() }
    model.sourceText = String(repeating: "The resource is published by the server. ", count: 30)

    let run = Task { await model.translate() }
    while model.pendingTermsRequest == nil { await Task.yield() }
    #expect(announced.count == 1)
    model.pendingTermsRequest?.cancel()
    await run.value
}

@MainActor private final class Announcement {
    private(set) var count = 0
    func fire() { count += 1 }
}
