# Presenting content: prose, documents, code and changes — design

Date: 2026-09-04
Status: designed, not implemented

## Status of this document

This is an analysis of how the app shows what comes back — in the window's right pane and in
the floating panel — measured against Apple's own guidance and apps and against the products
this app is compared with, ending in one proposal. Once code exists for §7, **the code is the
authority on behaviour and this document is the authority on why.**

Three kinds of claim, marked as such:

- **In the code** restates something `Sources/` already does; the pointer says where. §1 is
  entirely this kind and was read on 2026-09-04 from `TranslationPane.swift`,
  `RenderedTextView.swift`, `RenderedReplyView.swift`, `PanelView.swift`,
  `TranslationPanel.swift` and `MarkupKit/MarkdownToAttributed.swift`.
- **Cited** quotes a primary source fetched on 2026-09-04. Apple pages were read through their
  `developer.apple.com/tutorials/data/*.json` bodies and `support.apple.com` HTML (a local hook
  blocked the fetch tool for every URL; `curl` was used). Products change; the URL says what was
  read.
- Everything else is intent, and §11 lists what has to be measured before it is trusted.

The formatting design of 2026-08-31 decided *how* Markdown is drawn and is not reopened here.
This document decides **what each kind of content should look like** on top of that, and adds
the one capability that design and the правка design both left open: showing what a правка
changed (`2026-08-10-proofreading-design.md` §10.1, «the designated first fast-follow»).

---

## 1. What the two surfaces do today

In the code, and correct — this section exists so §5–§8 can say what changes against it.

- **One converter, one gate, one setting.** `MarkdownToAttributed` (`MarkupKit`) is the only
  Markdown → `NSAttributedString` path; the same attributed document is what «Скопировать»
  writes as `public.rtf`. `MarkdownPresence.hasMarkup` (first 128 KB) decides whether anything
  is rendered at all; `AppSettings.showsRenderedMarkup` («Разметка | Исходник») is one key read
  by the window's pane and the panel alike. `ContentFont` (13 pt system by default, 11–32) is
  the only size anything in the content scales from — `docs/adr/0008`.
- **The window's pane** (`TranslationPane`) has three states: placeholder; a hosted read-only
  TextKit 1 `NSTextView` (`RenderedTextView`) whenever there is markup, in both «Разметка» and
  «Исходник»; a selectable SwiftUI `Text` when there is none. While a run streams it appends
  *settled* blocks (`MarkdownBlockScanner.settledPrefix`) and keeps the unsettled tail as plain
  characters, replacing only the tail region of the storage. Code blocks are cards with a
  language label and an always-visible «Скопировать» drawn as overlays. The исходник pane reads
  the same toggle (`SourcePaneMode`).
- **The panel** (`PanelView`) streams plain characters and renders once, at the settle
  (`PanelView.rendersFinalReply`: run ended, no press starting, markup present, setting on),
  through `RenderedReplyView` — a bare `NSTextView` with its own `sizeThatFits`, because the
  panel's size comes from a detached measuring host. Three sections: pinned header, a
  stretching middle (reply + warnings, the only region that scrolls), pinned status and buttons.
  A hidden copy of the source reserves the reply's room while the run is in flight.
- **Правка** shows the corrected text exactly as перевод shows a translation. Nothing on either
  surface says what changed; the исходник pane is the only «original».
- **Warnings** (`WarningsView`) describe structure loss and glossary misses in words —
  «потеряно: заголовок 2-го уровня» — under the text, never in it.

---

## 2. The content the app actually shows

Twelve shapes reach the panes. They fall into three presentation classes plus one overlay, and
the design below is written per class, not per shape.

| # | Shape | Arrives from | Class |
|---|---|---|---|
| 1 | A sentence or a paragraph of prose | hotkey selection, chat, mail | **Prose** |
| 2 | Several paragraphs of prose | selection, pasted mail, `.txt` | Prose |
| 3 | Prose with hard line breaks (address, verse, a list with no markers) | selection | Prose |
| 4 | «•» / «–» bullet lines | mail, chat, Word | Prose, drawn as a list (`PlainBulletList`) |
| 5 | A quoted reply (`>` lines) and a signature | mail | Document (blockquote) + Prose |
| 6 | A Markdown document: headings, lists, tables, quotes, links, emphasis, rules | `.md`, README, queue | **Document** |
| 7 | Rich pasteboard content — a table or list from a browser or Word, converted by `RichMarkdown` | ⌘C fallback, ⌘V | Document |
| 8 | Fenced code inside prose | README, chat | Document with **Code** blocks |
| 9 | Inline code and bare URLs | docs, chat | Document (inline) |
| 10 | A selection that is entirely code, unfenced | IDE, terminal | Prose to the pipeline, deliberately — indentation is not a code signal |
| 11 | A flat text the «Оформить» pass gave structure to | any | Document, **synthesised** |
| 12 | A правка result | operations «только ошибки» / «ошибки и стиль» / «переписать» | any class above, plus the **changes overlay** (§7) |

Two things about the table are decisions already made and kept: shape 10 stays prose
(`docs/design/specs/2026-08-07-lossless-chunking-design.md`), and shape 4 is a display decision
only — the scanner hands a paragraph to the chunker, the skeleton and «Заменить».

---

## 3. What Apple does, and what was taken

Cited. Only the findings that changed or confirmed a decision below.

- **Typography.** macOS default text size is 13 pt, minimum 10 pt; «macOS doesn’t support
  Dynamic Type»; the text styles are Large Title 26/32, Title 1 22/26, Title 2 17/22, Title 3
  15/20, Headline 13 bold, Body 13/16, Callout 12, Subheadline 11, Footnote 10, Caption 10.
  «Prioritize important content when responding to text-size changes … they don’t always want to
  increase the size of every word on the screen.» «In general, avoid light font weights.»
  «Minimize the number of typefaces you use.» For wide columns or long passages «more space
  between lines (loose leading) can make it easier for people to keep their place».
  — https://developer.apple.com/design/human-interface-guidelines/typography
  **Taken:** `docs/adr/0008` is that sentence in code — only the user's text scales. The heading
  ladder ×1.6/1.4/1.25/1.1 sits between the Title 1…3 ratios (1.69/1.31/1.15) and needs no
  change. Nothing in the content is drawn lighter than Regular; nothing below 11 pt.
- **Writing Tools (Proofread).** «All changes are underlined with a glowing line.» The user can
  «Switch between the updated and original versions», «View changes and an explanation for each
  change: Click ‹ and ›», «Revert», «Done». Rewrite: «A rewritten version of your text appears
  inline. If you selected text in a read-only document (like a PDF), the text appears in the
  Writing Tools dialog»; there «Copy»; «Replace doesn’t appear if the original text can’t be
  edited». — https://support.apple.com/guide/mac-help/mchldcd6c260/mac
  WWDC24: «For proofreading, the suggested changes are applied to the text view automatically.
  User can review and reject individual suggestions.» «When the text is long, the rewritten text
  may be delivered to the text view in separate chunks. We apply animations to the text being
  processed.» Code blocks and quotes are ranges the tool ignores; lists and tables travel as
  `NSTextList` / `NSTextTable`. — https://developer.apple.com/videos/play/wwdc2024/10168/
  WWDC25: «For proofreading, Writing Tools shows an underline for text ranges that were
  changed» and a click shows «the inline proofreading popup». A TextKit 1 view «will get a
  limited experience that just shows rewritten results in a panel».
  — https://developer.apple.com/videos/play/wwdc2025/265/
  **Taken:** the whole of §7 — the corrected text is the default view, changes are *underlined*
  in it, there is a stepper and an «Оригинал» switch, and the panel (a read-only context, like
  Apple's PDF case) offers «Скопировать» and «Заменить» rather than editing in place. Also
  confirmed: the app's own protected ranges — fenced code is never sent to the model, so it can
  never carry a change mark.
- **Translate.** The context-menu popover: language pop-ups, «Copy Translation», «Replace with
  Translation». — https://support.apple.com/guide/mac-help/mchldd8b3c15/mac
  Live Translation in Messages: «Translations appear inline» under the original.
  — https://support.apple.com/guide/mac-help/translate-messages-and-calls-mchl58dfbdba/mac
  **Taken:** the panel's «Скопировать» / «Заменить» pair already mirrors the popover. Apple
  documents controls, not layout — no primary source describes the popover's typography.
- **Generative AI.** «Consider giving specific, reassuring feedback during generation … instead
  of ‘Processing…’, say ‘Summarizing key themes from your notes.’» «Make it easy for people to
  refine or revert generated results … controls like Edit, Undo, Retry, or Adjust near generated
  content.» — https://developer.apple.com/design/human-interface-guidelines/generative-ai
  **Taken:** «Перевожу…» / «Исправляю…» / «Оформляю…» are the specific verbs; «Ещё вариант»,
  «Повторить» and «Заменить» sit beside the text. Confirmed, not changed.
- **Colour and accessibility.** «When you use color to convey information, be sure to provide
  the same information in alternative ways.» «Avoid redefining the semantic meanings of dynamic
  system colors.» Apple defines **no** semantic insertion/deletion colours.
  — https://developer.apple.com/design/human-interface-guidelines/color ,
  https://developer.apple.com/design/human-interface-guidelines/accessibility
  **Taken:** §7's marks carry meaning by *shape* (underline = changed, strikethrough = removed);
  the colour is one tint and never `StatusColour`'s warning/failure, which already mean
  something else in this app. Pages' own model is one colour per author plus a strikethrough
  for deletions, change bars in the margin, and «Final» / «Markup» / «Markup Without Deletions»
  views. — https://support.apple.com/guide/pages/track-changes-tan2685b84ff/mac
- **Xcode.** «The source editor displays a change bar in the gutter. If you hover over the
  change bar, the source editor highlights both the lines and the text»; inline comparison by
  default, side by side on request.
  — https://developer.apple.com/documentation/xcode/tracking-code-changes-in-a-source-control-repository
  **Taken:** inline by default; the исходник pane *is* the side-by-side view and needs no
  second one.
- **Text views and feedback.** «Use a text view when you need to display text that’s long,
  editable, or in a special format»; «Make useful text selectable.»
  — https://developer.apple.com/design/human-interface-guidelines/text-views
  «Display status information in a passive way»; people «only need to know when it doesn’t
  [succeed]». — https://developer.apple.com/design/human-interface-guidelines/feedback
  **Taken:** the text view over a stack of `Text`s (already decided, 2026-08-31 §6); a finished
  run keeps saying nothing, except that a правка now says how many changes it made.
- **VoiceOver.** «Inform VoiceOver when visible content or layout changes occur.»
  — https://developer.apple.com/design/human-interface-guidelines/voiceover
  **Taken:** the settle announcement gains the change count; the stepper moves the selection so
  each change is read in context.

---

## 4. What mature products do, and what was taken

Cited; help-centre pages behind Cloudflare were read through search excerpts and are marked.

- **Word.** «Simple Markup displays tracked changes with a red line in the margin. All Markup
  displays tracked changes with different colors of text and lines … No Markup … Original.»
  «Deletions are marked with a strikethrough, and additions are marked with an underline.»
  — https://support.microsoft.com/en-us/office/track-changes-in-word-197ba630-0f5f-4a8e-9a77-3712475e806a
  Copilot's rewrite presents «rewritten options to choose from» with Replace / Insert below /
  Regenerate — candidates, not a diff.
  — https://support.microsoft.com/en-us/word/copilot/rewrite-text-with-copilot-in-word
  **Taken:** the two-view model («Результат» ≈ Simple Markup without the margin bar,
  «Изменения» ≈ All Markup) and the rule that a free rewrite is a *candidate*, which is why
  «переписать» opens in «Результат» and the density rule (§7.4) collapses word confetti.
- **DeepL Write** (excerpts of support.deepl.com): changes «are marked in green»; a «Show
  changes» toggle; click a highlight for «Replace word» / «Rephrase sentence».
  — https://support.deepl.com/hc/en-us/articles/11673757647388-Use-DeepL-Write
  **Taken:** the toggle's existence and its default (off — the clean text first).
- **Grammarly.** Underline colours by category, cards with Accept / Dismiss.
  — https://support.grammarly.com/hc/en-us/articles/360003474732-Grammarly-Editor-user-guide
  **Not taken:** categories need explanations, and explanations need structured output from a
  local model — still deferred (правка design §10.1). One tint, not four.
- **GitHub.** Markdown files carry a «Code» button to see the source; the rendered prose diff
  marks non-text changes with «a low-key dotted underline. Hover over the text to see what has
  changed». Typography: h1 2 em … h6 0.85 em semibold, `pre` at 85 % with `overflow: auto`.
  — https://docs.github.com/en/repositories/working-with-files/using-files/working-with-non-code-files ,
  https://github.blog/2014-02-14-rendered-prose-diffs/
  **Taken:** the dotted underline is the mark for a change *inside* structure (a table cell, a
  list item) where a coloured run would fight the block's own drawing; and code does **not**
  shrink — 85 % of 13 pt is 11 pt, the content floor, and `docs/adr/0008` scales code with the
  text.
- **Streamed Markdown** (Vercel, Streamdown): unclosed fences and half-finished emphasis «fail
  to render, leak raw Markdown, or disrupt layout»; the fixes are block memoisation (only the
  tail re-renders), auto-closing markers for display, and a per-block copy button «automatically
  disabled during streaming».
  — https://ai-sdk.dev/cookbook/next/markdown-chatbot-with-memoization ,
  https://streamdown.ai/docs/termination , https://streamdown.ai/docs/code-blocks
  **Taken as confirmation:** `settledPrefix` is block memoisation with a stronger promise (a
  block never changes kind after it is drawn), and a code card exists only once its fence has
  closed, so its button is never live on half a block. **Not taken:** auto-closing markers in
  the tail — the tail is drawn as the Markdown it currently is, on purpose (formatting design
  §7), and a fabricated close would show a heading that may not be one.
- **Diff readability.** The one controlled experiment found compares split and unified views
  *of code* and measures «no significant difference» (24 participants).
  — https://bergel.eu/MyPapers/Coss20a-SplitOrUnified.pdf
  No study of word-level versus character-level marks for prose was found; tool practice
  (Kaleidoscope, Meld) is word-level inside a changed region. **Taken:** word-level tokens, and
  no claim that this is measured — §11 makes it a thing to look at.

---

## 5. Principles

Five rules; every table below is derived from them.

1. **The text is the user's; the app only dresses it.** Nothing changes the bytes the pane shows
   or copies — marks, cards, list bullets and change highlights are *attributes and overlays*,
   never characters. This is the formatting design's invariant extended to §7: a правка's marks
   are review furniture and must not reach the pasteboard or «Заменить».
2. **One typographic system, sized from one number.** `ContentFont.size` is the base; every
   run is a multiple of it or exactly it; nothing is lighter than Regular; nothing is below
   11 pt. Chrome keeps the system size (`docs/adr/0008`, HIG «Prioritize important content»).
3. **Meaning by shape first, colour second.** Underline, strikethrough, a bar, a card border,
   a dotted line — each carries its meaning without colour; colour reinforces and is either a
   semantic system colour or a value held to ≥ 4.5:1 on both appearances by a test
   (`StatusColour`, `SyntaxPalette` precedent). The three status colours are never reused for
   content.
4. **Show the answer plainly; show the work on request.** The default view of any result is the
   clean text (HIG Feedback: passive status; Word Simple Markup; Apple Proofread's underlined
   result). Deletions, raw Markdown and the original are one click away and never the first
   thing on screen.
5. **Nothing moves under a reader.** A drawn block is never redrawn as something else; the
   panel does not reflow while it streams; the swap at the settle may grow the panel and never
   shrink it except at the settle itself. Marks appear at the settle, once. Unchanged from the
   two designs before this one and restated because §7 has to obey it.

---

## 6. The rules, per content class

### 6.1 Prose

- Drawn as it is today: the content font, label colour, paragraphs separated by the document's
  own blank lines. No justification, no hyphenation, no first-line indent — an app that
  translates a chat message must not typeset it like a book.
- **Leading.** Body is 13/16 in Apple's table, and the system font's default leading at 13 pt
  is that ratio; no `lineHeightMultiple` is added. HIG's «loose leading for long passages» is
  answered by the *measure*, not the leading: the panel is capped at 560 pt (75 characters of
  Russian at 13 pt, `docs/adr/0008`), and the window's pane is the user's own split.
- **Hard line breaks** (shape 3) stay where they are; a document with two trailing spaces is
  drawn with the break and the skeleton already guards it (`MarkupToken.hardLineBreak`).
- **Plain bullets** (shape 4) are drawn as a list with `NSTextList`, as today, so the RTF
  flavour arrives in Word as a list and the toggle offers the raw lines back.
- **A selection that is all code, unfenced** (shape 10) is prose and is drawn as prose. Not
  detected, not restyled: a heuristic that guessed «this looks like code» would guess wrong on
  a config-like mail and silently protect prose from translation.

### 6.2 Documents

All in the code since 2026-09-02 and kept; the rows say what each block *means* so that a
future change is judged against the meaning rather than the pixels.

| Block | Rule | Why |
|---|---|---|
| Headings h1–h6 | ×1.6/1.4/1.25/1.1/1.0/1.0 of base, semibold, label colour; spacing before ×0.5 and after ×0.35 of the heading's own size | Sits between Apple's Title 1…3 ratios; semibold and not bold because Body 13 next to Bold 21 is two weights apart and reads as chrome |
| Paragraph | Base, Regular, paragraph spacing ×0.65 | The blank line is spacing, not an empty paragraph, so the rich copy has no stray lines |
| Lists | Hanging indent ×1.4 per level, `NSTextList`, marker in the text (AppKit's own pairing) | A rich paste is a list; a plain paste is the user's bytes |
| Quote | 3 pt bar on the leading edge, secondary label colour, indented per depth | The one visual every reader knows a quote by; a mail's `>` reply reads as a reply |
| Table | Rules between rows, filled semibold header, no column grid, cell padding ×0.4/×0.6 | GitHub/ChatGPT/Claude draw tables this way; a grid reads as a spreadsheet |
| Code block | Card: 1 pt border, quaternary fill, 24 pt header with language and «Скопировать», monospaced at **base size**, syntax colours only with a profile | Base size and not 85 % because the content floor is 11 pt and `docs/adr/0008` scales code with the text |
| Inline code | Monospaced at base, quaternary background, no border | Enough to say «this is a token» without a box inside a sentence |
| Link | Link colour, single underline, pointing-hand cursor; a click opens it | HIG: make useful text selectable; opening a link is the user's explicit act and leaves the machine only then |
| Thematic break | 1 pt rule | A 1 × 1 `NSTextTable` border, because that is what AppKit is measured to lay out |
| Emphasis | Bold / italic via symbolic traits; strikethrough as strikethrough | From Foundation's inline intents; the block layer never re-reads markers |

Two open questions are carried as such rather than decided by fiat: whether a table in a 300 pt
panel should let the panel grow to 560 before wrapping cells (it does today because the natural
width is measured), and whether code lines should wrap by word, by character, or not at all.
The pane and the panel both wrap today because `NSTextContainer.widthTracksTextView` is what
makes the height measurable; a horizontal scroller inside an `NSTextTable` block does not exist
in TextKit 1. The proposal is **wrap by character for code** (`.byCharWrapping` in the card's
paragraph style) so an identifier is never split from its neighbour by a soft break that a word
rule would place at an underscore — measured only by looking (§12).

### 6.3 Code

The card is right and stays. Three things the research adds:

- **The copy button is live only on a settled block**, which is already true by construction
  (a card exists once the fence closes). Streamdown disables it during streaming for the same
  reason; here there is nothing to disable.
- **No colours without a profile**, kept: «a guess about comment syntax is how a URL turns
  green».
- **A правка never marks anything inside a code block** (§7), because the model never saw it
  (`Chunk.passthrough`). Apple ignores `pre` and `blockquote` ranges; this app ignores them one
  layer earlier.

### 6.4 Mail and chat shapes

- A quoted reply is a blockquote and looks like one; a signature is prose. A mail that arrives
  flat is prose; the «Оформить» pass, when on, may recover its list or table (`docs/adr/0011`)
  and then it is a Document.
- Emoji, @-mentions and URLs are characters and are drawn as such; a bare URL is a link only
  when Foundation's inline parser calls it one.

### 6.5 Synthesised structure

A document whose structure came from the «Оформить» pass is drawn exactly like one that arrived
with it; there is no badge on the text. What tells the user is the исходник pane, which shows
the reconstructed source in «Разметка», and the notice under «Оформить не удалось» when the
pass was refused. HIG's «clearly identify when and where you use AI» is met by the setting
being off by default and by its own label; a persistent watermark on the translation would be
noise on every run that used it deliberately.

---

## 7. Правка: showing what changed

The one new capability. Everything above is dressing; this is the trust mechanism the правка
design named and deferred, made without the part that needed a model — the explanations.

### 7.1 Two views and a switch

- **«Результат»** (default): the corrected text, clean, with every changed range underlined.
  This is Apple's Proofread result and Word's Simple Markup minus the margin bar.
- **«Изменения»**: the same text with deletions shown inline, struck through, before the text
  that replaced them — Word All Markup, Pages Markup.
- **«Оригинал»**: the source, unmarked. In the window it already exists — the исходник pane —
  so the window offers only the first two. The panel has no source on screen and offers all
  three.

The switch is a setting, `AppSettings.showsChangeDetail` (false = «Результат»), written by
both surfaces directly — the same treatment as «Разметка | Исходник» and the степень/стиль
pickers, so a choice made where the text is read survives the window closing. «Оригинал» in the
panel is not a setting: it is a per-presentation peek, cleared by `show(at:)`.

### 7.2 The marks

> **Measured away on 2026-09-04, and the code is the authority (`docs/adr/0012`).** Two rows of
> the table below did not survive measurement item 7: the mark is `.patternDot` **everywhere**,
> because `linkColor` against the blue accent is 1.49:1 (light) and 1.14:1 (dark) and the
> preview showed a link and a change told apart by nothing but the pattern; and the tint is the
> accent blended 35 % toward black in the light appearance, because three of the eight accents
> fall under 3:1 on the white pane bare (жёлтый 1.51:1). The «inside a cell or list item» row
> therefore collapsed into the first. The reasoning below is kept as written.

| Mark | Shape | Colour | Where |
|---|---|---|---|
| Changed range | Single underline, `.thick` at ≥ 17 pt base and `.single` below | `controlAccentColor` | «Результат», «Изменения» |
| Removed text | Strikethrough, single | Secondary label colour | «Изменения» only |
| Change inside a cell or list item | Dotted underline (`.patternDot`) | Same tint | Both, when the range's block is a table cell or list item — a coloured run beside a table rule or a bullet fights the block's own drawing (GitHub's rule) |

Colour is one tint because Pages' model is one colour per author and there is one author here.
It is the accent and not `systemGreen`/`systemRed`, because `StatusColour` already spends
green, orange and red on *status* in the same window, and a red strikethrough beside a red
failure line would say two things in one colour — principle 3. The accent's contrast against
the pane is not the mark's contrast: the underline sits under label-coloured text whose own
contrast is untouched, which is why an underline was chosen over a background fill. Apple's own
mark is an underline for the same reason.

### 7.3 The diff

- A word-level diff between the source and the result, computed **locally and deterministically**
  in `TranslationCore` (`TextDiff`, Foundation only, `docs/adr/0007`): tokens are words,
  runs of whitespace and single punctuation marks, matched by `CollectionDifference`
  (`difference(from:)`, Myers, O(ND)); adjacent inserts and removes are merged into one change.
- Per **block**, not per document: the two documents are scanned with `MarkdownBlockScanner`
  and blocks are paired in order — `Translator.proofread` demands structure preservation, and
  a pairing that fails (block counts differ) falls back to one diff over the whole text. Code
  blocks are never diffed; they are pass-through and identical by construction.
- **Bounded** like `MarkdownPresence`: a document over the inspection limit gets no marks and a
  one-line notice under the text — «Изменения не отмечены: текст слишком длинный». The limit is
  a measurement to take (§11), not a guess written here.
- Computed **once, at the settle**, from `TranslationOutcome.final` and the source the run was
  given; never on a streamed token. A mid-stream diff would move marks under a reader.

### 7.4 The density rule

A rewrite is a candidate, not a correction (Word Copilot, Grammarly; §4). Marking every moved
word of a «переписать» paragraph produces confetti that says «everything changed» in the least
readable way. So: **when more than a threshold of a paragraph's tokens changed, the paragraph
carries one mark** — one underline over the whole paragraph in «Результат», and in «Изменения»
the old paragraph struck through above the new one. The threshold is measured on the правка
corpus (§11), with 50 % as the starting point and the answer recorded in
`docs/reference/MEASUREMENTS.md`. Below the threshold, word-level marks; above it, one.

The rule is per paragraph and not per document, so a «переписать» that left half the mail alone
still shows the one sentence it moved.

### 7.5 The window

> **Specified with two deviations** in `2026-09-04-change-marks-spec.md` («Deviations from the
> design»): the stepper lives in the status bar's finished line rather than in the pane header,
> and the header keeps one picker with a third segment («Результат | Изменения | Исходник»)
> rather than swapping pickers. The reasons are there; this section is kept as written.

- The pane header, in правка mode, gains a **stepper** «‹ 3 из 7 ›» beside «Скопировать»:
  each press selects the next change in the text view and scrolls it into view — Apple's ‹ ›,
  Word's Next/Previous. With zero changes the header says «Изменений нет» in the secondary
  colour and there is no stepper; that sentence is the whole answer to «только ошибки» on a
  clean text, and it is worth more than an empty pane.
- The header's segmented control, in правка mode, is **«Результат | Изменения»** where перевод
  has «Разметка | Исходник». A правка result with markup still needs its raw source view; that
  is reached through the исходник pane's own toggle, which `TranslationPane.offersToggle`
  already draws whenever the source has markup. One control per header — two segmented
  pickers side by side is the shape `Scripts/toolbar-fit.swift` exists to refuse.
- Clicking an underlined range shows a **popover** anchored to its glyph rect with «было → стало»
  (old struck through, new plain) and, in phase 2, «Вернуть» — the per-change reject. Phase 1
  ships the popover as a readout: the stepper plus «Изменения» already show the same, and the
  popover exists so a mouse user has the one-click route Apple gives them. Measuring a popover
  off a TextKit 1 glyph rect inside a hosted view is §11's item, not assumed.

### 7.6 The panel

- The reply is rendered at the settle already (`RenderedReplyView`); a правка reply renders
  **whether or not it has markup**, because the marks are attributes and the plain `Text` cannot
  carry them. `PanelView.rendersFinalReply` gains that clause for `operation == .proofread`,
  and the settle-then-swap order is unchanged (grow only).
- The pinned степень/стиль row gains a third `.menu` picker, **«Вид»**: «результат» /
  «изменения» / «оригинал». It is `.mini` like its neighbours and lives in the same 272 pt;
  `Scripts/panel-proofread-row.swift` is re-run with three menus before this is believed
  (§11). No stepper in the panel: a panel holds a paragraph, and the underline finds a change
  in a paragraph without help; a long selection is what «Открыть в окне» is for.
- The status row, empty on `.finished` today, says **«Исправлено: 7 изменений»** — passive
  status in the row that exists for it, and the one line VoiceOver hears. This is 24 pt the
  reservation already books for the running row, so the settle does not grow the panel for it.
- `PanelSizer`'s floors are measurements of the pinned block; a third menu and a status line on
  `.finished` change what that block can be. `minHeight` and `dragMinHeight` are re-measured
  in the states that pin the most, as their comments require.

### 7.7 Copy and «Заменить»

- «Скопировать» and ⏎ write the **clean** result: `.string` as today, and the `.rtf` flavour —
  when there is markup and «Разметка» is on — built by a converter call **without** the change
  attributes. `PaneRendering.rtf(of:font:)` stays the one place the flavour is decided and
  learns nothing about changes, which is how the marks stay out of Word.
- «Заменить» writes the plain result, unchanged. Apple's Revert has no equivalent here because
  the source application was never touched until the user presses the button.
- A selection dragged inside the view copies what any rich text view copies; that carries the
  underline as an attribute. Accepted: the button is the fidelity path and is labelled as such
  in the formatting design; the toggle to «Изменения» is one click from seeing exactly what a
  drag would carry.

### 7.8 Accessibility

- The settle announcement (`PanelView.announcement(for:)`) becomes «Правка готова, 7
  изменений» / «Правка готова, изменений нет».
- The stepper moves the text view's selection, so VoiceOver reads each change in its sentence;
  no custom rotor is built in phase 1.
- Marks are shapes with colour on top; «Уменьшение прозрачности» and «Увеличение контраста»
  change nothing about them, and `accessibilityDisplayShouldDifferentiateWithoutColor` is
  already satisfied because the shape carries the meaning.

### 7.9 Streaming

Nothing changes while a правка streams: the window's pane draws settled blocks and the plain
tail, the panel draws characters. Marks are applied in one storage update at the settle, in the
same turn as the rendered swap, so a reader sees one change of state and not two.

---

## 8. Per-surface rules

| | Window pane | Panel | Queue (same pane) |
|---|---|---|---|
| Streaming | Settled blocks rendered, tail plain | Plain characters | As window |
| Settle | Whole document, one render | Rendered swap, grow only | As window |
| Header control | «Разметка \| Исходник» (перевод) / «Результат \| Изменения» (правка) | None; «Вид» menu in the правка row | «Разметка \| Исходник» |
| Change stepper | Yes, in правка | No | n/a — queue is перевод only |
| Status on finish | Nothing (перевод) / count (правка) in `RunStatusBar` | Nothing / count in the status row | Per-row state as today |
| Copy | Markdown + RTF (clean) per `PaneRendering` | Same rule, plain mid-stream | Same as window |
| Original | The исходник pane | «Вид → оригинал» | The file on disk |

---

## 9. Streaming presentation, restated

Confirmed rather than changed, because both research passes asked the same question:

- The window renders **settled blocks only**; the tail stays plain Markdown; the storage update
  touches the tail region only. This is stronger than the block memoisation the streaming
  renderers converged on, and it is what keeps principle 5.
- The panel **does not render while it streams**. Apple animates the range being processed and
  delivers a long rewrite in chunks; this app's equivalent is the status row's verb and the
  reservation that books the room the reply will need, so the buttons do not jump.
- No tail cursor, no auto-closed markers, no per-token fade. Each was considered and each is a
  fabrication drawn over bytes the model has not sent.

---

## 10. Confirmed and unchanged

Decisions already in the code that the research supports, listed so nobody re-litigates them
on the strength of a screenshot from another product:

- A hosted `NSTextView` rather than a stack of SwiftUI views (selection across the document;
  one converter for pixels and RTF; `NSTextTable` only in TextKit 1). HIG Text views; WWDC24's
  own «TextKit 1 view gets a panel» is a fact about Writing Tools, not an argument here.
- `docs/adr/0008`: only the user's text scales, and the heading ladder is a multiple of it.
  HIG Typography says the same in one sentence.
- Semantic system colours for everything but the two measured palettes.
- Render at the settle in the panel; settled prefix in the window.
- Two pasteboard flavours from one converter; plain «Заменить».
- The «•»/«–» list is display only.
- `MarkdownPresence` decides whether a toggle exists at all.

---

## 11. To be measured, not assumed

Each of these is a number this document does not have, and the code that depends on it must not
be written as though it did.

1. **The density threshold** (§7.4). Run `TextDiff` over the правка corpus at all three степени
   on the models `AppSettings.proofreadModel` names; record the distribution of per-paragraph
   change ratios; pick the threshold that separates «corrected» from «rewritten» paragraphs
   and record it in `docs/reference/MEASUREMENTS.md`.
2. **The diff's bound** (§7.3). Time `TextDiff` on the 256 KB `DroppedDocument` ceiling and on
   a worst case (every other word changed); set the inspection limit from that, the way
   `MarkdownPresence.inspectionLimit` was set.
3. **The panel's floors** (§7.6). Re-take `PanelSizer.minHeight` / `dragMinHeight` with the
   «Вид» menu and a status line on `.finished`, at 300 pt, in the states that pin the most;
   re-run `Scripts/panel-proofread-row.swift` with three menus.
4. **The popover off a glyph rect** (§7.5). A probe in the style of
   `Scripts/panel-rendered-measure.swift`: does `NSPopover.show(relativeTo:of:)` anchored to
   `boundingRect(forGlyphRange:in:)` of a `CodeBlockTextView` inside an `NSHostingView` land on
   the glyphs, and does it survive the pane scrolling.
5. **Underline thickness against the accent** at 11, 13, 17, 22 and 32 pt, both appearances —
   an extension of `Scripts/accent-contrast.swift`, because the accent is the user's choice
   and «Graphite» is not «Blue».
6. **Character wrapping for code** (§6.2): draw the `renderPreview` fixtures with
   `.byCharWrapping` on the card and look; the number here is a judgement, and the PNGs are
   how it is made.

---

## 12. What only a human can check

`docs/reference/OPEN-ITEMS.md` §1 gains these rows when the code exists.

- The underline reading as «changed» and not as a link: the link colour is blue on the default
  accent, and both are underlined. If a screen says they confuse, the change mark moves to a
  dotted pattern everywhere rather than only inside blocks.
- The «Изменения» view of a paragraph above the threshold — old struck through above new — not
  reading as two paragraphs of the result.
- The popover's placement and dismissal against a scrolling pane.
- The panel's «Вид» menu fitting beside степень and стиль at 300 pt.
- Whether «Изменений нет» in the pane header is enough, or whether a clean «только ошибки» run
  needs the status bar to say it too.

---

## 13. Rejected alternatives

- **Four Grammarly-style categories with colours.** Categories need a model to name them;
  structured output from a local 8–27B model is the investigation the правка design deferred,
  and four colours in a pane that already carries three status colours and six syntax colours
  would exceed what a reader can hold. One tint, shapes first.
- **Red/green for removed/added.** Word does it with author colours, DeepL Write with green
  alone. Here red and green are `StatusColour`'s and mean «failed» and «ready» in the same
  window; borrowing them for content breaks principle 3 and HIG's «avoid redefining the
  semantic meanings».
- **Background fills instead of underlines.** A fill changes the text's contrast against its
  ground on every accent and both appearances; an underline leaves label-on-pane untouched.
  Apple's own Proofread mark is an underline.
- **A side-by-side diff pane.** The исходник pane is the side-by-side view; a third column
  is a second window's worth of chrome for the one experiment found, which measured no
  difference between split and unified.
- **Explanations per change.** Deferred as before; nothing here forecloses them — the popover
  of §7.5 is where they would go.
- **Per-change accept/reject in phase 1.** Rejecting a change means editing the result and
  re-deriving the diff against a text that is no longer the model's; it is a real feature with
  its own undo story and is phase 2, after the marks have been looked at.
- **Rendering the panel's stream.** Rejected in 2026-08-31 §7 and still: a reflowing layout at
  300–560 pt is worse than raw markers, and the sizer is tuned against characters.
- **Auto-closing half-arrived markers in the tail.** A fabricated heading is worse than a
  visible `#`.
- **Shrinking code to 85 %** (GitHub). 11 pt is the floor and code is the user's text.
- **A badge on synthesised structure.** Noise on every deliberate use; the source pane and the
  notice already say it.

---

## 14. Phasing

1. **Marks.** `TextDiff` in `TranslationCore` with tests (pinned on fixtures, including the
   merge of adjacent ops and the per-block pairing); `MarkdownToAttributed.rendering(of:config:
   changes:)` applying attributes over the clean rendering; `RenderedTextView` and
   `RenderedReplyView` taking the change set; «Результат | Изменения» in the pane header;
   the stepper; «Вид» in the panel row; the status line and the announcement; the density rule
   with the measured threshold; the bound. Gated on §11 items 1–3 and 5.
2. **The popover** («было → стало»), gated on §11 item 4; then «Вернуть» per change, with the
   result re-derived and the diff recomputed against the edited result.
3. **Explanations**, when a model can be made to produce them under the acceptance harness's
   discipline — unchanged from the правка design.
4. **Cosmetics judged from `renderPreview` PNGs**: character wrapping for code; the table in a
   300 pt panel; anything §12 turns up.

---

## 15. Documents to update when the code exists

- `CLAUDE.md`: the перевод pane's paragraph gains the правка marks, the header's second
  segmented state, and the rule that the RTF flavour is built without them.
- `CONTEXT.md` → «Правка»: **изменение** (a changed range), **«Результат» / «Изменения»**,
  **«Вид»** (the panel's menu); avoid «диф», «правки» for the marks (collides with the operation).
- `docs/adr/`: a short ADR — «Change marks are shapes in one tint, computed locally, never
  copied» — because the colour decision will be questioned by the first screenshot of Word.
- `docs/reference/MEASUREMENTS.md`: the threshold, the bound, the re-taken floors.
- `docs/reference/PLATFORM-TRAPS.md`: whatever §11 item 4 finds about popovers off glyph rects.
- `docs/reference/OPEN-ITEMS.md` §1: the rows in §12.
- `docs/design/specs/2026-08-10-proofreading-design.md` §10.1: mark as designed here.
