# Measurements

Every number this project rests on, with what it means and where the reasoning lives.

**This file is an index, not the authority** — same standing as `docs/PLATFORM-TRAPS.md`. Each
figure is owned by a code comment or by `docs/BASELINE.md`; those are kept true by sitting next
to what they constrain. When they disagree, they are right.

The numbers split by lifetime, and the split matters more than the numbers:

- **Durable** — facts about macOS, AppKit and the models. Re-measuring is expensive and rarely
  worthwhile; they change when Apple or Ollama changes something.
- **Perishable** — what the engine scores today. Re-measured by `swift run acceptance` on every
  run, machine-dependent, and recorded in `docs/BASELINE.md` rather than here. **No perishable
  number is copied into this file**, because a copy is a claim that stops being checked.

---

## Durable — the platform

| Figure | Meaning | Owner |
|---|---|---|
| **1.503 s** vs **22 ms** | Accessibility messaging against a wedged app vs a healthy one. The default 1.5 s timeout is spent synchronously on every hotkey press; bounded to 0.25 s. | `SelectionReader.swift` |
| **10 / 10**, **0 / 10** | `NSPasteboard` concurrent-read aborts for one name, and for distinct names. The asymmetry is what identifies the per-name item cache as the corrupted state. | `PasteboardSnapshot.swift` |
| **3 / 3** | TIS/TSM concurrent-use aborts, with and without a lock — and again with a locked background call against unlocked AppKit main-thread calls, which still aborts. | `HotkeyCombo.swift` |
| **0.5 s** | Clipboard poll deadline after the synthetic ⌘C. Long enough for a slow app, short enough not to stall; a copy arriving later overwrites the restored clipboard, which is the one failure the fallback cannot contain. | `SelectionReader.swift` |
| **380 × 120** → **380 × 260** | The panel before and after `sizingOptions = []`. The first is what `NSHostingView` compressed it to regardless of content. **Quarantined:** taken on a `.titled` panel against a fixed size, and neither condition exists since the UI redesign. The mechanism stands; the figures cannot be reproduced without the bundle on a screen. | `TranslationPanel.swift`, `docs/OPEN-ITEMS.md` |
| **274 × 94** / **6929 × 302** | The real `PanelView` measured through the two calls `PanelController.measure` makes, for a one-word and a forty-sentence translation. They clamp to `PanelSizer`'s width floor and ceiling. These replace the **97 pt / 301 pt** ideal heights, which are retired with the doc comment that held them: they described a size the controller now measures directly. | `TranslationPanel.swift`, `PanelSizer.swift` |
| **1.797e+308** | What `sizeThatFits(in: unbounded)` answers on the real `PanelView` for *both* a one-word and a forty-sentence translation — `greatestFiniteMagnitude`, which passes an `isFinite && > 0` check and is read as a real measurement. Why the width pass uses `fittingSize` instead. | `TranslationPanel.swift` |
| **4.75 → 6.04**, ink **991 → 1197** | The two levers behind «текст плохо читаем», which 4.75:1 — past WCAG's 4.5 — did not answer. The fill became a pair: `#0F6E6E` where the ground is white and separation is free (label 6.04, separation 6.04), `#15807E` where it is not (4.75, 3.51). Deeper was measured and rejected: `#0C6060` reads 7.35 but sits 55 from `StatusColour.success`, inside the ~60 at which two fills read as one. And the label went semibold — counted as glyph pixels against the fill's, 991 at regular, 1139 at `.medium`, **1197** at `.semibold`, 21% more ink for the same colours. | `PrimaryButtonColour.swift` |
| **93 → 105** | «Перевести»'s control width, and why it grew. `.borderedProminent` gave a 68 pt label a 93 pt control — 12.4 pt a side — while the toolbar's three `Menu`s came out 134–168 pt; discounting their chevron leaves roughly 17–18 pt around their labels, so the primary action had the least air of anything in the row it leads. On the bundle the toolbar items read `[120, 28, 109, 143, 94]` afterwards and still fit from ≤620 pt, under the window's 700 minimum. | `PrimaryButtonColour.labelPadding` |
| **4.75 / 4.75 / 3.51**, distance **74** | «Перевести»'s fill, `#15807E`, against the three things a primary fill must satisfy: a 13 pt label wants 4.5:1, a control wants 3:1 against the window behind it in **both** appearances, and two fills closer than ~60 in sRGB read as one colour. It is the only candidate clearing all three with a single value — the deeper teal `#0F6E6E` separates at 2.76 on a dark window, indigo at 1.82, and the icon's own cinnabar sits 27 from `StatusColour.failure`. The system accent it replaced managed 4.02 on the label at best. Re-measure with `Scripts/accent-contrast.swift`. | `PrimaryButtonColour.swift` |
| **1.41:1 → 3.23:1** | The worst white-on-accent contrast across the eight accents System Settings offers, before and after the label colour is derived from the fill. White fails 4.5:1 on **every** accent and falls to 1.41 on yellow in the dark appearance; the switch at 3:1 leaves blue, purple, pink and red with the platform's own white and flips orange, yellow, green and graphite to black. Maximising instead would put black on all eight — black beats white everywhere — which is not what a Mac app draws. Re-measure with `Scripts/accent-contrast.swift`. | `AccentLabel.swift` |
| **2.31:1** / **2.22:1** / **3.57:1** → **4.20:1** / **5.27:1** / **4.99:1** | `systemOrange`, `systemGreen` and `systemRed` as 11 pt text on a white pane in the light appearance, against the darkened values the drawing uses instead. The dark appearance needs no correction — the drawing's own dark orange and the measured `systemOrange` there are the same colour — so `StatusColour` answers with the system colour on that side and a hex on this one. Re-measure with `swift Scripts/colour-contrast.swift`; `StatusColourTests` asserts the three the app ships. **4.20 is short of WCAG AA's 4.5** and is the drawing's own value, kept as drawn — `docs/OPEN-ITEMS.md` carries the gap. | `StatusColour.swift` |
| **560 × 120** holding **270** | The panel after the user dragged 150 pt off its bottom edge, against what its content needed. Nothing re-fitted after a drag, so the non-scrolling variant stayed installed and the whole bottom section hung below the window. The fix re-fits once, on release. Two things keep it from fighting the hand: `applyFit` declines outright while `inLiveResize`, and `contentMinSize` states a floor to AppKit. A settle landing during a drag is **lost, not deferred** — the machinery that tried to defer it was inert, because `windowDidResize` has already set `userSized` and `fit` returns from its own guard before it consults `settling`; once a hand has moved an edge the size is the user's until the panel hides. `userSized` alone was **not** enough and the first version of this row said it was: that branch of `fit` answers `max(previous, floor)`, which is the panel's own size only above the floors. | `PanelController.windowDidResize`, `windowDidEndLiveResize` |
| **300 → 160** at the settle | The panel's height when a reply comes back shorter than the room reserved for it. `PanelSizer.fit` is monotonic within a presentation so the reader is not moved mid-stream; `settling: true` is the one call exempted, because the middle section stretches and anything the height keeps after the content gives it back sits as a hole between the translation and the buttons. Pinned in `PanelSizerTests` and **not** against a real panel: the settle is the one resize `PanelController` animates, and a frame read after `panel.animator()` passed alone and failed in the full suite three times out of three. | `PanelSizer.fit`'s height rule |
| **300 × 120** against **134 / 198 / 294 / 486** | What the ⌥⌘T panel opened at, against what its content needed the instant the run started, for selections of one, three, six and twelve sentences. `HotkeyCoordinator.handlePress` shows the panel before it gives the model the text, so a reservation gated on `state == .running` was not in force when `show(at:)` measured — the panel opened at the floor on both axes — 120 when this was taken, 132 since — and the button row hung up to 366 pt below the bottom edge. Told by `HotkeyCoordinator.isStartingRun` instead — the one thing that is true before `translate()` runs — and with the status row reported from the same signal, the shortfall is **0** at every length. | `PanelView.awaitingReply`, `HotkeyCoordinator.isStartingRun` |
| **120 → 198** vs **198 → 174** | The panel's height across one streaming run of a six-sentence paragraph, before and after it reserves the reply's room from the source: it used to open at the floor, 120 pt at the time, and gain ~16 pt a sentence in five steps, each moving the button row under the reader's hand; it now opens at 198 and settles at 174, so the window never grows. The settle is 24 pt shorter at every length from two sentences to twenty — the «Перевожу…» row — which is why the buttons are held at the panel's bottom edge rather than under the text. | `PanelView.swift`, `TranslationPanelTests` |
| **{0, 0}** and **5** | `TextEditor`'s `textContainerInset` / `textContainerOrigin`, and the `lineFragmentPadding` its text container defaults to. The first is why the pane needs its own top margin — text otherwise starts against the top edge — and the second is why the placeholder's leading inset is 5 rather than matching the vertical one. Caret top and text-view top measured equal at 443 pt after the fix, with the pane top at 451. | `SourceEditor.swift` |
| **52 → 40** | The main window's toolbar band — `frame.height - contentLayoutRect.height` — under `.unified` against `.unifiedCompact`, verified on the running bundle. The row fits from the same width in both, so the 700 pt minimum does not move, and no title reappears. **`.controlSize` is not a lever here**: the band measures 52 at `.regular`, `.small` and `.mini` alike while the controls inside shrink 26 → 24 → 21. Re-measure both with `Scripts/toolbar-height.swift`. | `TranslatorApp.swift`'s `Window` scene |
| **840 → 960 → 900 → 700** | The window width at which `NSToolbar` stops pushing items into the » overflow: before the «Из»/«В»/«Тон» labels existed, with each label its own toolbar item, with each label paired beside its picker inside one item, and with each label folded into a `Menu`'s own title — which is what ships and what restores the drawing's 700 pt minimum. The last figure is the *guaranteed* one: measured on the bundle at 700 pt with four selections including the longest language name on both sides, 5 of 5 items visible each time. `.controlSize(.regular)` against the toolbar default was measured at **10 pt** and rejected as not worth leaving the platform metrics for. `Scripts/toolbar-fit.swift` compares arrangements; it disagrees with the bundle on absolutes, and the bundle wins. | `MainWindowView.swift`'s toolbar |
| **347 → 370 → 6929** | The real `PanelView`'s ideal width at three phases of one run: `.running` with no reply yet, `.running` with one line of it, and the whole forty-sentence reply. The heights those widths produce: 486 pt at ~330 against 302 at 560. This is why the panel's width is **not** chosen at `show(at:)` and not at the first content update either — no early moment knows the final width — and why it grows with the reply and freezes at the settle instead. 347 is also, independently, roughly what `minWidth` is for: it is the panel's own button row. | `PanelSizer.swift` (the width rule in `fit`) |
| **326 × 120** and **560 × 131**, versus **560 × 305** and **326 × 120** | An `.empty` and a `.notPermitted` press, opened with and without `measuring.view.layoutSubtreeIfNeeded()`. Taken against the **real `PanelHost`** driven through the real `HotkeyCoordinator.handlePress`, reading the frame at `show(at:)`; deterministic, and the same whether or not the panel is hidden between presses. Without the layout call the size is stale but **not frozen** — presses 4 and 5 of the five-press sequence are each exactly the previous press's size. The full sequence (short, long, `.empty`, `.notPermitted`, short) is 300 × 120 / 300 × 120 / 326 × 120 / 560 × 131 / 560 × 305 with the call and 300 × 120 / 300 × 120 / 560 × 305 / 326 × 120 / 560 × 131 without it. Reproducing it needs `PanelHost`'s `private` lifted for `@testable import`. Note what these frames are since the final fix wave: the size at `show(at:)` is now **provisional** — the width is no longer frozen there — so for a `.text` press the panel corrects itself as the reply arrives. It is still the right place to read the staleness from, and it is still the *final* size for an `.empty` or a `.notPermitted` press, because neither runs a translation. | `TranslationPanel.swift`, `docs/history/2026-07-30-ui-redesign-ledger.md` |
| **x = 19 → x = 221** | A panel frame rewritten by `constrainFrameRect` on order-in, AppKit reserving the Stage Manager strip. **Re-measured after `.titled` left the mask, and this case did not reproduce** — consistent with the original note saying it was taken on a machine with Stage Manager on. What did reproduce, and what keeps the override: a frame crossing the menu-bar band still comes back pulled down by the height of the band, identically to the titled panel. Both halves are in `constrainFrameRect`'s own doc comment now, with the difference in standing spelled out; for a while only the menu-bar half was, which is what `docs/OPEN-ITEMS.md` §2 recorded as owed. | `TranslationPanel.swift` |
| **~19 ms** | Round trip to snapshot and restore a 64 MB pasteboard flavour. Not a hotkey-path hazard at that size. | `PasteboardSnapshot.swift` |
| **~0.5 µs** | A full keyboard-layout lookup through `UCKeyTranslate`. Cheap enough to hold a lock across. | `HotkeyCombo.swift` |

---

## Durable — the models

From the throwaway prototype that preceded the engine. See the note below about its status.

| Figure | Meaning | Owner |
|---|---|---|
| **~2000 ms** cold vs **~155 ms** warm | Model load. This is the entire reason `keep_alive` is treated as load-bearing rather than as an optimisation, and the reason the app warms the model at launch. | `CLAUDE.md`, `TranslatorApp.warmUp()` |
| **78 s** | `qwen3:30b` reasoning before the first character of translation. Why it is blacklisted for the interactive path. **Not reproduced on 2026-08-11 and not refuted either**: the same model reasoned 14.5 s cold and 7.3 s warm — but against a one-sentence prompt, where the original figure came from a document, so the two do not measure the same thing. Re-measuring it properly needs a real text; until then the blacklist entry stands as written. | `ModelPolicy.swift` |
| **0 / 2798 / 563** | Characters of reasoning that `"think": false` leaves, on `qwen3:8b`, `qwen3:30b` and `gpt-oss:20b` — silenced, moved into `message.content`, and ignored outright. The three outcomes of one parameter across eight models, and the reason the rule about it is now written per model rather than per protocol. The full sweep, including the **HTTP 400** that `think: true` draws from a model without the `thinking` capability and the 15 / 441 / 889 characters `gpt-oss:20b`'s levels grade, is the table in `docs/PLATFORM-TRAPS.md`. | `ModelPolicy.swift`, `docs/PLATFORM-TRAPS.md` |
| identifier corruption | `gemma3n` mangles identifiers character-by-character — `StructureDefiinition` inside inline code. The worst failure mode for technical documentation, because it breaks a type name silently. | `ModelPolicy.swift` |
| **64–68 %** → **88 %** | Cross-chunk terminology adherence before and after the document glossary. The mechanism is worth about twenty points, which is why the two glossaries follow opposite injection rules. | `docs/adr/0001` |
| **20 terms** | Document-glossary cap. Chosen against an originally-intended 40 for the reason recorded in the ADR. | `TermExtractor.swift`, `docs/adr/0001` |
| **900 characters** | Default chunk size. Larger means a more coherent long translation and a longer wait for the first result. | `AppSettings.swift`, and the same default at each call site |
| **120 s** | Request timeout. | `OllamaClient.swift` |

### The prototype is not in this repository

The model figures above came from a throwaway prototype that the design spec cites as
`prototype-translation-engine/`. That directory holds only build artefacts, is untracked, and a
fresh clone gets nothing. **These figures are historical and cannot be reproduced from a
clone.** They are kept because they justify decisions that were really made — the model choice,
the blacklist, the two-glossary design — not because anyone can re-derive them.

Anything that still *gates* something is re-measured on every acceptance run, which is the
distinction that matters: a historical figure explains a past decision, a gated figure fails a
build.

---

## Perishable — see `docs/BASELINE.md`

Terminology adherence per corpus file, time to first token, and the markup diffs the model
produces are re-measured by `swift run acceptance` and recorded there, dated, with the machine
and model version. The two gates the harness enforces — a TTFT ceiling and an adherence floor —
are read out of `Sources/acceptance/main.swift` by a test, so a threshold cannot be changed
without the documentation going red.

---

## Adding a measurement

Put it in a comment at the code it justifies, with the count, not just the conclusion —
«10 aborts in 10 runs» rather than «this races». Then add a row here pointing at that file.
A number whose provenance is not recorded becomes unfalsifiable within a month, and this
project has one section of exactly that already.
