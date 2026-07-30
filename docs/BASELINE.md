# Acceptance baseline

`swift run acceptance` prints numbers and then says ACCEPTED or FAILED. On its own that is a
binary: it cannot tell you whether 85.2 % adherence is normal for this corpus or a regression
that squeaked past the floor. This file is the record that makes it interpretable.

**Append, do not edit.** Each entry is what one run actually printed, with enough about the
machine to know whether two entries are comparable. An entry is never revised after the fact —
if a number looks wrong later, that is a finding, not a typo.

Run it from the package root; the harness reads `./corpus` relative to the working directory.

---

## Reading the output

Three kinds of line, and two of them are not warnings even though they read like one:

- **`average N% (x/y)`** — cross-chunk terminology adherence: of the terms the document
  glossary fixed, how many came back rendered the same way in every chunk. **Gated at 80 %.**
  Only multi-chunk files have it; a single-chunk file prints `adherence n/a` because a
  document glossary is not built for one chunk, and that is correct rather than a gap.
- **`TTFT … (info only — multi-chunk, not asserted)`** — time to first token. **Gated at
  1000 ms, but only for single-chunk files.** A multi-chunk run pays for the preparatory
  term-list call before its first chunk, so its TTFT measures something else entirely and is
  printed for information. The single-chunk figures are the ones that guard the hotkey path's
  hard requirement.
- **`known` and `known-limitation`** — markup diffs that are expected and deliberately not
  failed. They are recorded so that a *new* diff is visible against them, not because
  something is wrong. Their content is in §11a of the design spec.

TTFT is the first **consumer-visible** emission, not the first token off the wire — see
`TranslationOutcome.timeToFirstTokenMS` in `Sources/TranslationCore/Translator.swift`, which
owns that definition. The thresholds live in `Sources/acceptance/main.swift`.

An entry that says FAILED is worth keeping. A baseline with no failures in it is a baseline
nobody has tested.

---

## Runs

### 2026-07-29 — after the documentation pass

- Machine: Apple M5 Pro, macOS 26.5.2
- Ollama 0.31.1, model `aya-expanse:8b`
- Commit: `5a4d5f8` plus the documentation work (no engine code changed)
- Verdict: **ACCEPTED**

```
article-en.md: run1 83.3% (30/36) · run2 91.7% (33/36) · run3 90.6% (29/32) · average 88.5% · 3 chunks · 20 terms · TTFT 3251/2962/2916 ms (info only — multi-chunk, not asserted)
email-en.md:   adherence n/a (single chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 453 ms
snippet-en.md: adherence n/a (single chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 464 ms
techdoc-en.md: run1 87.8% (43/49) · run2 87.8% (43/49) · run3 87.8% (43/49) · average 87.8% · 4 chunks · 20 terms · TTFT 3059/2730/2774 ms (info only — multi-chunk, not asserted)
techdoc-ru.md: run1 94.4% (51/54) · run2 94.4% (51/54) · run3 94.4% (51/54) · average 94.4% · 4 chunks · 20 terms · TTFT 3908/3252/3031 ms (info only — multi-chunk, not asserted)
```

Both known markup diffs reproduced on all three runs of `techdoc-en`: the bare URL rewritten
into link syntax, and the model translating the commit message inside a bash fence. No new
diff appeared.

The gated numbers: single-chunk TTFT **453 ms** and **464 ms** against a 1000 ms ceiling, and
the lowest average adherence **87.8 %** against an 80 % floor.

Worth noting for comparison with future runs: `article-en` swung from 83.3 % to 91.7 % across
three runs of the same input, which is the normal spread at temperature 0.2 and the reason a
single low run is not a regression. `techdoc-en` and `techdoc-ru` were identical across all
three runs.

---

## What a regression looks like

- **Adherence drifting below 80 %** on `techdoc-en` or `techdoc-ru` is the signal the document
  glossary has stopped working. Before it existed the same corpus measured 64–68 %; the whole
  mechanism is worth about twenty points, so a drop toward the seventies means something in
  the glossary path is half-broken rather than merely noisy.
- **Single-chunk TTFT above 1000 ms** means the hotkey path no longer meets its one hard
  requirement. Check first whether the model was resident: a cold load costs about 2000 ms
  against roughly 155 ms warm, so an unwarmed run fails this for reasons that have nothing to
  do with the code.
- **A new markup diff** that is not in the `known` list is a real change in how the model
  treats structure. Add it to the list only after deciding it is acceptable, never to make the
  run green.
- Run-to-run variation of two or three points in adherence is normal — the model is sampled at
  temperature 0.2, not zero. A single low run is not a regression; three are.
