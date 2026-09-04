# Change marks for правка: «Результат | Изменения», a count and a stepper — specification

Date: 2026-09-04
Status: specified, not implemented
Issue: https://github.com/mordvic/tolmach/issues/81 (this document from «Problem statement» on)
Design: `2026-09-04-content-presentation-design.md` §7 (the why). This document is the how.

## Status of this document

The implementation specification for the one new capability the content-presentation design
proposes: a правка result shows what changed. It is written in the shape of spec #72 — problem,
solution, user stories, decisions per step, testing, out of scope — so it can be filed as the
issue the pull requests reference. Once code exists, **the code is the authority on behaviour,
the design on why, and this document on what was asked for.**

Two places deviate from the design's §7.5–7.6 on purpose, and both are stated in §«Deviations
from the design» rather than folded in silently.

Numbers marked *start* are defaults to ship with; §«Measurement protocol» is what turns each
into a measured constant, and the constant's comment must then carry the figure.

---

## Problem statement

A правка run returns the corrected text and nothing else. The window shows it beside the
исходник and the panel shows it alone, exactly as a translation is shown. Under «только ошибки»
the app promises a minimal diff and asks the user to take it on faith; under «переписать» the
user cannot tell one moved sentence from a rewritten mail without reading both texts twice.
Apple's Proofread underlines every change and steps through them; Word and DeepL Write offer a
«show changes» view; this app offers the исходник pane. The правка design named change
highlighting «the designated first fast-follow» (§10.1) and deferred it on the cost of asking a
local model for structured explanations.

The explanations are still deferred. The marks do not need them: the diff between the source
and the result is a deterministic computation this app can make itself, without a model, and
that is what this specification adds.

## Solution

1. **`TextDiff` in `TranslationCore`**: a word-level, per-block, deterministic diff between the
   source and the result, over the plain projection of each block (`MarkdownPlainText`), with
   a density rule that turns a rewritten paragraph into one change, bounds that keep it cheap,
   and no model involvement. `Translator.proofread` computes it once, at the settle, and
   returns it in `TranslationOutcome.changes`.
2. **`ChangeMarks` in `MarkupKit`**: attributes over the clean rendering — an underline on every
   changed range, a dotted underline inside table cells and list items — and, for the
   «Изменения» view, the removed text spliced in before its replacement with a strikethrough.
   Marks are located in the rendered storage by aligning tokens, so they work in «Разметка»,
   «Исходник» and plain prose alike. The RTF flavour is built without them.
3. **The window**: the pane header's picker gains a third segment in правка mode
   («Результат | Изменения | Исходник»), the status bar's finished line says «6 изменений»
   and carries a ‹ › stepper, and the «Перевод» menu gains «Следующее изменение» /
   «Предыдущее изменение».
4. **The panel**: a правка reply renders at the settle whether or not it has markup, the
   степень/стиль row gains a third `.menu` picker «Вид» (результат / изменения / оригинал),
   and the status row says «Исправлено: 6 изменений». VoiceOver hears the count.

One tint for every mark — `controlAccentColor` — and shapes that carry the meaning without it.
Deletions are the secondary label colour. Red and green stay `StatusColour`'s.

## User stories

1. As a user who ran «только ошибки», I want every changed range underlined in the result, so
   that I can see the minimal diff I was promised without reading the source again.
2. As a user reading a правка in the window, I want the status bar to say how many changes
   were made, so that a clean text says «изменений нет» instead of showing an unchanged pane.
3. As a user, I want ‹ › in the status bar and ⌘-shortcuts in the menu to jump to the next and
   previous change, so that a long правка can be reviewed without hunting for underlines.
4. As a user, I want a «Изменения» view that shows the removed words struck through before
   the words that replaced them, so that I can judge a change without opening the source.
5. As a user who ran «переписать», I want a rewritten paragraph marked once as a whole rather
   than word by word, so that the view says «this paragraph was rewritten» instead of
   showering it with marks.
6. As a user with a Markdown source, I want the marks drawn in the rendered document and in
   the raw «Исходник» view alike, so that the toggle never costs me the marks.
7. As a user with a plain-prose правка, I want the same marks, so that the feature does not
   depend on the text having a heading.
8. As a user of the panel, I want the finished reply underlined and the status row to say
   «Исправлено: 6 изменений», so that a ⌥⌘R press tells me what it did.
9. As a user of the panel, I want a «Вид» menu with «оригинал», so that I can see the text I
   selected without leaving the panel — the window has the исходник pane, the panel has nothing.
10. As a user pressing «Скопировать» or ⏎, I want the clean result copied — plain and, where
    there is markup, rich — with no underlines and no struck-through words, so that a правка
    never arrives in Word wearing review marks.
11. As a user pressing «Заменить», I want the plain result written back exactly as today.
12. As a user who switched to «Изменения» and then closed the window, I want the choice
    remembered, the same way «Разметка | Исходник» is.
13. As a VoiceOver user, I want the settle announced as «Правка готова, 6 изменений» and each
    ‹ › step to move the selection onto the change, so that it is read in its sentence.
14. As a user whose правка was interrupted, I want the partial text shown plain with no marks,
    so that nothing claims to describe a text the model did not finish.
15. As a user whose text is too long for the diff, I want the result shown unmarked with one
    line saying so, so that a missing mark is never mistaken for an unchanged word.
16. As a user with «Шрифт текста» at 32 pt, I want the underline to scale with the text, so
    that a 1 pt line under 32 pt words does not disappear.
17. As a user with a code block in the text, I want no mark ever drawn inside it, so that the
    one part of the text the model never saw is never claimed to have changed.
18. As a user translating (перевод), I want nothing about this to appear, so that a
    translation is never diffed against its source.
19. As a maintainer, I want `translate-cli --proofread` to print the change count and, on
    request, the per-block ratios, so that the density threshold is measured on the corpus
    rather than guessed.
20. As a maintainer, I want the diff's bounds measured on the 256 KB ceiling before they are
    trusted, so that a paste of a whole document cannot freeze the settle.
21. As a maintainer, I want the panel's floors re-measured with the new row and the new
    status line, so that a hand-dragged panel cannot put its buttons off the frame.
22. As a maintainer, I want the four steps shipped as four pull requests in order, each
    reviewable and revertible on its own.

## Implementation decisions

### Shared

- **Nothing in the model round-trip changes.** `Translator.proofread`'s prompt, chunking,
  streaming and reassembly are untouched; the diff runs after `final` exists and before the
  outcome is built. `translate` and `format` are untouched except for passing `changes: nil`.
- **The diff is over the plain projection, not over the Markdown bytes.** Both texts are
  scanned with `MarkdownBlockScanner.blocks(of:)`; each block is projected with the same
  per-block spelling `MarkdownPlainText.render` already uses (headings lose their `#`, list
  items keep a «•» or «1.» label, table rows join cells with tabs, code blocks are excluded,
  links keep their text). The count therefore describes visible words; a dropped `**` is
  already reported by `WarningsView` as «потеряно: жирное выделение» and is not counted twice.
  To make the projection callable per block, `MarkdownPlainText` gains
  `public static func plain(_ block: MarkdownBlock, in markdown: String) -> String`, and
  `render(_:)` is rewritten as a loop over it — one spelling, two callers.
- **One tokenizer, in `TranslationCore`, used by the diff and by the locator.**
  `TextTokenizer.tokens(of:) -> [TextToken]` where a token is a *word* (a maximal run of
  `alphanumerics ∪ nonBaseCharacters`, with a single `'`/`’`/`-` joining two word characters,
  so «кто-нибудь» and «don’t» are one token) or a *mark* (any other non-whitespace character,
  one token each). Whitespace is a boundary and never a token, which is what makes a collapsed
  double space not a change. Case-sensitive; «е»/«ё» differ, because that is a correction.
  Each token carries its `Range<String.Index>` in the string it was cut from.
- **Marks are attributes; the «Изменения» view is a second string.** In «Результат» the
  storage's `string` is byte-identical to the clean rendering's. In «Изменения» the removed
  text is *characters* — struck through, secondary — and that view is therefore a different
  document, like «Исходник» is. `PaneRendering.rtf(of:font:)` and both `richFlavour()` call
  sites never see a change set, so the flavour on the pasteboard is the clean one by
  construction. A drag-selection copy inside the «Изменения» view carries the struck text as
  any rich text view would; the button is the fidelity path, as the formatting design says.
- **Settings keep `AppSettings`' shape**: `showsChangeDetail` (key `"showsChangeDetail"`,
  default `false`), a direct `UserDefaults` accessor with hand-written observation, no entry in
  the settings window — written by the pane's picker and the panel's menu, the same way
  `showsRenderedMarkup` is.
- **Every new string is Russian**, with «guillemets» and «ё», through `RussianCopy`, no
  backticks in `Text(String)`.

### Step 1 — `TextDiff` and `TranslationOutcome.changes` (`TranslationCore`, `translate-cli`)

Types, all `Sendable`, `Equatable`, in `Sources/TranslationCore/TextDiff.swift`:

```swift
public struct ChangeSet {
    public let changes: [TextChange]
    public let blocks: [BlockPair]           // one per compared block pair, for the measurement
    public let notCompared: NotComparedReason? // nil when the diff ran
    public var count: Int { changes.count }
    public enum NotComparedReason { case tooLong(tokens: Int) }
}

public struct TextChange {
    public enum Scope { case words, block }
    public let scope: Scope
    /// Index into the RESULT's block list (`MarkdownBlockScanner.blocks(of: final)`).
    public let block: Int
    /// Content-token indices in the result block's plain projection. Empty for a pure removal,
    /// whose `lowerBound` is then the token the removal sits before (== token count at block end).
    public let insertedTokens: Range<Int>
    public let removed: String   // plain text of the removed run, "" for a pure insertion
    public let inserted: String  // plain text of the inserted run, "" for a pure removal
}

public struct BlockPair {
    public let source: Int?      // nil: the result block has no counterpart (inserted block)
    public let result: Int?      // nil: the source block has no counterpart (removed block)
    public let sourceTokens: Int, resultTokens: Int, changedTokens: Int
    public let similarity: Double // Dice over content-token multisets, 0…1
}
```

- **Pairing.** Equal block counts → pair by index (правка demands structure preservation; this
  is the shipped case). Unequal counts → `difference(from:)` over the blocks' plain projections
  finds the unchanged blocks as anchors; between two anchors the changed runs are paired by
  index up to the shorter length, and the leftover blocks become `scope: .block` changes with
  an empty `removed` or `inserted` (`BlockPair.source`/`result` nil accordingly).
- **Code blocks are skipped**: a paired `.codeBlock` produces no change and no `BlockPair`
  entry, because the bytes went through `Chunk.passthrough` and the model never saw them.
  `.thematicBreak` likewise.
- **Per pair**, with `s` and `r` the content tokens of the two projections:
  1. `similarity = 2·|s ∩ r| / (|s| + |r|)` over multisets. If `similarity < densityThreshold`
     (*start 0.5*) → one `scope: .block` change (`removed` = the whole source block,
     `inserted` = the whole result block, `insertedTokens = 0..<r.count`). Myers never runs
     on a block this different, which is what bounds its `D`.
  2. Otherwise `r.difference(from: s)` on token strings; consecutive removals and insertions
     are folded into changes; two changes in one block **merge when at most `mergeGap`
     (*start 1*) unchanged content tokens lie between them**, the merged change spanning both
     and the unchanged token between (this is what makes «посмотрите, пожалуйста,» one change
     and not two commas).
  3. If, after folding, `changedTokens / (|s| + |r|) > densityThreshold` → collapse to one
     `scope: .block` change (a reordered sentence has similarity 1 and a dozen changes).
  4. A block with more than `blockTokenLimit` (*start 4 000*) content tokens on either side is
     compared by equality of projections only: equal → nothing, unequal → one block change.
- **Bounds.** If `|s| + |r|` summed over all pairs exceeds `inspectionLimit` (*start 60 000*),
  `ChangeSet(changes: [], blocks: [], notCompared: .tooLong(tokens:))`. Measured, not guessed —
  §«Measurement protocol» item 2.
- **Where it runs.** `Translator.proofread`, after `final` is assembled and after
  `MarkupSkeleton.compare`: `try Task.checkCancellation()` first, then
  `TextDiff.changes(source: text, result: final)`. `totalMS` is taken **before** the diff and
  the diff's own cost is not folded into it, so `docs/reference/BASELINE.md`'s figures do not
  move; the cost is measured separately (item 2). `translate` passes `changes: nil`.
- `TranslationOutcome` gains `public let changes: ChangeSet?`. `nil` means «not a правка».
  `documentGlossaryAttempted == false` stays the правка marker; `changes != nil` is not a
  substitute for it.
- **`translate-cli --proofread`** prints one more line to stderr: `changes: 6`, `changes: none`
  or `changes: not compared (too long, 71 204 tokens)`. `--changes-json` (valid only with
  `--proofread`) prints the `ChangeSet` as JSON to stdout instead of the text — `changes[]`
  with `scope`, `block`, `removed`, `inserted`, and `blocks[]` with the four counts and
  `similarity` — for `Scripts/change-density.sh`.

### Step 2 — `ChangeMarks` and `Rendering.blockRanges` (`MarkupKit`)

- `MarkdownToAttributed.Rendering` gains `public let blockRanges: [NSRange]`, one per block in
  the order the blocks were rendered, covering each block's output including its terminator.
  `rendering(blocks:in:config:)` records them as it appends; `rendering(of:config:)` inherits
  them. A new `plainRendering(of text: String, config:) -> Rendering` wraps `plain(_:config:)`
  and computes `blockRanges` from `MarkdownBlockScanner.blocks(of: text)` converted to
  `NSRange`s over the same string — «Исходник» and plain prose go through it. `plain(_:config:)`
  itself is unchanged, because the stream tail does not need ranges.
- `ChangeMarks.apply(_ set: ChangeSet, to rendering: Rendering, resultMarkdown: String,
  detail: Detail, config: MarkdownFontConfig) -> Rendering`, `Detail` being `.result` or
  `.changes`. It returns a new rendering and never mutates the input.
- **Locating a change in the storage** (per block, blocks processed from last to first so an
  insertion never shifts a range still to be located):
  1. `plain = TextTokenizer.tokens(of: MarkdownPlainText.plain(block, in: resultMarkdown))`;
     `shown = TextTokenizer.tokens(of: storageString[blockRange])`.
  2. Align greedily: walk `shown`; when `shown[i] == plain[j]` record `j → i` and advance both,
     otherwise advance `i` alone — an unmatched shown token is a marker (`**`, `#`, `|`, `-`),
     a list label («•», «1.») or a cell terminator, and never a word the projection has.
  3. If `j` does not reach `plain.count`, the block is left unmarked and the count is not
     changed — a located mark is never guessed.
  4. A change's range is from `shown[map[first]]`'s start to `shown[map[last]]`'s end; a pure
     removal's anchor is `shown[map[insertedTokens.lowerBound]]`'s start, or the block's last
     content token's end when the removal sits at the block end.
- **The attributes** on a located range, in both details: `.underlineStyle` (`.single` below a
  17 pt base, `.thick` from 17 pt — `ChangeMarks.underlineStyle(for:)`, one function, pinned),
  `.underlineColor: NSColor.controlAccentColor`, and `ChangeMarks.changeKey`
  (`NSAttributedString.Key("tolmach.change")`) carrying the change's index in `set.changes`.
  Inside a `.table` or `.listItem` block the style is `.patternDot` instead, because a solid
  line beside a table rule or under a bullet's hanging indent fights the block's own drawing.
  A `scope: .block` change underlines the block's content from its first to its last token.
- **`.changes` detail** additionally inserts the removed text as characters: before the
  anchor, taking the anchor run's `.font` and `.paragraphStyle` and nothing else, plus
  `.strikethroughStyle: .single`, `.foregroundColor: .secondaryLabelColor`, and a single space
  after it when `inserted` is non-empty (before it when `inserted` is empty and the anchor is
  not at the block's start). A `scope: .block` removal is inserted as its own paragraph before
  the result block: the plain text, the result block's first paragraph style, strikethrough,
  secondary colour, its own `"\n"`. Every `CodeRegion` and `blockRange` at or after an insertion
  point is offset by the inserted length (`CodeRegion.offset(by:)` exists for this).
- **Never inside code**: a change never targets a `.codeBlock` block by construction (step 1),
  and `apply` asserts it in debug builds rather than trusting it.
- The RTF flavour is unaffected because nothing calls `apply` on the rendering that produces
  it. Pinned by a test, not by this sentence.

### Step 3 — the window (`TranslatorApp`)

- **`TranslationPane`** gains `changes: ChangeSet? = nil`, `showsChangeDetail: Binding<Bool>
  = .constant(false)`, `changeCursor: Int? = nil`. `MainWindowView` passes
  `model.outcome?.changes` **only when `model.state == .finished`** (an interrupted run's
  partial text is never marked) and only in «Текст» mode — the queue passes nothing.
  The pane hosts `RenderedTextView` when `rendering.hasMarkup || changes != nil`; with
  changes and no markup the view takes the plain path (`plainRendering`).
- **The header's picker** in правка mode (`changes != nil`) has three segments —
  «Результат», «Изменения», «Исходник» — when `offersToggle` is true and two without the
  third. The selection is derived from the two settings and writes both:
  «Результат» → `showsRenderedMarkup = true, showsChangeDetail = false`;
  «Изменения» → `true, true`; «Исходник» → `showsRenderedMarkup = false` and the detail is left
  as it was. `PaneViewChoice` is the value type that does the mapping both ways, and it is
  tested. In перевод mode the picker is exactly what it is today. **Its width is measured**
  (§«Measurement protocol» item 3) before the third segment is believed to fit at the pane's
  280 pt minimum beside «Ещё вариант» and «Скопировать»; if it does not, the fallback is a
  `.menu` picker in that header for правка only, and the measurement says which shipped.
- **`RenderedTextView`** gains `changes`, `showsChangeDetail` and `changeCursor`. The first two
  join `Coordinator.Mode`, so a change to either resets and rebuilds the storage — the finished
  document already takes the whole-render path, and marks are applied to it through
  `ChangeMarks.apply` with `detail` from the setting. `changeCursor` is handled outside `Mode`:
  when it changes, the coordinator enumerates `ChangeMarks.changeKey` for the matching index,
  sets `selectedRange` to it, calls `scrollRangeToVisible(_:)` and `showFindIndicator(for:)`.
  The find indicator is AppKit's own way of pointing at a range and needs no drawing of ours;
  whether it reads well over an underline is §«What only a human can check».
- **`TranslationViewModel`** gains `private(set) var changeCursor: Int?` and
  `func stepChange(by delta: Int)` (wraps; no-op without changes). The cursor is cleared wherever
  `outcome` is cleared or assigned — the four sites the grep finds today — and `adopt(from:)`
  starts it at nil.
- **`RunStatusBar.textModeLine`**, `.finished`, when `outcome.changes != nil`: «Готово за
  1 812 мс · 6 изменений» with the existing warnings `summary` appended after, followed by two
  `.small` borderless buttons ‹ › that call `stepChange(by:)`, disabled at zero changes; the
  count text is `RussianCopy.changeCount(_:)` («изменений нет», «1 изменение», «2 изменения»,
  «5 изменений», through the existing `plural`), and «изменения не отмечены — текст слишком
  длинный» when `notCompared` is set. Nothing else in the row moves.
- **The «Перевод» menu** gains «Следующее изменение» and «Предыдущее изменение», enabled when
  `mode == .text` and the text model has a non-empty change set, calling `stepChange(by: ±1)`.
  Shortcuts ⌘G and ⇧⌘G — the platform's Find Next / Find Previous, and this window has no
  find — **unless** a dump of the installed menus in the manner of `Scripts/view-menu.swift`
  shows SwiftUI already binding ⌘G in the standard «Правка» menu, in which case ⌥⌘↓ / ⌥⌘↑ are
  used and the comment on the declaration records the dump.
- **Copy** is untouched: `MainWindowView.richFlavour()` builds from `PaneRendering`, which
  takes no change set.

### Step 4 — the panel (`TranslatorApp`)

- **`PanelView.rendersFinalReply`** gains `hasChanges: Bool`:
  `guard !awaitingRun, state != .running else { return false }`;
  `if hasChanges { return true }`; `return showsRenderedMarkup && MarkdownPresence.hasMarkup(text)`.
  `PanelHost.updateReplyRendering` passes `coordinator.panelModel.outcome?.changes != nil`.
  The settle-then-swap order in `PanelController` is unchanged; the swap may grow the panel
  and not shrink it, and switching «Вид» to «изменения» is a growth for the same reason
  (`applyFit()` through `setRendersFinalReply`'s path — a rebuild of the installed host and
  one fit).
- **`RenderedReplyView`** gains `rendersMarkup: Bool`, `changes: ChangeSet?`,
  `showsChangeDetail: Bool`, `original: String?`. With `original` non-nil it renders that text
  through the same path with no marks — «оригинал». The coordinator's memo key is the whole
  tuple, because `sizeThatFits` is asked several times per fit and the «Изменения» rendering
  is a different document from the «Результат» one.
- **«Вид»** is a third `.menu` picker in `proofreadingControls`, `.mini` like its neighbours,
  items «результат», «изменения», «оригинал» (`PanelReplyView`, a `CaseIterable` enum with
  Russian names in `RussianCopy`). «результат»/«изменения» write `settings.showsChangeDetail`
  through a coordinator hook, like степень/стиль; «оригинал» is
  `HotkeyCoordinator.showsOriginal`, a per-presentation flag cleared in `handlePress`,
  `switchOperation(to:)` and `anotherVariant()`, never persisted. The row is drawn only for
  правка, as today, and the menu is disabled while a run is in flight, like its neighbours.
  **The row is measured with three menus** (`Scripts/panel-proofread-row.swift`, item 4)
  before this is believed to fit in 272 pt; the script's stacked fallback is the fallback.
- **`PanelStatus.Kind`** gains `.summary`: `showsSpinner` false, `symbol` `checkmark.circle`,
  colour `.secondary`. `status(for:…)` gains `changes: ChangeSet?`; for `.finished` with
  `operation == .proofread` and a non-nil set it returns
  `PanelStatus(kind: .summary, message: RussianCopy.proofreadSummary(changes), offersRetry: false)`
  — «Исправлено: 6 изменений», «Изменений нет», «Изменения не отмечены: текст слишком длинный».
  Every other `.finished` stays nil. The `CaseIterable` tests over `Kind` are extended, which is
  what that conformance exists for.
- **`announcement(for:operation:changes:)`**: «Правка готова, 6 изменений» / «Правка готова,
  изменений нет»; unchanged for перевод.
- **`PanelSizer.minHeight` and `dragMinHeight` are re-measured** (item 5) in the states that pin
  the most, now including «finished правка, summary row, three menus» at 300 pt, and their
  tables updated; `TranslationPanel.contentMinSize` follows `dragMinHeight` as it does today.
- Copy and ⏎ go through `TranslatorApp.panelRichFlavour()` → `PanelView.richFlavour`, which
  calls `PaneRendering` and takes no change set. Unchanged, pinned.

## Testing decisions

Swift Testing, behaviour-named, offline, under `docs/reference/TESTING.md`'s mutation rule: each
test below names a mutation it fails under.

**Step 1 — `Tests/TranslationCoreTests/TextDiffTests.swift`, `ProofreaderTests.swift`,
`MarkdownPlainTextTests.swift`**

- Tokenizer: «кто-нибудь» is one token and «кто — нибудь» is three; «don’t» is one; a double
  space between two words yields the same tokens as a single one; each token's range slices
  its own text back out (fails if ranges are off by one).
- «отчет за август» → «отчёт за август» is exactly one `.words` change with `removed ==
  "отчет"`, `inserted == "отчёт"`, `insertedTokens == 0..<1` (fails under case-folding or
  «е»/«ё» folding).
- «посмотрите пожалуйста до» → «посмотрите, пожалуйста, до» is **one** change under
  `mergeGap 1` and **two** under `mergeGap 0` — the constant is exercised, not restated.
- A paragraph whose every second word changed collapses to one `.block` change; the same
  paragraph with one word changed does not; the threshold is passed as a parameter in the test
  and the boundary case at exactly the threshold is pinned on the side the code takes.
- A reordered sentence (similarity 1, many edits) collapses through the post-Myers check
  (fails if only the pre-check exists).
- A source with a fenced block whose contents differ in the result produces no change for
  that block (fails if code is diffed).
- Equal block counts pair by index even when a middle block is wholly rewritten; a result with
  one extra paragraph yields one inserted `.block` change and pairs the rest correctly
  (fails under naive index pairing).
- A document over `inspectionLimit` tokens (the limit passed in) yields `notCompared ==
  .tooLong` and an empty change list; one under it yields a list.
- `Translator.proofread` through `FakeLLMClient`: the outcome's `changes` is non-nil, its count
  matches the fake's edit, and `translate` returns `changes == nil`. A cancellation during the
  run still surfaces `CancellationError` (the diff's `checkCancellation` is the mutation).
- `MarkdownPlainText.render(_:)` over the existing fixtures is byte-identical before and after
  the per-block refactor (a golden test over the current outputs, written *before* the
  refactor).
- `translate-cli`: `--changes-json` without `--proofread` is refused; with it the output parses.

**Step 2 — `Tests/MarkupKitTests/ChangeMarksTests.swift`, `MarkdownToAttributedTests.swift`**

- `blockRanges.count == blocks.count` for a document with every block kind, the ranges tile
  the string without gaps, and `plainRendering`'s ranges equal the scanner's ranges in UTF-16.
- In `.result` detail the marked rendering's `string` equals the clean rendering's `string`
  (fails if any character is inserted) and the underlined ranges, read back through
  `changeKey`, slice out exactly `inserted` for a words change in a paragraph, in a heading,
  in a list item (dotted), in a table cell (dotted) and in the raw «Исходник» rendering of the
  same document with `**` around the changed word (fails if the aligner cannot skip markers).
- In `.changes` detail the removed text appears struck through immediately before the
  underlined range, `codeRegions` after the insertion point are shifted by exactly its length,
  and a `.block` removal appears as its own paragraph.
- A change whose tokens cannot be aligned (a fixture whose projection and rendering disagree on
  purpose) leaves the block unmarked and the other blocks marked.
- The clean rendering's `rtf` contains no `\strike` and is byte-identical whether or not a
  change set exists for the document (shape 5 of TESTING.md: the test calls the real copy path,
  `PaneRendering.rtf(of:font:)`, not the builder).
- `underlineStyle(for:)` answers `.single` at 16 and `.thick` at 17 (boundary pinned).

**Step 3 — `Tests/TranslatorAppTests/`: `RenderedMarkupTests`, `TranslationViewModelTests`,
`RussianCopyTests`, `AppSettingsTests`, a new `PaneViewChoiceTests`**

- `PaneViewChoice`: the six (setting, setting) → segment mappings and the three writes; picking
  «Исходник» leaves `showsChangeDetail` as it was (fails if it resets).
- `RenderedTextView` with a change set and no markup takes the plain path and its storage
  carries `changeKey` runs; switching `showsChangeDetail` rebuilds the storage (string length
  changes); `changeCursor = 2` sets the selection to the third change's range.
- `stepChange(by:)` wraps at both ends and is a no-op with no changes; the cursor is nil after
  a new run's first token, after `swapLanguages()` and after `adopt(from:)`.
- `RussianCopy.changeCount`: 0, 1, 2, 5, 11, 21, 104 (the `plural` edge cases, shape 2:
  each asserted separately).
- `showsChangeDetail` round-trips through `InMemoryDefaults` and defaults to false.
- The «Перевод» menu items' enablement rule as a value (`ChangeNavigation.isAvailable(mode:
  changes:)`), because the menu itself cannot be rendered here.

**Step 4 — `PanelViewTests`, `PanelRenderedReplyTests`, `TranslationPanelTests`,
`HotkeyCoordinatorTests`**

- `rendersFinalReply` is true for a finished prose правка with changes and
  `showsRenderedMarkup == false` (fails if the markup clause is still required), false while
  running, false with `awaitingRun`.
- `status(for: .finished, operation: .proofread, changes: set)` is `.summary` with the count
  sentence; the same with `operation: .translate` is nil; `.summary` is in `Kind.allCases` and
  the glyph-rule test over `allCases` passes without a hand-written list.
- `announcement` says the count.
- `RenderedReplyView.measuredSize` for the `.changes` detail is ≥ the `.result` detail's at
  the same width for the fixture (the deleted text costs height, never saves it).
- `showsOriginal` is cleared by `handlePress`, `switchOperation`, `anotherVariant`.
- The real `PanelView`, measured through `PanelController` as the existing sizing tests do, in
  «finished правка with summary and three menus» at 300 pt: its pinned block fits under the
  re-measured `dragMinHeight` (the number the measurement produces is asserted, not a bound).

## Out of scope

- Per-change accept/reject («Вернуть») and the «было → стало» popover — phase 2, after the
  marks have been looked at and §«Measurement protocol» item 6 has been probed.
- Explanations per change — still waits on a model that can produce them under the acceptance
  harness's discipline.
- Marks for перевод, for the file queue, and for `acceptance`.
- Any change to the RTF flavour, to «Заменить», or to the streaming path on either surface.
- A settings-window control for `showsChangeDetail`; the picker and the menu are the controls.
- Character-level highlighting inside a changed word (Apple, Word and DeepL all mark words).

## Deviations from the design

1. **The stepper lives in the status bar, not in the pane header.** The design put «‹ 3 из 7 ›»
   in the header; the header at the pane's 280 pt minimum already holds a picker and two link
   buttons, and the status bar's finished line is the row that says «Готово за … мс» and has the
   width. The menu items are what a keyboard user reaches for either way.
2. **One picker with three segments, not two pickers.** The design gave правка «Результат |
   Изменения» *instead of* «Разметка | Исходник» and sent the raw view to the source pane's
   toggle; that toggle *is* this one control, drawn in this header for both panes. Three
   segments keep one control and keep «Исходник» reachable; the mapping is a tested value.

The design's §7.5–7.6 should be annotated with a pointer to this section when the code lands,
not rewritten.

## Measurement protocol

Each item produces a number that replaces a *start* value or gates a step. Record every figure
in `docs/reference/MEASUREMENTS.md` under a new «Durable — change marks» heading, with the
date, the machine and the model.

1. **`densityThreshold`.** `Scripts/change-density.sh`: the правка corpus, each text through
   `translate-cli --proofread --changes-json` at `errorsOnly`, `errorsAndStyle` and `rewrite`,
   on the model `AppSettings.proofreadModel` names (and on the translation model when they
   differ), three runs each, serially from the main session. Collect every `blocks[]` entry;
   plot `1 − similarity` and `changedTokens/(sourceTokens+resultTokens)` per степень. The
   threshold is the value that puts ≥ 90 % of `errorsOnly` blocks below it and ≥ 90 % of
   `rewrite` blocks that a reader would call rewritten above it; if no single value does both,
   record the two distributions and keep 0.5 with that finding beside it.
2. **`inspectionLimit`, `blockTokenLimit`, and the settle's cost.** `Scripts/text-diff-cost.swift`
   times `TextDiff.changes` on: the 256 KB `DroppedDocument` ceiling of prose with 1 % of words
   changed; the same with every other word changed; one 4 000-token paragraph reordered; and
   200 paragraphs each rewritten. The limits are set so the worst case stays under 50 ms on
   this machine, and the figure is written into each constant's comment.
3. **The pane header at 280 pt.** A script in the manner of `Scripts/toolbar-fit.swift`
   measuring `PaneHeader` with «Правка», the three-segment picker, «Ещё вариант» and
   «Скопировать» through a detached `NSHostingController`'s `fittingSize`. Decides segmented
   versus `.menu` for правка.
4. **The panel row with three menus.** `Scripts/panel-proofread-row.swift` extended with the
   «Вид» picker at its longest label («вид: изменения»); decides inline versus stacked.
5. **`PanelSizer.minHeight` / `dragMinHeight`.** The existing tables re-taken with the new
   states, at 300 pt.
6. **The find indicator over an underline, and the popover anchor** (phase 2's gate): a probe
   in the manner of `Scripts/panel-rendered-measure.swift` showing `showFindIndicator(for:)`
   on a `CodeBlockTextView` inside an `NSHostingView`, and `NSPopover.show(relativeTo:of:)`
   anchored to `boundingRect(forGlyphRange:in:)` surviving a scroll.
7. **Underline contrast.** `Scripts/accent-contrast.swift` extended: the accent under
   label-coloured text at 11, 13, 17, 22 and 32 pt on both appearances for every accent macOS
   offers; the finding decides whether `.thick` from 17 pt is right or the break moves.

## What only a human can check

Rows for `docs/reference/OPEN-ITEMS.md` §1 when the code exists:

- An underlined change beside a link on the default accent: both blue, both underlined. If
  they confuse, every change mark becomes `.patternDot` and the design's §12 is answered.
- The «Изменения» view of a rewritten paragraph — struck paragraph above the new one — not
  reading as two paragraphs of the result.
- The find indicator's bubble over a 13 pt underline and over a 32 pt one.
- «Готово за 1 812 мс · 6 изменений ‹ ›» in the status bar at the window's 700 pt minimum,
  with the warnings chevron beside it.
- The panel's «Вид» menu beside степень and стиль at 300 pt, and the summary row under a
  one-line reply not opening a hole above the buttons.
- Whether «Изменений нет» in the status bar is enough for a clean «только ошибки» run, or the
  pane wants a word too.

## Pull requests, in order

1. `feat(core): word-level change set for правка` — step 1, `TextDiff`, tokenizer,
   `MarkdownPlainText.plain(_:in:)`, `TranslationOutcome.changes`, CLI lines, tests.
2. `feat(markup): change marks over the rendering` — step 2, `blockRanges`, `plainRendering`,
   `ChangeMarks`, tests including the RTF pin.
3. `feat(app): «Результат | Изменения | Исходник», the count and the stepper` — step 3, with
   measurements 3 and the ⌘G dump recorded in the declarations they decide.
4. `feat(app): the panel's marks, «Вид» and «Исправлено: N изменений»` — step 4, with
   measurements 4 and 5 and the updated `PanelSizer` tables.
5. `docs: change marks measured` — measurements 1, 2 and 7; the constants updated; the ADR
   («Change marks are shapes in one tint, computed locally, never copied»); `CLAUDE.md`,
   `CONTEXT.md` («изменение», «Результат»/«Изменения», «Вид», «оригинал» — and why not
   «исходник», which already means the raw form of a pane), `MEASUREMENTS.md`,
   `OPEN-ITEMS.md`, `PLATFORM-TRAPS.md` if item 6 finds anything, and the правка design's
   §10.1 marked as designed and specified here.

Each pull request builds with tests at zero warnings and runs the suite; a warning is a
failure of the pull request, not a note in it.
