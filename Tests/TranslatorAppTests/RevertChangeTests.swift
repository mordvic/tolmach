// Tests/TranslatorAppTests/RevertChangeTests.swift
//
// «Вернуть» (issue #89, phase 2): `TranslationViewModel.revertChange(at:undoManager:)` and
// `selectChange(_:)` — restoring one правка change in the result, re-deriving the count and
// the marks from it, and the undo story that sits above both.
import AppKit
import Foundation
import Testing
@testable import TranslationCore
@testable import TranslatorApp

/// Never `.general` — the same reasoning `TranslationViewModelTests.scratchPasteboard()`
/// gives, private to that file.
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.revert.\(UUID().uuidString)"))
}

/// The same shape as `ChangeCursorTests.makeModel(responses:)`, private to that file.
@MainActor
private func makeModel(responses: [String], pasteboard: NSPasteboard? = nil) -> TranslationViewModel {
    TranslationViewModel(
        translator: Translator(client: QueueClient(replies: responses)),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "revert")),
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("g-\(UUID().uuidString).json")),
        pasteboard: pasteboard ?? scratchPasteboard())
}

@MainActor
private func finishedProofread(reply: String, source: String,
                               pasteboard: NSPasteboard? = nil) async -> TranslationViewModel {
    let model = makeModel(responses: [reply], pasteboard: pasteboard)
    model.sourceText = source
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsOnly
    await model.run()
    return model
}

// Two independent, unambiguous word-level substitutions in one paragraph — the shape
// `ChangeMarks.revertEdit` locates without guessing (both `removed` and `inserted` non-empty).
private let twoWordSubstitutionsSource = "Первый абзац неверен. Второй абзац неверен тоже."
private let twoWordSubstitutionsReply = "Первый абзац исправлен. Второй абзац исправлен тоже."

@MainActor @Test func revertingAChangeRestoresExactlyThatWordAndNothingElseMoves() async {
    let model = await finishedProofread(reply: twoWordSubstitutionsReply,
                                        source: twoWordSubstitutionsSource)
    guard let before = model.changes else { Issue.record("expected a change set"); return }
    #expect(before.count == 2)
    #expect(model.revertChange(at: 0))
    // Exactly the first «исправлен» went back to «неверен» — the second sentence's own
    // correction is still standing, so the reverted text is neither the full source nor the
    // full reply.
    #expect(model.translatedText == "Первый абзац неверен. Второй абзац исправлен тоже.")
    guard let after = model.changes else { Issue.record("expected a change set"); return }
    #expect(after.count == 1)
    #expect(model.changeCursor == nil)
}

@MainActor @Test func aSecondRevertOnTheAlreadyEditedResultFindsTheRemainingChange() async {
    let model = await finishedProofread(reply: twoWordSubstitutionsReply,
                                        source: twoWordSubstitutionsSource)
    #expect(model.revertChange(at: 0))
    guard let remaining = model.changes, remaining.count == 1 else {
        Issue.record("expected exactly one change left"); return
    }
    #expect(model.revertChange(at: 0))
    #expect(model.translatedText == twoWordSubstitutionsSource)
    #expect(model.changes?.count == 0)
}

@MainActor @Test func revertingABlockScopeChangeRestoresTheWholeParagraph() async {
    let source = "Абзац с несколькими словами, который модель полностью переписала целиком."
    let reply = "Совершенно другой абзац, переписанный моделью с нуля от начала и до конца."
    let model = await finishedProofread(reply: reply, source: source)
    guard let changes = model.changes, changes.count == 1,
          changes.changes[0].scope == .block else {
        Issue.record("expected one block-scope change"); return
    }
    #expect(model.revertChange(at: 0))
    #expect(model.translatedText == source)
    #expect(model.changes?.count == 0)
}

@MainActor @Test func revertingAnUnlocatableChangeLeavesTranslatedTextUntouchedAndReportsIt() async {
    // A pure removal — `ChangeMarks.revertEdit` refuses it (`ChangeMarksTests` pins why), so
    // the model must refuse too rather than guess a splice, and must touch nothing when it does.
    let source = "Смотрите, пожалуйста, повнимательнее."
    let reply = "Смотрите повнимательнее."
    let model = await finishedProofread(reply: reply, source: source)
    guard let changes = model.changes, changes.count == 1 else {
        Issue.record("expected one change"); return
    }
    let before = model.translatedText
    #expect(!model.revertChange(at: 0))
    #expect(model.translatedText == before)
    #expect(model.changes?.count == 1)
}

@MainActor @Test func revertChangeAtAnOutOfRangeIndexIsRefusedHarmlessly() async {
    let model = await finishedProofread(reply: twoWordSubstitutionsReply,
                                        source: twoWordSubstitutionsSource)
    let before = model.translatedText
    #expect(!model.revertChange(at: 99))
    #expect(!model.revertChange(at: -1))
    #expect(model.translatedText == before)
}

@MainActor @Test func aNewRunClearsThePreviousRunsRevertOverride() async {
    let model = makeModel(responses: [twoWordSubstitutionsReply, twoWordSubstitutionsReply])
    model.sourceText = twoWordSubstitutionsSource
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsOnly
    await model.run()
    #expect(model.revertChange(at: 0))
    #expect(model.changes?.count == 1)
    // «Ещё вариант» — the same run again. The override must not survive into it: this run's
    // own change set describes what the reply changed, not what the last one's edit left.
    await model.run()
    #expect(model.state == .finished)
    #expect(model.changes?.count == 2)
    #expect(model.translatedText == twoWordSubstitutionsReply)
}

@MainActor @Test func selectChangeMovesTheCursorToTheGivenIndexDirectly() async {
    let model = await finishedProofread(reply: twoWordSubstitutionsReply,
                                        source: twoWordSubstitutionsSource)
    #expect(model.changeCursor == nil)
    model.selectChange(1)
    #expect(model.changeCursor == 1)
    model.selectChange(0)
    #expect(model.changeCursor == 0)
    // Out of range: left exactly where it was, not clamped or cleared.
    model.selectChange(99)
    #expect(model.changeCursor == 0)
}

@MainActor @Test func revertPushesAnUndoActionThatRestoresTheEditedText() async {
    let model = await finishedProofread(reply: twoWordSubstitutionsReply,
                                        source: twoWordSubstitutionsSource)
    let undoManager = UndoManager()
    let original = model.translatedText
    #expect(model.revertChange(at: 0, undoManager: undoManager))
    let edited = model.translatedText
    #expect(edited != original)
    #expect(undoManager.canUndo)
    undoManager.undo()
    #expect(model.translatedText == original)
    #expect(model.changes?.count == 2)
    #expect(undoManager.canRedo)
    undoManager.redo()
    #expect(model.translatedText == edited)
    #expect(model.changes?.count == 1)
}

@MainActor @Test func anAdoptedProofreadCarriesThePanelsAlreadyRevertedChanges() async {
    let panel = await finishedProofread(reply: twoWordSubstitutionsReply,
                                        source: twoWordSubstitutionsSource)
    #expect(panel.revertChange(at: 0))
    #expect(panel.changes?.count == 1)
    let window = makeModel(responses: [])
    #expect(window.adopt(from: panel))
    #expect(window.translatedText == panel.translatedText)
    #expect(window.changes?.count == 1)
}

@MainActor @Test func copyToPasteboardCarriesTheRevertedTextNotTheOriginalReply() async {
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }
    let model = await finishedProofread(reply: twoWordSubstitutionsReply,
                                        source: twoWordSubstitutionsSource, pasteboard: board)
    #expect(model.revertChange(at: 0))
    let edited = model.translatedText
    await model.copyToPasteboard()
    #expect(board.string(forType: .string) == edited)
}
