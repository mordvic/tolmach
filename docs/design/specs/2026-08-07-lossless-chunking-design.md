# Lossless chunking — design

Date: 2026-08-07
Status: approved for implementation

## Status of this document

This is the pre-implementation design for making the translation pipeline structure-preserving:
the assembled translation must reproduce the source document's separators — blank-line runs,
indentation, line endings, document-edge whitespace — byte for byte. Once the code exists,
**the code is the authority on behaviour and this document is the authority on why**.

A claim marked **measured** restates an observation already recorded in the code or in `docs/`;
the citation says where. Everything else is intent.

**Correction (2026-08-07).** The decision that an indented run is code (§1.2–1.3, §3, §5 — never
sentence-split, kept solo, reproduced by `Translator` with no model call, protected by a prompt
clause, tokenised as a code block by `MarkupSkeleton`) was implemented and reverted the same day.
A code-review wave reproduced what it costs a *selection* translator, which has no format or
container context: tab- and space-indented plain text out of an email or a PDF, and every Markdown
loose-list continuation paragraph, came back untranslated with a success state. The no-call path
also stamped `firstTokenAt` with no model content at all, defeating the «nil TTFT == an empty
reply» contract, and a user-glossary term occurring only inside such a block was deterministically
reported `.missing`. Indented text is prose again and is translated; its indentation is preserved
through the verbatim separators instead, and fenced and inline code are the only protected forms.
Everything else in this document stands. The code is the authority.

This is the first of three sub-projects agreed on 2026-08-07. The other two — rich-text
(RTF/HTML) capture, and returning the translation into the source application in place of the
selection — each get their own spec and depend on this one: rich text will be converted to
Markdown and travel through this same chunker, and pasting back into someone else's document is
only acceptable if the structure survives the round trip.

---

## 1. What is wrong today

Read from the code, not from a running app.

### 1.1 The chunker fabricates paragraph breaks

A block longer than `maxChunkCharacters` is split by `Chunker.splitBySentences`, and the pieces
are joined with `"\n\n"` — both inside a chunk (`Chunker.swift`, the packing loop) and between
chunks when `Translator` assembles `final` (`translatedChunks.joined(separator: "\n\n")`). One
long source paragraph therefore comes out as several paragraphs. The markup diff cannot report
this: it deliberately compares against the *normalised* input (`Translator.swift`, the
`markupDiffs:` argument), so a break the chunker itself inserted is invisible to the one check
that exists to catch structural drift.

### 1.2 The chunker normalises whitespace irreversibly

`Chunker.blocks(in:)` discards the text between blocks: any run of blank lines becomes exactly
one paragraph break, and `flushProse` trims the joined block, cutting the first line's leading
indentation. Consequences:

- A document whose author used two blank lines between sections gets one.
- An indented code block (four spaces, no fences) loses the indentation that makes it a code
  block, is treated as prose, split by sentences, and translated.
- CRLF line endings do not survive.
- The selection's own leading and trailing whitespace — which `SelectionReader` deliberately
  preserves (**measured**: its `meaningful(_:)` comment) — is dropped by the engine anyway.

### 1.3 The skeleton's vocabulary has gaps

`MarkupSkeleton` does not tokenise Markdown tables, indented code blocks, or setext headings
(`===`/`---` underlines), so dropping any of them in translation goes unreported. Backticks
inside an indented code block are today misread as inline code spans.

---

## 2. The contract

One invariant, checkable by a test that could not previously exist:

> **`Σ (chunk.separatorBefore + chunk.text) + trailingWhitespace == source text, byte for byte.`**

Everything below serves it. The division of labour it encodes: **the model translates blocks;
the separators are restored by us, verbatim from the source.** Model discipline can therefore
never affect separators — only the structure *inside* a block still depends on the model, and
that part the markup diff already watches.

## 3. `Chunker`

- `Block` gains a kind — `prose | fencedCode | indentedCode` — and records the exact separator
  preceding it **as a substring of the original text**, never re-synthesised from a line count
  (re-synthesis is precisely how CRLF and `"\n\n\n"` would die).
- `flushProse` stops trimming: indentation and trailing spaces (Markdown hard breaks) are part
  of the block.
- An indented code block — a run of lines indented ≥ 4 spaces following a blank line, per
  CommonMark — is never sentence-split, mirroring fenced blocks today.
- **Packing rule:** adjacent blocks merge into one chunk *only if* the actual separator between
  them is exactly `"\n\n"`. Any other separator — three blank lines, CRLF, a blank line
  containing spaces — forces a chunk boundary and is restored verbatim at assembly. The model
  always sees canonical text; the diff can never cry wolf over separators. The cost is a rare
  extra chunk boundary on unusually-formatted documents, paid deliberately.
- Sentence-splitting an oversized block: the inter-sentence whitespace moves into the *next*
  piece's `separatorBefore` (typically `" "`), so the fabricated `"\n\n"` of §1.1 disappears
  and the reconstruction invariant holds across the split.
- `Chunk` publicly gains `separatorBefore: String`. `containsCodeFence` keeps its name and its
  one consumer's semantics — the `allowFenceUnwrap` gate concerns fenced replies only.

## 4. `Translator`

- `final = Σ (separatorBefore + translated chunk) + trailing whitespace of the source`. The two
  hard-coded `"\n\n"` writes (the `onToken` separator and the `joined(separator:)`) become
  `separatorBefore`. The stream/`final` invariant — pinned by
  `theStreamReconstructsExactlyWhatFinalContains` — is preserved by construction, and the
  separator keeps its current character: it never stamps `timeToFirstTokenMS` and is not
  content (`TranslationViewModel`'s consumer already holds whitespace-only pieces in `pending`).
- `markupDiffs` goes back to diffing against the **actual source text**. The comment that moved
  it onto the normalised input (**measured**: phantom paragraph/hard-break diffs on decorated
  whitespace) is rewritten, because the normalisation it describes no longer exists — per the
  «measured» contract in `CLAUDE.md`.
- `PromptBuilder`: the code rule extends to indented blocks, next to the fenced rule and in its
  words («reproduce them byte for byte»).

## 5. `MarkupSkeleton` and `DiffPresentation`

- Indented code blocks tokenise as `.codeBlock` with an empty `lang` — «a code block was
  dropped» means the same thing for both spellings, and tracking them as blocks stops their
  backticks producing false `.inlineCode` tokens.
- New token: a table row — a line whose trimmed form starts with `|`.
- Setext headings: a line of only `=` (level 1) or `-` (level 2) directly under a non-blank
  line tokenises as `.heading`.
- `DiffPresentation.label` gains Russian labels for the new tokens; its exhaustive switch with
  no `default:` forces the additions at compile time.

## 6. Errors and cancellation

No new error paths. Cancellation semantics are untouched: the explicit
`Task.checkCancellation()` calls stay where they are, and the separator emission sits exactly
where today's `"\n\n"` emission sits.

## 7. Testing

Per `docs/reference/TESTING.md` (the mutation rule; a test must fail under the defect it names):

- The reconstruction invariant over a corpus of hostile inputs: CRLF, `"\n\n\n"`, blank lines
  containing spaces, leading/trailing document whitespace, indentation, hard breaks, an
  oversized paragraph.
- «A long paragraph gains no paragraph breaks» — written first, failing on today's code.
- «Indented code is not sentence-split, not merged with prose across a non-canonical
  separator, and tokenises as a code block».
- The existing stream/`final` invariant test extends to non-`"\n\n"` separators.
- Mutating the packing rule (merge on any separator) must fail the invariant corpus.
- `swift run acceptance` is run by hand after implementation — the markup-integrity measurement
  may shift now that the diff sees the real source — and the result recorded against
  `docs/reference/BASELINE.md`.

## 8. Deliberately unchanged

The two-glossary scheme and both injection rules (ADR 0001), `ResponseCleaner`, panel and
window behaviour, `stats`/TTFT semantics, `expectedChunkCount`, the `keep_alive` and model
policy. Nothing in this design touches OllamaKit or TextCapture.
