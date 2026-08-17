# Pinning the panel's chrome while its translation scrolls

**Goal:** When the floating panel's translation is long enough to scroll, the panel's chrome —
the direction line, the ⨯, and the action buttons — stays where it is instead of scrolling away
with the text.

**Branch:** `fix/panel-pinned-chrome`, from `main` at `be2c56f`.

**Why this is written as requirements rather than as code.** The build ledger for the UI
redesign records seven defects that reached commits from code the plan supplied verbatim,
including three in this exact file. A block of finished code in a plan reads as though it has
been checked, and gets transcribed without the scrutiny a prose requirement forces. So this plan
says what must be true and how to prove it, and leaves the writing to the implementer.

---

## 1. The defect

`PanelView.body` is:

```swift
Group { if scrolls { ScrollView { content } } else { content } }
```

and `content` is the whole panel: header, translation, status line, warnings, button row. So the
moment `PanelSizer` decides the content is taller than the panel can be, **everything scrolls,
not just the text.**

Consequences, in ascending order of harm:

| | |
|---|---|
| The ⨯ leaves the top | The panel cannot be closed with the mouse until the user scrolls back up |
| «Скопировать» / «Открыть в окне» sit below the whole translation | Reachable only by scrolling to the bottom |
| The failure row and its «Повторить» sit after the text | On a run that failed while keeping a long previous translation on screen, the error and the only way to retry are below the fold |
| **«Отмена» during a run** | The run is streaming, the panel is at its ceiling, the stop button has scrolled out of reach — and arriving text pushes it further away |

The existing comment on `content` justifies wrapping everything: *«the ceiling applies to the
sum: a long translation with a long document glossary can put the button row off the bottom on
its own»*. The concern is real. The remedy is not: it makes the button row reachable **by**
scrolling at the cost of making it unreachable **without** scrolling, always.

## 2. What must be true when this is done

1. The direction line and the ⨯ are visible whatever the length of the translation, without
   scrolling.
2. «Скопировать», «Открыть в окне» and — while a run is in flight — «Отмена» are visible
   whatever the length of the translation, without scrolling.
3. The translation, the status line and the warnings are what scrolls, together, in one region.
   Not two scroll views.
4. A document glossary of any length cannot push the button row out of view. This is the
   concern the current comment raises, and pinning the row answers it outright rather than
   mitigating it.
5. The three non-`.text` states — `.empty`, `.notPermitted` — keep a reachable ⨯ too. They are
   short and will not scroll, but the structure must not make them a special case that only
   happens to work.

## 3. The invariant that must not break

**The measured variant must stay flat.** `PanelController.measure` asks a detached host for
`fittingSize` and then `sizeThatFits(in:)`, and `PanelContentVariant.measured` already reports
`scrolls == false`, so the flat path is what gets measured.

**Corrected after implementation, because the first version of this section was wrong.** It said
a `ScrollView` «compresses to nothing» under measurement and required that «the flat layout and
the scrolling layout have the same ideal height». Both claims are false, and a test written to
the second one would have asserted something that cannot hold. Probed on the two calls the
controller actually makes:

```
flat        fittingSize 6901 × 64   sizeThatFits@400  368
scrolling   fittingSize 6901 × 64   sizeThatFits@400  greatestFiniteMagnitude
```

A `ScrollView` is **greedy**, not compressible. The width pass is unaffected — `fittingSize`
ignores it entirely — and the height pass answers the whole unbounded proposal. So the two
layouts *cannot* agree on ideal height, by construction.

What actually protects the measurement is narrower and enforceable: the `.measured` case of
`PanelContentVariant` reports `scrolls == false`. Break that and `PanelSizer` reads
`greatestFiniteMagnitude` as a real measurement — it is finite — clamps to the ceiling, and
every panel comes out 0.6 × the screen and scrolling, for a one-word result as readily as for a
long one. Measured by mutation: every panel settled at 774 pt on this display, short and long
alike.

`fillsPanel` is unrelated to this change and must keep its current behaviour — `false` while
measuring, or the view answers `greatestFiniteMagnitude` on both axes and every panel comes out
`maxWidth` × ceiling.

## 4. How to prove it

The panel's structure is not observable from a test process, so the proof is split.

**Testable — and, as it turned out, already tested.**

The invariant worth pinning is the corrected one above: the measured variant never scrolls.
Mutating `PanelContentVariant.measured` to report `scrolls == true` and running the whole suite
fails three existing tests —
`theRealPanelViewIsMeasuredRatherThanEchoingTheProposalBackAtTheSizer`,
`aReusedControllerMeasuresThePressItIsShowingNotThePreviousOne` and
`aShortTranslationInTheRealPanelViewDoesNotAskToScroll` — each reporting every panel at 774 pt,
short and long alike.

**So no new test is added, deliberately.** The split introduces `scrollingMiddle`, which carries
no decision of its own: it wraps or does not wrap according to a flag whose only interesting
value is already pinned three times over. A fourth test asserting the same thing would be
ceremony, and this project has already shipped three tests that passed under the defect they
named. `PanelView.status(for:)` and `direction(outcome:target:)` keep their signatures and stay
covered by their existing tests.

**And the change itself is unguarded, which has to be said rather than left to be discovered.**
Reverting the fix — putting the `ScrollView` back around the whole content — was applied and the
full suite run: **346 tests, zero failures.** That is not a gap in the tests, it is the shape of
the defect. Scrolling everything and scrolling the middle produce the same *sizing*, because the
measured variant is flat either way; what differs is only which rows are on screen when the user
scrolls, and no test in this environment can see a row's position. The `docs/reference/OPEN-ITEMS.md` §1
row added by this change is the only thing standing guard over it.

**Not testable here, and must be recorded rather than claimed:**

- That the chrome is actually visible while the middle scrolls. No GUI automation exists in this
  environment. Add a row to `docs/reference/OPEN-ITEMS.md` §1 naming what a human should look for: a
  translation long enough to scroll, then the ⨯ and both buttons still on screen, and «Отмена»
  still reachable while it streams.

**Mutation-check the height-agreement test.** Reintroduce the whole-content `ScrollView`, run
the test, confirm it fails, restore, confirm it passes. Report both runs. A regression test for
a layout invariant that cannot fail is worse than none.

## 5. Constraints

- Swift tools 6.0, `.swiftLanguageMode(.v5)`, macOS 14 floor. No new targets, no dependencies.
- Swift Testing only, sentence-named tests.
- `rm -rf .build && swift build --build-tests` → zero warnings, verified on a **clean** rebuild.
  An incremental one does not recompile untouched files, and that false negative reached a commit
  message on the previous branch.
- Baseline: 346 tests.
- Russian strings with «guillemets» and «ё»; no backticks in `Text(String)`.
- Comments carry *why* and the measurement behind it. «Measured» and «load-bearing» mean an
  observation was actually made.
- **Claim nothing visual.** Ten over-claims were caught on the previous branch.

## 6. The comment that must be rewritten, not deleted

The justification on `content` — that the ceiling applies to the sum — is the reasoning this
change overturns. It must not simply disappear with the code it explained. It becomes the record
of why the button row is now outside the scroll: the sum was the right observation and pinning
is the answer to it, rather than scrolling everything. Deleting the line and keeping the comment,
or deleting the comment and keeping the behaviour, is the failure `CLAUDE.md` says has already
cost this project two defects.
