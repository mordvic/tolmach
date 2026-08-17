# Only the user's own text follows the content font

«Шрифт текста» — the typeface and size a person chooses in «Основные» → «Текст» — governs
exactly three places: the исходник in the window, the перевод beside it, and the text in the
панели. Every label, button, status line, warning and table keeps the system's size, whatever
the setting says.

That is a narrower promise than «размер текста в приложении» sounds like, and the narrowness is
the decision.

## Why the interface is excluded

Three groups of numbers in this codebase are measurements of chrome at the system size, and a
setting that moved the chrome would turn each of them from a constant into a function of a
preference:

- `PanelSizer.minHeight` (132) and `dragMinHeight` (164) are the height of the panel's *pinned*
  block — header, status row, buttons, and the «окно занято» caption — measured state by state
  at 300 pt. They are what stops a hand-dragged panel from putting its own button row off the
  frame, and nothing in that block scrolls.
- `PanelSizer.minWidth` (300) is the panel's button row, and `Scripts/panel-proofread-row.swift`
  measures the степень/стиль row against the 272 pt that leaves.
- `settingsPane()`'s 560 × 480 and `Scripts/toolbar-fit.swift`'s narrowest fitting toolbar are
  the same kind of number for the window and the settings.

Re-deriving all of them as functions of a user setting is possible; it is simply a much larger
piece of work than the one being paid for, and every one of those measurements would have to be
re-taken at each end of the range rather than once.

The reading argument points the same way. Measured: every caption in this app is `.caption`,
which is **10 pt**; `.callout` is 12 and `.body` is 13. Because the chrome stays put, the content
floor is 11 pt — one point above the captions — so the user's text can never end up smaller than
the words labelling it. A setting that moved both would have no such anchor.

## Considered and rejected

- **Scale the whole interface.** The honest version of «сделать всё крупнее», and the answer for
  someone who needs it is the system's own: Универсальный доступ → Дисплей, or a scaled
  resolution. An application-level zoom that duplicates a system feature badly is worse than not
  having one.
- **A separate font per surface** (window vs панель, исходник vs перевод). Three font settings in
  an application with one primary action costs more explaining than it saves. One setting; if the
  «крупно в панели, обычно в окне» case turns out to be real, splitting it later means new keys
  and three call sites, and that is the price accepted here.

## Consequences

- **The tables holding the user's words do not scale**: «Термины документа», the glossary pane,
  and the terms quoted by `WarningsView`. They are scanned rather than read, and each lives in a
  container with a measured geometry of its own.
- **`PanelSizer.maxWidth` stays 560 pt.** Measured, that is 75 characters of Russian prose at
  13 pt — the classic reading measure, and the number is therefore not arbitrary. Holding that
  measure at 22 pt would need a 947 pt panel, which is a second window floating over the
  document rather than a panel. So a large font in the панель means a narrow column and more
  scrolling, deliberately.
- **`PanelView.reservationLimit` becomes font-derived** — `16 000 × (13 / size)²`, and the
  square is the measurement rather than a guess. Its comment justifies 16 000 as «twice the
  length that already reaches this display's ceiling», and that length moves with the setting:
  bisected against a 774 pt ceiling, the reserved height first reaches it at 3 817 / 2 914 /
  1 789 / 1 032 / 661 / 511 characters at 11 / 13 / 17 / 22 / 28 / 32 pt. A line is `size` tall
  and holds `1/size` of the characters, so the height goes as the square — and the linear
  `13/size` written first predicts less than half the movement. The original 43 ms cost figure
  was **not** re-measured; a stand-in probe failed to reproduce it, so the generalisation rests
  on «the same answer for less work», not on a measured saving. For the same reason the cap is
  applied in one direction only — `min(16 000, …)`. Below 13 pt the square would *raise* it, to
  22 347 characters at 11 pt, and spend more of the layout the cap exists to bound than the one
  length whose cost anybody has timed.
- **On a large font the панель will usually open at its height ceiling** (0.6 of the screen),
  because the reservation books the room the reply will need. That trade is already recorded in
  `docs/OPEN-ITEMS.md`; the setting makes it arrive at a few hundred characters of selection
  instead of a few thousand.
- The default is 13 pt системный, which measures **identically** to today's `.body`
  (375.0 × 16.0 for the same string, probe-checked). An install that never opens the setting
  renders exactly as it does now.

## Where the code is

`Sources/TranslatorApp/ContentFont.swift` (the value and its rules), `AppSettings.contentFont`
(two keys, clamped on read), and the three sites it reaches: `SourceEditor`, `TranslationPane`,
`PanelView` — the last of which must hand the same font to the hidden reservation `Text` as to
the visible one, or the reservation stops predicting the reply's height.
