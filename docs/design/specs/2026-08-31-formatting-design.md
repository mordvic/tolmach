# Formatting: keeping the markup, and showing it — design

Date: 2026-08-31
Status: designed, not implemented

## Status of this document

Three separate defects wear one face — «переведённый текст теряет заголовки, абзацы, списки,
выделения и код». They live in three different layers, and the deep pass this document came out
of found that the layer the report *sounds* like — the model dropping markup — is measurably the
smallest of the three on the models this install actually runs. Once the code exists, **the code
is the authority on behaviour and this document is the authority on why.**

Everything below is measured, on this machine, on 2026-08-31:

- `Scripts/markup-render.swift` re-takes every platform number (parsing, rendering, AppKit round
  trip, text-view mechanics).
- The live loss series (§2) ran against this install's own Ollama
  (`translategemma:12b`, `translategemma:27b`, `aya-expanse:32b`) through the release
  `translate-cli` at `--chunk 4000` — the sizes and budget the user actually runs.
  `Scripts/markup-loss.sh` re-runs it.
- `Scripts/rich-capture.swift` is the interactive probe for the one measurement only a human can
  take (§11.1); its phase is gated on it.
- The DeepL claim in §3 is quoted from `developers.deepl.com/docs/xml-and-html-handling/html`
  as fetched today, not from memory.

## 1. The diagnosis: three causes, three layers

### 1.1 The capture hands over plain text — there is nothing left to preserve

`SelectionReader.accessibilityText()` asks for `kAXSelectedTextAttribute` and returns
`selected as? String`; the comment at that cast records that an application answering with an
`NSAttributedString` «casts to nil rather than to its characters» and degrades to the clipboard
fallback — which reads `pasteboard.string(forType: .string)` and nothing else.

So a heading, a bold run or a table selected in Word, Pages, a browser or Slack reaches
`Translator` as unmarked prose. The pipeline preserves the structure it is given; in this path it
is given none. **For selections out of rich applications this is the whole story**, and no
model-side or render-side work changes it.

### 1.2 The output is rendered as its own source code

`TranslationPane.swift:58` is `Text(text)` and `PanelView.swift:567` is
`Text(model.translatedText)`. When the source *was* Markdown — a `.md` file in «Файлы», a README
pasted into «Текст» — the bytes are intact (§2 measures just how intact) and the screen shows
`# Заголовок`, `**жирный**`, ``` ``` ``` and `| a | b |` as literal characters. Nothing is lost;
nothing is shown either. This is the half the request names directly: «правильно отображать …
таблицы, отдельные участки кода, которые можно скопировать».

### 1.3 The model loses markup — rarely, systematically, and invisibly

Rarely and systematically: §2. Invisibly: `MarkupToken` has no case for emphasis at all, so when
a model does drop a `**`, `MarkupSkeleton.compare` reports nothing, `WarningsView` says the
structure survived, and `acceptance`'s markup gate passes. The blind spot, not the loss rate, is
the defect in this layer.

## 2. What the models actually lose — measured, not assumed

No number for this existed anywhere in the project, so the deep pass took one before choosing a
strategy. One ~1 KB EN technical document carrying every form at once — H1, H2, six `**bold**`
and five `*italic*` spans, two `` ` `` spans, a nested bullet list, an ordered list, a
blockquote, a 4-row GFM table — translated EN→RU through the release `translate-cli`,
`--chunk 4000`, and scored by counting surviving forms (`Scripts/markup-loss.sh`
re-runs the whole series, both routes; the document joins `corpus/` in Phase 2, deliberately
not before — `acceptance` reads `./corpus` unconditionally, so adding the file moves that
harness's numbers and belongs with a BASELINE entry, not with this analysis).

**Series A — the shipped prompt, 11 runs:**

| Model | Runs | Headings, lists, nesting, quote, code, all 4 table rows | 6 bold | 5 italic |
|---|---|---|---|---|
| translategemma:12b | 5 | survived in 5/5 | 6/6 in 5/5 | **4/5 in 5/5** — always the same span |
| translategemma:27b | 3 | survived in 3/3 | 6/6 | 5/5 |
| aya-expanse:32b | 3 | survived in 3/3 | 6/6 | **4/5 in 3/3** — always the same span |

Two facts matter more than the totals. **Block structure did not lose a single token in 11
runs** — including the table, the form the report most fears for. And the italic loss is not
noise: 12b dropped `*read-only*` (rendering it as unmarked «только для чтения») in all five
runs, aya-expanse:32b dropped `*first*` in all three, 27b dropped nothing. Each model
*decides*, consistently, that one particular emphasis does not survive its phrasing. That is a
property to detect and show, not a randomness to suppress.

**Series B — the same 8 runs with one added protection rule** («Preserve inline emphasis:
words wrapped in ** or * … Never drop the markers»):

- 12b, 5/5 runs: `**staging**` came back as `*staging*` — **the rule converted a bold into an
  italic**, a new defect that series A never produced — and `*read-only*` stayed lost.
- aya-expanse:32b: 1 clean run, and 2/3 runs **added emphasis the source never had**
  (`*пятницам*` for an unmarked «on Fridays»).

So the obvious instruction is measurably *harmful* on these models: it redistributes markers
instead of preserving them. The line does not land, and this repeats the project's own
2026-08-10 finding that plausible prompt edits must be measured — this one was, and failed.

**Series C — the правка route** (`--proofread --level errorsAndStyle`, `--from ru`, the 27b
translation as source): 6/6 runs — translategemma:12b ×3 and aya-expanse:32b ×3 — preserved
every counted form, headings to table rows to all eleven emphasis spans, while genuinely
editing (15–19 changed lines per run against the source). Markup survival on this route is
*better* than on translation for these models, which does not contradict the правка
calibration's 4/4 code-span corruption on aya-expanse:8b — different model, different failure
(editing *inside* protected spans, which this counter does not probe and the calibration does).

**What this changes about the design.** The deep pass began expecting model-side loss to be a
main cause and structural protection (§3) to be the main cure. Measured, on the models this
install runs, the loss is ~1 inline span per document on two models out of three and zero block
tokens anywhere — so the cure is **verification and display, not construction and not
instruction**: make the loss visible (§9), render what survives (§5), and leave the prompt
alone. The one-document corpus is a limit of this measurement, stated plainly; Phase 5 folds
the document into `corpus/` so the number is re-taken by the same harness that owns the other
gates.

## 3. Prior art: how mature systems keep formatting

Surveyed to steal the strongest shape, and because the repo has done this before
(`docs/design/specs/2026-08-10-…`: DeepL's tag handling, LanguageTool's stripping).

- **DeepL** (`tag_handling=html/xml`): «The API extracts the text from the HTML structure,
  translates it, and places the translation back into the structure» — quoted from the vendor's
  page today. Structure never rides through the model as trusted content. The same page:
  invalid HTML never errors, and `translate="no"` marks protected elements — their spelling of
  this repo's pass-through chunks.
- **Browser translators** (Google Translate's page mode, immersive-translate): operate on DOM
  nodes — the block *is* the unit, text nodes are replaced in place, tags are never model
  output. Structure by construction again.
- **CAT tools / XLIFF** (SDL/Trados lineage, OmegaT, Okapi): inline formatting travels as paired
  placeholder tags and QA validates tag parity after translation. Works because the translator —
  human or NMT — is trained on tags. (Background knowledge, not re-verified today.)
- **Apple Writing Tools**: operates on attributed ranges inside the responder's own text system;
  formatting never leaves the document. (Background knowledge, not re-verified today.)

The pattern across all four: **nobody asks the model to preserve structure; they take structure
away from it and put it back deterministically.** This repo already follows that philosophy for
fenced and inline code. The deep question was whether to extend it to headings, lists, tables
and emphasis. The answer from §2 is: not yet, and not by instruction either —

| Form | Strategy chosen | Why |
|---|---|---|
| Fenced code | Construction (pass-through chunk) | Already shipped; measured necessary |
| Inline code | Construction (positional restore) | Already shipped; restorable because untranslated |
| Headings, lists, quotes, tables | **In-band, verified** | 0 losses in 11 live runs; construction would cost per-block alignment machinery the loss rate does not justify |
| Bold/italic | **In-band, verified, rendered** | ~1 span/document, systematic; the instruction cure measurably backfires (series B); CAT-style placeholders contradict this repo's own marker-echo measurement (`PromptBuilder.userPrompt`) |

«Verified» is §9's new skeleton tokens: the tool must *see* the 1-in-13 span it cannot prevent,
and say «Разметка изменилась» about it. If a future model regresses on block forms, the
construction option (a `Chunk` that holds its decorations and re-attaches them) stays on the
table — the corpus document from Phase 5 is what would detect that regression.

## 4. The invariant this design refuses to break

**A Markdown string stays the only representation the pipeline knows.** `Translator` keeps
taking and returning `String`; `ChunkPlan.assembled(from:)` stays byte-for-byte lossless;
`MarkupSkeleton` keeps diffing bytes. Formatting becomes two conversions *outside* the engine:

```
rich selection ──► Markdown ──► [ unchanged pipeline ] ──► Markdown ──► attributed document
                                                                          ├─► rendered view
                                                                          └─► rich pasteboard flavour
```

Measured constraint, not conservatism: `AttributedString(markdown:, .full)` is **not lossless**
— `"Строка один\nСтрока два в том же абзаце\n\nВторой абзац"` comes back
`"Строка один Строка два в том же абзацеВторой абзац"`, soft breaks collapsed, the paragraph
boundary gone from the characters. Its sibling `inlineOnlyPreservingWhitespace` **is**
byte-lossless on the same string. Hence: blocks by hand, inline by Foundation, storage never.

## 5. Part A — one block structure, shared with the chunker

New file, `Sources/TranslationCore/MarkdownBlocks.swift`:

```swift
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, range: Range<String.Index>)
    case paragraph(range: Range<String.Index>)
    case listItem(depth: Int, marker: ListMarker, content: Range<String.Index>)
    case blockquote(depth: Int, content: Range<String.Index>)
    case codeBlock(lang: String, content: Range<String.Index>, closed: Bool)
    case table(header: [Range<String.Index>], rows: [[Range<String.Index>]], alignments: [Alignment])
    case thematicBreak(range: Range<String.Index>)
}

public enum MarkdownBlockScanner {
    public static func blocks(of text: String) -> [MarkdownBlock]
    /// The prefix whose shape can no longer change however the document grows — §7.
    public static func settledPrefix(of text: String) -> (blocks: [MarkdownBlock], tail: Range<String.Index>)
}
```

Two properties are load-bearing:

- **Every block carries a `Range` into the original string, never a copy.** That is what lets
  «Скопировать» on a code block hand over source bytes exactly, and what keeps «Исходник» (§8)
  the same string rather than a re-serialisation of a tree.
- **It reads lines through `LineScanner` and fences through `LineScanner.isFenceMarker`** — the
  same code `Chunker`, `MarkupSkeleton`, `ResponseCleaner` and `InlineCodeRestorer` already
  share. The renderer must see the document the chunker saw, or it will draw a table where the
  diff saw a paragraph.

### Why not `interpretedSyntax: .full` for the blocks

Measured, it is stronger than expected — GFM tables *with per-column alignment*, nested lists
with item numbers, blockquotes, fenced code with language, hard breaks; 91 000 bytes → 8 400
runs in 52–73 ms — and still wrong here, in descending order:

1. **It reads a four-space indent as a code block, and this pipeline reads indentation as
   prose.** Measured: `"Абзац:\n\n    отступ на четыре пробела\n\nещё абзац"` →
   `[paragraph, codeBlock '<none>', paragraph]`; an indented quoted email
   (`"    > Здравствуйте, коллеги"`) → `codeBlock`. `PromptBuilder.protectionRules` carries the
   opposite rule with its history; `.full` would render an indented email as code the engine
   cheerfully translated.
2. **It is not lossless** (§4), so nothing copied or toggled back could come from it.
3. It is all-or-nothing per parse, which §7's streaming rule cannot use.

**Inline spans, though, are Foundation's job and no parser is written for them.** Within one
block's range: `inlineOnlyPreservingWhitespace` + `returnPartiallyParsedIfPossible`. Measured:
byte-lossless, and yields `inlinePresentationIntent` bold (rawValue 2) / italic (1) / code (4)
plus `link`. One caveat, stated at the call site: that option turns a fence line into an inline
code run, which is safe only because a `codeBlock`'s range is never handed to it — the same
all-or-nothing fence discipline `MarkupSkeleton.inlineCodeSpans` already documents.

## 6. Part B — the renderer is a text view, and that is a change of recommendation

The first draft of this design rendered blocks as a SwiftUI `VStack` and kept a hosted
`NSTextView` as a rejected alternative. The deep pass took four measurements and the
recommendation flipped. **The rendered pane is a read-only hosted `NSTextView` (TextKit 1)
displaying an `NSAttributedString` built from the blocks** — `SourceEditor` is the in-repo
precedent for hosting one.

What flipped it:

1. **Selection.** A translator's primary interaction with its output is select-and-copy, and a
   `VStack` of `Text`s cannot be dragged across — SwiftUI's `.textSelection` is per-view. A text
   view selects across the whole document by construction. The first draft paid this as a known
   regression; the measurements below removed the reason to pay it.
2. **Rich copy is the same code as rendering, not a second serialiser.** Measured:
   `writeSelection(to:)` on the probe document put `public.rtf` (28 763 bytes) *and* plain text
   on the board in one call. In the SwiftUI variant, the view and a separate
   Markdown→`NSAttributedString` serialiser could drift apart — «a second copy of this pane is
   how two surfaces come to disagree» is this repo's own sentence for that shape.
3. **Tables lay out.** `NSTextTable` 2×2 measured 395 × 68 pt headless, borders and all;
   SwiftUI would need a hand-built `Grid` *and* the serialiser would still need `NSTextTable`
   for the rich flavour anyway.
4. **Streaming cost.** 500 appends to `NSTextStorage` up to 90 500 chars: 35 ms total, worst
   single append 0.3 ms with layout. (SwiftUI is not slow either — a 700-block `VStack` lays
   out in 38 ms, `LazyVStack` in 1 ms — performance did not decide this; selection and the
   single serialiser did.)

Concretely:

- **`MarkupKit.MarkdownToAttributed`** (§10) is the one Markdown → `NSAttributedString`
  converter, used by the pane, the panel and the copy path. Headings scale `ContentFont.size`
  by level (semibold ×1.6/1.4/1.25/1.1/1.0/1.0); lists via `NSTextList` with hanging indents;
  quotes indented with a `.secondaryLabelColor` cast; code blocks in the monospaced face on a
  `.quaternaryLabelColor`-tinted block with the source bytes verbatim; tables via
  `NSTextTable`, header row semibold, alignments from the parse; inline runs mapped from the
  Foundation intents. Colours are semantic `NSColor`s throughout so both appearances hold, and
  anything that ever means «warning» stays `StatusColour`'s.
- **Only the user's text scales** (`docs/adr/0008`): `ContentFont` governs every rendered run —
  headings and code included, as multiples of its size — and nothing else in the pane.
- **The per-code-block «Скопировать» affordance** is an overlay button positioned from
  `layoutManager.boundingRect(forGlyphRange:in:)` — measured to answer exact rects headless —
  shown on hover over a code block, copying the block's source bytes (`MarkdownBlock`'s own
  range). Its look, hover feel and scroll-tracking are §11.2's human check.
- **Copy semantics.** The pane's «Скопировать» button writes two flavours in one pasteboard
  write: `.string` = the Markdown bytes (unchanged from today) and `.rtf` = the same attributed
  document the pane is showing. A drag-selection copy inside the view yields what any rich text
  view yields — RTF + plain *without* markers; the button is the Markdown-fidelity path, and
  the toggle (§8) is one click from a raw-Markdown selection. When the pane is showing
  «Исходник», or there is no markup, the copy is plain only — a plain-prose translation never
  arrives in Word wearing a font this app chose.
- **«Заменить» (`SelectionWriter`) keeps writing plain text.** Measured reason: AppKit's HTML
  import shows what RTF carries — `<h2>` arrives as *18 pt bold Times*, faces and sizes, not
  semantics — so pasting rich back would replace the user's selection with this app's idea of
  Times 12. Revisiting needs §11.3's measurement of how real applications merge an incoming
  RTF run.

## 7. Part C — streaming, and what the panel does

Measured shapes of a half-arrived document: an unterminated `**` stays a literal; an
unterminated fence parses as a code block; a half-written table (`"| a | b |\n|---|"`) parses
as paragraph text with its lines glued into one — a table assembles itself out of a
run-together paragraph as rows land.

- **`MarkdownBlockScanner.settledPrefix` is the streaming rule.** A block is settled when a
  later byte cannot change its shape: a fence when closed, a table when a non-`|` line follows,
  a paragraph/heading/list item when a blank line follows. The window's pane appends settled
  blocks to the text storage (measured cheap, above) and keeps the unsettled tail as plain
  characters, so a block never changes kind on screen after being drawn as itself. The scanner
  re-scans only from the start of the unsettled tail.
- **The panel renders once, at the end of the run.** During the stream it stays today's plain
  `Text`: the panel exists to answer in under a second at 300–560 pt, a reflowing layout is
  worse there than raw `**`, and this keeps `PanelSizer`'s monotonic-height rule and the
  reservation prediction (`docs/adr/0008`, square-law) untouched. The final rendered content
  goes through the same measure-then-grow path the reply already uses; hosting an
  `NSViewRepresentable` inside the detached measuring host needs a `sizeThatFits`
  implementation, flagged in §11.4 as a platform trap to probe before Phase 4.

## 8. «Разметка» / «Исходник», and when rendering engages at all

A two-item toggle in `PaneHeader`, stored as `AppSettings.showsRenderedMarkup` (default true).
«Исходник» is the same string in the same text view without the conversion — today's behaviour,
whole-document selection over raw Markdown, never removed, one click away.

The toggle appears **only when there is something to render**: `MarkdownPresence.hasMarkup(_:)`
answers false when the scan yields nothing but paragraphs, and the pane then behaves exactly as
today. Measured safety for prose that merely contains the characters:
`"Цена 5 * 3 = 15, файл a_b_c.txt и #хэштег"` parses as one plain paragraph — pairing rules
protect it — but a line-leading `# ` in prose *is* a heading, which is why «Исходник» exists.

## 9. Part D — teaching the verifier that emphasis is structure

`MarkupToken` gains `.emphasis(strong: Bool)` and `.tableCells(count: Int)`. Emphasis spans are
found the way `inlineCodeSpans` finds code — parity-paired markers per line, UTF-16
coordinates, sorted into the same `found` array so document order between token kinds holds.
`.tableRow` stays; `.tableCells` catches a row that survived with two of its four cells.
`RussianCopy` gains the labels.

After this, §2's systematic losses — the exact defects measured today — reach `WarningsView`,
`JobResult`, `translate-cli` and `acceptance`. **No prompt change ships with it**: series B is
the measurement that the obvious rule makes these models worse, recorded here so it is not
re-proposed as tidying. The corpus gains the §2 document so `acceptance` re-takes the loss rate
whenever models or prompts move (both gates go info-only off `aya-expanse:8b`, per the
harness's own rule).

## 10. Part E — the capture, made rich

`SelectionReader.read()` gains a richer answer without changing its two-tier discipline:

```swift
public struct CapturedSelection: Sendable {
    public let plain: String
    public let html: Data?      // public.html, as the application wrote it
    public let rtf: Data?       // public.rtf
}
```

**`TextCapture` converts nothing** — it hands over raw flavours, stays «every fragile macOS API,
isolated on purpose», and keeps its no-`TranslationCore` independence (`Package.swift:20`).
Conversion is `MarkupKit`'s job, called from `HotkeyCoordinator`.

Three tiers, each degrading to the next: (1) Accessibility attributed —
`kAXAttributedStringForRangeParameterizedAttribute`, worth building **only if** §11.1's
measurement shows real applications answer it with more than visual attributes; (2) the
clipboard's `public.html`/`public.rtf`, read inside the same held lock once the `.string` poll
(the flavour whose arrival is already measured) lands — `PasteboardSnapshot` already preserves
and restores every flavour, `docs/adr/0005`; (3) plain, exactly as today.

**HTML is converted by parsing tags, not by importing through AppKit.** Measured:
`NSAttributedString(data:, .html)` keeps only visuals — `<h2>` → 18 pt bold Times (level gone),
`<code>` → Courier, `<ul>` → `textLists` plus literal `"\t•\t"` characters, `<table>` →
`NSTextTableBlock` — and costs 216–262 ms cold / ~60 ms warm on a path budgeted at «panel in
under a second». So `MarkupKit.HTMLToMarkdown` is a small closed-tag-list scanner (`h1…h6`,
`strong`/`b`, `em`/`i`, `code`, `pre`, `ul`/`ol`/`li`, `blockquote`, `table`/`tr`/`th`/`td`,
`a href`, `br`, `p`) over the flavour where semantics still exist; unknown tags contribute
their text and nothing else — a converter, not a browser, and `docs/adr/0007`'s fifth
hand-written dependency. `MarkupKit.AttributedToMarkdown` covers the RTF flavour, where visuals
are all there is, mapping heading level from relative font size — honest for RTF because RTF
has nothing better.

**The gate that keeps this a strict improvement:** converted Markdown is accepted only if
`MarkupSkeleton.tokens(of:)` finds at least one block token in it that the plain flavour's own
scan lacks; otherwise the plain flavour is used. A conversion that fabricates markup is worse
than one that loses it — a stray `**` would ride into every chunk's prompt and §2 says the
models then do strange things with it.

### Targets

```
TranslationCore (+ MarkdownBlocks)         TextCapture (raw flavours; still no TranslationCore)
      ↑            ↑            ↑                       ↑
  OllamaKit   LMStudioKit    MarkupKit (AppKit)         │
      ↑            ↑            ↑                       │
              TranslatorApp · translate-cli · acceptance┘
```

`MarkupKit` — `MarkdownToAttributed`, `HTMLToMarkdown`, `AttributedToMarkdown` — depends on
`TranslationCore` and AppKit; a deliberate `docs/adr/0007` whitelist edit, the first non-app
target to import AppKit. Both directions of conversion live in one target so they can be tested
against each other. New targets repeat `.swiftLanguageMode(.v6)` and the macOS 14 floor;
`swift build --build-tests` stays at zero warnings.

## 11. What only a human can check, and what is owed before which phase

Additions for `docs/reference/OPEN-ITEMS.md` §1 (the first is already there):

1. **What applications actually offer a rich capture** — `Scripts/rich-capture.swift` against
   Safari, Chrome, Word, Pages, Notes, Mail, Slack, Telegram, VS Code: which flavours their ⌘C
   writes, and whether the AX attributed answer carries semantics or only visuals. **Phase 3 is
   gated on this table**; tier 1 may be dead code.
2. **The rendered pane by eye**: the code-block hover button (placement from measured rects,
   feel by hand), a table at the pane's narrow widths, both appearances, and the settled-prefix
   streaming showing no visible re-layout of already-drawn blocks.
3. **How a rich paste behaves in Word and Pages** — whether an incoming RTF run adopts the
   destination's font or imposes ours. §6's «Заменить» decision waits on it.
4. **The panel's final render at 300 pt** — whether a table is legible there or should collapse
   to «строка: значение» pairs below some width; and the `sizeThatFits` probe for measuring a
   hosted text view inside `PanelController`'s detached host (a `PLATFORM-TRAPS` candidate).

## 12. Phasing

Each phase ships on its own and none touches `Translator`.

- **Phase 1 — see it and copy it.** `MarkdownBlocks` + `MarkupKit.MarkdownToAttributed` + the
  hosted rendered pane with per-code-block copy + the «Разметка»/«Исходник» toggle +
  `MarkdownPresence` + the two-flavour «Скопировать». One converter powers both showing and
  copying, which is why the first draft's Phases 1 and 2 became one.
- **Phase 2 — keep it honestly.** `.emphasis`/`.tableCells` tokens, `RussianCopy` labels, the §2
  document into `corpus/`, a BASELINE entry. Independent of Phase 1; smallest; closes the blind
  spot that let §2's losses go unmeasured for the project's whole life.
- **Phase 3 — capture it.** `CapturedSelection`, `HTMLToMarkdown`, `AttributedToMarkdown`, the
  improvement-or-no-op gate. Gated on §11.1.
- **Phase 4 — the panel.** Final-render only, after §11.4's probe.

Phase 1 answers «правильно отображать … таблицы, отдельные участки кода»; Phase 3 answers «не
сохраняет … жирный текст или курсив» for rich applications; Phase 2 is what keeps both honest.

## 13. Rejected alternatives

- **Structural protection for block markers and tables** (the DeepL/CAT shape: strip
  decorations, translate content, re-attach). Rejected *for now* on §2's measurement: zero
  block-token losses in 11 live runs on the models this install runs, against real costs — a
  reply/source line-alignment problem the repo has measured models breaking («routinely true
  after the model merges two source lines into one»), or per-block calls where the chunker
  currently merges (measured elsewhere in this repo: 30 chunks → 31 calls vs 2 → 3). The
  design keeps the door open: the Phase 2 corpus document is the tripwire, and a table-cells
  batch call could reuse the `=>` echo contract's parser if that tripwire ever fires.
- **A prompt rule for emphasis.** Measured today and rejected on the evidence (§2 series B):
  bold→italic degradation 5/5 on 12b, fabricated emphasis 2/3 on aya-expanse:32b.
- **Put `AttributedString` through the pipeline.** Not lossless (§4); would re-derive
  `ChunkPlan`'s invariant on a representation that already discarded the bytes.
- **Render with `.full` + `Text` alone.** Reads indents as code against the pipeline's own rule;
  SwiftUI ignores block intents anyway (measured: a `# heading` lays out identically to plain).
- **SwiftUI block views** (the first draft's choice). Flipped by four measurements — §6. Kept as
  the fallback if hosting proves worse in practice than measured; nothing in `MarkupKit`
  depends on the choice, which is the point of having `MarkdownToAttributed` be the seam.
- **Ask the model for HTML or a structured format.** Contradicts the measured marker-echo
  finding at `PromptBuilder.userPrompt`; format repair would sit on every chunk's critical path.
