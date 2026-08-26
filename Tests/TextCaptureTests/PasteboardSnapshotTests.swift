import Testing
import AppKit
@testable import TextCapture

private func scratchPasteboard() -> NSPasteboard {
    // Never `.general`: these tests overwrite whatever they are given.
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.\(UUID().uuidString)"))
}

/// Serves its bytes only when someone asks for them, the way an application that puts a
/// promise on the pasteboard does. Declared at file scope because a data provider has to be
/// an `@objc` class and a class local to a function cannot be one.
private final class Promiser: NSObject, NSPasteboardItemDataProvider {
    nonisolated(unsafe) static var callCount = 0
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        Promiser.callCount += 1
        item.setData(Data("обещанное".utf8), forType: type)
    }
}

// Every test here runs on the main actor. `NSPasteboard` is not thread-safe — two concurrent
// reads of one pasteboard abort the whole process with an uncaught `NSException` — and off
// the main thread AppKit also logs «synchronous promise fulfillment requested from a
// background thread» on each read. Named boards keep these tests apart either way, but this
// is how the application calls the type, so it is how the tests should call it.

@MainActor
@Test func aPlainStringRoundTrips() {
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    pb.setString("привет", forType: .string)

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    pb.setString("затёрто", forType: .string)
    snapshot.restore(to: pb)

    #expect(pb.string(forType: .string) == "привет")
}

@MainActor
@Test func everyTypeOfAnItemSurvivesNotJustTheString() {
    // The whole reason this type exists. A user who copied rich text out of Pages has an
    // RTF flavour alongside the plain string; restoring only the string silently downgrades
    // their clipboard to plain text and they find out when they paste.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData(Data("простой".utf8), forType: .string)
    item.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
    pb.writeObjects([item])

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    pb.setString("затёрто", forType: .string)
    snapshot.restore(to: pb)

    #expect(pb.string(forType: .string) == "простой")
    #expect(pb.data(forType: .rtf) == Data("{\\rtf1 rich}".utf8))
}

@MainActor
@Test func aPrivateTypeAndItsExactBytesSurvive() {
    // «Every type» has to mean the ones no test author thought of: an application's own
    // private flavour, carrying bytes that are not text at all. Anything that goes through a
    // `String` on the way in or out mangles these — the NULs terminate it and the 0x80 and
    // 0xFE are not valid UTF-8, so a lossy conversion turns them into replacement characters
    // instead of failing where someone would notice.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    let privateType = NSPasteboard.PasteboardType("ru.tolmach.test.private")
    let bytes = Data([0x00, 0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x80, 0x41])
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData(bytes, forType: privateType)
    item.setData(Data("текст".utf8), forType: .string)
    pb.writeObjects([item])

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    pb.setString("затёрто", forType: .string)
    snapshot.restore(to: pb)

    #expect(pb.data(forType: privateType) == bytes)
    #expect(pb.string(forType: .string) == "текст")
}

@MainActor
@Test func theDeclaredOrderOfAnItemsFlavoursIsPreserved() {
    // `NSPasteboard.types` is an ordered list, and a receiver that enumerates it rather than
    // asking for a preferred type takes the first flavour it recognises. Storing the
    // flavours in a dictionary hands them back in Swift's hash order, which is stable within
    // a process and different between processes — so the same clipboard would paste as rich
    // text today and plain text after a relaunch. Private types are used because the
    // pasteboard derives no extra flavours from them, so the order asserted is exactly the
    // order written.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    let declared = (1...6).map { NSPasteboard.PasteboardType("ru.tolmach.test.flavour\($0)") }
    pb.clearContents()
    let item = NSPasteboardItem()
    for (index, type) in declared.enumerated() { item.setData(Data([UInt8(index)]), forType: type) }
    pb.writeObjects([item])
    // Guards the assertion below from passing vacuously: the pasteboard itself keeps the
    // order it was given, so anything different afterwards came from the snapshot.
    #expect(pb.pasteboardItems?.first?.types == declared)

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    snapshot.restore(to: pb)

    #expect(pb.pasteboardItems?.first?.types == declared)
}

@MainActor
@Test func promisedDataIsFetchedRatherThanRestoredEmpty() {
    // An application that puts a promise on the pasteboard writes the type names now and the
    // bytes only when a receiver asks. A snapshot that copied what is already materialised
    // would put back a clipboard advertising flavours with nothing behind them, and the
    // promising application is not there to serve them a second time.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    Promiser.callCount = 0
    let promiser = Promiser()
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setDataProvider(promiser, forTypes: [.string])
    pb.writeObjects([item])

    let snapshot = PasteboardSnapshot.take(from: pb)
    #expect(Promiser.callCount == 1)
    pb.clearContents()
    pb.setString("затёрто", forType: .string)
    snapshot.restore(to: pb)

    #expect(pb.string(forType: .string) == "обещанное")
}

@MainActor
@Test func multipleItemsStayMultipleItems() {
    // A multi-file copy in Finder is several items. Collapsing them to one loses all but
    // the first, and the loss is invisible until the user pastes.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    let first = NSPasteboardItem(); first.setData(Data("один".utf8), forType: .string)
    let second = NSPasteboardItem(); second.setData(Data("два".utf8), forType: .string)
    pb.writeObjects([first, second])

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    snapshot.restore(to: pb)

    #expect(pb.pasteboardItems?.count == 2)
    #expect(pb.pasteboardItems?.compactMap { $0.string(forType: .string) } == ["один", "два"])
}

@MainActor
@Test func anEmptyPasteboardRestoresAsEmptyRatherThanUnchanged() {
    // If the user's clipboard was empty before the hotkey, it must be empty after. Skipping
    // the restore when there is nothing to write leaves the copied selection sitting in the
    // clipboard — exactly the leak this type exists to prevent.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    pb.setString("выделенный текст", forType: .string)
    snapshot.restore(to: pb)

    #expect(pb.pasteboardItems?.isEmpty ?? true)
    #expect(pb.string(forType: .string) == nil)
}

@MainActor
@Test func theChangeCountIsCapturedSoTheCopyCanBeDetected() {
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    // Several clears first, so the live count is a number no plausible constant matches.
    for _ in 0..<4 { pb.clearContents() }
    let before = PasteboardSnapshot.take(from: pb)
    // The assertion that actually pins the capture. `pb.changeCount > before.changeCount`
    // below passes just as happily if `take` recorded a zero, and a wrong count is not
    // harmless: `SelectionReader` compares against it to decide whether the synthetic ⌘C
    // landed, so a count that never matches makes it hand back the user's old clipboard as
    // if it were the selection.
    #expect(before.changeCount == pb.changeCount)
    #expect(before.changeCount >= 4)

    pb.clearContents()
    pb.setString("новое", forType: .string)
    #expect(pb.changeCount > before.changeCount)
}

// MARK: - A restore must not overwrite somebody else's newer clipboard

private func scratchBoard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.restore.\(UUID().uuidString)"))
}

/// The ordinary case: nothing touched the board since the value was accepted, so the user's
/// clipboard comes back.
@Test func aBoardThatHasNotMovedIsRestored() {
    let board = scratchBoard()
    board.clearContents()
    board.setString("исходный буфер", forType: .string)
    let snapshot = PasteboardSnapshot.take(from: board)

    // Stand in for the synthetic ⌘C: the board moves on, and that new count is what the caller
    // accepted its value at.
    board.clearContents()
    board.setString("выделение", forType: .string)
    let accepted = board.changeCount

    #expect(snapshot.restoreIfUnchanged(to: board, since: accepted))
    #expect(board.string(forType: .string) == "исходный буфер")
}

/// The defect. The ⌘C poll waits up to half a second — fully exposed when the target app ignores
/// the keystroke — and a third-party write inside that window was overwritten by the stale
/// snapshot, so the user's next ⌘V pasted old content. Universal Clipboard delivering a copy
/// from the user's iPhone is the concrete case ADR 0005 now records.
@Test func aBoardSomethingElseWroteToIsLeftAlone() {
    let board = scratchBoard()
    board.clearContents()
    board.setString("исходный буфер", forType: .string)
    let snapshot = PasteboardSnapshot.take(from: board)

    board.clearContents()
    board.setString("выделение", forType: .string)
    let accepted = board.changeCount

    // Somebody else writes after the value was accepted.
    board.clearContents()
    board.setString("с айфона", forType: .string)

    #expect(!snapshot.restoreIfUnchanged(to: board, since: accepted))
    #expect(board.string(forType: .string) == "с айфона", "a newer clipboard was destroyed")
}
