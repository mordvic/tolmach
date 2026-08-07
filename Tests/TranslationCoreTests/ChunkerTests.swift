// Tests/TranslationCoreTests/ChunkerTests.swift
import Testing
@testable import TranslationCore

private let doc = """
First paragraph that is fairly long and descriptive about the subject at hand.

Second paragraph, also with enough words to matter for the budgeting logic here.

```bash
profile-server publish --ig ./ig.json --strict --out ./dist

echo "a blank line lives inside this fenced block on purpose"
```

Final paragraph after the code, closing the document out with a few more words.
"""

@Test func fencedCodeBlockIsNeverSplit() {
    let chunks = Chunker.plan(doc, maxCharacters: 120).chunks
    let codeChunks = chunks.filter(\.containsCodeFence)
    #expect(codeChunks.count == 1)
    let code = codeChunks[0].text
    #expect(code.contains("profile-server publish"))
    #expect(code.contains("blank line lives inside"))
    // The fence stays balanced: an even number of ``` markers.
    #expect(code.components(separatedBy: "```").count % 2 == 1)
}

@Test func chunksAreContiguousAndIndexed() {
    let chunks = Chunker.plan(doc, maxCharacters: 120).chunks
    #expect(chunks.count > 1)
    for (offset, chunk) in chunks.enumerated() { #expect(chunk.index == offset) }
}

@Test func shortTextIsOneChunk() {
    let chunks = Chunker.plan("Just a sentence.", maxCharacters: 900).chunks
    #expect(chunks.count == 1)
    #expect(chunks[0].containsCodeFence == false)
}

@Test func whitespaceOnlyInputYieldsNoChunks() {
    #expect(Chunker.plan("   \n\n  \t ", maxCharacters: 900).chunks.isEmpty)
    #expect(Chunker.plan("", maxCharacters: 900).chunks.isEmpty)
}

@Test func unterminatedFenceIsKeptWholeAndNotSplit() {
    let doc = """
    Intro paragraph before the code that is long enough to matter here.

    ```swift
    let a = 1
    let b = 2

    let c = 3
    """
    let chunks = Chunker.plan(doc, maxCharacters: 60).chunks
    let fenceChunks = chunks.filter(\.containsCodeFence)
    #expect(fenceChunks.count == 1)
    #expect(fenceChunks[0].text.contains("let a = 1"))
    #expect(fenceChunks[0].text.contains("let c = 3"))
}

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
    // U+2028 LINE SEPARATOR: in-line whitespace to `Chunker.scanLines`, a sentence
    // boundary to NLTokenizer. A run of them between two sentences made the sentence
    // splitter emit a whitespace-only group, which tripped the packing precondition.
    "One sentence here. \u{2028}\u{2028}\u{2028} Two sentence here.",
    // The same class with one separator: a cut lands at the sentence range's own
    // lowerBound, so the piece used to BEGIN with the space after the U+2028 —
    // structure the chunk text must never carry (see `Block.range`).
    "Word one two. \u{2028} Word three four.",
]

/// Budgets small enough to force a cut at nearly every sentence: that is where the
/// edge-whitespace defects lived, and the loss they caused was invisible at 120.
private let hostileBudgets = [10, 20, 120, 900]

/// Reassembly through the shipped path, `ChunkPlan.assembled` — the same call
/// `Translator` makes — with each chunk standing in for its own translation. A
/// hand-rolled restatement of the formula here would pin a copy of it and stay green
/// while `Translator` drifted.
///
/// `assembled` returns "" for an empty plan, so the whitespace-only case is spelled out
/// rather than fed through it; that divergence is `ChunkPlan.assembled`'s doc comment.
private func reassembled(_ text: String, maxCharacters: Int) -> String {
    let plan = Chunker.plan(text, maxCharacters: maxCharacters)
    guard !plan.chunks.isEmpty else { return plan.trailingSeparator }
    return plan.assembled(from: plan.chunks.map(\.text))
}

@Test(arguments: hostileDocuments) func chunkingIsLossless(_ text: String) {
    for budget in hostileBudgets { #expect(reassembled(text, maxCharacters: budget) == text) }
}

@Test(arguments: hostileDocuments) func everySeparatorIsWhitespaceOnly(_ text: String) {
    // Stated on `Chunk.separatorBefore`, asserted in `plan`, and rested on by
    // `TranslationViewModel`: its streaming consumer tells a separator from model
    // content by whitespace alone, holding whitespace-only pieces in `pending` rather
    // than treating them as the first output of a new run. A separator carrying a
    // non-whitespace character would clear the previous translation off screen for a
    // run that then fails — the case spec 8 says must be survivable. Nothing checked it.
    // Bound to a `let` before the assertion because `allSatisfy` is `rethrows`, and the
    // `#expect` macro cannot expand a possibly-throwing call in a non-throwing test.
    for budget in hostileBudgets {
        let plan = Chunker.plan(text, maxCharacters: budget)
        for chunk in plan.chunks {
            let isWhitespaceOnly = chunk.separatorBefore.allSatisfy(\.isWhitespace)
            #expect(isWhitespaceOnly)
        }
        let trailingIsWhitespaceOnly = plan.trailingSeparator.allSatisfy(\.isWhitespace)
        #expect(trailingIsWhitespaceOnly)
    }
}

@Test(arguments: hostileDocuments) func assembledIsTheReassemblyContract(_ text: String) {
    // `ChunkPlan.assembled` is the one formula, so it has to hold the invariant itself:
    // fed each chunk's own text it must give the source back, byte for byte.
    for budget in hostileBudgets {
        let plan = Chunker.plan(text, maxCharacters: budget)
        guard !plan.chunks.isEmpty else { continue }
        #expect(plan.assembled(from: plan.chunks.map(\.text)) == text)
    }
}

@Test func anEmptyPlanAssemblesToNothing() {
    // The deliberate divergence: a whitespace-only input keeps its bytes on the plan's
    // trailing separator, but the *translation* of a document with no translatable
    // content is empty — `Translator` emits nothing for it.
    let plan = Chunker.plan("   \n\n  \t ", maxCharacters: 900)
    #expect(plan.assembled(from: []) == "")
    #expect(plan.trailingSeparator == "   \n\n  \t ")
}

@Test(arguments: hostileDocuments) func noChunkTextBeginsOrEndsWithWhitespace(_ text: String) {
    // `Block.range` states this for whole blocks; the sentence splitter has to hold
    // it too, or `ResponseCleaner.clean`'s edge-trimming of the reply eats structure
    // the chunker chose to send to the model.
    for budget in hostileBudgets {
        for chunk in Chunker.plan(text, maxCharacters: budget).chunks {
            #expect(chunk.text.first?.isWhitespace == false)
            #expect(chunk.text.last?.isWhitespace == false)
        }
    }
}

@Test func aSplitParagraphFabricatesNoParagraphBreaks() {
    // One long paragraph, no blank lines anywhere: no chunk boundary inside it may
    // carry one either. The defect this guards against is the old design's, which
    // joined every sentence-split piece back with "\n\n" — paragraph breaks the
    // document never had, invisible to the markup diff because the diff was taken
    // against the same fabricated text.
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

@Test func aCRLFDocumentMergesLikeAnLFOneAndStaysByteIdentical() {
    // One blank line in the CRLF convention is "\r\n\r\n", and it must merge exactly
    // like "\n\n": gating on the LF spelling alone meant a CRLF document never merged
    // at all — 30 paragraphs became 31 model calls where an LF copy of the same
    // document needed 3. The join uses the document's own bytes, so the chunk text is
    // still byte-identical to the source span it came from.
    let text = "Short first paragraph.\r\n\r\nShort second paragraph."
    let plan = Chunker.plan(text, maxCharacters: 900)
    #expect(plan.chunks.count == 1)
    #expect(plan.chunks[0].text == text)
    #expect(plan.chunks[0].separatorBefore.isEmpty)
    #expect(plan.trailingSeparator.isEmpty)
    // And the byte-for-byte contract still holds when the budget forces a boundary.
    #expect(reassembled(text, maxCharacters: 30) == text)
}

@Test(arguments: ["\r\r", "\r\n\n", "\n\r\n"])
func oneBlankLineInAnyEndingConventionMerges(_ separator: String) {
    // The merge gate used to enumerate two spellings, "\n\n" and "\r\n\r\n", so a
    // CR-only document (classic Mac, and what some editors still emit) and every
    // mixed-EOL document — routine in a hand-edited file, or in a selection pasted
    // together from two sources — never merged at all: 2 chunks at a 900-character
    // budget where the LF twin gave 1. The rule is structural now: exactly one blank
    // line, whatever the document spells it with.
    let text = "Short first paragraph.\(separator)Short second paragraph."
    let plan = Chunker.plan(text, maxCharacters: 900)
    #expect(plan.chunks.count == 1)
    #expect(plan.chunks[0].text == text)
    #expect(plan.chunks[0].separatorBefore.isEmpty)
    #expect(plan.trailingSeparator.isEmpty)
    // And the byte-for-byte contract still holds when the budget forces a boundary.
    for budget in hostileBudgets { #expect(reassembled(text, maxCharacters: budget) == text) }
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

// MARK: - Indented text is prose, and its indentation survives anyway.

@Test func aTabIndentedParagraphAfterABlankLineIsProse() {
    // Indentation is not a code signal here, deliberately: a hotkey selection out of
    // an email or a PDF is routinely indented wholesale, and a Markdown loose list's
    // continuation paragraphs are indented by rule — reading either as code returned
    // it untranslated, with a success state. Only fenced and inline code are
    // protected. The indentation survives regardless: the first line's lives in the
    // separator, every continuation line's inside the chunk text.
    let text = "Intro.\n\n\tThis looks like a sentence. And another sentence here."
        + " And one more now.\n\tAnd a fourth one closes the block.\n\nAfter."
    let plan = Chunker.plan(text, maxCharacters: 900)
    #expect(plan.chunks.contains { $0.text.contains("This looks like a sentence.") })
    #expect(plan.chunks.contains { $0.text.contains("\n\tAnd a fourth one closes the block.") })
    #expect(reassembled(text, maxCharacters: 900) == text)

    // Oversized, it sentence-splits like any other prose — the pre-wave behaviour.
    let split = Chunker.plan(text, maxCharacters: 45)
    #expect(split.chunks.count > plan.chunks.count)
    #expect(!split.chunks.contains {
        $0.text.contains("This looks like a sentence.") && $0.text.contains("fourth one")
    })
    #expect(reassembled(text, maxCharacters: 45) == text)
}
