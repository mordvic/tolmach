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
    let chunks = Chunker.chunk(doc, maxCharacters: 120)
    let codeChunks = chunks.filter(\.containsCodeFence)
    #expect(codeChunks.count == 1)
    let code = codeChunks[0].text
    #expect(code.contains("profile-server publish"))
    #expect(code.contains("blank line lives inside"))
    // The fence stays balanced: an even number of ``` markers.
    #expect(code.components(separatedBy: "```").count % 2 == 1)
}

@Test func chunksAreContiguousAndIndexed() {
    let chunks = Chunker.chunk(doc, maxCharacters: 120)
    #expect(chunks.count > 1)
    for (offset, chunk) in chunks.enumerated() { #expect(chunk.index == offset) }
}

@Test func shortTextIsOneChunk() {
    let chunks = Chunker.chunk("Just a sentence.", maxCharacters: 900)
    #expect(chunks.count == 1)
    #expect(chunks[0].containsCodeFence == false)
}

@Test func whitespaceOnlyInputYieldsNoChunks() {
    #expect(Chunker.chunk("   \n\n  \t ", maxCharacters: 900).isEmpty)
    #expect(Chunker.chunk("", maxCharacters: 900).isEmpty)
}

@Test func unterminatedFenceIsKeptWholeAndNotSplit() {
    let doc = """
    Intro paragraph before the code that is long enough to matter here.

    ```swift
    let a = 1
    let b = 2

    let c = 3
    """
    let chunks = Chunker.chunk(doc, maxCharacters: 60)
    let fenceChunks = chunks.filter(\.containsCodeFence)
    #expect(fenceChunks.count == 1)
    #expect(fenceChunks[0].text.contains("let a = 1"))
    #expect(fenceChunks[0].text.contains("let c = 3"))
}
