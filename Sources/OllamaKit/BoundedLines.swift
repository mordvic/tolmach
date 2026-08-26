// Sources/OllamaKit/BoundedLines.swift
import Foundation

/// `bytes.lines` with a ceiling on how long one line may grow before it is refused.
///
/// **Why not `AsyncLineSequence`.** It buffers a whole line before yielding it and has no
/// bound, so a process answering 200 on the configured loopback port and then streaming
/// newline-free bytes grows that buffer until the app dies. The inter-data timeout cannot save
/// it — every arriving byte resets the timer, which is documented on `OllamaClient.Timeout`
/// itself — and the 900 s resource timeout is a very long time to spend filling memory at
/// loopback throughput. The 64 KB bound this project already applied to a *refusal's* body was
/// the right instinct applied to the wrong half of the response: an error body is bounded and
/// the success stream is not.
///
/// **Duplicated in `LMStudioKit`, deliberately.** The two transport modules do not depend on
/// each other and `TranslationCore` is the domain layer, which knows nothing about byte
/// streams; `OllamaClient.request(_:timeout:method:)` and its LM Studio twin are duplicated for
/// the same reason and say so. The two copies are identical and each is pinned by its own test.
///
/// Generic over the byte sequence rather than concrete over `URLSession.AsyncBytes`, so the
/// ceiling can be tested without a network at all.
struct BoundedLines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String

    /// The most one line may carry.
    ///
    /// Three orders of magnitude above anything this protocol sends: the largest frame measured
    /// on 2026-08-26 against Ollama 0.32.14 is the `done` frame with its stats, at about 400
    /// bytes, and a token frame is smaller. Reasoning does not change that — it arrives token by
    /// token (258 frames in one measured response), not in one line.
    static var defaultMaxBytes: Int { 1024 * 1024 }

    let base: Base
    let maxBytes: Int

    init(_ base: Base, maxBytes: Int = BoundedLines.defaultMaxBytes) {
        self.base = base
        self.maxBytes = maxBytes
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let maxBytes: Int

        mutating func next() async throws -> String? {
            var line: [UInt8] = []
            while let byte = try await base.next() {
                guard byte != UInt8(ascii: "\n") else { return Self.string(of: line) }
                line.append(byte)
                guard line.count <= maxBytes else {
                    throw OllamaError.oversizedLine(maxBytes)
                }
            }
            // A trailing fragment with no terminator is still a line — `AsyncLineSequence`
            // yields it too, and an NDJSON stream whose last frame arrives unterminated
            // carries the `done` marker this client now insists on seeing.
            return line.isEmpty ? nil : Self.string(of: line)
        }

        /// A CR before the LF is dropped, as `AsyncLineSequence` drops it. Nothing here sends
        /// CRLF, but a reader that handed `"…}\r"` to `JSONSerialization` would turn a
        /// protocol difference into an unparseable frame.
        private static func string(of line: [UInt8]) -> String {
            var line = line
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            return String(decoding: line, as: UTF8.self)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), maxBytes: maxBytes)
    }
}
