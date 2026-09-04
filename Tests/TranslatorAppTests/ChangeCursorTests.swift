// Tests/TranslatorAppTests/ChangeCursorTests.swift
//
// `TranslationViewModel.changeCursor` and `stepChange(by:)` (spec #81, step 3): where the
// window's stepper stands, and every moment it must forget.
import AppKit
import Foundation
import Testing
@testable import TranslationCore
@testable import TranslatorApp

/// The same shape as `TranslationViewModelTests.makeModel(responses:)`, which is private to
/// that file: a `QueueClient` (from `FileQueueModelTests`) so the run has real replies, an
/// in-memory store, a scratch glossary and a scratch board.
@MainActor
private func makeModel(responses: [String]) -> TranslationViewModel {
    TranslationViewModel(
        translator: Translator(client: QueueClient(replies: responses)),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "cursor")),
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("g-\(UUID().uuidString).json")),
        pasteboard: NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.cursor.\(UUID().uuidString)")))
}

@MainActor
private func finishedProofread(reply: String, source: String) async -> TranslationViewModel {
    let model = makeModel(responses: [reply])
    model.sourceText = source
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsOnly
    await model.run()
    return model
}

@MainActor @Test func aFinishedProofreadExposesItsChangesAndTheCursorStepsThroughThemWrapping() async {
    let model = await finishedProofread(reply: "Привет, мир. Как дела?",
                                        source: "Превет мир. Как дила?")
    #expect(model.state == .finished)
    guard let changes = model.changes else {
        Issue.record("a finished правка has no change set"); return
    }
    #expect(changes.count >= 2)
    #expect(model.hasChanges)
    #expect(model.changeCursor == nil)
    // From nil, forward lands on the first change and backward on the last — «предыдущее»
    // before anything was visited means the end. Mutation: starting at 0 for both directions
    // fails the second half.
    model.stepChange(by: 1)
    #expect(model.changeCursor == 0)
    model.stepChange(by: -1)
    #expect(model.changeCursor == changes.count - 1)
    // …and wraps past the end. Mutation: clamping instead of `%` stays at `count − 1`.
    model.stepChange(by: 1)
    #expect(model.changeCursor == 0)
}

@MainActor @Test func steppingWithoutChangesIsANoOp() async {
    let model = makeModel(responses: ["Hello, world."])
    model.sourceText = "Привет, мир."
    await model.run()
    // A translation has no set at all — `Translator.translate` passes nil.
    #expect(model.state == .finished)
    #expect(model.changes == nil)
    #expect(!model.hasChanges)
    model.stepChange(by: 1)
    #expect(model.changeCursor == nil)
}

@MainActor @Test func theChangesAreExposedOnlyForAFinishedRun() async {
    // `outcome.changes` outlives the text until the next run's first token; `changes` must not.
    // Reached through `swapLanguages()`, which sets `.idle` and drops the outcome — the one
    // path that moves `state` off `.finished` without a new run. Mutation: `changes` reading
    // `outcome?.changes` without the state guard is caught by the interrupted-run case the
    // spec names, which this suite cannot reach deterministically; here the outcome is gone
    // too, so the assertion below holds for both halves of the rule at once.
    let model = makeModel(responses: ["Hello, world."])
    model.sourceText = "Привет, мир."
    // Stated, not detected: `canSwapLanguages` needs both languages known, and a two-word
    // source is not something the detector is asked to be sure about.
    model.sourceOverride = .ru
    model.targetOverride = .en
    await model.run()
    #expect(model.canSwapLanguages)
    model.swapLanguages()
    #expect(model.state == .idle)
    #expect(model.changes == nil)
    #expect(model.changeCursor == nil)
}

@MainActor @Test func theCursorIsDroppedWithTheOutcomeItPointedInto() async {
    let model = makeModel(responses: ["Привет, мир.", "Пока, мир."])
    model.sourceText = "Превет мир."
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsOnly
    await model.run()
    model.stepChange(by: 1)
    #expect(model.changeCursor == 0)
    // A second run («Ещё вариант», or the same text again): the first token clears `outcome`
    // and the finish assigns a new one; the cursor must survive neither. Mutation: either
    // clear removed → still 0 after a run whose list it never pointed into.
    await model.run()
    #expect(model.state == .finished)
    #expect(model.changeCursor == nil)
}

@MainActor @Test func anAdoptedProofreadArrivesWithItsChangesAndACursorAtTheTop() async {
    let panel = await finishedProofread(reply: "Привет, мир.", source: "Превет мир.")
    panel.stepChange(by: 1)
    #expect(panel.changeCursor == 0)
    let window = makeModel(responses: [])
    #expect(window.adopt(from: panel))
    #expect(window.changes?.count == panel.changes?.count)
    #expect(window.changes?.count ?? 0 > 0)
    // Nil and not the panel's 0: the window reads it from the top. Mutation: copying
    // `other.changeCursor` fails here.
    #expect(window.changeCursor == nil)
}
