// Sources/TranslationCore/LineScanner.swift
import Foundation

/// The engine's one line discipline: what counts as a line break, a blank line, a fence
/// marker, and exactly one blank line.
///
/// `Chunker` and `MarkupSkeleton` must read the same document or the markup diff reports
/// structure the chunker never saw — a phantom «потеряно» on a perfect translation. That
/// parity used to be maintained in parallel: each layer had its own line scan, its own
/// blank-line test (`Character.isWhitespace` in one, `CharacterSet.whitespaces` in the
/// other) and its own fence predicate, and they drifted. It is structural now — one
/// implementation, consumed by both — so the parity cannot be broken by editing one side.
enum LineScanner {
    struct Line {
        /// The line's characters, terminator excluded.
        let content: Range<String.Index>
        /// Index just past the terminator — the start of the next line.
        let end: String.Index
    }

    /// Every character Unicode calls a mandatory line break: LF, CR, CRLF, NEL, VT, FF,
    /// LINE SEPARATOR and PARAGRAPH SEPARATOR. Each is one Swift `Character` (CRLF
    /// included, which is why it is compared for explicitly and one `index(after:)`
    /// consumes both its scalars).
    ///
    /// The full family rather than just LF/CR because a model normalises the exotic ones
    /// to "\n" in its reply: a source using U+2028 between list items diffed against such
    /// a reply reported «добавлено: элемент списка» when only LF and CR broke lines here,
    /// because the source read as one line and the translation as two.
    static func isTerminator(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n"
            || character == "\u{85}" || character == "\u{0B}" || character == "\u{0C}"
            || character == "\u{2028}" || character == "\u{2029}"
    }

    /// Hand-rolled rather than `components(separatedBy: .newlines)` because the whole
    /// point is to keep ranges into the original string: separators are extracted as
    /// substrings, so "\r\n" and every other byte survive. That character set also splits
    /// on unicode *scalars*, so "\r\n" came out as two breaks with an empty line between
    /// them and the skeleton fabricated a `.paragraphBreak`.
    static func scanLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        var index = text.startIndex
        while index < text.endIndex {
            var cursor = index
            while cursor < text.endIndex, !isTerminator(text[cursor]) {
                cursor = text.index(after: cursor)
            }
            let contentEnd = cursor
            let lineEnd = cursor < text.endIndex ? text.index(after: cursor) : cursor
            lines.append(Line(content: index..<contentEnd, end: lineEnd))
            index = lineEnd
        }
        return lines
    }

    /// One line, kept apart from the terminator that followed it.
    ///
    /// `terminator` is empty for a final line that has none, and is otherwise the document's
    /// own bytes — `"\r\n"` stays `"\r\n"`. That is the whole point: a caller that takes a
    /// document apart line by line and puts it back together must put back the terminators it
    /// found, not the one it would have chosen. `InlineCodeRestorer` split on `"\n"` and
    /// rejoined with `"\n"`, which was lossless only by accident.
    struct Piece: Equatable {
        let content: String
        let terminator: String
    }

    /// The document as `(content, terminator)` pairs, under this type's line discipline.
    ///
    /// Lossless by construction: `pieces(t).map { $0.content + $0.terminator }.joined() == t`
    /// for every `t`, and a test pins it. Use this wherever `components(separatedBy:)` was
    /// reached for — that function is what let three layers disagree about what a line is.
    static func pieces(_ text: String) -> [Piece] {
        scanLines(text).map { line in
            Piece(content: String(text[line.content]),
                  terminator: String(text[line.content.upperBound..<line.end]))
        }
    }

    /// The first line, split from everything after it — or nil while no terminator has arrived.
    ///
    /// For a caller reading a stream, where «is the first line complete yet» is the question and
    /// a partial buffer is the normal state. `nil` means «not yet», never «no line».
    static func firstCompleteLine(_ text: String) -> (content: String, rest: String)? {
        guard let line = scanLines(text).first, line.end > line.content.upperBound else { return nil }
        return (String(text[line.content]), String(text[line.end...]))
    }

    /// Empty, or nothing but whitespace. A blank line separates blocks in the chunker and
    /// is a `.paragraphBreak` in the skeleton; those two must be the same predicate.
    static func isBlank(_ line: Line, in text: String) -> Bool {
        text[line.content].allSatisfy(\.isWhitespace)
    }

    /// An indented ``` is still a fence marker, in both layers.
    static func isFenceMarker(_ line: Line, in text: String) -> Bool {
        text[line.content].trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// True iff `separator` is two bare line terminators and nothing else — one blank
    /// line, in whatever line-ending convention the document is written in.
    ///
    /// The chunker's merge gate. Spelled structurally rather than as a list of literals
    /// because the list was `"\n\n"` and `"\r\n\r\n"`, and a CR-only or mixed-EOL document
    /// therefore never merged at all: measured, "Short first paragraph.\r\rShort second
    /// paragraph." gave 2 chunks at a 900-character budget where its LF twin gave 1.
    /// «Bare» is load-bearing: a blank line carrying spaces still forces a chunk boundary,
    /// because a merge across it would have to reproduce those spaces from the model's
    /// reply instead of from the source.
    static func isExactlyOneBlankLine(_ separator: String) -> Bool {
        let lines = scanLines(separator)
        return lines.count == 2 && lines.allSatisfy { $0.content.isEmpty }
    }
}
