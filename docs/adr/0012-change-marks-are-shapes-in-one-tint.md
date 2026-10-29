# Change marks are shapes in one tint, computed locally, and never copied

Date: 2026-09-04. Status: accepted; amended 2026-10-29 (below). Spec: GitHub issue #81;
`docs/design/specs/2026-09-04-change-marks-spec.md` (how),
`docs/design/specs/2026-09-04-content-presentation-design.md` §7 (why).

## Context

A правка run used to return the corrected text and nothing else: the window showed it beside
the исходник, the panel showed it alone, and under «только ошибки» the user was asked to take a
minimal diff on faith. The правка design of 2026-08-10 named change highlighting «the designated
first fast-follow» and deferred it because the version it imagined — Apple's Proofread, an
underline *with an explanation* per fix — needs structured output from a local model, which is
a quality investigation of its own.

The 2026-09-04 design separated the two halves. The explanations still need a model. The marks
do not: the difference between the source and the result is a computation this app can make
itself, deterministically, in the domain layer.

## Decision

1. **The diff is local and deterministic.** `TextDiff` (`TranslationCore`, Foundation only)
   compares the source and the result block by block over their plain projections
   (`MarkdownPlainText.plain(_:in:)`), token by token (`TextTokenizer`: words and marks,
   whitespace a boundary), through `CollectionDifference`. It runs once, at the settle, inside
   `Translator.proofread`, and travels in `TranslationOutcome.changes`. No model is asked
   anything about what it changed.
2. **A rewritten paragraph is one change, not confetti.** Below a similarity threshold, or above
   a changed-token ratio, a block carries one block-scope change (`densityThreshold`, measured
   by `Scripts/change-density.sh`). A rewrite is a candidate text, and every product surveyed
   shows candidates rather than word diffs (Word Copilot, Grammarly, DeepL Write's default).
3. **Marks are attributes; the «Изменения» view is a second string.** In «Результат» the
   storage is byte-identical to the clean rendering; only `.underlineStyle`, `.underlineColor`
   and `ChangeMarks.changeKey` are added. «Изменения» splices the removed words in as
   characters, struck through in the secondary label colour, and is therefore a different
   document — the way «Исходник» is.
4. **The mark is a dotted underline in one tint, and the tint is the accent, darkened where it
   has to be.** Shape carries the meaning: dotted underline = changed, strikethrough = removed.
   The tint is `controlAccentColor`. *As first decided* it was blended 35 % toward black in
   the light appearance, because against the white pane three of the eight accents fell under
   the 3:1 non-text floor (оранжевый 2.31:1, зелёный 2.22:1, жёлтый 1.51:1). *Since the
   2026-10-29 amendment* it is moved toward the ink only as far as each accent needs to clear
   3.5:1 against every ground the marks are drawn on — see below for why the blend failed. It is dotted *everywhere*, not only inside tables and lists as first drawn,
   because `linkColor` against the blue accent is 1.49:1 (light) and 1.14:1 (dark) — the same
   colour — and a link and a change in one sentence were told apart by nothing until the
   pattern differed (`renderChangesPreview`, 2026-09-04). `ChangeMarksColourTests` holds every
   accent preset in both appearances against every measured ground.
5. **Marks are never copied and never written back.** `PaneRendering.rtf(of:font:)` and both
   `richFlavour()` call sites take no change set; the RTF on the pasteboard is the clean
   rendering by construction, pinned by a test. «Заменить» writes the plain result as before.
6. **The count is said, the changes are stepped.** The window's status bar reads «Готово за
   N мс · 6 изменений» with ‹ › and ⌘G/⇧⌘G; the panel's status row reads «Исправлено: 6
   изменений»; VoiceOver hears «Правка готова, 6 изменений». «Изменений нет» is the answer for
   a clean text, and it is worth more than an unchanged pane.

## Consequences

- `TranslationOutcome` gained `changes: ChangeSet?`; `nil` means «not a правка».
  `documentGlossaryAttempted == false` is still the правка marker.
- `MarkupKit` gained `ChangeMarks` and `Rendering.blockRanges`; the marks are *located* in the
  storage by aligning tokens of the projection with tokens of what is shown, so one change set
  marks «Разметка», «Исходник» and plain prose. A block the aligner cannot consume is left
  unmarked and the count is untouched: a guessed underline is worse than none.
- The pane header's picker has a third segment in правка mode («Результат | Изменения |
  Исходник»), driven by `PaneViewChoice` over two settings; the panel's степень/стиль row has a
  third menu, «Вид», whose «оригинал» is a per-presentation flag on `HotkeyCoordinator`.
- `PanelSizer.dragMinHeight` moved 164 → 179, measured: «finished правка + окно занято» is
  the tallest pinned block now.
- The three status colours stay `StatusColour`'s. Nothing in the marks means «warning».

## Rejected

- **Red for removed, green for added.** Word does it with author colours and DeepL Write with
  green alone; here red and green already mean «не удалось» and «готово» in the same window,
  and HIG asks not to redefine a semantic colour.
- **Four categories with four colours (Grammarly).** Categories need explanations, and
  explanations need the model. One tint.
- **A background fill.** It changes the text's own contrast against the pane on every accent;
  an underline leaves label-on-pane untouched. Apple's own mark is an underline.
- **A side-by-side diff pane.** The исходник pane is the side-by-side view.
- **Per-change accept/reject in the first phase.** Rejecting a change edits the result and
  re-derives the diff against a text that is no longer the model's; that is a feature with its
  own undo story, and it is the spec's phase 2.
- **A solid line with dots reserved for structure.** The first drawing. Measured away, above.

## Amendment, 2026-10-29

Spec: `openspec/changes/improve-change-mark-legibility/`. Measured on the screen rather than
resolved from `NSColor`: `Scripts/change-grounds.swift` and the last section of
`Scripts/accent-contrast.swift`; figures in `docs/reference/MEASUREMENTS.md`.

**What was wrong.** The colours were held against white and #1e1e1e — what `NSColor` resolves
offscreen. The screen shows the dark window as #31302d, the hotkey panel's material up to
#494845 and the change card's glass as #4d4c48. Against those, five dark accents were under 3:1
(this machine's #007aff 2.14:1); `secondaryLabelColor` for removed text was 3.84–3.98:1 in
light, under the 4.5:1 HIG sets for text; and the 35 % blend left синий 2.12:1 from the text
over it, a hairline in the tone of its own letters. Three of six counted changes in a test
paragraph had nothing to see: two pure removals and an inserted comma.

**What changed.**

- **The tint is a floor.** The accent moves toward the ink in 0.01 steps until it clears 3.5:1
  against every ground of its appearance; 4.5:1 under Increase Contrast, which also makes every
  line thick. The setting is passed in from `NSWorkspace`, because a high-contrast appearance
  cannot be built offscreen to test against.
- **Removed text** is the label's hue at the smallest alpha that clears 4.5:1 by 0.2 on the
  worst ground (6:1 under Increase Contrast); its strike takes the underline's weight; the
  spaces a splice adds are not struck.
- **Every counted change is visible.** A pure removal leaves a caret on its gap in «Результат»;
  an insertion with no word in it is drawn in the mark's colour; a change bar stands beside
  every line holding a change.
- **A rewritten block carries no underline** and is marked by one continuous bar — the
  candidate-text reading point 2 already gave it.

Point 3 (marks are attributes, «Изменения» a second document), point 5 (never copied) and the
dotted pattern stand. Bars and carets are drawn by the view, never characters, so point 5
holds for them by construction.

**Also rejected, 2026-10-29.**

- **A dashed underline.** It breaks irregularly per glyph at 13 pt and becomes blocks at 22 pt;
  the dots stay even and do not resemble the system spelling mark (round, dense, red).
- **The strike in the mark's colour.** It binds the pair, but under a red or green accent it
  paints removals red or green — the meanings the rejection of red/green above protects — and
  from 17 pt it is the loudest line on the page.
- **A background fill**, again, for a second reason: an accent wash shares its hue with
  `selectedTextBackgroundColor`, and in the dark appearance a washed change and the selection
  ‹ › puts on it cannot be told apart.
