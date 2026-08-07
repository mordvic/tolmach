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

@Test func aDropOfReadableFilesComesBackInTheOrderItWasDropped() throws {
    let scratch = Scratch()
    let a = scratch.file("a.md", "first")
    let b = scratch.file("b.txt", "second")
    let accepted = try #require(QueueDrop.accept([a, b]))
    #expect(accepted.map(\.url) == [a, b])
    #expect(accepted.map(\.text) == ["first", "second"])
}

@Test func aMixedDropKeepsWhatItCanReadAndNamesWhatItCannot() throws {
    // The queue has a slot per file and no ambiguity about intent — the user means all
    // of them — so there is nothing to guess. A spring-back is legible feedback for one
    // file and a riddle for ten: everything returns and nothing says which was refused.
    let scratch = Scratch()
    let good = scratch.file("a.md", "text")
    let bad = scratch.file("b.pdf", "text")
    let accepted = try #require(QueueDrop.accept([good, bad]))

    #expect(accepted.map(\.url) == [good, bad])
    #expect(accepted[0].text == "text")
    #expect(accepted[1].text == nil)   // becomes a visible .unreadable row
}

@Test func aDropWithNothingReadableInItIsRefusedWhole() throws {
    // Only here does the spring-back stay the right answer: there is no row worth
    // making, and eleven refused rows would be a mess rather than an explanation.
    let scratch = Scratch()
    #expect(QueueDrop.accept([scratch.file("a.pdf", "x"), scratch.file("b.key", "y")]) == nil)
}

@Test func aFileOverTheCeilingIsRefusedWithoutBeingRead() throws {
    let scratch = Scratch()
    let huge = scratch.file("huge.md", bytes: QueueDrop.maximumBytes + 1)
    let readable = scratch.file("ok.md", "text")
    let accepted = try #require(QueueDrop.accept([huge, readable]))
    #expect(accepted[0].text == nil)
}

@Test func theCeilingHereIsHigherThanTheTextPanesOnPurpose() {
    // DroppedDocument's 256 KB is justified by what a person waits for *at a window*.
    // The queue has a progress bar, a per-file state and a cancel button, so that
    // reasoning does not carry across — see the spec, §4.1.
    #expect(QueueDrop.maximumBytes > DroppedDocument.maximumBytes)
    #expect(QueueDrop.maximumBytes == 2 * 1024 * 1024)
}

@Test func aFileOfBlankLinesIsNotReadableEitherAndSaysSo() throws {
    let scratch = Scratch()
    let blank = scratch.file("blank.md", "\n\n   \n")
    let readable = scratch.file("ok.md", "text")
    let accepted = try #require(QueueDrop.accept([blank, readable]))
    #expect(accepted[0].text == nil)
}

@Test func anEmptyDropIsRefusedRatherThanAcceptedAsAnEmptyQueue() {
    #expect(QueueDrop.accept([]) == nil)
}

@Test func aFileThatIsNotUTF8IsNotReadable() throws {
    let scratch = Scratch()
    let url = scratch.directory.appendingPathComponent("latin1.md")
    try Data([0xFF, 0xFE, 0xFD]).write(to: url)
    let readable = scratch.file("ok.md", "text")
    let accepted = try #require(QueueDrop.accept([url, readable]))
    #expect(accepted[0].text == nil)
}
