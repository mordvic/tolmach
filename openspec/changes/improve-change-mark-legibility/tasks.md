# Tasks

## 1. Measurement

- [x] 1.1 Add `Scripts/change-grounds.swift`. It opens borderless probe windows, samples the titled window's ground, the `.regularMaterial` panel over five backdrops and an `NSPopover`, and prints each as hex per appearance. Add it to the command list in `CLAUDE.md`. Verify: one run prints values within 2 levels of the table in design.md.
- [x] 1.2 Extend the change-mark section of `Scripts/accent-contrast.swift`. For every accent preset and both appearances, it should print today's colour and the floor-based colour (design D1) against every ground of its appearance. Verify: the output reproduces design D1's figures (for example blue → #007ce8 light, #40adff dark).
- [x] 1.3 Record in `docs/reference/MEASUREMENTS.md` under «change marks»: the grounds, the per-accent table, the removed-text alphas, the card width (733 pt for 128 characters today) and the find-indicator observation. In `docs/reference/OPEN-ITEMS.md`, close the row «The find indicator over a dotted mark, at 13 pt and at 32 pt». Verify: each number in the entry matches the 1.1 and 1.2 output.

## 2. Mark colour and weight

- [x] 2.1 In `ChangeMarks.markColour`, replace `lightBlend` with the floor rule: 3.5:1 against the worst ground, move toward black or white in 0.01 steps, cache per resolved accent and appearance. Rewrite the doc comments' measured figures. Verify: `ChangeMarksColourTests` asserts at least 3.5:1 for 8 presets × 2 appearances × every ground of that appearance, and asserts that purple in the light appearance is drawn unchanged.
- [x] 2.2 Add Increase Contrast to the providers: an injectable flag that defaults to `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`, a 4.5:1 floor, and `.thick` weight at every size. Add a by-eye row for the real setting to `OPEN-ITEMS.md`. Verify: with the flag on, a test asserts at least 4.5:1 on every ground and `.thick` at 13 pt.
- [x] 2.3 Rebuild the marked rendering in `RenderedTextView.Coordinator` and `RenderedReplyView` on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`. Verify: a test posts the notification with the flag flipped and reads `.thick` from the rebuilt storage.
- [x] 2.4 Amend `docs/adr/0012-change-marks-are-shapes-in-one-tint.md` point 4 and its «Rejected» list (dash, tinted strike, wash). Update the change-marks paragraph in `CLAUDE.md` that says «darkened 35 % in the light appearance». Verify: `grep -rn "35 %" CLAUDE.md docs/adr/0012*` finds no stale claim.

## 3. Removed text

- [x] 3.1 Give removed text the colour from design D3 (α 0.60 / 0.65, 0.65 / 0.80 under Increase Contrast), with the strike in the same colour and the underline's weight rule. Verify: tests assert at least 4.5:1 (6:1 under Increase Contrast) against every ground including the card's, and a thick strike from 17 pt.
- [x] 3.2 Make `splice` give the spaces `padded()` adds only `.font` and `.paragraphStyle`. Verify: a `ChangeMarksTests` case finds no `.strikethroughStyle` on whitespace around a spliced removal, and the «Вернуть» tests still pass.
- [x] 3.3 Make `renderChangesPreview` draw on #ffffff and #31302d (window) and on #edebea and #4d4c48 (the worst grounds) instead of `calibratedWhite 0.12`. Verify: the run writes PNGs for both grounds, and the removed text in them is visibly struck word by word.

## 4. Pure removals

- [x] 4.1 In `.result` and «Исходник», have `ChangeMarks.apply` put `changeKey` with no underline on the gap before a pure removal's anchor token. Verify: a test with the six-shape fixture from the spec finds six distinct `changeKey` values, including a length-1 range at the gap.
- [x] 4.2 Draw the caret in `CodeBlockTextView` from a pure function that maps a glyph rect, baseline and font size to the chevron's path. Add a by-eye row for the caret at 11 pt and its click target. Verify: a unit test of the function at 13 and 22 pt, plus the caret visible in `renderChangesPreview`.
- [x] 4.3 Make ‹ ›, ⌘G and a click reach the anchor. Verify: a test shows `Coordinator.range(ofChange:)` returns the gap, and `ChangeCard.of` for that change has only «Было».
- [x] 4.4 Announce a pure removal to VoiceOver when stepping onto it: «Удалено: <removed>», built by a value function and posted with `.announcementRequested`. Add the string to `CONTEXT.md` if it names something new, and add a by-eye row for VoiceOver. Verify: a test of the value function. Check that nothing is passed to `Log`.

## 5. Punctuation and rewritten blocks

- [x] 5.1 Give an insertion with no letter or digit `.foregroundColor = markColour`. Verify: a test on «непонятно пишите» → «непонятно, пишите» reads the mark colour on the comma.
- [x] 5.2 Drop the underline from block-scope changes in both views and keep `changeKey`. Verify: a test finds no `.underlineStyle` in the block's range, and finds `changeKey` there.
- [x] 5.3 Keep a click on a block-scope change's text from opening the card. Verify: a value-level test of the click decision, for a block-scope change and for a words-scope change.

## 6. Change bars in the window

- [x] 6.1 Add a pure function that returns bar rects from a TextKit 1 layout: lines meeting a `changeKey` or strike range, one continuous rect for a block-scope range or a multi-line strike. Verify: tests on a laid-out storage show a comma-only line gets a bar, an unchanged line none, and a block one rect.
- [x] 6.2 Draw the bars in `CodeBlockTextView.drawBackground(in:)` at x = 1…3.5. Verify: a test shows the first glyph's x is identical with and without changes, and `renderChangesPreview` shows the bars.
- [x] 6.3 Make a click in the gutter beside a barred line open the card for that line's first change. Verify: a value-level hit-test test.
- [x] 6.4 Keep the copy paths clean. Verify: the existing test that the RTF flavour has no marks still passes, and a new assertion finds the `.result` storage's string equal to the clean rendering's.

## 7. Change bars in the panel

- [x] 7.1 Draw the panel's bars in `PanelView`'s 14 pt padding (design D8, revised: `clipsToBounds` off, plus the scroll region pushed into the padding), outside `PanelController.measure`. Keep a rewritten block's card reachable from its text there. Verify: a test shows the reply's inset and padding are still zero and every bar rect lies left of the text.
- [x] 7.2 Measure the settle swap with bars present. Record the figure in `docs/reference/PLATFORM-TRAPS.md` beside the existing inset measurement. Verify: the first glyph's x is equal before and after the swap, with a 0 pt shift.
- [x] 7.3 Decide the bar's inset from the padding's inner edge by eye (design's open question). Add an `OPEN-ITEMS.md` row for bars in a scrolled panel. Verify: the chosen value and the row are committed.

## 8. Change card

- [x] 8.1 In `ChangeCardView`: words at `.body`, labels «Было» and «Стало» at `.caption`, removed words in the D3 colour with a strike, inserted words with the dotted mark, no arrow. Remove `ChangeCard.showsArrow` and its test now that nothing reads them. Verify: `ChangeCardTests` pass.
- [x] 8.2 Bound the text column to 320 pt and let it wrap. Verify: a test measures `fittingSize.width` for a 400-character change at 320 pt plus padding or less.

## 9. Integration

- [x] 9.1 Run `swift build --build-tests` and `swift test` with the Xcode toolchain. Verify: zero warnings, every test passes, and the suite time stays near today's.
- [x] 9.2 Run `RENDER_PREVIEW_CHANGES` at 13 and 22 pt and compare with the proposal's renders. Verify: the PNGs show every requirement scenario of `specs/change-marks` that a still image can show.
- [ ] 9.3 Build the bundle with `./Scripts/make-app-bundle.sh`. Check «Результат», «Изменения» and «Исходник» in the window and the panel in both appearances, plus a card and a pure-removal step. Verify: the observations are written to `OPEN-ITEMS.md` §1, and UI behaviour that was not seen is not described.

## Workflow follow-up

- Archive the change with `openspec archive improve-change-mark-legibility` after the pull request is merged. This creates `openspec/specs/change-marks` and `openspec/specs/change-card`.
- Verify the archived specs read well without the change folder.
