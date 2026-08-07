// Sources/TranslationCore/Chunker.swift
import Foundation

public struct Chunk: Sendable, Equatable {
    public let index: Int
    public let text: String
    /// The exact bytes between the previous chunk's content and this chunk's content,
    /// as a substring of the source document — never synthesised. Assembly restores it
    /// verbatim; the model never sees it. For the first chunk this is the document's
    /// leading whitespace.
    ///
    /// **Always whitespace-only**, and consumers depend on it. `Block.range` and
    /// `splitBySentences` move edge whitespace out of every chunk and nothing else ever
    /// lands here, so `TranslationViewModel`'s streaming consumer is entitled to tell a
    /// separator from model content by whitespace alone: it holds whitespace-only
    /// pieces in `pending` instead of treating them as the first output of a new run.
    /// A separator carrying a non-whitespace character would clear the previous
    /// translation off screen for a run that then fails — exactly what spec 8 forbids.
    /// `Chunker.plan` asserts it at every append.
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
    ///
    /// Whitespace-only for the same reason and with the same consequence as
    /// `Chunk.separatorBefore` — see there.
    public let trailingSeparator: String

    /// Reassembly, in one place: the formula `ChunkPlan` promises, applied to the
    /// translations of `chunks`.
    ///
    /// It lived in three — this type's doc comment, `Translator`'s zip-and-join, and
    /// `ChunkerTests`' helper — so the tests pinning byte-for-byte losslessness pinned
    /// a *restatement* of the shipped path and would have stayed green while it drifted.
    ///
    /// One deliberate divergence from a literal reading of the invariant: an empty plan
    /// assembles to `""`, not to `trailingSeparator`, even though a whitespace-only
    /// input puts all of its bytes there. `Translator` emits nothing at all for input
    /// with no translatable content, and the assembled result is a *translation* — the
    /// bytes are still on the plan for a caller that wants them.
    public func assembled(from texts: [String]) -> String {
        precondition(texts.count == chunks.count,
                     "ChunkPlan.assembled: one translation per chunk is required")
        guard !chunks.isEmpty else { return "" }
        return zip(chunks, texts).map { $0.separatorBefore + $1 }.joined() + trailingSeparator
    }
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
        // one blank line — `LineScanner.isExactlyOneBlankLine`, i.e. two bare line
        // terminators in whatever convention the document is written in — and the join
        // uses the separator's own bytes, so the joined text stays byte-identical to
        // the source span it came from. Any other separator (three blank lines, a lone
        // "\n" before a fence, a blank line carrying spaces) forces a chunk boundary
        // and is restored verbatim at assembly. The cost is a rare extra chunk on
        // unusually-formatted documents; the gain is that the markup diff can never cry
        // wolf over spacing the chunker itself changed.
        //
        // Accepting every convention is not a relaxation of that guarantee. The model
        // may well normalise an interior "\r\n" to "\n" in its reply, but
        // `MarkupSkeleton` scans lines through the same `LineScanner`, which reads
        // either as one line break — so the diff cannot cry wolf over the difference.
        // Enumerating spellings instead cost whole conventions every merge: gating on
        // "\n\n" alone cost a CRLF document 30 chunks (31 model calls, with the
        // term-list call) on 30 short paragraphs at a 900-character budget, against the
        // 2 chunks — 3 calls — an LF copy of the same document produced; adding
        // "\r\n\r\n" to the list left CR-only and mixed-EOL documents in the same hole
        // (measured: 2 chunks against the LF twin's 1). Structural, so there is no list
        // to fall behind.
        var chunks: [Chunk] = []
        var current = ""
        var currentSeparator = ""
        var currentHasFence = false
        func flush() {
            guard !current.isEmpty else { return }
            // The whitespace-only separator invariant, checked where it is produced —
            // see `Chunk.separatorBefore` for the consumer that rests on it. Debug-only
            // is enough: it is a statement about this function's own arithmetic, not
            // about anything a user can supply.
            assert(currentSeparator.allSatisfy(\.isWhitespace),
                   "Chunker: a separator must be whitespace only")
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
            // Every line terminator is a single Swift `Character` ("\r\n" included), so
            // one blank line is `count == 2` in every convention and the budget check
            // below reads the actual separator rather than a literal.
            if !current.isEmpty, LineScanner.isExactlyOneBlankLine(piece.separatorBefore),
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
        let trailing = String(text[previousEnd...])
        assert(trailing.allSatisfy(\.isWhitespace),
               "Chunker: the trailing separator must be whitespace only")
        return ChunkPlan(chunks: chunks, trailingSeparator: trailing)
    }

    // MARK: - Blocks

    static func blocks(in text: String) -> [Block] {
        // Line discipline — what breaks a line, what a blank line is, what opens a
        // fence — lives in `LineScanner` and is shared with `MarkupSkeleton`. The two
        // layers must read the same document or the markup diff reports structure the
        // chunker never saw; sharing one implementation is what makes that structural
        // rather than a parallel-maintenance promise.
        let lines = LineScanner.scanLines(text)
        var blocks: [Block] = []
        var index = 0

        func isBlank(_ line: LineScanner.Line) -> Bool { LineScanner.isBlank(line, in: text) }
        func isFenceMarker(_ line: LineScanner.Line) -> Bool {
            LineScanner.isFenceMarker(line, in: text)
        }
        /// Content range trimmed of whitespace at both edges — see `Block.range`.
        func blockRange(first: LineScanner.Line, last: LineScanner.Line) -> Range<String.Index> {
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
            // consider part of either sentence — a lone U+2028 between two non-blank
            // lines is the reproducible case: `LineScanner` breaks the line there but
            // the run stays one block, so the separator sits *inside* the body while
            // the tokenizer reads it as a sentence boundary. A piece beginning with
            // whitespace then had that whitespace eaten by `ResponseCleaner.clean`'s
            // edge trim of the reply. Still live after the terminator widening:
            // measured, the hostile corpus takes this branch 6 times.
            var contentStart = cut
            while contentStart < end, body[contentStart].isWhitespace {
                contentStart = body.index(after: contentStart)
            }
            guard contentStart < end else {
                // A segment of nothing but whitespace. It carries no content to
                // translate, so it becomes separator bytes rather than an empty
                // piece; emitting one tripped the packing precondition below.
                // The reproducer that found this — three U+2028s between two
                // sentences — no longer reaches here: `LineScanner` now breaks lines
                // on U+2028, so a run of them is blank lines and the two sentences
                // are separate blocks. Kept, and no longer measured as reachable (the
                // hostile corpus takes it 0 times), because the precondition below
                // depends on it and a whitespace-only segment is not a shape the
                // tokenizer promises never to produce.
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
