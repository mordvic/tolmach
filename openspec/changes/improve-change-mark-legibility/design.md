# Design

## Context

How things work today: `ChangeMarks.apply` (MarkupKit) adds `.underlineStyle`, `.underlineColor` and `changeKey` to a clean rendering and, in «Изменения», splices the removed text in as struck characters. `CodeBlockTextView` hosts the result in the window. `RenderedReplyView` hosts it in the panel with zero inset and zero `lineFragmentPadding`; that was measured, so the streamed text and the settled document start on the same pixel. `ChangeCardView` is the click popover. The motivation is in proposal.md, the required behaviour in `specs/change-marks` and `specs/change-card`.

On-screen measurements behind every decision below (macOS 27, 2026-10-29) come from `Scripts/change-grounds.swift` (task 1.1). Its first run superseded an earlier throwaway probe: that one sampled the card over another application's window, and the card is glass.

| Ground | Light | Dark | How |
|---|---|---|---|
| Window (titled, content) | #ffffff | #31302d | screen pixels; `windowBackgroundColor` resolves to #1e1e1e offscreen |
| Hotkey panel, `.regularMaterial` | #edebea…#f1f0ee | #3c3937…#494845 | over white, black, grey, blue and orange backdrops |
| Change card, `NSPopover` | #f5f5f5 | #4d4c48 | screen pixels, pane-coloured backdrop |

The worst ground per appearance is #edebea (light, darkest: the panel over black) and #4d4c48 (dark, lightest: the card). A colour that clears its floor there clears it on every surface. One dynamic colour can therefore serve the window, the panel and the card without knowing which one it is drawn on.

## Goals / Non-Goals

**Goals:**
- Every mark meets its floor on every measured surface, in both appearances and under Increase Contrast.
- Every counted change has something visible to step to.
- The text never moves for a mark, and no mark becomes part of the text a copy carries.

**Non-Goals:**
- Change explanations in the card (`Translator.explain` stays CLI-only).
- Changing what `TextDiff` counts as a change, its thresholds, or `TranslationOutcome`.
- Marks in the file queue's pane (a файл's result is never a правка).
- A per-change accept/reject workflow beyond today's «Вернуть».

## Decisions

### D1. Mark colour: a floor against the worst ground, not a fixed blend
`markColour` resolves `controlAccentColor` and moves it toward black (light) or white (dark) in steps of 0.01 until it reaches 3.5:1 against every ground of that appearance (4.5:1 under Increase Contrast). It is computed on each resolve, at most 95 steps of four contrasts each, which is cheap enough not to need a cache.

- *Why:* the fixed 35 % blend was calibrated so that yellow passes on white. It drags blue (#0058a6) and purple to 1.86–2.12:1 from the text above them, and it does nothing in dark, where the panel needs lightening.
- *Alternative:* a separate blend per preset. Rejected: the accent is the user's, it can change under a running app, and a «multicolor» or tinted accent matches no preset.
- *Why 3.5:* it is 3:1 plus one step of margin, the same discipline as `StatusColour`.
- *Measured result:*

  | Accent | Light | Dark |
  |---|---|---|
  | blue | #007ce8 | #40adff |
  | purple | unchanged | #e87bf7 |
  | yellow | #967800 | unchanged |
  | this machine's #007aff | #0078fa | #5caaff |

  The full table is in `MEASUREMENTS.md` (task 2.4).

### D2. Increase Contrast is read from `NSWorkspace`, and the storage is rebuilt on change
The dynamic providers read `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`.

- *Why:* `NSAppearance(named: .accessibilityHighContrastAqua)` cannot be simulated offscreen. `bestMatch(from:)` returns `.aqua` for it, and system colours resolve as usual, so a branch keyed on the appearance name can neither be tested nor trusted.
- Underline and strike weight are attributes, not dynamic colours. The view therefore rebuilds the marked rendering on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
- *Alternative:* key everything on `effectiveAppearance`. Rejected for the reason above.

### D3. Removed text: a label-hued alpha, not `secondaryLabelColor`
The colour is black at α 0.60 (light) or white at α 0.65 (dark); 0.65 and 0.80 under Increase Contrast. Worst-ground contrast: 5.44, 4.74, 6.54 and 6.22:1. The strike uses the same colour and the underline's weight rule (thick from 17 pt or under Increase Contrast).

- *Why:* `secondaryLabelColor` is 3.84–3.98:1 on every light ground and 3.89:1 on the dark card. Each alpha is the smallest 0.05 step that clears its floor by at least 0.2 on the worst ground, so removed text stays as light as it can under body text (α 0.85).
- *Rejected:* a strike in the mark colour. It binds the pair visually, but it paints removals red or green under a red or green accent, and those colours mean «не удалось» and «готово» in the same window. From 17 pt up it is also the loudest line on the page.

### D4. Splice padding is plain
`padded()` keeps adding the spaces a splice needs. `splice` gives those spaces only the anchor's `.font` and `.paragraphStyle`, so the strike covers the removed tokens alone.

### D5. A pure removal gets an anchor character and a drawn caret
In `.result` (and «Исходник»), `apply` puts `changeKey` with no underline on the gap before the anchor token: the separating space, or the token itself when no space precedes it, as before «.». `CodeBlockTextView` draws a chevron under that character's glyph at the baseline, 0.42 × font size wide, with a 1.4 pt stroke (2 pt from 17 pt), in the mark colour.

- Because the anchor carries `changeKey`, `Coordinator.range(ofChange:)`, the stepper, the find indicator and the click handler work with no new path.
- Selecting a space reads as nothing to VoiceOver, so stepping onto a pure removal posts `NSAccessibility.post(element:notification: .announcementRequested, …)` with «Удалено: <removed>». The removed words go to the accessibility API only, never to `Log`.
- *Alternative:* underline the gap space. Rejected: two dots under a 3.5 pt space are as invisible as the comma case.

### D6. Inserted punctuation takes the mark colour as its foreground
When a words-scope change's `inserted` has no letter or digit, `apply` adds `.foregroundColor = markColour` to its range.

- The glyph is then at 3.5:1, under the 4.5:1 text floor. That is accepted because a comma is not running text, and Increase Contrast raises it to 4.5:1.
- *Alternative:* a thicker underline. Rejected: under a comma it is still about 3 pt long.

### D7. Change bars are drawn by the view, from the storage
`CodeBlockTextView.drawBackground(in:)` draws the bars. The set of lines comes from a pure function over the text storage and layout manager: line fragments intersecting a `changeKey` range or a strike range. A block-scope range, or a strike range spanning lines, yields one continuous bar.

- Bar: 2.5 pt wide, radius 1.25, inset 3 pt top and bottom per line, in the mark colour.
- In the window, the gutter is inset 3 plus padding 5, so the bar sits at x = 1…3.5 and nothing moves.
- Bars are not characters, so neither RTF nor any copy can carry them.
- A click in the gutter beside a barred line opens the card for that line's first change. A click on the text of a block-scope change does not open the card, because nothing there is visibly marked.

### D8. Panel bars live in the panel's padding
The panel's reply starts at x = 0 of its text view by measurement (`RenderedReplyView.inset`, `lineFragmentPadding = 0`). Its bars must therefore be drawn outside that view, in the 14 pt panel padding.

- Approach (revised during apply, 2026-10-29): `PanelReplyTextView` turns `clipsToBounds` off and draws its bars at x = −7, 4.5 pt from the text as in the window. `Scripts/panel-bar-clip.swift` measured that this reaches the padding in the flat layout and is clipped by a `ScrollView`. So `PanelView.scrollingMiddle` pushes the scroll region 8 pt into the padding with `.contentMargins` and pushes its content back by the same 8, and the text does not move (14.7 pt in both layouts).
- *Rejected:* publishing the bar rects to a SwiftUI view in the padding. It needs a callback and state per layout pass for the same picture.
- Neither `PanelSizer`'s measurement nor the detached measuring host includes the bars: they are drawn, not laid out.
- **Consequence:** AppKit routes a click by the subview's frame, so a click in the padding never reaches the reply's view, and the panel's bars are not clickable. In the panel, a rewritten block's card therefore opens from a click on its text (`ChangeBars.clickOnTextOpensCard(for:barsAreClickable:)`). The window keeps D7's rule.

### D9. Block-scope changes lose their underline in both views
`apply` keeps `changeKey` on the block but adds no underline, and D7 draws one continuous bar. In «Изменения» the old block stays spliced above, struck, with its own bar.

- *Why:* ADR 0012 already treats a rewrite as one candidate text. A dot under every word on every line contradicts that.

### D10. The change card
- The words are `.body`; the labels «Было» and «Стало» are `.caption`, secondary.
- Removed words use D3's colour and strike. Inserted words carry `.underline(pattern: .dot, color: markColour)`.
- The text column is limited to 320 pt and wraps (`fixedSize(horizontal: false, vertical: true)`). The arrow goes, because the labels already give the direction.
- ADR 0008 holds: system sizes, not «Шрифт текста».
- Today's `.fixedSize()` on both axes measured 733 pt wide for a 128-character change.

### D11. Kept as is, on purpose
- **The dotted pattern.** At 13 pt it is even. `.patternDash` breaks per glyph and turns into blocks at 22 pt. It also does not resemble the system spelling mark (round, dense, red).
- **No fill.** An accent wash shares its hue with `selectedTextBackgroundColor` (#b3d7ff, #3f638b). In the dark appearance a washed change and a selected word could not be told apart, and the stepper selects changes.
- **The find indicator.** Seen on screen at 13 and 32 pt in both appearances: AppKit redraws the word black on yellow without the mark.

## Risks / Trade-offs

- [The panel's material depends on the desktop: graphite accent, desktop tinting, wallpaper] → The grounds were sampled over five backdrops and the spread is small (light 4 levels, dark about 16). The new probe makes re-measuring one command, and the first spec requirement says the list is updated before any floor is relaxed.
- [Increase Contrast cannot be exercised offscreen] → Tests drive the providers through an injected flag. A by-eye row in `OPEN-ITEMS.md` covers the real setting.
- [Bars add chrome; a heavily edited text bars nearly every line] → A bar is 2.5 pt outside the text. «Результат» stays readable, and a dense column of bars is honest about a dense правка.
- [The caret's click target is a single space, about 3.5 pt at 13 pt] → The stepper and the bar's gutter click are the primary routes; the caret click is a convenience.
- [Inserted punctuation at 3.5:1 is below the 4.5:1 text floor] → Accepted per D6; Increase Contrast lifts it to 4.5:1.
- [The panel bar overlay drifts from its line during a scroll or resize] → The rects come from the text view on every layout. Task 7 checks a scrolled panel by eye.

## Migration Plan

No data or settings migrate. Each task group lands as its own commit with its tests. Rollback is a revert of the groups in reverse order: D1–D3 and D4 stand alone, while D5–D9 depend on D1's colour.

## Open Questions

- ~~The exact bar inset in the panel.~~ Resolved during apply: 4.5 pt from the text to the bar's right edge, the same as in the window. It was chosen for that consistency rather than by eye, and the look is owed in `OPEN-ITEMS.md`.
