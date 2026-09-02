import AppKit
import Testing
import TranslationCore
@testable import TranslatorApp

// The «Оформить» pass as the window and the panel run it: one extra model call before the
// operation, only when asked for, only for a text with no structure, only when it fits one
// request — and whatever it returns, the user's translation still happens.

private let flat = "Folder\nTrunk\n/nova\nmain"
private let table = "| Folder | Trunk |\n| --- | --- |\n| /nova | main |"

@MainActor
private func makeModel(replies: [String], surface: TranslationViewModel.Surface = .window,
                       holdCallAtIndex: Int? = nil, failCallAtIndex: Int? = nil)
-> (TranslationViewModel, QueueClient, AppSettings) {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "fmt-\(UUID().uuidString)"))
    let client = QueueClient(replies: replies, holdCallAtIndex: holdCallAtIndex,
                             failCallAtIndex: failCallAtIndex)
    let model = TranslationViewModel(
        translator: Translator(client: client), settings: settings,
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("g-\(UUID().uuidString).json")),
        pasteboard: NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.fmt.\(UUID().uuidString)")),
        surface: surface)
    return (model, client, settings)
}

@MainActor @Test func withTheSettingOffNoFormattingCallIsMade() async {
    let (model, client, _) = makeModel(replies: ["перевод"])
    model.sourceText = flat
    await model.run()
    #expect(client.callCount == 1)
    #expect(!client.receivedMessages[0][0].content.contains("typesetter"))
}

@MainActor @Test func anAcceptedReconstructionReplacesTheSourceAndIsWhatGetsTranslated() async {
    let (model, client, settings) = makeModel(replies: [table, "перевод"])
    settings.reconstructsStructure = true
    model.sourceText = flat
    await model.run()
    #expect(client.callCount == 2)
    #expect(client.receivedMessages[0][0].content.contains("typesetter"))
    #expect(client.receivedMessages[1].last?.content.hasSuffix(table) == true)
    #expect(model.sourceText == table)
    #expect(model.sourceWasReconstructed)
    #expect(model.formattingNotice == nil)
    #expect(model.state == .finished)
}

@MainActor @Test func aTextThatAlreadyHasStructureIsNotReformatted() async {
    let (model, client, settings) = makeModel(replies: ["перевод"])
    settings.reconstructsStructure = true
    model.sourceText = "# Title\n\nBody."
    await model.run()
    #expect(client.callCount == 1)
    #expect(model.formattingNotice == nil)
    #expect(!model.sourceWasReconstructed)
}

@MainActor @Test func aTextLongerThanOneRequestSkipsThePassAndSaysSo() async {
    let (model, client, settings) = makeModel(replies: ["перевод"])
    settings.reconstructsStructure = true
    settings.chunkSize = 300
    model.sourceText = String(repeating: "One flat line of prose.\n", count: 40)
    await model.run()
    // The translation itself is several calls for a text this long; what must be absent is
    // the pass — no call carried its prompt.
    #expect(!client.receivedMessages.contains { $0[0].content.contains("typesetter") })
    #expect(model.formattingNotice == .tooLong)
    #expect(model.state == .finished)
}

@MainActor @Test func aRejectedReconstructionTranslatesTheOriginalAndSaysWhy() async {
    let (model, client, settings) = makeModel(replies: ["| Folder | Trunks |\n| --- | --- |\n| /nova | main |",
                                                        "перевод"])
    settings.reconstructsStructure = true
    model.sourceText = flat
    await model.run()
    #expect(client.callCount == 2)
    #expect(client.receivedMessages[1].last?.content.hasSuffix(flat) == true)
    #expect(model.sourceText == flat)
    #expect(!model.sourceWasReconstructed)
    #expect(model.formattingNotice == .rejected(.wordsChanged))
    #expect(model.state == .finished)
}

/// A failed pass is a failed enhancement, not a failed translation — the same rule the
/// document glossary follows, with the difference that the user asked for this one and is
/// told.
@MainActor @Test func aFailedFormattingCallStillTranslatesAndIsReported() async {
    let (model, client, settings) = makeModel(replies: ["перевод"], failCallAtIndex: 0)
    settings.reconstructsStructure = true
    model.sourceText = flat
    await model.run()
    #expect(client.callCount == 2)
    #expect(model.state == .finished)
    #expect(model.translatedText == "перевод")
    if case .failed = model.formattingNotice {} else {
        Issue.record("expected a .failed notice, got \(String(describing: model.formattingNotice))")
    }
}

/// The panel answers in under a second by contract, and the pass is a second call in front of
/// the first token — so the panel's model follows a second checkbox of its own.
@MainActor @Test func thePanelFormatsOnlyUnderItsOwnCheckbox() async {
    let (model, client, settings) = makeModel(replies: ["перевод", table, "перевод"], surface: .panel)
    settings.reconstructsStructure = true
    model.sourceText = flat
    await model.run()
    #expect(client.callCount == 1)
    settings.reconstructsStructureInPanel = true
    await model.run()
    #expect(client.callCount == 3)
    #expect(model.sourceText == table)
}

@MainActor @Test func thePassRunsBeforeAProofreadToo() async {
    let (model, client, settings) = makeModel(replies: [table, "исправлено"])
    settings.reconstructsStructure = true
    model.operation = .proofread
    model.sourceText = flat
    await model.run()
    #expect(client.callCount == 2)
    #expect(client.receivedMessages[1].last?.content.hasSuffix(table) == true)
}

/// While the pass runs the status rows say so — the run is `.running` and nothing is
/// streaming, which without this flag reads as a model that has stalled.
@MainActor @Test func theModelSaysItIsFormattingWhileThePassIsInFlight() async {
    let (model, client, settings) = makeModel(replies: [table, "перевод"], holdCallAtIndex: 0)
    settings.reconstructsStructure = true
    model.sourceText = flat
    let run = Task { await model.run() }
    // Both halves: the flag is raised on the main actor before the pass's task has reached
    // the client, so waiting on the flag alone found `callCount == 0` one run in a few.
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(model.isFormatting && client.callCount == 1), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.isFormatting)
    #expect(model.state == .running)
    #expect(client.callCount == 1)
    model.cancel()
    await run.value
    #expect(!model.isFormatting)
    #expect(model.state == .interrupted)
}

/// A notice belongs to its run: the next run must not carry the previous one's «не удалось».
@MainActor @Test func theNoticeIsResetByTheNextRun() async {
    let (model, _, settings) = makeModel(replies: ["| a | b |\n| --- |\n| c |", "перевод", table, "перевод"])
    settings.reconstructsStructure = true
    model.sourceText = flat
    await model.run()
    #expect(model.formattingNotice != nil)
    model.sourceText = flat
    await model.run()
    #expect(model.formattingNotice == nil)
}

/// «•» bullets are drawn as a list by the pane, but they are not structure the pass is barred
/// from adding to — the text beside them may still hold a collapsed table.
@MainActor @Test func plainBulletsDoNotStopThePass() async {
    let source = "• first\n• second\nFolder\nTrunk\n/nova\nmain"
    let formatted = "- first\n- second\n\n| Folder | Trunk |\n| --- | --- |\n| /nova | main |"
    let (model, client, settings) = makeModel(replies: [formatted, "перевод"])
    settings.reconstructsStructure = true
    model.sourceText = source
    await model.run()
    #expect(client.callCount == 2)
    #expect(model.sourceText == formatted)
}
