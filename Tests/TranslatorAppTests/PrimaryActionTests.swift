import Foundation
import Testing
import AppKit
import TranslationCore
@testable import TranslatorApp

/// `makeQueueModel(_:prefix:configure:)`, `QueueClient` and `scratchGlossary` come from
/// `FileQueueModelTests.swift` and are shared across the module; that file's own
/// `makeTextModel` is `private` to it, so this one mirrors its body rather than reusing it.
@MainActor
private func makeTextModel() -> TranslationViewModel {
    TranslationViewModel(translator: Translator(client: QueueClient(replies: [])),
                         settings: AppSettings(defaults: InMemoryDefaults(prefix: "primary-action")),
                         glossary: scratchGlossary(),
                         pasteboard: NSPasteboard(name: .init("primary-action-\(UUID().uuidString)")))
}

@MainActor
private func makeQueueModel() -> FileQueueModel {
    makeQueueModel(QueueClient(replies: []), prefix: "primary-action")
}

@MainActor
@Test func theStartTitleFollowsTheOperationInTextModeOnly() {
    let text = makeTextModel()
    let queue = makeQueueModel()
    text.operation = .proofread
    #expect(PrimaryAction.forMode(.text, text: text, queue: queue).startTitle == "Исправить")
    text.operation = .translate
    #expect(PrimaryAction.forMode(.text, text: text, queue: queue).startTitle == "Перевести")
    // «Файлы» is translation-only whatever the text model's switch says (spec §6).
    text.operation = .proofread
    #expect(PrimaryAction.forMode(.files, text: text, queue: queue).startTitle == "Перевести")
}

@MainActor
@Test func swapIsUnavailableUnderProofread() {
    let text = makeTextModel()
    let queue = makeQueueModel()
    text.sourceOverride = .en
    text.targetOverride = .ru
    text.operation = .proofread
    #expect(!PrimaryAction.forMode(.text, text: text, queue: queue).canSwap)
}

// MARK: - The engine wave

@MainActor @Test func neitherModeCanStartBeforeAModelHasBeenChosen() {
    // The state LM Studio starts in: no honest default, and nothing auto-selected. Both modes
    // are blocked, because neither can translate without one — and the window says which
    // setting to fill in its status line rather than leaving a dead button unexplained.
    let text = makeTextModel()
    text.sourceText = "Он ждёт результата."
    let queue = makeQueueModel()
    queue.add([FileJob(url: URL(fileURLWithPath: "/tmp/a.md"), text: "first", partsTotal: 1)])

    for mode in SourceMode.allCases {
        let withModel = PrimaryAction.forMode(mode, text: text, queue: queue, hasModel: true)
        let without = PrimaryAction.forMode(mode, text: text, queue: queue, hasModel: false)
        #expect(withModel.canStart, "\(mode) should be startable when a model is chosen")
        #expect(without.canStart == false, "\(mode) must not start without a model")
    }
}
