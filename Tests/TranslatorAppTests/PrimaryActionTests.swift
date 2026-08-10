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
