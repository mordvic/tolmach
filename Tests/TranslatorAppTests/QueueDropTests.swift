import Foundation
import Testing
@testable import TranslatorApp

/// Writes real files, because the thing under test reads a filesystem and a fake one
/// would only pin the fake. Removed in `deinit`.
private final class Scratch {
    let directory: URL
    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func file(_ name: String, _ contents: String) -> URL {
        let url = directory.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: url)
        return url
    }

    func file(_ name: String, bytes: Int) -> URL {
        let url = directory.appendingPathComponent(name)
        try? Data(repeating: UInt8(ascii: "a"), count: bytes).write(to: url)
        return url
    }
}

@Test func aDropOfReadableFilesComesBackInTheOrderItWasDropped() {
    let scratch = Scratch()
    let a = scratch.file("a.md", "first")
    let b = scratch.file("b.txt", "second")
    #expect(QueueDrop.acceptable([a, b]))
    let items = QueueDrop.read([a, b])
    #expect(items.map(\.url) == [a, b])
    #expect(items.map(\.text) == ["first", "second"])
}

@Test func aMixedDropKeepsWhatItCanReadAndNamesWhatItCannot() {
    // The queue has a slot per file and no ambiguity about intent — the user means all of
    // them — so there is nothing to guess. A spring-back is legible feedback for one file
    // and a riddle for ten: everything returns and nothing says which was refused.
    let scratch = Scratch()
    let good = scratch.file("a.md", "text")
    let bad = scratch.file("b.pdf", "text")
    #expect(QueueDrop.acceptable([good, bad]))

    let items = QueueDrop.read([good, bad])
    #expect(items.map(\.url) == [good, bad])
    #expect(items[0].text == "text")
    #expect(items[1].text == nil)   // becomes a visible .unreadable row
}

@Test func aDropWithNothingPlausibleInItIsRefusedWhole() {
    // Only here does the spring-back stay the right answer: there is no row worth making,
    // and eleven refused rows would be a mess rather than an explanation.
    let scratch = Scratch()
    #expect(!QueueDrop.acceptable([scratch.file("a.pdf", "x"), scratch.file("b.key", "y")]))
}

@Test func theSynchronousCheckAnswersFromAttributesAndNotFromBytes() {
    // `dropDestination` runs on the main actor and must answer at once. A file whose
    // *contents* disqualify it — not UTF-8, or nothing but blank lines — is therefore
    // accepted here and becomes a named `.unreadable` row, rather than costing the window a
    // freeze while every dropped file is loaded and decoded to decide a Bool.
    let scratch = Scratch()
    let blank = scratch.file("blank.md", "\n\n   \n")
    #expect(QueueDrop.acceptable([blank]))
    #expect(QueueDrop.read([blank])[0].text == nil)
}

@Test func aFileOverTheCeilingIsRefusedWithoutBeingRead() {
    let scratch = Scratch()
    let huge = scratch.file("huge.md", bytes: QueueDrop.maximumBytes + 1)
    // Refused by the cheap check, so its bytes are never loaded.
    #expect(!QueueDrop.acceptable([huge]))
    #expect(QueueDrop.read([huge])[0].text == nil)
}

@Test func theCeilingHereIsHigherThanTheTextPanesOnPurpose() {
    // DroppedDocument's 256 KB is justified by what a person waits for *at a window*. The
    // queue has a progress bar, a per-file state and a cancel button, so that reasoning does
    // not carry across — see the spec, §4.1.
    #expect(QueueDrop.maximumBytes > DroppedDocument.maximumBytes)
    #expect(QueueDrop.maximumBytes == 2 * 1024 * 1024)
}

@Test func anEmptyDropIsRefusedRatherThanAcceptedAsAnEmptyQueue() {
    #expect(!QueueDrop.acceptable([]))
}

@Test func aFileThatIsNotUTF8BecomesAnUnreadableRow() throws {
    let scratch = Scratch()
    let url = scratch.directory.appendingPathComponent("latin1.md")
    try Data([0xFF, 0xFE, 0xFD]).write(to: url)
    #expect(QueueDrop.acceptable([url]))
    #expect(QueueDrop.read([url])[0].text == nil)
}

@Test func aSymlinkCannotSmuggleALargeFilePastTheCeiling() throws {
    // `attributesOfItem` reports on the link — the length of its target *path*, a few dozen
    // bytes — while `Data(contentsOf:)` follows it. A symlink named `notes.md` pointing at
    // something enormous therefore walked straight past the 2 MB ceiling.
    let scratch = Scratch()
    let big = scratch.file("big.md", bytes: QueueDrop.maximumBytes + 1)
    let link = scratch.directory.appendingPathComponent("notes.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)

    #expect(!QueueDrop.acceptable([link]))       // refused without opening the target
    #expect(QueueDrop.read([link])[0].text == nil)
}

@Test func aSymlinkToSomethingSmallIsStillReadable() throws {
    let scratch = Scratch()
    let real = scratch.file("real.md", "текст")
    let link = scratch.directory.appendingPathComponent("notes.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    #expect(QueueDrop.acceptable([link]))
    #expect(QueueDrop.read([link])[0].text == "текст")
}
