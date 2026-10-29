# Proposal

## Why

A правка result marks what changed with a dotted underline, struck-through removed words and a «было → стало» card. Measured on screen on 2026-10-29, those marks fail in exactly the places users read them:

- On the dark panel and card, the underline is 2.14–2.99:1 for the blue, purple, pink, red and graphite accents and for this machine's accent (#007aff). The floor for a non-text indicator is 3:1.
- Removed text is 3.84–3.98:1 on every light ground and 3.89–4.71:1 on the dark panel and card. HIG asks for 4.5:1 for text up to 17 pt.
- In the light appearance the underline is 1.86–2.27:1 from the text above it, so it blends into the letters.
- In a test paragraph, three of six counted changes have no visible mark at all: two pure removals and an inserted comma.

`ChangeMarksColourTests` passes because it checks only white and #1e1e1e. On screen the dark window is #31302d, the panel's material reaches #494845 and the card's popover is #4d4c48.

## What Changes

- The underline colour stops being «accent darkened 35 % in light». It becomes the user's accent, moved toward the text colour only as far as it needs to clear 3.5:1 against the worst measured ground of its appearance (4.5:1 under Increase Contrast).
- Removed text and its strike use a label-hued colour that clears 4.5:1 on every ground (6:1 under Increase Contrast). The strike follows the underline's weight rule.
- The spaces spliced in around removed text are no longer struck through.
- A pure removal in «Результат» gets a caret under the gap where the words were. ‹ ›, ⌘G and a click can reach it, and VoiceOver announces it.
- An insertion with no word in it (a comma, a dash) is drawn in the mark colour.
- A rewritten paragraph (a block-scope change) loses its underline and is marked by one continuous bar.
- New: a change bar at the leading edge of every line that holds changed or removed text, in the window and in the panel. Bars and carets never move the text and never reach the pasteboard.
- Under Increase Contrast every mark is thick at every size.
- The change card sets its words at the system body size, wraps them at 320 pt instead of growing without limit, and draws «Было» and «Стало» with the same marks as the text.
- Unchanged and now written down: the dotted pattern, the accent as the tint, no background fill, no red or green, marks never copied.

## Capabilities

### New Capabilities

- `change-marks`: How a правка result shows what changed in the window's pane and the hotkey panel. Covers shapes, colours, weights, contrast floors, carets, bars, stepping, and what a copy carries. It also records the existing behaviour this change keeps.
- `change-card`: The «было → стало» card a click on a change opens: its content per change shape, typography, contrast and size bounds.

### Modified Capabilities

None. The project has no OpenSpec specs yet. The current behaviour is described in `docs/adr/0012-change-marks-are-shapes-in-one-tint.md` and `docs/design/specs/2026-09-04-change-marks-spec.md`. This change amends both.

## Impact

- `Sources/MarkupKit/ChangeMarks.swift`: mark colour and weight, removed-text attributes, splice spacing, the pure-removal anchor, punctuation tint, block-scope underline.
- `Sources/TranslatorApp/RenderedTextView.swift` (`CodeBlockTextView`): bars and carets, bar hit-testing, rebuild on an accessibility display change, VoiceOver announcement.
- `Sources/TranslatorApp/RenderedReplyView.swift` and `PanelView.swift`: bars in the panel's own padding, so the reply text does not shift.
- `Sources/TranslatorApp/ChangeCard.swift`: typography, colours, width bound.
- Tests:
  - `Tests/MarkupKitTests/ChangeMarksColourTests.swift` and `ChangeMarksTests.swift`
  - `Tests/TranslatorAppTests/ChangeCardTests.swift`
  - `Tests/TranslatorAppTests/RenderPreview.swift` (`renderChangesPreview`)
- Scripts: `Scripts/accent-contrast.swift`, and a new probe that measures the window, panel and card grounds.
- Docs:
  - `docs/adr/0012` (amended)
  - `docs/reference/MEASUREMENTS.md`
  - `docs/reference/OPEN-ITEMS.md`
  - the change-marks paragraph in `CLAUDE.md`
- No new dependency, no new setting, no change to `TranslationOutcome`, `TextDiff` or the RTF and «Заменить» paths.
