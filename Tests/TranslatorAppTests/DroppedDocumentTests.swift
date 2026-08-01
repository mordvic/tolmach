import Testing
import Foundation
@testable import TranslatorApp

/// Writes `content` to a temp file with `name`, hands it to `body`, and removes it after.
///
/// Real files rather than an injected filesystem: every rule in `DroppedDocument` is about a
/// file — its extension, its size on disk, whether its bytes decode — so a stub would only
/// re-state the rules it is meant to check. `docs/TESTING.md` shape 5, avoided by making the
/// thing under test the thing that runs.
private func withTempFile<T>(named name: String, containing content: Data,
                             _ body: (URL) throws -> T) rethrows -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("drop-\(UUID().uuidString)-\(name)")
    try? content.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

private func withTempFile<T>(named name: String, containing text: String,
                             _ body: (URL) throws -> T) rethrows -> T {
    try withTempFile(named: name, containing: Data(text.utf8), body)
}

// MARK: - What is accepted

/// Every extension on the list, and one that is not, in one test so that shortening the list
/// fails here rather than passing quietly.
@Test func onlyTheFourTextExtensionsAreRead() {
    for name in ["a.txt", "a.text", "a.md", "a.markdown"] {
        withTempFile(named: name, containing: "Привет") {
            #expect(DroppedDocument.text(of: $0) == "Привет", "\(name) should be readable")
        }
    }
    // `.rtf` decodes as UTF-8 perfectly well, which is exactly why the list is closed rather
    // than «whatever decodes»: accepted, it would fill the pane with markup.
    withTempFile(named: "a.rtf", containing: #"{\rtf1\ansi Привет}"#) {
        #expect(DroppedDocument.text(of: $0) == nil)
    }
    withTempFile(named: "a.pdf", containing: "Привет") {
        #expect(DroppedDocument.text(of: $0) == nil)
    }
}

/// A dropped file arrives with whatever case the filesystem gave it, and `README.MD` is a real
/// way to write a file name.
@Test func theExtensionIsMatchedWithoutRegardToCase() {
    withTempFile(named: "A.MD", containing: "Привет") {
        #expect(DroppedDocument.text(of: $0) == "Привет")
    }
}

/// The file with no extension at all — the case a `hasSuffix` check gets wrong by accepting
/// «notes» because it ends in nothing.
@Test func aFileWithNoExtensionIsRefused() {
    withTempFile(named: "notes", containing: "Привет") {
        #expect(DroppedDocument.text(of: $0) == nil)
    }
}

// MARK: - The size limit

/// Exactly at the limit is accepted and one byte over is not, because an off-by-one in a
/// `<` is the whole failure mode of a bound.
@Test func theSizeLimitIsInclusiveAndOneByteOverIsRefused() {
    let atLimit = Data(repeating: UInt8(ascii: "a"), count: DroppedDocument.maximumBytes)
    withTempFile(named: "big.txt", containing: atLimit) {
        #expect(DroppedDocument.text(of: $0)?.count == DroppedDocument.maximumBytes)
    }
    let overLimit = Data(repeating: UInt8(ascii: "a"), count: DroppedDocument.maximumBytes + 1)
    withTempFile(named: "bigger.txt", containing: overLimit) {
        #expect(DroppedDocument.text(of: $0) == nil)
    }
}

/// Refused, never truncated. The distinction matters more than the limit itself: handing back
/// the first quarter of someone's document and presenting it as the translation is the failure
/// the limit exists to avoid, and a `prefix(maximumBytes)` would introduce it while keeping
/// every other assertion here green.
@Test func anOversizedFileIsRefusedRatherThanCutShort() {
    let over = Data(repeating: UInt8(ascii: "a"), count: DroppedDocument.maximumBytes * 2)
    withTempFile(named: "huge.txt", containing: over) {
        #expect(DroppedDocument.text(of: $0) == nil)
    }
}

// MARK: - What is inside

/// Bytes that are not UTF-8. A file that fails to decode must refuse rather than arrive as
/// replacement characters, which would look like a translation problem rather than a file one.
@Test func aFileThatIsNotUTF8IsRefused() {
    // 0xFF is not a legal UTF-8 byte anywhere.
    withTempFile(named: "latin.txt", containing: Data([0xFF, 0xFE, 0x41, 0x42])) {
        #expect(DroppedDocument.text(of: $0) == nil)
    }
}

/// Whitespace decides *whether* there is anything to translate; it is not stripped from
/// something that is there. The same judgement `SelectionReader.meaningful` makes, and the
/// test is shaped the same way: an empty-looking file refuses, and a real one keeps its own
/// leading and trailing whitespace.
@Test func aBlankFileIsRefusedWhileRealTextKeepsItsWhitespace() {
    withTempFile(named: "blank.txt", containing: "   \n\n\t  \n") {
        #expect(DroppedDocument.text(of: $0) == nil)
    }
    withTempFile(named: "spaced.txt", containing: "  Привет, мир.  \n") {
        #expect(DroppedDocument.text(of: $0) == "  Привет, мир.  \n")
    }
}

/// A path that is not there at all — a drag from a volume that went away between the drop and
/// the read. It must be a refusal, not a trap.
@Test func aMissingFileIsRefusedRatherThanTrapping() {
    let gone = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-such-file-\(UUID().uuidString).txt")
    #expect(DroppedDocument.text(of: gone) == nil)
}
