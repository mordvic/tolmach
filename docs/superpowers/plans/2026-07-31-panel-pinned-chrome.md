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
`fittingSize` and `sizeThatFits(in:)`, and a `ScrollView` anywhere in what it measures compresses
to nothing — measured on the running bundle at 380 × 120 regardless of content, before
`hosting.sizingOptions = []` existed. `PanelContentVariant.measured` already reports
`scrolls == false`, so the flat path is what gets measured; the requirement is that **the flat
layout and the scrolling layout have the same ideal height for the same content.**

If they diverge, the panel is sized against a layout it is not showing, and the symptom is the
one this project has already paid for twice: a panel whose height is right for something else.

`fillsPanel` is unrelated to this change and must keep its current behaviour — `false` while
measuring, or the view answers `greatestFiniteMagnitude` on both axes and every panel comes out
`maxWidth` × ceiling.

## 4. How to prove it

The panel's structure is not observable from a test process, so the proof is split.

**Testable, and must be tested:**

- The flat and scrolling layouts agree on ideal height. Build a `PanelController`, drive it to a
  content size that scrolls, and assert the frame `PanelSizer` settles on is the same as the one
  the same content produces when it does not scroll. If the split changed the ideal height, this
  fails.
- `PanelView.status(for:)` and `PanelView.direction(outcome:target:)` keep their signatures and
  behaviour. They are pure and already covered; the existing tests must still pass untouched.
- Whatever new type or property the split introduces, if it carries a decision, it is testable
  and gets a test. If it carries none, say so rather than writing a test that cannot fail —
  three tests on the previous branch passed under the defects they named.

**Not testable here, and must be recorded rather than claimed:**

- That the chrome is actually visible while the middle scrolls. No GUI automation exists in this
  environment. Add a row to `docs/OPEN-ITEMS.md` §1 naming what a human should look for: a
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
