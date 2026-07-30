> Historical record of the build. Where this and the code disagree, the code is right.
>
> Written at the end of the branch from the session ledger, the fourteen task reports and the
> review diffs. It records what was found, what was ruled, and what was rejected — including
> defects in the plan itself. It is not maintained: it is the account of a build that has
> finished.

# SDD ledger — plan: docs/superpowers/plans/2026-07-30-ui-redesign.md

Spec: `docs/superpowers/specs/2026-07-30-ui-redesign-design.md`
Branch: `feat/ui-redesign`
Merge base: `89efea3` (main)
Baseline at start: 289 tests, zero warnings from `swift build --build-tests`.
At the end: **341 tests, zero warnings on a clean rebuild.**

Three surfaces were rebuilt: the floating panel, the main window and the settings window, plus
a status glyph in the menu bar. No engine code was touched — `TranslationCore`, `OllamaKit` and
`TextCapture` are unchanged except for one new pasteboard writer.

---

## The one thing to read if you read nothing else

**Nobody looked at any of it.** This environment has no GUI automation and never had any. Not
one screenshot was taken, not one physical key was pressed, not one window was rendered. Every
size in this document was measured inside a test process; every claim about how something
*looks* is absent on purpose. `./Scripts/make-app-bundle.sh` was run at Tasks 4 and 7 and the
bundle assembles and signs — that is a build check, not a visual one.

`docs/OPEN-ITEMS.md` §1 carries the full list of what a human still owes. It is long. It is
supposed to be long.

---

## What each task did

| # | Commits | Tests | What it actually did |
|---|---|---|---|
| 1 | `c0637ad..3e07668` | 296 | `PanelPlacement` gained `PanelAnchor` (the corner nearest the pointer), a `Placement` struct and `reframe(current:newSize:anchor:screen:)`, so a growing panel moves its *far* edge. The old `frame(cursor:size:screen:gap:)` stayed as a wrapper with unchanged behaviour. |
| 2 | `3e07668..6fbda70` | 307 | New `PanelSizer.swift`: `minWidth 300`, `maxWidth 560`, `minHeight 120`, `maxHeightFraction 0.6`, and `fit(ideal:frozenWidth:previous:screen:userSized:) -> Fit`. Every sizing rule in one testable enum with no AppKit in it. |
| 3 | `6fbda70..ec1cb5f` | 308 | `PanelView` gained a header with a ⨯, a material background with a 12 pt continuous corner radius, and a `scrolls` flag. **Removed** the inner 220 pt text ceiling, the warnings' `ViewThatFits` 120 pt slot and the 340–520 pt width frame — the four internal ceilings that never added up to the panel. |
| 4 | `ec1cb5f..ac29815` | 318 | The panel measures itself. `.titled` left the style mask, `.resizable` joined it, `isOpaque = false` / `backgroundColor = .clear` / `hasShadow = true` make the rounded material work. `PanelController` rewritten: a second detached measuring host, a 100 ms leading-edge throttle with a trailing call, `applyFit(settling:)` animating only the settle and only when Reduce Motion is off, `windowDidEndLiveResize` handing the size to the user. Two fix rounds. |
| 5 | `ac29815..f469cc0` | 324 | `TranslationViewModel.canSwapLanguages` and `swapLanguages()`, deriving the pair from a finished run when the user set no overrides. |
| 6 | `f469cc0..f075acd` | 325 | `SourcePane.swift` and `TranslationPane.swift`, sharing a `PaneHeader`. The translation side became a read-only `Text` — the defect it replaces is a `TextEditor` bound to `.constant(...)`, which took a caret and silently discarded typing. `RussianCopy.characterCount`. |
| 7 | `f075acd..64ce327` | 327 | The window rebuilt around a real `.toolbar` (pickers and ⇄ on `.navigation`, «Перевести»/«Отмена» on `.primaryAction`), an `HSplitView` of the two panes, and a new collapsible `RunStatusBar` with a 200 pt cap on expanded warnings. `ChunkHint` deleted. Fix round added `GeneralPasteboard.write(_:to:)` as the single pasteboard writer for both surfaces. |
| 8 | `64ce327..c56f331` | 328 | `OllamaProbe.installedModels()` returns `[OllamaModel]` rather than `[String]`, carrying the size the server already reported. `OllamaModel` gained a public memberwise init, without which the type is unconstructible outside `OllamaKit`. |
| 9 | `c56f331..70c2fa9` | 328 | `SettingsPane.swift`: one `settingsPane()` modifier at 560 × 480 for every tab, replacing three panes that fixed 420, 420, 520 × 440 and 420 of their own. «Основные» became five `Section`s. The «Доступ» row is now always rendered; only its explanation and button stay conditional. |
| 10 | `70c2fa9..1dcbfbe` | 330 | «Дополнительно» folded into «Модели» and `SettingsAdvancedView.swift` deleted — four tabs became three. New «Ollama» and «Установленные модели» sections, `ModelsViewModel.resident`, `RussianCopy.modelSize`. |
| 11 | `1dcbfbe..7accba3` | 337 | `GlossaryOrder.visibleOrder(entries:query:)` — a pure function returning *indices*, so the rows do not move under the caret while a search is being typed. |
| 12 | `7accba3..7e54765` | 340 | The glossary pane got a search field, a term count, a language picker and multiple selection; `GlossaryList.swift` split out of `SettingsGlossaryView.swift`. The third and last pane moved onto `settingsPane()`. |
| 13 | `7e54765..96e2e7f` | 341 | `OllamaStatus.menuBarSymbol`, so the menu-bar glyph says whether Ollama is answering, and a first menu row saying the same in words. Five wired refresh points, no polling timer. |
| 14 | this commit | 341 | This document, and making `docs/` true again. |

The plan's own test-count checksum predicted 332 and every task brief from Task 5 onward
carried a stale number (320, 321, 321, 324, 331, 331, 332 against actual 326, 328, 328, 330,
337, 337, 341). The drift is not mysterious — the plan counted only the tests it listed, and
seven fix rounds added tests it could not have listed. The checksum did its job anyway: each
implementer verified the real baseline with `swift test` before touching a file rather than
trusting the brief, which is what the plan asked for.

---

## Where the plan was wrong

**Seven defects reached a commit inside code the plan supplied verbatim.** In each case the
implementer transcribed the brief faithfully, which is precisely how the defect got in. This
is the single most important line in this document: on this branch, following the plan exactly
was the failure mode, not the safeguard.

| Where | The defect the plan supplied | How it was caught |
|---|---|---|
| Task 2, panel | The `userSized` branch returned `previous` unguarded. `previous == .zero` is the documented pre-first-show default, so a hand-resize before the first show would hand `NSWindow.setFrame` a degenerate zero-size frame — the exact hazard the type exists to prevent. | Review, Important. Floors applied inside the branch; `aUserResizedPanelCannotProduceADegenerateZeroSizeFrame` added. |
| Tasks 3 → 4, panel | `.frame(maxWidth: .infinity, maxHeight: .infinity)` in `PanelView.body`, mandated by Task 3, made Task 4's whole measurement inert: the real view answered `greatestFiniteMagnitude` on both axes, which is finite and positive, so `PanelSizer` read it as a measurement. Every panel came out 560 × 0.6·screen, always scrolling, and `applyFit`'s `guard fit.size != panel.frame.size` then returned early on every token — the panel never resized at all. Thirteen tests stayed green because every one of them substituted `Text(…).padding(14)` for the view that ships. | Review, Critical, at Task 4. Escalated to the human as a plan conflict. **Ruling: the plan is superseded** — the measured variant drops the fill frame, the installed variant keeps it, so a hand-resized panel still has its material painted to the window edge. Expressed as a `PanelContentVariant` enum rather than a second `Bool`, so «measured *and* filling» is unspeakable rather than merely discouraged. |
| Task 4, panel | The brief prescribed `NSHostingView` and `measuring.sizeThatFits(in:)`. That does not compile: `sizeThatFits(in:)` is declared on `NSHostingController` and the `NSHostingView` class body has no `sizeThatFits` of any signature. The brief's prescribed remedy for the anticipated failure — presetting a frame — was for a failure that never occurred. | At implementation, before any commit, by probing all four candidates in a standalone binary at `.prohibited` policy. |
| Task 9, settings | The brief's prose said to keep `isTrusted`, its doc comment, `.onAppear` and `.onReceive` "exactly as they are"; its code block silently omitted the four-line comment above `.onAppear`. The implementer transcribed the block. | Review, Important. Restored verbatim against `c56f331`. |
| Task 10, tests | `aFailedReloadStopsClaimingAnythingIsInMemory` asserts `broken.resident.isEmpty` against a **freshly constructed** view model whose `resident` defaults to `[]` — so it passes whether or not `reload()`'s `catch` clears anything. Zero regression signal for the behaviour it names. | Review, Critical, proved by mutation. The reviewer's own suggested fix was *also* defective — it kept the probe as a struct and mutated the caller's copy, which the stored copy never sees — and was refused as written. Both tests moved onto a class-based `FlakyProbe`. A **second** pre-existing tautology of the same shape, `aProbeFailureIsReportedInRussianAndLeavesTheListAlone`, was found while fixing the first. |
| Task 11, tests | `theOrderIsStableForTermsThatCompareEqual` cannot catch removal of the index tiebreaker: `Array.sort` is behaviourally stable on this toolchain even though the stdlib does not promise it. Mutated away, arrays of 3, 50, 200 and 5000 entries all passed. The brief called this property the one most likely to bite and then shipped a test that could not see it. Its sibling, `theSearchMatchesTermsCaseInsensitively`, pinned only the query side of the normalisation — every fixture term was already lowercase, so dropping `.lowercased()` from the entry side still passed. | Review, Critical + Important. The tiebreaker keeps its line and gains an honest comment: it makes the ordering **total**, so the result cannot depend on `sort`'s unspecified handling of equal elements, and *no black-box test catches its removal on this toolchain*. Fixtures made mixed-case and mutation-verified. |
| Task 12, glossary | **Data loss.** The brief prescribed `selection = selection.filter { order.contains($0) }` and required no clearing in `remove(at:)`. Membership filtering is only safe when indices cannot shift. Traced: with `[альфа, бета, гамма]`, select «бета» (index 1), delete «альфа» by its row minus — every later index shifts down, so index 1 now denotes «гамма» while still passing `order.contains(1)` — and the header minus then deletes «гамма» and persists it. No undo, no confirmation. `reload()` had the same hole for a hand-edited file that keeps or grows its row count. | Review, Critical. The rule was extracted into a pure `GlossaryOrder.selection(_:survivingIn:indicesMayHaveShifted:)` whose doc comment states when membership filtering is safe and when it is not. The two shifting call sites pass `true`; the three non-shifting ones keep the filter, so a search keystroke no longer costs the user their selection. Three tests, both mutations reproduced independently, and the re-reviewer re-ran the original trace against the fixed code as a throwaway unit test. |

Three more plan defects were caught before they could reach a commit, and are worth recording
because they show what the plan got wrong *systematically* rather than by accident:

- **Interfaces contradicting their own sample code.** Task 6's brief declares
  `SourcePane(model:onClear:)` and then wires the button to an inline `model.sourceText = ""`.
  The interface line won; Task 7 supplied the closure.
- **A named function that does not exist.** Task 7's sample calls
  `GeneralPasteboard.write(_:)`; the type's only member was `withExclusiveAccess(_:)`. The same
  brief hedged two lines later — "Check `GeneralPasteboard`'s actual API … Do not guess" — which
  is the plan telling the implementer not to trust the plan.
- **`@Test` functions that `await` without `async`.** In Tasks 5, 8 and 10's briefs. Caught by
  the compiler every time, which is the cheap kind.

And two ordering problems resolved before dispatch: Task 6/Task 7's two options for deleting
`ChunkHint`, one of which leaves a commit that does not build (Task 6 leaves it, Task 7 deletes
it — the Global Constraint "both must hold at every commit" governs); and Task 10's
`resident.contains(model.name)`, which had to be `models.resident.contains(...)`.

### What the plan got right that an implementer removed

Worth its own heading, because it is the mirror image and it cost a fix round. Task 4's brief
called for `layoutSubtreeIfNeeded()` after reassigning the measuring host's `rootView`. The
implementer dropped it, reporting it as **measured** unnecessary. The measurement was real but
narrow: it had been taken with a builder that captured a `String`, where the rebuilt view
genuinely differs and SwiftUI re-evaluates unasked. The app is not that case — `PanelHost`
reads its model inside `body`, so the rebuilt view's stored properties are identical and the
pending invalidation is never flushed. Restoring the line was fix round 2.

---

## Over-claims

Eight over-claims are what the branch's running ledger counted through Task 13; enumerated by
shape below they come to eleven entries, because Task 9's two comment losses and Task 13's four
comment findings can each reasonably be grouped as one — and because the last row was committed
by **Task 14**, the task written to close the pattern. **The count is not the point.** The
pattern is, and it is the most transferable thing on this branch: on work that cannot be seen,
the failure mode is not writing broken code, it is writing a true-sounding sentence about code
nobody checked.

| Task | Shape | What was claimed, and what was so |
|---|---|---|
| 2 | **Declared clean when it was not.** | "Concerns: None. Implementation matches brief exactly" — while the `userSized` branch could return a zero frame. The report's own later diagnosis names the cause: an invariant that was assumed but not enforced, "outside the type, in calling code that did not yet exist". |
| 4 | **«Measured» attached to a narrow observation and then generalised.** | The `rootView` reassignment was reported as sufficient, «measured». True for a captured `String`, false for the observation case the app actually is. |
| 4 | **A screen appearance stated as fact.** | A comment described the rounded corner rendering "with no grey notch". Nothing had rendered it. Rewritten as the AppKit mechanism — an `NSWindow` fills its frame with `backgroundColor` beneath whatever SwiftUI draws, so a `clipShape` alone exposes the window's own fill — with the appearance claim removed and listed in `OPEN-ITEMS.md` instead. |
| 7 | **A clean-build check that was incremental.** | The report and the commit message said `swift build --build-tests` was run with `.build` removed and returned 0 warnings. Only `.build/debug` was removed, after an earlier build, so `RunStatusBar.swift` was never recompiled — and its real warning (an unused `if let summary` binding) is exactly what the incremental run could not see. Corrected by amending the original commit message in place, tree verified unchanged. |
| 7 | **"Mirrors X exactly" when it did not.** | `copyWindowResult()` was described as following `HotkeyCoordinator.copyResult()`'s pattern. It wrote `NSPasteboard.general` directly, fire-and-forget, bypassing `GeneralPasteboard`. The fix made the claim true rather than softening it: one writer for both callers, with a scratch-board test that fails under a dropped write. |
| 9 | **A comment deleted while the report said the code around it was untouched.** | Twice. `.onAppear` *was* untouched; the four-line comment above it was gone. And "every piece of text required to survive verbatim did so" was true of the label strings, which had been checked, and not of the `.fixedSize` comment's wording, which had never been diffed. Both restored verbatim. This is the failure mode `CLAUDE.md` names by name. |
| 10 | **A verified count asserted for a set that was never enumerated.** | "Every one of the five comments in that file carried over", while naming two. The deleted file held three comment blocks; two moved and one correctly stayed behind. |
| 11 | **A test claimed to verify a property it gives zero signal for.** | "Stable sort using index tiebreaker handles the critical test case that would fail with unstable sort." The test had been run green and the green read as confirmation, without ever mutating the tiebreaker away. |
| 12 | **A comment promising two load-bearing reasons when one had been invalidated.** | The by-index comment said "Two independent reasons, both load-bearing". One of them — `Table` needing bindings into `let` properties — had been stale since `GlossaryEntry`'s properties became `var`, in the very commit the comment's own ledger tag pointed at. Cut to the one reason that still holds, tag restored. |
| 13 | **Rationale claiming more precision than it has.** | Four at once. A defaulted closure justified by "the existing tests that construct this view directly" — `grep -rn "MainWindowView" Tests/` returns nothing, and the default would have let a future second call site compile while silently never refreshing. A fold comment arguing why one observer beats two, which never mentioned that the panel builds *two* hosts and both would call it. An ordering rationale justified on residency accuracy, when residency can only ever change the label's text and never the glyph. And `MenuBarExtra` content caching stated as fact, inherited from general SwiftUI behaviour and measured on nothing. |
| 14 | **A stand-in's artefact recorded as a measurement — in the file that exists for provenance.** | This document, `PLATFORM-TRAPS.md`, `OPEN-ITEMS.md` and `MEASUREMENTS.md` all carried "five presses all came out 300 × 120 — it freezes at the first content it ever laid out". Both halves were artefacts of a probe that replaced `PanelHost` with a look-alike; against the real type the size lags rather than freezing. The `MEASUREMENTS.md` row — the one a future reader cites — carried the sequence with no mention that the content was a stand-in at all. Caught on review, re-taken against the real `PanelHost`, and written up above. Recorded here rather than quietly fixed, because a catalogue of over-claims that omits its own author's is the same failure one level up. |

Two things about this list are worth more than the list itself.

**Every one was caught by someone re-running the claim rather than reading it.** The reviewer
who found Task 7's incremental build re-ran it with `.build` gone. The reviewer who found Task
11's tautology mutated the tiebreaker away at four array sizes. The re-reviewers on Tasks 10,
11 and 12 reproduced the implementers' mutation claims independently instead of accepting them.
Reading a report cannot catch an over-claim; only re-running it can.

**Refusing a bad correction is part of the job.** Task 10's reviewer proposed a fix that was
still tautological, for a subtler reason, and the implementer said so and used a different one.
Task 13's implementer rejected two things the brief asked for — an `onRefresh` parameter that
the brief's own wiring never calls, and hanging a `.task` on `MenuBarExtra` content, which the
brief's own prose concedes is unreliable across macOS versions. Both rejections were judged
correct on review. Performative agreement would have shipped dead code and an indicator that
works on some machines.

---

## Measurements

### Taken

| Figure | What it says |
|---|---|
| **274 × 94** and **6929 × 302** | The real `PanelView` through the two calls `PanelController.measure` makes, for a one-word and a forty-sentence translation. They clamp to `PanelSizer`'s width floor and ceiling respectively. Heights at each candidate width, for the record: short 94 at 300, 400 and 560; long 558 / 398 / 302. |
| **1.797e+308** on both axes | What `sizeThatFits(in: unbounded)` answers on the real `PanelView` for short *and* long content. `greatestFiniteMagnitude` is finite and positive, so an `isFinite && > 0` guard reads it as a measurement. This is why the width pass uses `fittingSize`, where a `Spacer` is 0. |
| **6929 × 44**, frame or no frame | An `NSHostingView`'s `fittingSize` for a long paragraph, both unframed and with the frame preset to 560 × 120. `fittingSize` is not a proposal-taking API, so there is no way to ask an `NSHostingView` for a height *at a width*. |
| **274 × 94 → 6929 × 94 / 302** | The measuring host before and after `layoutSubtreeIfNeeded()`, with content changed through `@Observable`. Both `fittingSize` and `sizeThatFits` are stale in the same way and neither read may be hoisted above the layout call. |
| **300 × 120 / 300 × 120 / 326 × 120 / 560 × 131 / 560 × 305** with the layout call, and **300 × 120 / 300 × 120 / 560 × 305 / 326 × 120 / 560 × 131** without it | Five presses — short text, long text, `.empty`, `.notPermitted`, short text — through the **real** `PanelHost` and the **real** `HotkeyCoordinator.handlePress`, frame read at `show(at:)`. Deterministic, and identical whether or not the panel is hidden between presses. See the section below for what it settles and what it refutes. |
| **canBecomeKey: `true` → `false`** | A stock `NSPanel` with the old mask and with the new one. Dropping `.titled` is what makes `TranslationPanel.canBecomeKey` load-bearing; it was not before. |
| **600+ combinations, 0 mismatches** | `RunStatusBar`'s warning count against `WarningsView.hasContent`, probed to establish that the agreement is structural rather than coincidental. |
| **3, 50, 200, 5000 entries** | Array sizes at which the glossary tiebreaker's removal was mutated in and *not* caught. Recorded in the source so the line is not tidied away on the strength of a green suite. |
| **installed=1 measured=1 → installed=1 measured=0** | The panel refreshing Ollama's status twice per settled run, because `PanelController` builds two live hosts from one builder and both observed `panelModel.state`. Gated on the installed variant; `onContentChange` deliberately still fires from both, so sizing is untouched (Panel tests 54/54). |
| **7 / 20 → 0 / 40** | Full-suite failures before and after the flaky-test fix. The failing assertion was always the *lower* bound — `translatedText` still empty at the moment of cancellation — because the `@MainActor` tests share one actor and a third of a second of synchronous layout work in another test starves token delivery through a 150 ms sleep. Both tests now wait on the condition their assertion needs, then cancel; the assertions are unchanged and the deadline records an `Issue` rather than sleeping. (The branch ledger records the pre-fix rate as 4 in 20 and the reviewer measured 6 in 19; the three counts are different samples of the same flake.) |
| **«4,8 ГБ»** from 5 100 273 664 | `RussianCopy.modelSize`, pinned to `ru_RU` so the decimal comma is asserted rather than inherited from the machine. |

### Invalidated and re-taken

- **`constrainFrameRect`.** Its evidence was taken on a `.titled` window. Re-measured against a
  stock `NSPanel` with the new mask: a frame crossing the menu-bar band still comes back pulled
  down by the height of the band, identically. The Stage Manager case — x = 19 → x = 221 — did
  **not** reproduce, which is consistent with the original note saying it was taken on a machine
  with Stage Manager on. Both facts are now in the comment and mirrored in the test's doc.
- **The panel's ideal heights, 97 pt and 301 pt.** Retired with the doc comment that held them.
  They described a size the controller now measures directly, and quoting stale numbers beside a
  live measurement is worse than having none. Replaced by 274 × 94 / 6929 × 302 above.
- **The settings panes' 420 / 420 / 520 × 440 / 420 spread.** Superseded by design rather than
  disproved — it is now recorded in `SettingsPane`'s doc comment as the *reason* one shared
  560 × 480 frame exists.

### Retired as unrepeatable, and deliberately not deleted

- **`hosting.sizingOptions = []`, 380 × 120 → 380 × 260.** Taken on a `.titled` panel against a
  fixed size, and neither condition exists any more. The mechanism it records is sound and the
  line stays on that basis; the numbers are quarantined in the comment, in
  `docs/MEASUREMENTS.md` and in `docs/PLATFORM-TRAPS.md`, and re-measuring is owed to a human.
  The project contract offers two options for an invalidated measurement — re-measure, or record
  why it no longer applies — and this took the second.
- **«~70 characters in the 500 ms window, the 5 ms sleeps settling at ~7 ms each».** Retired
  rather than disproved: after the flaky-test fix there is no longer a window for it to
  describe, because 31 characters is a precondition of reaching the line rather than a
  prediction about it.
- **The `Table` half of the glossary's by-index reasoning.** Invalidated by `GlossaryEntry`'s
  properties becoming `var` in an earlier plan; the surviving reason is that duplicate terms are
  reachable, so rows have no stable identity.
- **The rationale for refreshing Ollama's status *after* `warmUp()`.** It rested on residency
  accuracy, but `menuBarSymbol` maps `.unknown` and both `.running` cases to the same glyph, so
  residency only ever changes the label's text. The real cost fell the other way: `warmUp()`
  awaits a request with a 120-second timeout, so a hung Ollama would leave a healthy-looking
  glyph up for two minutes. `refresh()` now runs first, with the trade stated.

### The one measurement this branch got wrong three times

It is worth the space, because it is the cleanest example on the branch of the thing the branch
kept doing: three probes, three different answers, and the first two were wrong for the same
reason.

The comment in `PanelController.measure` says a stale measuring host sizes «every» press
against the previous one, and singles out `.empty` and `.notPermitted` as the presses that never
get a second chance, because neither runs a translation.

- **Probe 1**, run during Task 4's fix rounds, reported that a change of selection *kind*
  re-evaluates without a layout pass — because `PanelHost` hands `selection` to `PanelView` as a
  stored value — and therefore that `.empty` and `.notPermitted` were never stale and only
  text-to-text presses were. That was written into this ledger as the branch's third over-general
  claim in Task 4, and Task 14 was instructed to narrow the comment on the strength of it.
- **Probe 2**, run at Task 14 to check probe 1 before writing it down, could not reproduce it. It
  reported the opposite over-correction: that without the layout call the host *freezes* at the
  first content it ever laid out, so all five presses of a sequence came out 300 × 120. The
  comment was left alone on that basis, which was the right call for a wrong reason.
- **Probe 3**, run at Task 14's review, settled it. Both earlier probes used a **stand-in** for
  `PanelHost` rather than the type itself, because `PanelHost` is `private` to `TranslatorApp`.
  Lifting that one keyword makes it visible to `@testable import`, and `HotkeyCoordinator`
  already takes an injectable `SelectionReader`, so presses can be driven through the real
  `handlePress` instead of simulated. Neither earlier probe took that route, and each got a
  different wrong answer for it.

Against the real `PanelHost`, frame read at `show(at:)`, five presses — short text, long text,
`.empty`, `.notPermitted`, short text — deterministic over repeated runs and identical whether or
not the panel is hidden between presses:

| press | with `layoutSubtreeIfNeeded()` | without it |
|---|---|---|
| 1 · `.text` short | 300 × 120 | 300 × 120 |
| 2 · `.text` long | 300 × 120 | 300 × 120 |
| 3 · `.empty` | 326 × 120 | **560 × 305** |
| 4 · `.notPermitted` | 560 × 131 | **326 × 120** |
| 5 · `.text` short | 560 × 305 | **560 × 131** |

Three things follow, and the comment survives all three.

1. **A selection-kind change is stale too.** Probe 1 is refuted: `.empty` and `.notPermitted`
   come out at the wrong size, and they are precisely the presses with no translation to correct
   them. «Every» is right.
2. **The stale size is not frozen — it lags.** Probe 2 is refuted: presses 4 and 5 are each
   exactly the previous press's size. Press 3 is stale at a size that is neither its own nor its
   immediate predecessor's, so «lags by exactly one» describes the direction and two of the three
   affected presses here rather than a law — but «sizes every press against the previous one»,
   which is what the comment actually says, is the accurate description.
3. Presses 1 and 2 are equal in both columns and that is **not** staleness: `handlePress`
   assigns `sourceText` *after* `afterCapture()` shows the panel, so a text press legitimately
   opens on the previous run's content either way. Only presses 3, 4 and 5 discriminate.

The transferable part is not the numbers. It is that two probes agreed on nothing except that
they had both replaced the type under test with something shaped like it, and that a two-keyword
access-level change was all that stood between them and the real answer. Where a probe stands in
for the thing being measured, the stand-in is the measurement.

---

## Rejected, and why

- **Unifying the two glossaries' injection rules.** Not attempted; `docs/adr/0001` already owns
  the reason and no task on this branch went near the engine.
- **`onRefresh` threaded through `MenuContent`, and a `.task` on `MenuBarExtra` content.** Task
  13, rejected by the implementer and upheld on review. The brief's own prose concedes the
  `.task` is not reliable across macOS versions, and its own sample body never calls the
  parameter — an indicator that refreshes on some machines and not others is worse than one that
  refreshes at five known points and says so. "When the menu opens" was dropped from the trigger
  list entirely rather than worked around with an `NSMenuDelegate`.
- **Deleting the `sizingOptions` line along with its stale numbers.** Rejected: the mechanism
  outlived the conditions the numbers were taken under.
- **Removing the glossary tiebreaker because no test catches it.** Rejected, with the honest
  comment as the price: the line makes the ordering total, and its removal is invisible to
  black-box testing on this toolchain.
- **Merging the two `TranslationViewModel` instances.** Never proposed; still forbidden for the
  reason `docs/adr/0004` gives.
- **The reviewer's own suggested fix at Task 10.** See above — still tautological, refused.

---

## Deferred, with the reason

None of these was fixed. They are recorded so that a future reader can tell «unfinished» from
«decided». The three that a user could actually meet are promoted into `docs/OPEN-ITEMS.md` §2;
the rest live only here.

**Behaviour, and therefore promoted:**

- `windowDidEndLiveResize` sets `userSized` but never re-fits, so dragging a finished panel
  smaller clips its content, with no scroll view, until the panel hides.
- `lastFit` is not reset in `show(at:)`, so a presentation opening within 100 ms of the previous
  one's last fit has its first growth delayed.
- A trailing-fit `Task` scheduled in one presentation can be consumed by the next when a hide
  and a show land inside 100 ms. Benign — `applyFit` re-measures live state — but it jitters the
  throttle. A generation token would make it exact.

**Test coverage that is held by inspection rather than by test:**

- `thePanelOffersACloseControlOfItsOwn` proves `onClose` is stored and callable, not that the
  header's ⨯ is what calls it. A copy-paste wiring the button to a different closure passes.
  Inherent to an environment with no GUI automation.
- No test passes NaN into `PanelSizer.measured`. Today's implementation handles it — NaN is
  neither finite nor equal to infinity, so it falls to the floor — but weakening the first
  branch to `value != 0` would let NaN through as a frame value and none of the eleven tests
  would notice.
- Nothing asserts `resolvedTarget == nil` or `state == .idle` after a language swap; deleting
  either line passes all six of the task's tests. Traced as unexploitable through the current
  consumers, which gate on `outcome` and `target` together.
- The swap path that derives languages from a finished run is tested for `canSwapLanguages` and
  never for the values `swapLanguages()` actually writes.
- The stale-`expanded` fix in the status bar has no automated coverage; this project has no
  SwiftUI view-state inspection tooling.

**Comments that claim more than they hold:**

- `SourceFooter`'s carried-over comment lost the parenthetical naming its inputs
  (`sourceText`, `settings.chunkSize`), so the claim is no longer checkable, and it still says
  `ChunkHint` "is deleted once Task 7 rebuilds the window" in the future tense — pointing at a
  type that no longer exists.
- `WarningsView.hasContent`'s doc still says the panel hands the warnings a fixed 120 pt slot,
  in the present tense; `PanelView` says that slot is gone. Pre-existing, adjacent.
- `PanelSizer.measured`'s `.infinity` branch is unreachable as called — greedy SwiftUI views
  answer `greatestFiniteMagnitude`, not `.infinity`. Same outcome; the comment describes a case
  that cannot occur.
- The `measuring` doc comment claims an `intrinsicContentSize` figure the probe table behind it
  does not carry.
- The glyph's staleness comment omits «Проверить снова» in the «Модели» pane — a sixth,
  user-driven refresh point, and the most relevant one for a user who suspects the glyph.
- The window's run hook fires on every non-`.running` transition, which includes
  `swapLanguages()` and `adopt(from:)`, not only translation attempts. Every extra fire makes
  the glyph fresher, so this is a comment defect and not a behaviour one.
- `MenuBarExtra` content caching is stated as fact and is inherited, not measured. Moved to
  `docs/OPEN-ITEMS.md` §3 as an open question.

**Dead or stray:**

- `setContentBuilder`'s `measuring.rootView = builder(false)` is dead now that `measure()`
  reassigns it every pass.
- `MainWindowView.settings` is unused after the rewrite.
- `aShortTranslationInTheRealPanelViewDoesNotAskToScroll` asserts
  `height < visibleFrame.height * maxHeightFraction`, which degenerates to `120 < 120` on a
  display shorter than 200 pt.
- A test named `afinishedRunSupplies…` should be `aFinishedRun…`. The typo originates in the
  plan.
- `PanelView`'s property declaration order differs from the plan's stated argument order.
  Harmless: every call site uses keyword arguments.

---

## Hand checks performed

**None.**

Not "none yet", and not "deferred to a later pass" — none, at any point on this branch, by
anyone. Fourteen tasks changed three visible surfaces and a menu-bar icon, and no human and no
agent looked at any of them. Every task report says so in its own words, and five commits —
`35a4221`, `f075acd`, `9f6e27f`, `7162486`, `c517c8d`, one for each visible surface the branch
rebuilt — carry the caveat in the commit message itself.

What was gathered instead, uniformly, across every task:

- **Clean-rebuild warning counts**, run with `.build` actually removed after Task 7's over-claim
  showed what an incremental check misses. The two `grep -i warning` hits every run produces are
  the compiler naming `WarningsView.swift` and `WarningsViewTests.swift`.
- **macOS 14 floor checks read out of the SDK's `.swiftinterface`** wherever the API was new to
  the file — the SDK on this machine is far above the floor, so a successful build proves nothing
  about availability. Read directly: `LabeledContent` 13.0, `GroupedFormStyle` 13.0,
  `TitleAndIconLabelStyle` 11.3, `List(_:id:selection:rowContent:)` 10.15, the
  `.roundedBorder` and `.labelsHidden()` modifiers, `Label(_:systemImage:)` for a `StringProtocol`
  at 11.0, and `onChange(of:initial:_:)` at exactly macOS 14.0. Not every figure in the reports
  has that provenance: `ViewThatFits` at 13.0 and `HSplitView` at 10.15 are stated from recall —
  `HSplitView` is described as "SwiftUI's original split-view API" rather than cited — and should
  be re-read before anyone relies on them.
- **Mutation testing**, per `docs/TESTING.md`, with the source restored and `git status`
  confirmed clean after each one.
- **Scratch probes** for the things a unit test cannot reach: the four hosting-view measurement
  candidates, the observation staleness, the doubled status refresh, and this task's five-press
  re-probe.
- **`./Scripts/make-app-bundle.sh`** at Tasks 4 and 7 — the bundle assembles and signs with the
  «LocalTranslator Dev» identity. A build and signing check, and nothing more: that the identity
  is what makes the Accessibility grant survive a rebuild is inherited from `CLAUDE.md` and from
  Plan 3's manual pass, and was not re-established on this branch.

The distinction that matters, and the one this project keeps having to relearn: a green suite
says the arithmetic is right. It says nothing about whether the arithmetic reaches a screen.
Spec §8 knew that before the first line was written; `docs/OPEN-ITEMS.md` §1 is where it is now
kept, and it is the first thing a human with the bundle on a screen should work through.

---

PLAN COMPLETE. 341 tests, `swift build --build-tests` at zero warnings on a rebuild with
`.build` removed. No acceptance run was made: no task on this branch touched the engine, so
there was nothing for the corpus harness to regress against.
