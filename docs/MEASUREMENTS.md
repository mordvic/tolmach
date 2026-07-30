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
| **300 × 120**, five presses running | A `PanelController` driven through short, long, `.empty`, `.notPermitted` and short again with `measuring.view.layoutSubtreeIfNeeded()` removed: every press frozen at the first content laid out. With the call restored: 300 × 120 / 560 × 302 / 326 × 120 / 560 × 128 / 300 × 120. | `TranslationPanel.swift` |
| **x = 19 → x = 221** | A panel frame rewritten by `constrainFrameRect` on order-in, AppKit reserving the Stage Manager strip. **Re-measured after `.titled` left the mask and this case did not reproduce** — consistent with the original note saying it was taken with Stage Manager on. What did reproduce: a frame crossing the menu-bar band still comes back pulled down by the height of the band, identically to the titled panel. That is what keeps the override. | `TranslationPanel.swift` |
| **~19 ms** | Round trip to snapshot and restore a 64 MB pasteboard flavour. Not a hotkey-path hazard at that size. | `PasteboardSnapshot.swift` |
| **~0.5 µs** | A full keyboard-layout lookup through `UCKeyTranslate`. Cheap enough to hold a lock across. | `HotkeyCombo.swift` |

---

## Durable — the models

From the throwaway prototype that preceded the engine. See the note below about its status.

| Figure | Meaning | Owner |
|---|---|---|
| **~2000 ms** cold vs **~155 ms** warm | Model load. This is the entire reason `keep_alive` is treated as load-bearing rather than as an optimisation, and the reason the app warms the model at launch. | `CLAUDE.md`, `TranslatorApp.warmUp()` |
| **78 s** | `qwen3:30b` reasoning before the first character of translation. Why it is blacklisted for the interactive path. | `ModelPolicy.swift` |
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
