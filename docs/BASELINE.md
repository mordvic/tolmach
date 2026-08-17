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
(docs/design/specs/2026-08-10-prompt-improvement-design.md §3.1).

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
baseline (docs/design/specs/2026-08-10-prompt-improvement-design.md §3.1).

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
(docs/design/specs/2026-08-10-prompt-improvement-design.md §3.1).

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

---

## 2026-08-10 — blockquote rule after the re-basing failure

- Machine: Apple M5 Pro, macOS 26.6.1
- Ollama 0.31.1, model `aya-expanse:8b`
- Commit: entry above's commit plus this task's dedicated rule line in
  `Sources/TranslationCore/PromptBuilder.swift`'s shared `protectionRules`
  (`"- Every output line that corresponds to a source line beginning with \">\" must
  itself begin with \">\". Never drop a blockquote marker."`, immediately after the
  general «Preserve the original structure exactly…» line)
- Verdict: **FAILED — the fix made the regression worse, not better**

The entry above measured the problem: the model dropping the leading `>` on the
«Note»/«Важно» blockquote that now follows a standalone passthrough fenced block,
stochastically (dropped-blockquote diffs on 1–2 of 3 runs per file). This entry measures
the controller's dedicated-rule attempt at fixing it. Two live runs, same corpus, same
model, same machine.

```
article-en.md: run1 86.1% (31/36) · run2 86.1% (31/36) · run3 83.3% (30/36) · average 85.2% · 3 chunks · 20 terms · TTFT 3331/2868/3039 ms (info only — multi-chunk, not asserted)
    markup run1: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run1: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 455 ms
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 566 ms
techdoc-en.md: run1 84.3% (43/51) · run2 84.3% (43/51) · run3 86.3% (44/51) · average 85.0% · 6 chunks (4 model-bound) · 20 terms · TTFT 4677/4663/4542 ms (info only — multi-chunk, not asserted)
    markup run1: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run1: expected Optional(TranslationCore.MarkupToken.heading(level: 2)) actual nil
    markup run1: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run1: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run1: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected Optional(TranslationCore.MarkupToken.heading(level: 2)) actual nil
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected Optional(TranslationCore.MarkupToken.heading(level: 2)) actual nil
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
techdoc-ru.md: run1 91.8% (45/49) · run2 93.9% (46/49) · run3 91.8% (45/49) · average 92.5% · 5 chunks (4 model-bound) · 20 terms · TTFT 4560/4576/4382 ms (info only — multi-chunk, not asserted)
    markup run1: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run1: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run1: expected Optional(TranslationCore.MarkupToken.heading(level: 2)) actual nil
    markup run1: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run1: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run2: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected Optional(TranslationCore.MarkupToken.heading(level: 2)) actual nil
    markup run2: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run2: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run3: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected Optional(TranslationCore.MarkupToken.heading(level: 2)) actual nil
    markup run3: expected nil actual Optional(TranslationCore.MarkupToken.blockquote)
    markup run3: expected Optional(TranslationCore.MarkupToken.blockquote) actual nil

FAILED
  - article-en.md: unaccepted markup diff — expected nil actual Optional(TranslationCore.MarkupToken.blockquote) (9/3 runs)
  - techdoc-en.md: unaccepted markup diff — expected Optional(TranslationCore.MarkupToken.heading(level: 2)) actual nil (3/3 runs)
  - techdoc-en.md: unaccepted markup diff — expected nil actual Optional(TranslationCore.MarkupToken.blockquote) (12/3 runs)
  - techdoc-ru.md: unaccepted markup diff — expected Optional(TranslationCore.MarkupToken.blockquote) actual nil (6/3 runs)
  - techdoc-ru.md: unaccepted markup diff — expected Optional(TranslationCore.MarkupToken.heading(level: 2)) actual nil (3/3 runs)
  - techdoc-ru.md: unaccepted markup diff — expected nil actual Optional(TranslationCore.MarkupToken.blockquote) (6/3 runs)
```

Gates: adherence and TTFT both still pass (lowest average **85.0 %** on techdoc-en.md
against the 80 % floor; TTFT **455 ms**/**566 ms** against the 1000 ms ceiling). The
no-new-diff gate is **FAILED**, worse than the entry above rather than fixed by it.

Per-file blockquote-diff counts, dropped (`expected .blockquote actual nil`, the original
defect) vs. spurious (`expected nil actual .blockquote`, a new one the rule introduced),
in this recorded run:

| File | Dropped (defect the rule targeted) | Spurious (new, caused by the rule) | Heading dropped (new) |
|---|---|---|---|
| article-en.md | 0/3 runs (had 0 before, too) | **9** occurrences / 3 runs (0 before — this file has no source blockquote at all) | 0 |
| techdoc-en.md | 0/3 runs (was 1/3 in the recorded pre-fix entry) | **12** occurrences / 3 runs (0 before) | **3/3 runs** (0 before) |
| techdoc-ru.md | **6** occurrences / 3 runs (unchanged — was 6/3 before, identical count) | **6** occurrences / 3 runs (0 before) | **3/3 runs** (0 before) |

Reading the table: on `techdoc-en.md` the dedicated rule did stop the model from dropping
the one blockquote it used to drop — but on `techdoc-ru.md` the same defect persisted at
the exact same rate (6/3 runs, both before and after), so the rule did not reliably fix
even the targeted defect. Worse, it introduced two regressions across the whole corpus:
the model now inserts a spurious `>` in front of lines that were never blockquotes at all
— on `article-en.md`, a file with **zero source blockquotes** and **zero diffs in every
one of the eight prior entries in this file**, and on both `techdoc-*` files — and it now
drops the level-2 `##` heading immediately preceding the code fence on **every run of
both** `techdoc-*` files (3/3, deterministic, never seen before). Both regressions
reproduced identically on the discarded first run of this pair (article-en 13/3 spurious
plus a new `paragraphBreak` diff on one run; techdoc-en 12/3 spurious, 3/3 heading;
techdoc-ru 6/3 dropped unchanged, 6/3 spurious, 3/3 heading) — this is not a one-off
sampling artifact, it is what the rule does.

**Conclusion: the dedicated blockquote-marker rule should not be kept as written.** It
over-applies — the model appears to read «every output line matching a `>` source line
must begin with `>`» as license to also mark lines it merges or restructures near a
quote — and it destabilised heading translation on the same files it was meant to help.
Reverting it and trying a narrower formulation (e.g. one that names the specific line
rather than a general correspondence rule, or one scoped only to the line immediately
after a fenced block) is a decision left to the controller; this entry records why the
first attempt does not clear the bar, per the measurement discipline this file exists to
keep.

**Closing note, same day:** the rule above was reverted. It is worse on `aya-expanse:8b`
than the regression it targeted — spurious `>` insertions on lines that were never
blockquotes (9/3 runs on `article-en.md`, a file with zero source blockquotes and zero
diffs in every prior entry), a new deterministic drop of the level-2 heading before the
code fence (3/3 runs on both `techdoc-*` files), and the targeted defect itself unmoved
on `techdoc-ru.md` (6/3 runs, identical before and after). `protectionRules` in
`Sources/TranslationCore/PromptBuilder.swift` returns to its exact pre-rule content — no
acceptance run was repeated for this revert, because the code is now byte-identical to
what the «after pass-through chunks and inline restore (re-basing)» entry above already
measured; a third pair of live runs would remeasure the same FAILED state, not a new one.
The engine's state is that entry's: the stochastic blockquote-marker drop on both
`techdoc-*` files is an open regression, escalated to the user as an accept-or-not
decision rather than fixed by this attempt.

---

## 2026-08-10 — re-based state accepted (blockquote drop recorded as known limitation)

- Machine: Apple M5 Pro, macOS 26.6.1
- Ollama 0.31.1, model `aya-expanse:8b`
- Commit: entry above's commit plus this task's addition of a blockquote-drop
  known-limitation to `Sources/acceptance/main.swift` (engine code unchanged — the two
  prompt attempts above were reverted, not re-tried)
- Verdict: **ACCEPTED**

The user's decision, escalated by the two closing notes above: accept the stochastic
blockquote-marker drop as a known limitation rather than keep chasing a prompt fix. The
trade is the one the whole re-basing exists to make — Part A's pass-through fenced chunks
and inline-code restore turned a *deterministic* defect (the commit-message-inside-a-fence
corruption, wrong on 4/4 code-bearing runs before this pass) into a *stochastic* one (the
leading `>` dropped on 1–2 of 3 runs per file), and that stochastic marker loss is already
one `WarningsView` surfaces to the user like any other markup diff — it is not silent.
Trading a deterministic content corruption for an occasional, visible formatting slip is
accepted as a net improvement. The harness now records this trade explicitly:
`isBlockquoteDropDiff` (only the drop direction — `expected .blockquote actual nil` — a
diff where the model *adds* an unrequested `>` is a different, still-unaccepted defect)
paired with a per-file reason in `knownBlockquoteDropLimitations`, following the exact
shape of the existing `isCodeBlockDiff` / `knownFileLimitations` mechanism. This is the
green record the FAILED re-basing entry above was waiting for.

```
article-en.md: run1 83.3% (30/36) · run2 88.9% (32/36) · run3 86.1% (31/36) · average 86.1% · 3 chunks · 20 terms · TTFT 3025/2947/2964 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 296 ms
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 434 ms
techdoc-en.md: run1 82.4% (42/51) · run2 86.3% (44/51) · run3 82.4% (42/51) · average 83.7% · 6 chunks (4 model-bound) · 20 terms · TTFT 4250/4320/4296 ms (info only — multi-chunk, not asserted)
    known-limitation run2: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run3: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
techdoc-ru.md: run1 93.9% (46/49) · run2 93.9% (46/49) · run3 93.9% (46/49) · average 93.9% · 5 chunks (4 model-bound) · 20 terms · TTFT 4263/4314/4312 ms (info only — multi-chunk, not asserted)
    known-limitation run1: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run1: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run2: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run2: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run3: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run3: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)

ACCEPTED — engine meets the recalibrated baseline
```

The gated numbers: single-model-chunk TTFT **296 ms** (email-en) and **434 ms**
(snippet-en) against the 1000 ms ceiling, and the lowest average adherence **83.7 %**
(techdoc-en.md) against the 80 % floor — both comfortably clear. No diff outside the
known/known-limitation set appeared on any file in either run. The blockquote drop
itself appeared on 2/3 runs of `techdoc-en.md` and all 3/3 runs of `techdoc-ru.md` (two
blockquotes per run in that file, both dropped every time it showed) — every occurrence
printed as `known-limitation`, none counted toward `failures`. This closes the arc this
file has carried since the re-basing entry above: **ACCEPTED**.

---

## 2026-08-10 — adherence denominator corrected (pass-through chunks excluded)

The adherence loop in `Sources/acceptance/main.swift` counted a glossary term as
`applicable` even when it matched only inside a pass-through (fenced-code) chunk that
never reaches the model — penalising the metric for the protection itself, since such a
term can never be `honoured` — so the loop now skips `chunk.passthrough` chunks
entirely; expected direction: percentages rise (or hold unchanged, for a file with no
such occurrence).

```
article-en.md: run1 86.1% (31/36) · run2 83.3% (30/36) · run3 86.1% (31/36) · average 85.2% · 3 chunks · 20 terms · TTFT 3366/3117/3008 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 455 ms
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 468 ms
techdoc-en.md: run1 88.0% (44/50) · run2 88.0% (44/50) · run3 86.0% (43/50) · average 87.3% · 6 chunks (4 model-bound) · 20 terms · TTFT 4603/4539/4327 ms (info only — multi-chunk, not asserted)
    known-limitation run1: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run3: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
techdoc-ru.md: run1 93.9% (46/49) · run2 93.9% (46/49) · run3 93.9% (46/49) · average 93.9% · 5 chunks (4 model-bound) · 20 terms · TTFT 5059/4463/4778 ms (info only — multi-chunk, not asserted)
    known-limitation run1: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run1: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run2: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run2: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run3: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run3: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)

ACCEPTED — engine meets the recalibrated baseline
```
