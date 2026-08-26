import Testing
import Foundation
@testable import LMStudioKit

/// Bytes as an `AsyncSequence`, standing in for `URLSession.AsyncBytes`.
private struct AsyncBytesFixture: AsyncSequence {
    typealias Element = UInt8
    let bytes: [UInt8]
    init(_ text: String) { bytes = Array(text.utf8) }
    init(bytes: [UInt8]) { self.bytes = bytes }

    struct AsyncIterator: AsyncIteratorProtocol {
        var remaining: [UInt8]
        mutating func next() async -> UInt8? {
            remaining.isEmpty ? nil : remaining.removeFirst()
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(remaining: bytes) }
}

private func lines(of text: String, maxBytes: Int = BoundedLines<AsyncBytesFixture>.defaultMaxBytes)
    async throws -> [String] {
    var out: [String] = []
    for try await line in BoundedLines(AsyncBytesFixture(text), maxBytes: maxBytes) { out.append(line) }
    return out
}

@Test func linesAreSplitOnTheNewlineAndTheTerminatorIsNotKept() async throws {
    #expect(try await lines(of: "a\nbb\nccc\n") == ["a", "bb", "ccc"])
}

/// A final fragment with no terminator is a line too. `AsyncLineSequence` yields it, and on this
/// protocol it is the frame carrying `done` — dropping it would make every unterminated stream
/// look like one that never finished.
@Test func aTrailingFragmentWithNoTerminatorIsStillALine() async throws {
    #expect(try await lines(of: "a\nbb") == ["a", "bb"])
}

/// Nothing here sends CRLF, but a reader that handed `"…}\r"` to `JSONSerialization` would turn
/// a protocol difference into an unparseable frame. `AsyncLineSequence` drops it; so does this.
@Test func aCarriageReturnBeforeTheNewlineIsDropped() async throws {
    #expect(try await lines(of: "a\r\nbb\r\n") == ["a", "bb"])
}

@Test func anEmptyStreamYieldsNoLines() async throws {
    #expect(try await lines(of: "").isEmpty)
}

/// Blank lines survive: NDJSON carries them and the parser is what decides they mean nothing.
@Test func blankLinesAreYieldedRatherThanSwallowed() async throws {
    #expect(try await lines(of: "a\n\nb\n") == ["a", "", "b"])
}

/// The defect. `bytes.lines` buffers a whole line before yielding and has no bound, so a process
/// answering 200 on the loopback port and then streaming newline-free bytes grows that buffer
/// until the app dies. The inter-data timeout cannot save it — every arriving byte resets it —
/// and the 900 s resource timeout is a long time to spend filling memory at loopback speed.
@Test func aLineLongerThanTheCeilingIsRefusedRatherThanBuffered() async {
    let endless = String(repeating: "x", count: 500)
    await #expect(throws: LMStudioError.self) {
        _ = try await lines(of: endless, maxBytes: 100)
    }
}

/// The boundary, so the ceiling cannot be satisfied by refusing everything: a line exactly at
/// the limit is fine.
@Test func aLineExactlyAtTheCeilingIsAccepted() async throws {
    let atLimit = String(repeating: "x", count: 100)
    #expect(try await lines(of: atLimit + "\n", maxBytes: 100) == [atLimit])
}

/// The ceiling is per line, not per stream: a long response made of ordinary frames must not
/// trip it.
@Test func manyLinesTogetherLongerThanTheCeilingAreFine() async throws {
    let stream = String(repeating: "xxxxxxxxx\n", count: 100)   // 1000 bytes in 10-byte lines
    #expect(try await lines(of: stream, maxBytes: 100).count == 100)
}
