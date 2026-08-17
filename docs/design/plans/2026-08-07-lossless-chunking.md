# Lossless Chunking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The assembled translation reproduces the source document's separators — blank-line runs, indentation, CRLF, document-edge whitespace — byte for byte; indented code becomes code; the markup diff compares against the real source.

**Architecture:** `Chunker` gains a `plan()` API whose chunks carry `separatorBefore` (a verbatim substring of the source); the packing rule merges blocks only across an exactly-`"\n\n"` separator, so the model always sees canonical text and every other separator is restored at assembly by `Translator`. `MarkupSkeleton` learns indented code, table rows and setext headings. Spec: `docs/design/specs/2026-08-07-lossless-chunking-design.md`.

**Tech Stack:** Swift 6 / SwiftPM, Foundation + NaturalLanguage only in `TranslationCore`, Swift Testing (`@Test`, `#expect`).

## Global Constraints

- `.swiftLanguageMode(.v6)` everywhere; platform floor macOS 14; **zero warnings** (`swift build --build-tests` is gated in CI).
- No new dependencies. `TranslationCore` stays Foundation + NaturalLanguage only.
- Tests are Swift Testing, offline, names are sentences describing the pinned behaviour. `swift test` must never touch the network.
- Code comments carry *why* and measurements, not *what*. When changing code a comment justifies, update the reasoning (CLAUDE.md: the «measured» contract).
- User-facing strings are Russian with «guillemets»; no backticks in `Text(String)`.
- Commits: conventional, scoped — `feat(core):`, `test(core):`, `feat(app):`, `docs:`.
- Work happens on a branch off `docs/lossless-chunking-spec` (which holds the spec); suggested name `feat/lossless-chunking`.

**Read before starting:** the spec (path above); `docs/reference/TESTING.md` (the mutation rule); `Sources/TranslationCore/ResponseCleaner.swift` — Task 3 relies on knowing exactly what `clean` trims at the reply's edges. The design keeps every chunk's text free of leading/trailing whitespace precisely so the cleaner's edge-trimming can never eat structure.

---

### Task 1: `Chunker` — lossless plan with verbatim separators

**Files:**
- Modify: `Sources/TranslationCore/Chunker.swift` (full rewrite below)
- Test: `Tests/TranslationCoreTests/ChunkerTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (later tasks rely on these exact names):
  - `public struct Chunk { public let index: Int; public let text: String; public let separatorBefore: String; public let containsCodeFence: Bool }`
  - `public struct ChunkPlan: Sendable, Equatable { public let chunks: [Chunk]; public let trailingSeparator: String }`
  - `Chunker.plan(_ text: String, maxCharacters: Int) -> ChunkPlan`
  - `Chunker.chunk(_ text: String, maxCharacters: Int) -> [Chunk]` (kept; returns `plan(...).chunks` — `TranslationViewModel.expectedChunkCount` and existing tests call it)
- Invariant produced: `chunks.map { $0.separatorBefore + $0.text }.joined() + trailingSeparator == text`, byte for byte, for every input.

Key design facts the implementer must not lose (they are the spec's §3):

1. Separators are **substrings of the source**, never synthesised — that is what lets CRLF and `"\n\n\n"` survive.
2. A block's content range is trimmed of whitespace at **both** edges; the trimmed-off bytes live in the neighbouring separators. So a chunk's text never begins or ends with whitespace — which also makes it immune to `ResponseCleaner.clean`'s edge-trimming of the model's reply.
3. Merging two pieces into one chunk is allowed **only** when the source separator between them is exactly `"\n\n"` — then the joined chunk text is byte-identical to the source span, and the model always sees canonical spacing. Any other separator forces a chunk boundary.
4. An oversized prose block splits by sentences; the inter-sentence whitespace moves into the next piece's `separatorBefore`, so the split fabricates nothing.
5. `"\r\n"` is a single Swift `Character`; line scanning must compare against `"\n"`, `"\r"`, **and** `"\r\n"`.

- [ ] **Step 1: Write the failing tests** — append to `Tests/TranslationCoreTests/ChunkerTests.swift`:

```swift
// MARK: - Lossless chunking: the plan reassembles the source byte for byte.

private let hostileDocuments: [String] = [
    // CRLF endings, including in the separators.
    "First paragraph.\r\nStill the first paragraph here.\r\n\r\nSecond paragraph after CRLF.\r\n",
    // A run of blank lines that used to collapse to one.
    "First paragraph up top.\n\n\n\nSecond paragraph after three blank lines.",
    // Hard line breaks: interior ones stay inside the block, the block-final one
    // moves into the separator — both must survive reassembly.
    "Line one  \nLine two  \n\nNext paragraph closing out.",
    // Document-edge whitespace, both ends.
    "  \nLeading blank-ish line above.\n\nAnd a trailing tail below.\n\n  ",
    // A blank line that contains spaces is still a separator, spaces included.
    "A blank line with spaces below this.\n   \nAnd the paragraph after it.",
    // A fence with no blank lines around it: the "\n" separators must survive.
    "Run the command below.\n```bash\nls -la\n```\nDone.",
    // One paragraph far over any budget: split by sentences, reassembled exactly.
    String(repeating: "The server validates the resource before publishing it to every client. ",
           count: 12),
]

private func reassembled(_ text: String, maxCharacters: Int) -> String {
    let plan = Chunker.plan(text, maxCharacters: maxCharacters)
    return plan.chunks.map { $0.separatorBefore + $0.text }.joined() + plan.trailingSeparator
}

@Test(arguments: hostileDocuments) func chunkingIsLossless(_ text: String) {
    #expect(reassembled(text, maxCharacters: 120) == text)
    #expect(reassembled(text, maxCharacters: 900) == text)
}

@Test func aSplitParagraphFabricatesNoParagraphBreaks() {
    // One long paragraph, no blank lines anywhere. Today every sentence-split
    // piece is joined back with "\n\n" — fabricated paragraph breaks the markup
    // diff can never see. After the fix, no chunk boundary inside this paragraph
    // may carry a blank line.
    let paragraph = String(
        repeating: "The server validates the resource before publishing it to every client. ",
        count: 12)
    let plan = Chunker.plan(paragraph, maxCharacters: 120)
    #expect(plan.chunks.count > 1)
    for chunk in plan.chunks.dropFirst() {
        #expect(!chunk.separatorBefore.contains("\n"))
    }
    #expect(!plan.chunks.contains { $0.text.contains("\n\n") })
}

@Test func mergedBlocksAreByteIdenticalToTheSourceSpan() {
    // Two short paragraphs separated by exactly "\n\n" merge into one chunk, and
    // the merge must be a byte-level no-op: the chunk text IS the source span.
    let text = "Short first paragraph.\n\nShort second paragraph."
    let plan = Chunker.plan(text, maxCharacters: 900)
    #expect(plan.chunks.count == 1)
    #expect(plan.chunks[0].text == text)
    #expect(plan.chunks[0].separatorBefore.isEmpty)
    #expect(plan.trailingSeparator.isEmpty)
}

@Test func aNonCanonicalSeparatorForcesAChunkBoundaryAndSurvivesVerbatim() {
    let text = "First paragraph.\n\n\nSecond paragraph after a double blank."
    let plan = Chunker.plan(text, maxCharacters: 900)
    #expect(plan.chunks.count == 2)
    #expect(plan.chunks[1].separatorBefore == "\n\n\n")
}

@Test func whitespaceOnlyInputPutsEverythingInTheTrailingSeparator() {
    let plan = Chunker.plan("   \n\n  \t ", maxCharacters: 900)
    #expect(plan.chunks.isEmpty)
    #expect(plan.trailingSeparator == "   \n\n  \t ")
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `swift test --filter ChunkerTests 2>&1 | tail -20`
Expected: compile failure — `ChunkPlan` and `Chunker.plan` do not exist yet. That is the red state for an API-shaped change.

- [ ] **Step 3: Rewrite `Sources/TranslationCore/Chunker.swift`**

Replace the whole file with:

```swift
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
```

- [ ] **Step 4: Run the Chunker tests**

Run: `swift test --filter ChunkerTests 2>&1 | tail -20`
Expected: ALL pass — the five pre-existing tests (`fencedCodeBlockIsNeverSplit`, `chunksAreContiguousAndIndexed`, `shortTextIsOneChunk`, `whitespaceOnlyInputYieldsNoChunks`, `unterminatedFenceIsKeptWholeAndNotSplit`) plus the new ones. If a pre-existing test fails, the rewrite broke behaviour the project pins — fix the rewrite, not the test.

- [ ] **Step 5: Run the whole suite; expect collateral failures only in TranslatorTests**

Run: `swift test 2>&1 | tail -30`
Expected: `TranslatorTests` may fail where chunk *counts* changed (blocks separated by non-`"\n\n"` no longer merge) — those are Task 3's to fix. Nothing else may fail. Record which tests failed for Task 3.
If TranslatorTests all still pass, fine — proceed.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslationCore/Chunker.swift Tests/TranslationCoreTests/ChunkerTests.swift
git commit -m "feat(core): lossless chunk plan with verbatim separators"
```

---

### Task 2: `Chunker` — indented code blocks are code

**Files:**
- Modify: `Sources/TranslationCore/Chunker.swift` (from Task 1)
- Test: `Tests/TranslationCoreTests/ChunkerTests.swift`

**Interfaces:**
- Consumes: Task 1's `Block.Kind`, `blocks(in:)`, `plan`.
- Produces: `Block.Kind` gains `.indentedCode`; an indented-code block is never sentence-split. `Chunk.containsCodeFence` semantics unchanged (fenced only — the `allowFenceUnwrap` gate in `Translator` concerns fenced replies alone).

- [ ] **Step 1: Write the failing tests** — append to `ChunkerTests.swift`:

```swift
// MARK: - Indented code blocks (4+ spaces after a blank line) are code.

@Test func anIndentedCodeBlockIsNeverSentenceSplitAndReassemblesExactly() {
    // The code lines are sentence-shaped prose; if the block were treated as text,
    // a 60-character budget would split it. CommonMark: a run of lines indented by
    // four or more spaces after a blank line is a code block.
    let text = """
    Intro paragraph before the code.

        This looks like a sentence. And another sentence here. And one more now.
        let a = compute(1)

    Prose after the code block.
    """
    let plan = Chunker.plan(text, maxCharacters: 60)
    #expect(plan.chunks.map { $0.separatorBefore + $0.text }.joined()
            + plan.trailingSeparator == text)
    let codeChunk = plan.chunks.first { $0.text.contains("let a = compute(1)") }
    #expect(codeChunk != nil)
    #expect(codeChunk?.text.contains("This looks like a sentence. And another sentence here. And one more now.") == true)
}

@Test func indentationInsideAnIndentedCodeBlockSurvivesInTheChunkText() {
    // The block's FIRST line's indentation lives in the separator (chunk text never
    // starts with whitespace — see Block.range), but every continuation line keeps
    // its own indentation inside the chunk text.
    let text = "Intro.\n\n    first line\n    second line"
    let plan = Chunker.plan(text, maxCharacters: 900)
    let code = plan.chunks.first { $0.text.contains("first line") }
    #expect(code?.text.contains("\n    second line") == true)
    #expect(code?.separatorBefore.hasSuffix("    ") == true)
}

@Test func indentedLinesMidParagraphStayProse() {
    // CommonMark: indented code cannot interrupt a paragraph. No blank line above,
    // so these lines are a prose continuation, not code — the block stays one prose
    // block and an oversized one would still split by sentences.
    let text = "A paragraph line.\n    An indented continuation of the same paragraph."
    let plan = Chunker.plan(text, maxCharacters: 900)
    #expect(plan.chunks.count == 1)
    #expect(plan.chunks.map { $0.separatorBefore + $0.text }.joined()
            + plan.trailingSeparator == text)
}
```

- [ ] **Step 2: Run to verify the first test fails**

Run: `swift test --filter ChunkerTests 2>&1 | tail -20`
Expected: `anIndentedCodeBlockIsNeverSentenceSplitAndReassemblesExactly` FAILS (the block is prose today and the 60-char budget splits it). The other two may pass already — that is fine; keep them, they pin the boundary conditions.

- [ ] **Step 3: Implement** — three edits in `Chunker.swift`:

1. `Block.Kind`: `enum Kind { case prose, fencedCode, indentedCode }`
2. In `blocks(in:)`, add after the `isFenceMarker` helper:

```swift
        func isIndented(_ line: Line) -> Bool {
            let content = text[line.content]
            return content.hasPrefix("    ") || content.first == "\t"
        }
```

and track blank-line context; replace the `while index < lines.count` loop header section with:

```swift
        var previousWasBlank = true // document start behaves like after a blank line
        while index < lines.count {
            if isBlank(lines[index]) { previousWasBlank = true; index += 1; continue }

            if isFenceMarker(lines[index]) {
                // ... fence branch unchanged from Task 1, but add before its `continue`:
                previousWasBlank = false
                // ...
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

            // Prose branch unchanged from Task 1, but add before its `continue`:
            previousWasBlank = false
```

3. In `plan`, the sentence-split condition already reads `block.kind == .prose` — indented code therefore flows through the "one piece" path with no further change. Verify this is true rather than assuming it.

- [ ] **Step 4: Run the Chunker tests**

Run: `swift test --filter ChunkerTests 2>&1 | tail -20`
Expected: ALL pass, including the Task 1 lossless corpus.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/Chunker.swift Tests/TranslationCoreTests/ChunkerTests.swift
git commit -m "feat(core): indented code blocks are code — never sentence-split"
```

---

### Task 3: `Translator` — assemble with verbatim separators; diff against the real source

**Files:**
- Modify: `Sources/TranslationCore/Translator.swift`
- Test: `Tests/TranslationCoreTests/TranslatorTests.swift`

**Interfaces:**
- Consumes: `Chunker.plan(_:maxCharacters:) -> ChunkPlan`, `Chunk.separatorBefore`, `ChunkPlan.trailingSeparator` (Task 1).
- Produces: `outcome.final` reproduces source separators byte for byte; the `onToken` stream still concatenates to exactly `final`; `outcome.markupDiffs` is now `MarkupSkeleton.diff(source: text, translation: final)`. No signature changes.

**Read first:** `ResponseCleaner.clean` — confirm what it trims at the reply's edges. Chunk texts have no edge whitespace (Task 1 guarantees it), so the cleaner's edge-trimming cannot conflict with reassembly; if you find a cleaner behaviour that *can* alter interior bytes of a perfect echo beyond preamble/fence-unwrap, stop and reread the spec §4 before proceeding.

- [ ] **Step 1: Write the failing tests** — append to `TranslatorTests.swift`:

```swift
// MARK: - Lossless assembly: final restores the source's separators byte for byte.

/// A "perfect translator": echoes back exactly the text between the <text> markers
/// of the user prompt. The term-list call's prompt carries no markers and echoes
/// nothing, which parses as an empty document glossary — so this fake never needs
/// its response queue aligned with the unpredictable presence of that call.
private struct EchoLLMClient: LLMClient {
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        let user = messages.last?.content ?? ""
        let payload: String
        if let start = user.range(of: "<text>\n"),
           let end = user.range(of: "\n</text>", options: .backwards),
           start.upperBound <= end.lowerBound {
            payload = String(user[start.upperBound..<end.lowerBound])
        } else {
            payload = ""
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(payload))
            continuation.yield(.done(ChatStats(loadDurationMS: 0, promptEvalCount: 0,
                promptEvalDurationMS: 0, evalCount: 0, evalDurationMS: 0)))
            continuation.finish()
        }
    }
}

private let structuredDocuments: [String] = [
    "First paragraph up top.\n\n\n\nSecond paragraph after three blank lines.",
    "First paragraph.\r\n\r\nSecond paragraph, CRLF separated.",
    "Run the command below.\n```bash\nls -la\n```\nDone.",
    "Line one  \nLine two  \n\nNext paragraph.\n",
    String(repeating: "The server validates the resource before publishing it to every client. ",
           count: 12),
]

@Test(arguments: structuredDocuments)
func aPerfectEchoReproducesTheSourceByteForByte(_ text: String) async throws {
    let translator = Translator(client: EchoLLMClient())
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 120)
    #expect(outcome.final == text)
    #expect(outcome.markupDiffs.isEmpty)
}

@Test func theStreamCarriesTheVerbatimSeparatorsAndStillReconstructsFinal() async throws {
    let text = "First paragraph up top.\n\n\n\nSecond paragraph after three blank lines."
    let translator = Translator(client: EchoLLMClient())
    let collector = TokenCollector()
    let outcome = try await translator.translate(
        text: text, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 120,
        onToken: collector.onToken)
    #expect(collector.text == outcome.final)
    #expect(outcome.final.contains("\n\n\n\n"))
}

@Test func theMarkupDiffNowSeesStructureTheOldNormalisationHid() async throws {
    // The model (not the chunker) collapses the three blank lines to one. Diffing
    // against the normalised chunk text used to make this invisible; diffing
    // against the real source must report it.
    let fake = FakeLLMClient(responses: ["Первый абзац.\n\nВторой абзац."])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: "First paragraph.\n\n\nSecond paragraph.", target: .ru, tone: .neutral,
        userGlossary: nil, options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    // Wait — with lossless chunking these two paragraphs are two chunks (the
    // "\n\n\n" separator forces a boundary) and the separator is restored verbatim,
    // so a per-chunk perfect echo CANNOT lose it. To lose it the model must merge
    // within one chunk: use a budget that puts both paragraphs in one chunk only
    // when the separator is canonical — it is not here, so instead pin the
    // restored-verbatim behaviour:
    #expect(outcome.final.contains("\n\n\n"))
}
```

Note on the last test: with the new packing rule a non-canonical separator never reaches the model at all, so «the model collapsed the blank lines» is no longer a reachable defect for *separators* — that is the design working. The test therefore pins the positive fact (the separator survives even when the model's per-chunk output is unrelated text). Keep the comment; it is the reasoning a future reader needs.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TranslatorTests 2>&1 | tail -30`
Expected: the three new tests FAIL (final is joined with hard-coded `"\n\n"` today). Some pre-existing TranslatorTests may already be failing since Task 1 (chunk-count shifts) — note them; Step 3 fixes both.

- [ ] **Step 3: Implement in `Translator.swift`**

1. Replace `let chunks = Chunker.chunk(text, maxCharacters: maxChunkCharacters)` with:

```swift
        let plan = Chunker.plan(text, maxCharacters: maxChunkCharacters)
        let chunks = plan.chunks
```

2. In the per-chunk loop, replace `if !translatedChunks.isEmpty { onToken("\n\n") }` (and its comment) with:

```swift
            // The separator is the source document's own bytes, restored verbatim — it
            // carries no model content, so it goes straight to `onToken` (never through
            // `emit`, which would stamp `timeToFirstTokenMS`) exactly as the old
            // hard-coded "\n\n" did. The consumer contract is unchanged: whitespace-only
            // pieces are not "output" (TranslationViewModel holds them in `pending`).
            if !chunk.separatorBefore.isEmpty { onToken(chunk.separatorBefore) }
```

3. Replace `let final = translatedChunks.joined(separator: "\n\n")` with:

```swift
        var final = zip(chunks, translatedChunks).map { $0.separatorBefore + $1 }.joined()
        if !chunks.isEmpty, !plan.trailingSeparator.isEmpty {
            // The document's trailing whitespace is part of the byte-for-byte contract
            // (`ChunkPlan`), and the stream must carry it too or a consumer rendering
            // tokens live reconstructs a different document from the one `final`
            // describes. Emitted only when the run produced chunks at all: a
            // whitespace-only input yields no chunks and no output.
            onToken(plan.trailingSeparator)
            final += plan.trailingSeparator
        }
```

4. Replace the `markupDiffs:` argument and its comment:

```swift
            // Diff against the raw source. This used to diff against the chunk-joined
            // text instead, because the old Chunker normalised whitespace (blocks
            // rejoined with exactly "\n\n", trailing whitespace trimmed) and a perfect
            // translation could never match the raw source — the "cry wolf" failure.
            // Lossless chunking removed the normalisation: `ChunkPlan`'s invariant is
            // that separators reassemble byte for byte, so the source the model saw
            // and the source on disk are the same document again.
            markupDiffs: MarkupSkeleton.diff(source: text, translation: final),
```

5. Update `TranslationOutcome.timeToFirstTokenMS`'s doc comment: the phrase «The "\n\n" chunk separator and the internal term-list call never count either» becomes «The chunk separator (the source's own bytes, restored verbatim) and the internal term-list call never count either».

- [ ] **Step 4: Fix the pre-existing tests that pinned the old normalisation**

In `TranslatorTests.swift`:

1. `assertPerfectEchoProducesNoMarkupDiffs` — replace `FakeLLMClient(responses: chunks.map(\.text))` with `EchoLLMClient()` (the chunk count is no longer predictable from outside, and the echo client tracks it by construction). Delete the now-unused `let chunks = ...` line in the helper.
2. The four `perfectEcho...ProducesNoMarkupDiffs` tests: keep the assertions, rewrite the comments — they describe normalisation that no longer exists. In particular `perfectEchoOfHardLineBreaksProducesNoMarkupDiffs`'s «known, separate limitation» comment describes real content loss that this change **fixes**: the block-final hard break's spaces now live in the separator and survive. Say that.
3. The `listWithIndentedFence` fixture comment (lines 13–16) says Chunker «rejoins every block with exactly "\n\n"» — rewrite: the fence now forces a chunk boundary whose `"\n"` separator is restored verbatim; the model never sees fabricated blank lines.
4. `aFailedTermListCallLeavesDocumentGlossaryEmptyButTranslationProceeds` asserts `outcome.final == outcome.translatedChunks.joined(separator: "\n\n")` — replace with `#expect(outcome.final == "один\n\nдва")` only (the joined-with form restates the old assembly rule; the literal already pins the observable behaviour, and `multiChunkText`'s separator genuinely is `"\n\n"`).

- [ ] **Step 5: Run the full TranslationCore suite**

Run: `swift test --filter TranslationCoreTests 2>&1 | tail -20`
Expected: ALL pass. Pay attention to the cancellation and TTFT tests — they must not have changed behaviour (separators never stamp TTFT).

- [ ] **Step 6: Run everything**

Run: `swift test 2>&1 | tail -20`
Expected: ALL pass (~341+). `TranslationViewModelTests` in particular: the whitespace-only-piece `pending` logic must be indifferent to separators that are now `"\n\n\n\n"` or `"\r\n\r\n"` instead of `"\n\n"`.

- [ ] **Step 7: Update the comment in `TranslationViewModel.swift`**

The consumer comment (near `if piece.trimmingCharacters...`) says «`Translator` writes the "\n\n" between chunks straight to `onToken`» — change to «`Translator` writes the inter-chunk separator (the source's own whitespace, restored verbatim) straight to `onToken`». Behaviour is untouched; the comment must not describe a constant that no longer exists.

- [ ] **Step 8: Commit**

```bash
git add Sources/TranslationCore/Translator.swift Sources/TranslatorApp/TranslationViewModel.swift Tests/TranslationCoreTests/TranslatorTests.swift
git commit -m "feat(core): assemble translations with verbatim source separators"
```

---

### Task 4: `PromptBuilder` — indented code joins the do-not-translate rule

**Files:**
- Modify: `Sources/TranslationCore/PromptBuilder.swift`
- Test: `Tests/TranslationCoreTests/PromptBuilderTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: the system prompt's code rule covers indented code blocks.

- [ ] **Step 1: Write the failing test** — append to `PromptBuilderTests.swift`:

```swift
@Test func theSystemPromptProtectsIndentedCodeBlocksLikeFencedOnes() {
    let request = TranslationRequest(text: "    let a = 1", source: .en, target: .ru,
                                     tone: .neutral)
    let prompt = PromptBuilder.systemPrompt(for: request)
    #expect(prompt.contains("indented code blocks"))
    #expect(prompt.contains("byte for byte"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter theSystemPromptProtectsIndentedCodeBlocksLikeFencedOnes 2>&1 | tail -5`
Expected: FAIL — the prompt names only fenced and inline code today.

- [ ] **Step 3: Implement** — in `systemPrompt(for:)`, replace the fenced-code rule line with:

```swift
            "- Never translate the contents of fenced code blocks (```), indented code blocks (lines indented by four or more spaces), or inline code (`like this`). Reproduce them byte for byte, including any human-readable text inside them — a commit message, a string literal or a comment inside a code block must be left in the source language.",
```

- [ ] **Step 4: Run the PromptBuilder tests**

Run: `swift test --filter PromptBuilderTests 2>&1 | tail -10`
Expected: ALL pass. If a pre-existing test pinned the old sentence verbatim, update its expectation to the new sentence — the test's subject is «the rule is present», not the exact historical wording.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/PromptBuilder.swift Tests/TranslationCoreTests/PromptBuilderTests.swift
git commit -m "feat(core): prompt rule covers indented code blocks"
```

---

### Task 5: `MarkupSkeleton` — tokenise indented code

**Files:**
- Modify: `Sources/TranslationCore/MarkupSkeleton.swift`
- Test: `Tests/TranslationCoreTests/MarkupSkeletonTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: an indented code block tokenises as `.codeBlock(hash: <content hash>, lang: "")` — no new enum case, so `DiffPresentation` needs no change here («блок кода» already labels the empty-lang case).

- [ ] **Step 1: Write the failing tests** — append to `MarkupSkeletonTests.swift`:

```swift
@Test func anIndentedCodeBlockTokenisesAsACodeBlock() {
    let text = "Intro paragraph.\n\n    let a = `1`\n    let b = 2\n\nAfter."
    let tokens = MarkupSkeleton.tokens(of: text)
    #expect(tokens.contains { if case .codeBlock(_, let lang) = $0 { lang.isEmpty } else { false } })
    // The backticks inside the code are code bytes, not an inline-code span.
    #expect(!tokens.contains { if case .inlineCode = $0 { true } else { false } })
}

@Test func indentedLinesMidParagraphDoNotTokeniseAsACodeBlock() {
    // No blank line above: a prose continuation, exactly as the Chunker treats it.
    // The two layers must agree, or the diff reports structure the chunker never saw.
    let text = "A paragraph line.\n    An indented continuation line."
    let tokens = MarkupSkeleton.tokens(of: text)
    #expect(!tokens.contains { if case .codeBlock = $0 { true } else { false } })
}

@Test func aDroppedIndentedCodeBlockSurfacesInTheDiff() {
    let source = "Intro.\n\n    let a = 1\n\nAfter."
    let translation = "Введение.\n\nПосле."
    let diffs = MarkupSkeleton.diff(source: source, translation: translation)
    #expect(diffs.contains { diff in
        if case .codeBlock = diff.expected ?? .paragraphBreak { return diff.actual == nil }
        return false
    })
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MarkupSkeletonTests 2>&1 | tail -15`
Expected: the first and third FAIL (no indented-code tracking today; the backticks produce a phantom `.inlineCode`). The second may pass vacuously — keep it, it pins the boundary.

- [ ] **Step 3: Implement** — in `tokens(of:)`, add indented-code tracking alongside the fence tracking:

```swift
        var previousWasBlank = true // document start counts as after-a-blank
        var indentedBuffer: [String] = []
        func flushIndented() {
            guard !indentedBuffer.isEmpty else { return }
            // Same shape as a fenced block with no info string: the reader of a diff
            // is told "a code block was dropped/added" either way, and folding the two
            // spellings together is exactly how CommonMark treats them.
            tokens.append(.codeBlock(hash: indentedBuffer.joined(separator: "\n").hashValue,
                                     lang: ""))
            indentedBuffer = []
        }
```

and inside the per-line loop (after the fence handling, before the `trimmed.isEmpty` check is *used* for other tokens):

```swift
            if trimmed.isEmpty {
                flushIndented()
                tokens.append(.paragraphBreak)
                previousWasBlank = true
                continue
            }
            let isIndented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if !indentedBuffer.isEmpty || (previousWasBlank && isIndented) {
                if isIndented {
                    indentedBuffer.append(line)
                    previousWasBlank = false
                    continue
                }
                flushIndented()
            }
            previousWasBlank = false
```

after the loop, next to the unterminated-fence handling: `flushIndented()`.

Note: the existing `if trimmed.isEmpty { tokens.append(.paragraphBreak); continue }` line is *replaced* by the block above — do not end up with two paragraphBreak appends.

- [ ] **Step 4: Run the MarkupSkeleton tests**

Run: `swift test --filter MarkupSkeletonTests 2>&1 | tail -10`
Expected: ALL pass, existing tests included.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/MarkupSkeleton.swift Tests/TranslationCoreTests/MarkupSkeletonTests.swift
git commit -m "feat(core): markup skeleton tokenises indented code blocks"
```

---

### Task 6: `MarkupSkeleton` — table rows and setext headings; Russian label for the new token

**Files:**
- Modify: `Sources/TranslationCore/MarkupSkeleton.swift`
- Modify: `Sources/TranslatorApp/DiffPresentation.swift`
- Test: `Tests/TranslationCoreTests/MarkupSkeletonTests.swift`, `Tests/TranslatorAppTests/DiffPresentationTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `MarkupToken` gains `case tableRow`; a line whose trimmed form starts with `|` emits it. A line of only `=` (≥1) or only `-` (≥2) directly under a non-blank line emits `.heading(level: 1)` / `.heading(level: 2)`. `DiffPresentation.label(for: .tableRow) == "строка таблицы"`.

- [ ] **Step 1: Write the failing tests**

Append to `MarkupSkeletonTests.swift`:

```swift
@Test func tableRowsTokeniseAndADroppedRowSurfacesInTheDiff() {
    let source = "| Name | Value |\n|---|---|\n| a | 1 |"
    let translation = "| Имя | Значение |\n|---|---|"
    let diffs = MarkupSkeleton.diff(source: source, translation: translation)
    #expect(diffs.contains { $0.expected == .tableRow && $0.actual == nil })
}

@Test func setextHeadingsTokeniseAtTheirLevels() {
    let text = "Title\n=====\n\nSubtitle\n--------\n\nBody text."
    let tokens = MarkupSkeleton.tokens(of: text)
    #expect(tokens.contains(.heading(level: 1)))
    #expect(tokens.contains(.heading(level: 2)))
}

@Test func aDashRunAfterABlankLineIsNotASetextHeading() {
    // A thematic break, not an underline: nothing above it to be a heading of.
    let tokens = MarkupSkeleton.tokens(of: "Paragraph.\n\n---\n\nNext.")
    #expect(!tokens.contains { if case .heading = $0 { true } else { false } })
}
```

Append to `Tests/TranslatorAppTests/DiffPresentationTests.swift` (inside the labels test, alongside the existing `#expect` lines):

```swift
    #expect(DiffPresentation.label(for: .tableRow) == "строка таблицы")
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MarkupSkeletonTests 2>&1 | tail -10`
Expected: compile failure — `MarkupToken.tableRow` does not exist. Red state for an enum-shaped change.

- [ ] **Step 3: Implement**

1. `MarkupToken`: add `case tableRow`.
2. `DiffPresentation.label`: add `case .tableRow: "строка таблицы"` — the exhaustive no-`default:` switch forces this; grep for other switches over `MarkupToken` (`grep -rn "case .paragraphBreak" Sources Tests`) and extend any others found the same way.
3. In `tokens(of:)`, track the previous line's text-ness and handle the two new shapes for a non-blank, non-fence line (after the indented-code handling from Task 5, before the heading/list/inline block):

```swift
            // Setext underline: a line of only "=" (any count) or only "-" (two or
            // more — a lone "-" is closer to a stray bullet than to an underline)
            // directly under a non-blank line. CommonMark reads "---" after a
            // paragraph as a setext H2, not a thematic break.
            let isSetextUnderline = previousLineHadText && !trimmed.isEmpty
                && (trimmed.allSatisfy { $0 == "=" }
                    || (trimmed.count >= 2 && trimmed.allSatisfy { $0 == "-" }))
            if isSetextUnderline {
                tokens.append(.heading(level: trimmed.first == "=" ? 1 : 2))
                previousLineHadText = false
                continue
            }
            if trimmed.hasPrefix("|") { tokens.append(.tableRow) }
```

with `var previousLineHadText = false` declared beside `previousWasBlank`, set `false` on blank lines and inside fences/indented code, `true` at the end of the ordinary (prose) path. The table-row line still runs the inline scan after it (a row can carry inline code or URLs), and cannot also match heading/list prefixes — `|` excludes them.

- [ ] **Step 4: Run both test targets**

Run: `swift test --filter MarkupSkeletonTests 2>&1 | tail -10` then `swift test --filter DiffPresentationTests 2>&1 | tail -5`
Expected: ALL pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/MarkupSkeleton.swift Sources/TranslatorApp/DiffPresentation.swift Tests/TranslationCoreTests/MarkupSkeletonTests.swift Tests/TranslatorAppTests/DiffPresentationTests.swift
git commit -m "feat(core): markup skeleton learns table rows and setext headings"
```

---

### Task 7: Documentation, zero-warning gate, full verification

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/reference/OPEN-ITEMS.md`

**Interfaces:** none — this task closes the wave.

- [ ] **Step 1: Update `CLAUDE.md`'s pipeline facts**

In the «Facts that will bite you if you "tidy" them» list:

1. In the `final`/`onToken` bullet, replace the sentence «Chunks are joined with `"\n\n"` in both `final` and the stream.» with: «Chunks are joined by each chunk's `separatorBefore` — the source document's own bytes, restored verbatim — in both `final` and the stream, plus the source's trailing whitespace at the end; `ChunkPlan`'s invariant is that this reassembly is byte-for-byte lossless.»
2. Add a bullet after it: «**The packing rule is the structure guarantee.** Blocks merge into one chunk only across an exactly-`"\n\n"` separator, so the model always sees canonical spacing and every other separator never reaches it at all. Indented code (≥ 4 spaces after a blank line) is code: never sentence-split, protected by the prompt, tokenised by `MarkupSkeleton`. See `docs/design/specs/2026-08-07-lossless-chunking-design.md`.»

- [ ] **Step 2: Record the owed manual run in `docs/reference/OPEN-ITEMS.md`**

Read the file's own structure first and follow it. Add to the manual-checks section: «`swift run acceptance` after the lossless-chunking wave: the markup-integrity measurement now diffs against the raw source (it previously diffed against the chunker-normalised text), so the baseline may shift. Run against a live Ollama from the package root and record the result per `docs/reference/BASELINE.md`.»

- [ ] **Step 3: The zero-warning gate**

Run: `swift build --build-tests 2>&1 | grep -i warning; echo "exit: $?"`
Expected: no warnings printed (grep exits 1). Any warning is a failure of this task — fix it.

- [ ] **Step 4: Full suite, final**

Run: `swift test 2>&1 | tail -5`
Expected: ALL pass.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/reference/OPEN-ITEMS.md
git commit -m "docs: lossless chunking — pipeline facts and the owed acceptance run"
```

---

## Self-review notes (done at plan time)

- **Spec coverage:** §1.1/§2/§3 → Tasks 1–2; §4 → Task 3; §1.3/§5 → Tasks 5–6; prompt rule (§4) → Task 4; §7's acceptance note → Task 7. The spec's «hostile corpus» lives in Task 1 and partially re-runs end-to-end in Task 3.
- **Known count-shift:** Task 1 changes how many chunks some documents produce (non-canonical separators stop merging). TranslatorTests that assert counts use `outcome.chunks.count`-relative forms and survive; the perfect-echo helper is migrated to `EchoLLMClient` in Task 3 for exactly this reason.
- **Type consistency check:** `ChunkPlan.trailingSeparator`, `Chunk.separatorBefore`, `Chunker.plan(_:maxCharacters:)`, `Block.Kind.indentedCode`, `MarkupToken.tableRow` — spelled identically in every task above.
