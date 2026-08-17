import Testing
import AppKit
@testable import TextCapture

private func scratchPasteboard() -> NSPasteboard {
    // Never `.general`: these tests overwrite whatever they are given.
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.sw.\(UUID().uuidString)"))
}

/// A `SelectionWriter.Trigger` with a memory, so a test can tell what the pasteboard held at
/// the moment the trigger fired without ever posting a real ⌘V.
private final class RecordingTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _textSeenAtTrigger: String?
    private let board: NSPasteboard

    init(board: NSPasteboard) { self.board = board }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var textSeenAtTrigger: String? { lock.lock(); defer { lock.unlock() }; return _textSeenAtTrigger }

    func fire() {
        lock.lock()
        _callCount += 1
        _textSeenAtTrigger = board.string(forType: .string)
        lock.unlock()
    }
}

@MainActor
@Test func replaceWritesTheTextTriggersOnceThenRestoresWhatWasThereBefore() async {
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    pb.setString("пользовательский буфер", forType: .string)

    let trigger = RecordingTrigger(board: pb)
    let writer = SelectionWriter(triggerPaste: { trigger.fire() })
    await writer.replace("перевод", on: pb)

    #expect(trigger.callCount == 1)
    // The trigger is where a real target application's ⌘V would land, and by then the write
    // must already be on the board.
    #expect(trigger.textSeenAtTrigger == "перевод")
    // Restored afterward — «Заменить» must not permanently spend the user's clipboard.
    #expect(pb.string(forType: .string) == "пользовательский буфер")
}

@MainActor
@Test func replaceOnAnEmptyClipboardRestoresItAsEmpty() async {
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()

    let trigger = RecordingTrigger(board: pb)
    let writer = SelectionWriter(triggerPaste: { trigger.fire() })
    await writer.replace("перевод", on: pb)

    #expect(trigger.textSeenAtTrigger == "перевод")
    #expect(pb.string(forType: .string) == nil)
}

@MainActor
@Test func emptyResultTextIsANoOpThatNeverTouchesTheClipboardOrTheTrigger() async {
    // The same guard `GeneralPasteboard.write` applies for the same reason: clearing a board
    // with nothing to write back would destroy whatever the user has copied, for no gain —
    // and the button that calls this is disabled while `translatedText` is empty regardless,
    // so this is the second line of defence, not the only one.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    pb.setString("нетронуто", forType: .string)

    let trigger = RecordingTrigger(board: pb)
    let writer = SelectionWriter(triggerPaste: { trigger.fire() })
    await writer.replace("", on: pb)

    #expect(trigger.callCount == 0)
    #expect(pb.string(forType: .string) == "нетронуто")
}

@MainActor
@Test func richTextOnTheClipboardIsRestoredInFullNotJustItsString() async {
    // `SelectionWriter` shares `PasteboardSnapshot` with the read side, so the same guarantee
    // — every flavour, not just the string one — carries over here.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData(Data("простой".utf8), forType: .string)
    item.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
    pb.writeObjects([item])

    let writer = SelectionWriter(triggerPaste: {})
    await writer.replace("перевод", on: pb)

    #expect(pb.string(forType: .string) == "простой")
    #expect(pb.data(forType: .rtf) == Data("{\\rtf1 rich}".utf8))
}
