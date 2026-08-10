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

---

## 2026-08-10 — baseline before the prompt-improvement pass

- Machine: Apple M5 Pro, macOS 26.6.1
- Ollama 0.31.1, model `aya-expanse:8b`
- Commit: `5c6ca62` (prompt-improvement design plan, no engine changes yet)
- Verdict: **ACCEPTED**

Purpose: the «before» for the targeted prompt changes
(docs/superpowers/specs/2026-08-10-prompt-improvement-design.md §3.1).

```
article-en.md: run1 86.1% (31/36) · run2 83.3% (30/36) · run3 83.3% (30/36) · average 84.3% · 3 chunks · 20 terms · TTFT 3114/3021/2951 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 453 ms
snippet-en.md: adherence n/a (single chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 515 ms
techdoc-en.md: run1 87.8% (43/49) · run2 87.8% (43/49) · run3 87.8% (43/49) · average 87.8% · 4 chunks · 20 terms · TTFT 2886/2795/2951 ms (info only — multi-chunk, not asserted)
    known run1: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run1: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run1: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: -562926936420698314, lang: "bash")) actual nil)
    known-limitation run1: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: -903210525200679666, lang: "bash")))
    known run2: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run2: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run2: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: -562926936420698314, lang: "bash")) actual nil)
    known-limitation run2: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: -903210525200679666, lang: "bash")))
    known run3: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run3: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run3: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: -562926936420698314, lang: "bash")) actual nil)
    known-limitation run3: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: -903210525200679666, lang: "bash")))
techdoc-ru.md: run1 94.4% (51/54) · run2 94.4% (51/54) · run3 92.6% (50/54) · average 93.8% · 4 chunks · 20 terms · TTFT 3045/3084/3081 ms (info only — multi-chunk, not asserted)
```

The gated numbers: single-chunk TTFT **453 ms** and **515 ms** against a 1000 ms ceiling, and the lowest average adherence **84.3 %** (article-en), **87.8 %** (techdoc-en) and **93.8 %** (techdoc-ru) against an 80 % floor. All known markup diffs reproduced as expected; no new diff appeared.

---

## 2026-08-10 — after the anti-answering rule (prompt-improvement pass, change 1/2)

- Machine: Apple M5 Pro, macOS 26.6.1
- Ollama 0.31.1, model `aya-expanse:8b`
- Commit: `460eeb9` plus this task's change to `PromptBuilder.swift` (the anti-answering rule)
- Verdict: **ACCEPTED**

Purpose: measure the anti-answering rule added to both system prompts against the Task 1
baseline (docs/superpowers/specs/2026-08-10-prompt-improvement-design.md §3.1).

```
article-en.md: run1 88.9% (32/36) · run2 86.1% (31/36) · run3 86.1% (31/36) · average 87.0% · 3 chunks · 20 terms · TTFT 3185/2879/2967 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 447 ms
snippet-en.md: adherence n/a (single chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 465 ms
techdoc-en.md: run1 89.8% (44/49) · run2 87.8% (43/49) · run3 87.8% (43/49) · average 88.4% · 4 chunks · 20 terms · TTFT 3121/2827/2939 ms (info only — multi-chunk, not asserted)
    known run1: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run1: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run1: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: 960067138733016209, lang: "bash")) actual nil)
    known-limitation run1: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: 2070979244515798843, lang: "bash")))
    known run2: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run2: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run2: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: 960067138733016209, lang: "bash")) actual nil)
    known-limitation run2: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: 2070979244515798843, lang: "bash")))
    known run3: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run3: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run3: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: 960067138733016209, lang: "bash")) actual nil)
    known-limitation run3: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: 2070979244515798843, lang: "bash")))
techdoc-ru.md: run1 94.4% (51/54) · run2 94.4% (51/54) · run3 94.4% (51/54) · average 94.4% · 4 chunks · 20 terms · TTFT 3399/3067/3185 ms (info only — multi-chunk, not asserted)

ACCEPTED — engine meets the recalibrated baseline
```

The gated numbers: single-chunk TTFT **447 ms** and **465 ms** against a 1000 ms ceiling, and
the lowest average adherence **87.0 %** (article-en), **88.4 %** (techdoc-en) and **94.4 %**
(techdoc-ru) against an 80 % floor — each at or above its Task 1 baseline figure (84.3 %,
87.8 %, 93.8 % respectively), so nothing regressed by more than noise; every file in fact
moved flat-to-up. All known markup diffs reproduced as expected — the code-block hashes differ
run to run as they already did between the two prior entries — and no new diff appeared.

---

## 2026-08-10 — after the idiom/proper-noun rule (prompt-improvement pass, change 2/2)

- Machine: Apple M5 Pro, macOS 26.6.1
- Ollama 0.31.1, model `aya-expanse:8b`
- Commit: `92641e6` plus this task's change to `PromptBuilder.swift` (the idiom/proper-noun rule)
- Verdict: **ACCEPTED**

Purpose: measure the idiom-by-meaning and proper-noun rule added to the translation system
prompt only against the Task 1 baseline
(docs/superpowers/specs/2026-08-10-prompt-improvement-design.md §3.1).

```
article-en.md: run1 91.7% (33/36) · run2 83.3% (30/36) · run3 86.1% (31/36) · average 87.0% · 3 chunks · 20 terms · TTFT 3254/3022/2962 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 442 ms
snippet-en.md: adherence n/a (single chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 452 ms
techdoc-en.md: run1 87.8% (43/49) · run2 87.8% (43/49) · run3 87.8% (43/49) · average 87.8% · 4 chunks · 20 terms · TTFT 2976/2818/2850 ms (info only — multi-chunk, not asserted)
    known run1: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run1: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run1: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: 1540591031837262644, lang: "bash")) actual nil)
    known-limitation run1: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: -8801134030036687245, lang: "bash")))
    known run2: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run2: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run2: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: 1540591031837262644, lang: "bash")) actual nil)
    known-limitation run2: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: -8801134030036687245, lang: "bash")))
    known run3: expected Optional(TranslationCore.MarkupToken.url(bare: true)) actual nil
    known run3: expected nil actual Optional(TranslationCore.MarkupToken.url(bare: false))
    known-limitation run3: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected Optional(TranslationCore.MarkupToken.codeBlock(hash: 1540591031837262644, lang: "bash")) actual nil)
    known-limitation run3: aya-expanse:8b translates human-readable strings inside a code block — the commit message in `git tag -m "See CHANGELOG.md"` comes back translated. Sharpening the prompt rule was attempted and did not change it. (expected nil actual Optional(TranslationCore.MarkupToken.codeBlock(hash: -8801134030036687245, lang: "bash")))
techdoc-ru.md: run1 94.4% (51/54) · run2 94.4% (51/54) · run3 94.4% (51/54) · average 94.4% · 4 chunks · 20 terms · TTFT 3448/3123/3410 ms (info only — multi-chunk, not asserted)

ACCEPTED — engine meets the recalibrated baseline
```

The gated numbers: single-chunk TTFT **442 ms** and **452 ms** against a 1000 ms ceiling, and
the lowest average adherence **87.0 %** (article-en), **87.8 %** (techdoc-en) and **94.4 %**
(techdoc-ru) against an 80 % floor — each at or above its Task 1 baseline figure (84.3 %,
87.8 %, 93.8 % respectively), so nothing regressed. All three files land within the same
run-to-run noise band as the change-1/2 entry above (article-en identical average, techdoc-en
0.6 points lower but still equal to Task 1's 87.8 %, techdoc-ru identical). All known markup diffs
reproduced as expected — the code-block hashes differ run to run as they already did between
every prior entry — and no new diff appeared.

---

## 2026-08-10 — after pass-through chunks and inline restore (re-basing)

- Machine: Apple M5 Pro, macOS 26.6.1
- Ollama 0.31.1, model `aya-expanse:8b`
- Commit: `7af13b3` plus this task's change to `Sources/acceptance/main.swift` (classify by
  `TranslationOutcome.modelChunkCount`, not raw `chunks.count`)
- Verdict: **FAILED**

Part A of specs/2026-08-10-code-protection-and-styles-design.md changed the chunking of
every code-bearing file, so adherence is computed over a different chunk set and files
may have changed single-/multi-chunk class — percent-to-percent comparison with the
entries above is qualitative; the 80 % floor is absolute. Files that changed class: none.
`techdoc-en.md` and `techdoc-ru.md` are the only files with a fenced block; their fenced
block is now a standalone passthrough chunk that never reaches the model, so their raw
chunk count grew (4 chunks → 6 chunks (4 model-bound) for techdoc-en.md; 4 chunks →
5 chunks (4 model-bound) for techdoc-ru.md) while their model-bound count held at 4 — both
stayed on the multi-model-chunk (adherence-measured) side of the line throughout, so
neither crossed into or out of the TTFT-gated class. `article-en.md` (3 chunks),
`email-en.md` and `snippet-en.md` (1 chunk each) carry no fenced code and are unaffected.

```
article-en.md: run1 91.7% (33/36) · run2 86.1% (31/36) · run3 86.1% (31/36) · average 88.0% · 3 chunks · 20 terms · TTFT 3232/2978/2910 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 447 ms
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 504 ms
techdoc-en.md: run1 86.3% (44/51) · run2 82.4% (42/51) · run3 86.3% (44/51) · average 85.0% · 6 chunks (4 model-bound) · 20 terms · TTFT 4273/4112/4226 ms (info only — multi-chunk, not asserted)
    markup run2: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
techdoc-ru.md: run1 93.9% (46/49) · run2 91.8% (45/49) · run3 93.9% (46/49) · average 93.2% · 5 chunks (4 model-bound) · 20 terms · TTFT 4854/4515/5066 ms (info only — multi-chunk, not asserted)
    markup run1: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run1: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run2: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run2: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run3: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run3: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil

FAILED
  - techdoc-en.md: unaccepted markup diff — expected Optional(TranslationCore.MarkupToken.blockquote) actual nil (1/3 runs)
  - techdoc-ru.md: unaccepted markup diff — expected Optional(TranslationCore.MarkupToken.blockquote) actual nil (6/3 runs)
```

The gated numbers that pass: single-model-chunk TTFT **447 ms** (email-en) and **504 ms**
(snippet-en) against the 1000 ms ceiling, and the lowest average adherence **85.0 %**
(techdoc-en.md) against the 80 % floor — comfortably above it, and qualitatively consistent
with the pre-rebasing figures given the chunk set changed underneath it. The headline this
run exists to check: the known-limitation codeBlock diff (aya-expanse:8b translating the
commit message inside the bash fence) is **absent** from both runs of both `techdoc-*` files
— Part A's pass-through fenced chunks and inline-code restore remove that defect at the
source rather than merely resizing the checker's tolerance list.

But the markup-diff gate itself is **FAILED**: a diff shape outside `isKnownModelBehaviour`
and `knownFileLimitations` appeared on both code-bearing files — `expected
.blockquote actual nil`, i.e. the model dropped the leading `>` on the «Note»/«Важно»
blockquote that immediately follows the now-standalone fenced block. It reproduced on the
discarded first run too (techdoc-en 2/3 runs, techdoc-ru 6/3 — techdoc-ru carries two such
blockquotes, each diffing identically, so `MarkupDiffKey`'s per-pair count exceeds
`totalRuns`; that ratio format is pre-existing, not a defect of this task's edit), so this is
reproducible rather than a one-off sampling artifact. No prior entry in this file has ever
recorded a blockquote diff, so it is new relative to the whole recorded history, not merely
to the immediately preceding entry. Per this task's brief: engine code is left untouched: the
failure analysis and any fix belong to the controller, not to this task.
