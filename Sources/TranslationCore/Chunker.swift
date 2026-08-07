// Sources/TranslationCore/Chunker.swift
import Foundation

public struct Chunk: Sendable, Equatable {
    public let index: Int
    public let text: String
    /// The exact bytes between the previous chunk's content and this chunk's content,
    /// as a substring of the source document — never synthesised. Assembly restores it
    /// verbatim; the model never sees it. For the first chunk this is the document's
    /// leading whitespace.
    public let separatorBefore: String
    public let containsCodeFence: Bool
}

/// What `Chunker.plan` promises: `chunks.map { $0.separatorBefore + $0.text }.joined()
/// + trailingSeparator` reproduces the input byte for byte. The model translates the
/// chunk texts; every byte outside them is restored by the caller, so model discipline
/// can never affect separators. See the lossless-chunking spec §2–3.
public struct ChunkPlan: Sendable, Equatable {
    public let chunks: [Chunk]
    /// Whitespace after the last chunk's content, verbatim. The whole input, when the
    /// input contains no translatable content at all.
    public let trailingSeparator: String
}

public enum Chunker {
    struct Block {
        enum Kind { case prose, fencedCode, indentedCode }
        let kind: Kind
        /// Content range in the source: first non-whitespace character of the block's
        /// first line through last non-whitespace character of its last line. Edge
        /// whitespace deliberately lives in the separators instead: a chunk that never
        /// begins or ends with whitespace cannot have structure eaten by
        /// `ResponseCleaner.clean`'s edge-trimming of the model's reply. Interior
        /// whitespace — hard-break spaces on non-final lines, indentation of
        /// continuation lines — stays inside the block.
        let range: Range<String.Index>
    }

    struct Piece {
        let separatorBefore: String
        let text: String
        let kind: Block.Kind
    }

    public static func chunk(_ text: String, maxCharacters: Int) -> [Chunk] {
        plan(text, maxCharacters: maxCharacters).chunks
    }

    public static func plan(_ text: String, maxCharacters: Int) -> ChunkPlan {
        let blocks = blocks(in: text)
        guard !blocks.isEmpty else { return ChunkPlan(chunks: [], trailingSeparator: text) }

        // Blocks → pieces. An oversized prose block splits by sentences; the split
        // moves inter-sentence whitespace into the next piece's separator, so the
        // reassembly invariant holds across the split too. Fenced code is never split
        // regardless of size.
        var pieces: [Piece] = []
        var previousEnd = text.startIndex
        for block in blocks {
            let separator = String(text[previousEnd..<block.range.lowerBound])
            let body = String(text[block.range])
            previousEnd = block.range.upperBound
            if block.kind == .prose && body.count > maxCharacters {
                pieces.append(contentsOf: splitBySentences(body, separatorBefore: separator,
                                                           maxCharacters: maxCharacters))
            } else {
                pieces.append(Piece(separatorBefore: separator, text: body, kind: block.kind))
            }
        }

        // Pieces → chunks. Merging is allowed only across an exactly-"\n\n" separator:
        // then the joined text is byte-identical to the source span it came from, and
        // the model always sees canonical block spacing. Any other separator — three
        // blank lines, CRLF, a lone "\n" before a fence — forces a chunk boundary and
        // is restored verbatim at assembly. The cost is a rare extra chunk on
        // unusually-formatted documents; the gain is that the markup diff can never
        // cry wolf over spacing the chunker itself changed.
        var chunks: [Chunk] = []
        var current = ""
        var currentSeparator = ""
        var currentHasFence = false
        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(Chunk(index: chunks.count, text: current,
                                separatorBefore: currentSeparator,
                                containsCodeFence: currentHasFence))
            current = ""; currentSeparator = ""; currentHasFence = false
        }
        for piece in pieces {
            if !current.isEmpty, piece.separatorBefore == "\n\n",
               current.count + 2 + piece.text.count <= maxCharacters {
                current += "\n\n" + piece.text
                currentHasFence = currentHasFence || piece.kind == .fencedCode
            } else {
                flush()
                currentSeparator = piece.separatorBefore
                current = piece.text
                currentHasFence = piece.kind == .fencedCode
            }
        }
        flush()
        return ChunkPlan(chunks: chunks, trailingSeparator: String(text[previousEnd...]))
    }

    // MARK: - Line scanning

    struct Line {
        /// The line's characters, terminator excluded.
        let content: Range<String.Index>
        /// Index just past the terminator — the start of the next line.
        let end: String.Index
    }

    /// Hand-rolled rather than `components(separatedBy: .newlines)` because the whole
    /// point is to keep ranges into the original string: separators are extracted as
    /// substrings, so "\r\n" and every other byte survive. "\r\n" is a single Swift
    /// `Character`, so it must be compared for explicitly and one `index(after:)`
    /// consumes both scalars.
    static func scanLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        var index = text.startIndex
        while index < text.endIndex {
            var cursor = index
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == "\n" || character == "\r" || character == "\r\n" { break }
                cursor = text.index(after: cursor)
            }
            let contentEnd = cursor
            let lineEnd = cursor < text.endIndex ? text.index(after: cursor) : cursor
            lines.append(Line(content: index..<contentEnd, end: lineEnd))
            index = lineEnd
        }
        return lines
    }

    // MARK: - Blocks

    static func blocks(in text: String) -> [Block] {
        let lines = scanLines(text)
        var blocks: [Block] = []
        var index = 0

        func isBlank(_ line: Line) -> Bool { text[line.content].allSatisfy(\.isWhitespace) }
        func isFenceMarker(_ line: Line) -> Bool {
            text[line.content].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        func isIndented(_ line: Line) -> Bool {
            let content = text[line.content]
            return content.hasPrefix("    ") || content.first == "\t"
        }
        /// Content range trimmed of whitespace at both edges — see `Block.range`.
        func blockRange(first: Line, last: Line) -> Range<String.Index> {
            var start = first.content.lowerBound
            var end = last.content.upperBound
            while start < end, text[start].isWhitespace { start = text.index(after: start) }
            while end > start {
                let before = text.index(before: end)
                guard text[before].isWhitespace else { break }
                end = before
            }
            return start..<end
        }

        var previousWasBlank = true // document start behaves like after a blank line
        while index < lines.count {
            if isBlank(lines[index]) { previousWasBlank = true; index += 1; continue }

            if isFenceMarker(lines[index]) {
                var last = index
                var cursor = index + 1
                while cursor < lines.count {
                    last = cursor
                    if isFenceMarker(lines[cursor]) { break }
                    cursor += 1
                }
                // An unterminated fence runs to the end of the document; its trailing
                // blank lines are document whitespace, not code.
                while last > index, isBlank(lines[last]) { last -= 1 }
                blocks.append(Block(kind: .fencedCode,
                                    range: blockRange(first: lines[index], last: lines[last])))
                index = last + 1
                previousWasBlank = false
                continue
            }

            // CommonMark: indented code starts only at the document start or after a
            // blank line — it cannot interrupt a paragraph. A blank line ends it;
            // an indented run after the next blank line simply starts a new block,
            // and the separator between them is restored verbatim like any other.
            if previousWasBlank, isIndented(lines[index]) {
                var last = index
                while last + 1 < lines.count, !isBlank(lines[last + 1]),
                      isIndented(lines[last + 1]) {
                    last += 1
                }
                blocks.append(Block(kind: .indentedCode,
                                    range: blockRange(first: lines[index], last: lines[last])))
                index = last + 1
                previousWasBlank = false
                continue
            }

            // Prose: a maximal run of non-blank lines that does not open a fence.
            var last = index
            while last + 1 < lines.count, !isBlank(lines[last + 1]),
                  !isFenceMarker(lines[last + 1]) {
                last += 1
            }
            blocks.append(Block(kind: .prose,
                                range: blockRange(first: lines[index], last: lines[last])))
            index = last + 1
            previousWasBlank = false
        }
        return blocks
    }

    // MARK: - Sentence splitting

    /// Splits an oversized prose block into pieces, losslessly:
    /// `pieces.map { $0.separatorBefore + $0.text }.joined()` equals
    /// `separatorBefore + body`. Inter-sentence whitespace moves into the *next*
    /// piece's separator, which is what stops the old design's "\n\n" joins from
    /// fabricating paragraph breaks inside a paragraph.
    static func splitBySentences(_ body: String, separatorBefore: String,
                                 maxCharacters: Int) -> [Piece] {
        var starts: [String.Index] = []
        body.enumerateSubstrings(in: body.startIndex..<body.endIndex,
                                 options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.lowerBound)
        }
        if starts.first != body.startIndex { starts.insert(body.startIndex, at: 0) }

        // Group whole sentences under the budget; a cut lands at a group's start.
        // A single sentence over the budget stays whole — same as the old design.
        var cuts: [String.Index] = [body.startIndex]
        var currentLength = 0
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1] : body.endIndex
            let length = body.distance(from: start, to: end)
            if currentLength > 0, currentLength + length > maxCharacters {
                cuts.append(start)
                currentLength = 0
            }
            currentLength += length
        }

        var pieces: [Piece] = []
        var pendingSeparator = separatorBefore
        for (offset, cut) in cuts.enumerated() {
            let end = offset + 1 < cuts.count ? cuts[offset + 1] : body.endIndex
            var contentEnd = end
            while contentEnd > cut {
                let before = body.index(before: contentEnd)
                guard body[before].isWhitespace else { break }
                contentEnd = before
            }
            pieces.append(Piece(separatorBefore: pendingSeparator,
                                text: String(body[cut..<contentEnd]), kind: .prose))
            pendingSeparator = String(body[contentEnd..<end])
        }
        // `body` is already edge-trimmed (see `Block.range`), so the final pending
        // separator is always empty and dropping it loses nothing.
        return pieces
    }
}
