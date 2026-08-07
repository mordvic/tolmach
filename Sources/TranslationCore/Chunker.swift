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
        /// Fenced code is the only block form the engine protects. Indented text is
        /// prose: it is translated, and its indentation survives regardless — the
        /// first line's in `separatorBefore`, every continuation line's inside the
        /// block. Reading an indented run as code cost silent untranslation of
        /// tab-indented plain text and of Markdown loose-list continuations, because
        /// nothing in a selection carries format context.
        enum Kind { case prose, fencedCode }
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

        // Pieces → chunks. Merging is allowed only across a separator that is exactly
        // one blank line — in either line-ending convention, "\n\n" or "\r\n\r\n" —
        // and the join uses the separator's own bytes, so the joined text stays
        // byte-identical to the source span it came from. Any other separator (three
        // blank lines, a lone "\n" before a fence, a blank line carrying spaces)
        // forces a chunk boundary and is restored verbatim at assembly. The cost is a
        // rare extra chunk on unusually-formatted documents; the gain is that the
        // markup diff can never cry wolf over spacing the chunker itself changed.
        //
        // Accepting the CRLF spelling is not a relaxation of that guarantee. The model
        // may well normalise an interior "\r\n" to "\n" in its reply, but
        // `MarkupSkeleton` scans lines through `Chunker.scanLines`, which reads either
        // as one line break — so the diff cannot cry wolf over the difference. Gating
        // on the LF spelling alone cost a CRLF document *every* merge: measured on 30
        // short paragraphs at a 900-character budget, 30 chunks (31 model calls, with
        // the term-list call) against the 2 chunks — 3 calls — an LF copy of the very
        // same document produced. Both conventions now yield 2.
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
            // Structural, and stated rather than assumed because it once was not:
            // this read "unreachable today", and a sentence group of nothing but
            // U+2028 line separators reached it and trapped. Both producers now
            // guarantee it — `blockRange` trims both edges of a block, and
            // `splitBySentences` moves both edges of every segment into separators
            // and emits no piece at all for a segment that is entirely whitespace.
            // Kept as a precondition because an empty piece would take the `else`
            // branch and *overwrite* `currentSeparator` with its own — silently
            // dropping the separator of whatever came before it, which is the one way
            // the byte-for-byte contract could break without a test noticing.
            precondition(!piece.text.isEmpty, "Chunker: a piece must carry content")
            // "\r\n" is a single Swift `Character`, so both spellings of one blank
            // line have `count == 2` and the budget check below reads the actual
            // separator rather than a literal.
            let isOneBlankLine = piece.separatorBefore == "\n\n"
                || piece.separatorBefore == "\r\n\r\n"
            if !current.isEmpty, isOneBlankLine,
               current.count + piece.separatorBefore.count + piece.text.count <= maxCharacters {
                current += piece.separatorBefore + piece.text
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

        while index < lines.count {
            if isBlank(lines[index]) { index += 1; continue }

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
                continue
            }

            // Prose: a maximal run of non-blank lines that does not open a fence.
            // Indentation plays no part — an indented run is prose, and is translated.
            var last = index
            while last + 1 < lines.count, !isBlank(lines[last + 1]),
                  !isFenceMarker(lines[last + 1]) {
                last += 1
            }
            blocks.append(Block(kind: .prose,
                                range: blockRange(first: lines[index], last: lines[last])))
            index = last + 1
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
            // BOTH edges of the segment move into separators, for the reason
            // `Block.range` gives for whole blocks. The leading edge is not
            // symmetry: a cut lands at a sentence range's `lowerBound`, and
            // NLTokenizer puts that boundary *before* whitespace it does not
            // consider part of either sentence — U+2028 and its neighbours are the
            // reproducible case, since `scanLines` reads them as in-line whitespace
            // while the tokenizer reads them as sentence boundaries. A piece
            // beginning with whitespace then had that whitespace eaten by
            // `ResponseCleaner.clean`'s edge trim of the reply.
            var contentStart = cut
            while contentStart < end, body[contentStart].isWhitespace {
                contentStart = body.index(after: contentStart)
            }
            guard contentStart < end else {
                // A segment of nothing but whitespace — three U+2028s between two
                // sentences produce exactly that. It carries no content to
                // translate, so it becomes separator bytes rather than an empty
                // piece; emitting one tripped the packing precondition.
                pendingSeparator += String(body[cut..<end])
                continue
            }
            var contentEnd = end
            while contentEnd > contentStart {
                let before = body.index(before: contentEnd)
                guard body[before].isWhitespace else { break }
                contentEnd = before
            }
            pieces.append(Piece(separatorBefore: pendingSeparator + String(body[cut..<contentStart]),
                                text: String(body[contentStart..<contentEnd]), kind: .prose))
            pendingSeparator = String(body[contentEnd..<end])
        }
        // `body` is already edge-trimmed (see `Block.range`), so its last character
        // is non-whitespace: the final segment always has content, its `contentEnd`
        // is its `end`, and the final pending separator is therefore always empty.
        // Dropping it loses nothing.
        return pieces
    }
}
