# Acceptance baseline

`swift run acceptance` prints numbers and then says ACCEPTED or FAILED. On its own that is a
binary: it cannot tell you whether 85.2 % adherence is normal for this corpus or a regression
that squeaked past the floor. This file is the record that makes it interpretable.

**Append, do not edit.** Each entry is what one run actually printed, with enough about the
machine to know whether two entries are comparable. An entry is never revised after the fact —
if a number looks wrong later, that is a finding, not a typo.

Run it from the package root; the harness reads `./corpus` relative to the working directory.

Since 2026-08-21 it also takes `--engine ollama|lmstudio`, and **both gates are properties of
`aya-expanse:8b` on Ollama**: under the other engine the TTFT ceiling prints `info only` and every
markup diff is unaccepted, so a first entry for a new engine shows what that engine's model
actually does rather than inheriting a verdict measured elsewhere.

Since 2026-08-18 the harness takes `--model <ollama model>` and `--chunk <characters>`
(defaults: `ModelPolicy`'s interactive model, 900). **An entry must say which it ran** — the
harness prints that as its first line, paste it. Entries for different models or chunk budgets
are different baselines and are not compared to each other; the aya-expanse:8b entries below
predate the flags and were all run at the defaults.

---

## Reading the output

Three kinds of line, and two of them are not warnings even though they read like one:

- **`average N% (x/y)`** — cross-chunk terminology adherence: of the terms the document
  glossary fixed, how many came back rendered the same way in every chunk. **Gated at 80 %.**
  Only multi-chunk files have it; a single-chunk file prints `adherence n/a` because a
  document glossary is not built for one chunk, and that is correct rather than a gap.
- **`TTFT … (info only — multi-chunk, not asserted)`** — time to first token. **Gated at
  1000 ms, but only for single-chunk files, and only for the model `ModelPolicy` pins for
  the interactive path.** A multi-chunk run pays for the preparatory term-list call before
  its first chunk, so its TTFT measures something else entirely and is printed for
  information. The single-chunk figures are the ones that guard the hotkey path's hard
  requirement — a requirement of that path, measured on that model. Under any other
  `--model` the single-chunk line carries `(info only — TTFT not gated for this model)`:
  the number is recorded, not judged (`RunConfiguration.gatesTTFT` in
  `Sources/acceptance/main.swift` carries the measurement behind that rule).
- **`known` and `known-limitation`** — markup diffs that are expected and deliberately not
  failed. They are recorded so that a *new* diff is visible against them, not because
  something is wrong. Their content is in §11a of the design spec. **They apply only to
  `aya-expanse:8b`**, the model they were measured on; under any other `--model` every diff
  prints as `markup` and counts as unaccepted, so the model's first entry shows what it
  does. Accepting a limitation of another model is a decision to record here, by hand.

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

---

## 2026-08-18 — the harness takes `--model` and `--chunk`; first entries for translategemma:12b

- Machine: Apple M5 Pro, 48 GB, macOS 26.6.1
- Ollama 0.32.14
- Commit: `dc1ae43` (`feat(acceptance): take --model and --chunk; gate TTFT and known diffs per model`)
- Engine code unchanged since `bc145f9`; only the harness gained the flags and the per-model gate rule.

Three runs, one after another on an otherwise idle machine. The first proves the default path
is what it was; the other two are the first numbers ever recorded for the configuration this
machine's install actually runs (`interactiveModel = translategemma:12b`, `chunkSize = 4000`,
`batchModel` unset — so the same model for the file queue).

### Run A — defaults (aya-expanse:8b, 900), verdict **ACCEPTED**, 156 s

```
acceptance: model aya-expanse:8b · chunk 900 chars · TTFT gate enforced · known-limitation set applied
article-en.md: run1 80.6% (29/36) · run2 83.3% (30/36) · run3 83.3% (30/36) · average 82.4% · 3 chunks · 20 terms · TTFT 3315/2830/2970 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 463 ms
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 455 ms
techdoc-en.md: run1 82.0% (41/50) · run2 84.0% (42/50) · run3 88.0% (44/50) · average 84.7% · 6 chunks (4 model-bound) · 20 terms · TTFT 4353/4098/4219 ms (info only — multi-chunk, not asserted)
techdoc-ru.md: run1 95.9% (47/49) · run2 95.9% (47/49) · run3 95.9% (47/49) · average 95.9% · 5 chunks (4 model-bound) · 20 terms · TTFT 4802/4211/4211 ms (info only — multi-chunk, not asserted)
    known-limitation run1: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run1: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run2: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run2: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run3: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
    known-limitation run3: aya-expanse:8b stochastically drops the leading ">" on the blockquote that follows a fenced code block, now that the fence is a standalone passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to fix it made the model's structure preservation worse elsewhere and were reverted. Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already surfaces, traded against the deterministic code corruption the same change fixed 4/4. (expected Optional(TranslationCore.MarkupToken.blockquote) actual nil)
ACCEPTED — engine meets the recalibrated baseline
```

Same commit as the run an hour earlier at `bc145f9` (article-en 85.2 %, techdoc-en 86.7 %,
techdoc-ru 94.6 %; TTFT 455/446 ms): identical code, identical prompt, and the averages
moved by −2.8 / −2.0 / +1.3 points. **That is the run-to-run noise floor of this corpus at
temperature 0.2**, worth knowing before reading any two entries below as a difference.

### Run B — `--model translategemma:12b` (900), verdict **FAILED**, 263 s

```
acceptance: model translategemma:12b · chunk 900 chars · TTFT gate info only — not the interactive-policy model · known-limitation set not applied — measured on aya-expanse:8b
article-en.md: run1 75.0% (27/36) · run2 77.8% (28/36) · run3 77.8% (28/36) · average 76.9% · 3 chunks · 20 terms · TTFT 5236/4637/4745 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 726 ms (info only — TTFT not gated for this model)
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 997 ms (info only — TTFT not gated for this model)
techdoc-en.md: run1 92.0% (46/50) · run2 92.0% (46/50) · run3 92.0% (46/50) · average 92.0% · 6 chunks (4 model-bound) · 20 terms · TTFT 7649/7581/7516 ms (info only — multi-chunk, not asserted)
techdoc-ru.md: run1 93.9% (46/49) · run2 93.9% (46/49) · run3 91.8% (45/49) · average 93.2% · 5 chunks (4 model-bound) · 20 terms · TTFT 7401/6979/7019 ms (info only — multi-chunk, not asserted)
FAILED
  - article-en.md: average adherence 76.9% < 80%
```

What the entry says, read line by line:

- **The gate that failed is the adherence floor**, which is model-neutral on purpose: it
  measures the document-glossary mechanism, not the model's latency. `article-en.md` at
  76.9 % is 5.5 points under aya's 82.4 % on the same day and 3 under the floor; on the two
  technical documents the same model is *ahead* (techdoc-en 92.0 % vs 84.7 %, techdoc-ru
  93.2 % vs 95.9 % — inside the noise floor above). So the document glossary works on this
  model and one prose file falls short of it — the mechanism is not broken, and this is the
  number to move.
- **Single-chunk TTFT 726 ms and 997 ms, printed info-only** — the harness does not gate TTFT
  for a model `ModelPolicy` does not pin, and this is why: `snippet-en.md` sits 3 ms under the
  ceiling on a warm model. Cold-prefix prefill alone was measured at 634 ms for this prompt on
  this model (`docs/reference/PLATFORM-TRAPS.md`), so on the hotkey path the sub-second
  requirement holds only while Ollama's prefix cache is warm.
- **No `markup` line on any file** — translategemma:12b produced no markup diff at all on
  this corpus, where aya-expanse:8b carries a known blockquote drop on both techdocs. Under
  `--model` the `known`/`known-limitation` sets are not applied, so had it dropped one it
  would have printed as unaccepted; it dropped none.
- Multi-chunk TTFT 4.6–7.6 s against aya's 2.8–4.8 s: the term-list call plus a slower
  model. Info-only, as always.

### Run C — `--model translategemma:12b --chunk 4000` (this install's own `chunkSize`), verdict **ACCEPTED**, 194 s

```
acceptance: model translategemma:12b · chunk 4000 chars · TTFT gate info only — not the interactive-policy model · known-limitation set not applied — measured on aya-expanse:8b
article-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 1288 ms (info only — TTFT not gated for this model)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 708 ms (info only — TTFT not gated for this model)
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 836 ms (info only — TTFT not gated for this model)
techdoc-en.md: run1 92.5% (37/40) · run2 92.5% (37/40) · run3 92.5% (37/40) · average 92.5% · 5 chunks (3 model-bound) · 20 terms · TTFT 8417/7496/7503 ms (info only — multi-chunk, not asserted)
techdoc-ru.md: run1 92.9% (26/28) · run2 92.9% (26/28) · run3 92.9% (26/28) · average 92.9% · 3 chunks (2 model-bound) · 20 terms · TTFT 6852/6897/6951 ms (info only — multi-chunk, not asserted)
ACCEPTED — engine meets the recalibrated baseline
```

At 4000 characters `article-en.md` (2326 bytes) is one chunk, so the file that failed the
adherence floor at 900 is not measured for adherence at all here — **ACCEPTED is not a better
result than Run B's FAILED, it is a smaller measurement**: only the two technical documents
still chunk (their fenced blocks force boundaries the budget cannot merge across), at 92.5 %
and 92.9 % on 3 and 2 model-bound chunks. The other thing this run shows is what a 4000-
character budget costs on the hotkey path: `article-en.md` as a single 2.3 KB chunk took
1288 ms to its first token on a warm 12b, against 726–836 ms for the two short files — the
user's own text size, not the prompt, is what puts this configuration over the second.

Comparability: Runs B and C are the first entries under `--model`; every earlier entry in
this file is aya-expanse:8b at 900 and stays the reference for the default configuration.

---

## 2026-08-18 — user prompts hand the text over plainly; the `<text>` markers are gone

- Machine: Apple M5 Pro, 48 GB, macOS 26.6.1
- Ollama 0.32.14
- Commit: the `feat/prompt-shape-and-term-list` branch on top of `d31fdfa` — `PromptBuilder.userPrompt(for:)`
  and `proofreadMessages` lost their `<text>…</text>` wrapper (the text now follows one closing
  line, «Please translate the following English text into Russian:», two blank lines), the
  term-list prompt names the document's real source language, and `ResponseCleaner`'s marker
  unwrap plus the buffer-to-end it forced in `streamChunkReply` are removed.
- Why: measured on `translategemma:27b` — a question inside the markers was answered 5/5 and
  the markers were echoed back around 7/15 replies; 0/15 and 0/15 without them, isolated to the
  markers by variant. The full account is in `docs/reference/PLATFORM-TRAPS.md` («Ollama»)
  and the doc comment on `PromptBuilder.userPrompt(for:)`.
- Expected direction: no change on either model — the rules did not move, only the wrapper.
  Reference points are the same day's Run A (aya) and Run B (translategemma:12b) above.

### Run D — defaults (aya-expanse:8b, 900), verdict **ACCEPTED**, 160 s

```
acceptance: model aya-expanse:8b · chunk 900 chars · TTFT gate enforced · known-limitation set applied
article-en.md: run1 83.3% (30/36) · run2 83.3% (30/36) · run3 83.3% (30/36) · average 83.3% · 3 chunks · 20 terms · TTFT 3206/2841/2849 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 453 ms
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 456 ms
techdoc-en.md: run1 88.0% (44/50) · run2 82.0% (41/50) · run3 86.0% (43/50) · average 85.3% · 6 chunks (4 model-bound) · 20 terms · TTFT 4230/4154/4116 ms (info only — multi-chunk, not asserted)
techdoc-ru.md: run1 95.9% (47/49) · run2 95.9% (47/49) · run3 93.9% (46/49) · average 95.2% · 5 chunks (4 model-bound) · 20 terms · TTFT 4617/4170/4183 ms (info only — multi-chunk, not asserted)
ACCEPTED — engine meets the recalibrated baseline
```

Against Run A: article-en 82.4 → 83.3 %, techdoc-en 84.7 → 85.3 %, techdoc-ru 95.9 → 95.2 %,
single-chunk TTFT 463/455 → 453/456 ms — every move inside the noise floor Run A recorded
against its own predecessor (−2.8 / −2.0 / +1.3). One thing to note without claiming it: this
run printed **no `known-limitation` line at all** — the stochastic blockquote drop that Run A
showed six times across the two techdocs did not occur once here. Six chances in one run set
is not a measurement of a rate; it is recorded so that the next aya run can say whether the
plain hand-over changed that rate or this was the noise the drop has always had.

### Run E — `--model translategemma:12b` (900), verdict **FAILED**, 249 s

```
acceptance: model translategemma:12b · chunk 900 chars · TTFT gate info only — not the interactive-policy model · known-limitation set not applied — measured on aya-expanse:8b
article-en.md: run1 77.8% (28/36) · run2 77.8% (28/36) · run3 72.2% (26/36) · average 75.9% · 3 chunks · 20 terms · TTFT 4841/4482/4496 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 720 ms (info only — TTFT not gated for this model)
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 915 ms (info only — TTFT not gated for this model)
techdoc-en.md: run1 92.0% (46/50) · run2 94.0% (47/50) · run3 92.0% (46/50) · average 92.7% · 6 chunks (4 model-bound) · 20 terms · TTFT 7483/7109/7125 ms (info only — multi-chunk, not asserted)
techdoc-ru.md: run1 93.9% (46/49) · run2 93.9% (46/49) · run3 93.9% (46/49) · average 93.9% · 5 chunks (4 model-bound) · 20 terms · TTFT 6916/6673/6659 ms (info only — multi-chunk, not asserted)
FAILED
  - article-en.md: average adherence 75.9% < 80%
```

Against Run B: article-en 76.9 → 75.9 % (the same file under the same model-neutral floor,
the same failure — pre-existing, not the shape's), techdoc-en 92.0 → 92.7 %, techdoc-ru
93.2 → 93.9 %, single-chunk TTFT 726/997 → 720/915 ms; still no markup diff on any file.
Neither model moved outside its noise on either gate: the wrapper cost nothing to remove here
and cost `translategemma:27b` its anti-answering and its streaming to keep.

The правка user prompt changed with the same rule and was probed rather than harnessed (the
harness translates only): three seeded texts × 5 runs, old wrapper vs plain hand-over, on
aya-expanse:8b and translategemma:12b — language kept 15/15 on both shapes on both models,
no marker echo, no answering, seeded fixes present 5/15 → 5/15 (aya) and 13/15 → 14/15 (12b).
Neutral, as expected; the runner was throwaway, as the правка calibration's was.


---

## 2026-08-21 — first LM Studio entry: `google/gemma-4-e4b`, and it is not a recommendation

The first run through the second engine, taken to prove the transport end to end rather than to
choose a model. `google/gemma-4-e4b` was picked because it is the smallest model on this install
(8.97 GB, MLX) and therefore the cheapest to load — not because it is a translation model. Read
the verdict as being about that model. Machine: M5 Pro / 48 GB, macOS 26.5.2, LM Studio 0.4.21.

```
acceptance: engine lmstudio · model google/gemma-4-e4b · chunk 900 chars · TTFT gate info only — not Ollama's interactive-policy model · known-limitation set not applied — measured on aya-expanse:8b
article-en.md: run1 80.6% (29/36) · run2 86.1% (31/36) · run3 88.9% (32/36) · average 85.2% · 3 chunks · 20 terms · TTFT 29979/25932/34796 ms (info only — multi-chunk, not asserted)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 8737 ms (info only — TTFT not gated for this model)
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 634 ms (info only — TTFT not gated for this model)
techdoc-en.md: run1 90.0% (45/50) · run2 90.0% (45/50) · run3 90.0% (45/50) · average 90.0% · 6 chunks (4 model-bound) · 20 terms · TTFT 23560/17022/18055 ms (info only — multi-chunk, not asserted)
techdoc-ru.md: run1 89.8% (44/49) · run2 91.8% (45/49) · run3 91.8% (45/49) · average 91.2% · 5 chunks (4 model-bound) · 20 terms · TTFT 15023/17180/16668 ms (info only — multi-chunk, not asserted)
    markup run1: expected Optional(TranslationCore.MarkupToken.inlineCode("/session/sync")) actual nil
    markup run1: expected Optional(TranslationCore.MarkupToken.inlineCode("Authorization")) actual nil
    markup run2: expected Optional(TranslationCore.MarkupToken.inlineCode("Authorization")) actual nil
    markup run3: expected Optional(TranslationCore.MarkupToken.inlineCode("/session/sync")) actual nil
    markup run3: expected Optional(TranslationCore.MarkupToken.inlineCode("Authorization")) actual nil
FAILED
  - techdoc-ru.md: unaccepted markup diff — expected Optional(TranslationCore.MarkupToken.inlineCode("/session/sync")) actual nil (2/3 runs)
  - techdoc-ru.md: unaccepted markup diff — expected Optional(TranslationCore.MarkupToken.inlineCode("Authorization")) actual nil (3/3 runs)
EXIT: 1
```

**What this says about the engine: it works.** The corpus went through `/api/v1/chat` end to end,
the document glossary was built and injected, adherence came back in the range this corpus
produces on Ollama — 85.2 / 90.0 / 91.2 % against the 80 % floor — and `snippet-en.md` returned
its first token in **634 ms**, inside the second the interactive path is designed around, on an
engine whose TTFT gate is not even enforced.

**What this says about the model is a finding, not a pass:** `gemma-4-e4b` **drops inline code**.
`techdoc-ru.md` lost `Authorization` in 3 of 3 runs and `/session/sync` in 2 of 3, so the run
exits 1. Note what did *not* happen: the loss was detected rather than papered over. Inline spans
are restored positionally under an **equal-count** gate, so a model returning fewer spans than it
was given fails the diff instead of having something plausible pasted back in. This is the
`gemma3n` failure family — the reason that model is blacklisted — caught on a different model by
the corpus that exists for it.

**TTFT on the multi-chunk files is 15–35 s** and is not comparable with anything above: it
carries a cold load (5.6 s, measured separately) plus the preparatory term-list call, on a 4B
model at 900-character chunks. Recorded, not gated.

**Not measured here:** `qwen/qwen3.8-27b` and `openai/gpt-oss-20b`, the two models on this
install that would actually be candidates for use. Each is large enough that a three-run corpus
pass is a long job, and neither has an entry yet. That is the next thing this file wants.

---

## 2026-08-26 — one line discipline: `LineScanner` in `ResponseCleaner` and `InlineCodeRestorer`

- Machine: Apple M5 Pro, 48 GB, macOS 26.6.1
- Ollama 0.32.14

- What changed: `ResponseCleaner.clean` and `InlineCodeRestorer` stopped splitting text
  themselves — `firstIndex(of: "\n")` in one and `components(separatedBy: .newlines)` in the
  other — and went through `LineScanner`, the type built so the layers could not disagree.
  `Translator.streamChunkReply`'s fence check and its first-line decision followed.
- Why: issues #46, #50 and #55. A lone CR inside a chunk paired backticks across the break into
  a span no other layer saw, and a matching count let those bytes be spliced over real code; a
  CRLF reply's preamble was never stripped, and the fence unwrap fabricated a paragraph break.

### Run F — `--model translategemma:12b --chunk 4000`, verdict **ACCEPTED**

```
acceptance: engine ollama · model translategemma:12b · chunk 4000 chars · TTFT gate info only — not Ollama's interactive-policy model · known-limitation set not applied — measured on aya-expanse:8b
article-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 1511 ms (info only — TTFT not gated for this model)
email-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 711 ms (info only — TTFT not gated for this model)
snippet-en.md: adherence n/a (single model-bound chunk, document glossary not applicable) · 1 chunk · 0 terms · TTFT 920 ms (info only — TTFT not gated for this model)
techdoc-en.md: run1 92.5% (37/40) · run2 92.5% (37/40) · run3 95.0% (38/40) · average 93.3% · 5 chunks (3 model-bound) · 20 terms · TTFT 7660/7474/7292 ms (info only — multi-chunk, not asserted)
techdoc-ru.md: run1 92.9% (26/28) · run2 92.9% (26/28) · run3 92.9% (26/28) · average 92.9% · 3 chunks (2 model-bound) · 20 terms · TTFT 7169/7132/7113 ms (info only — multi-chunk, not asserted)
ACCEPTED — engine meets the recalibrated baseline
```

Against **Run C** (2026-08-18), the directly comparable entry — same model, same budget, same
machine:

| | Run C | Run F |
|---|---|---|
| `techdoc-en.md` | 92.5 / 92.5 / 92.5 → **92.5 %** | 92.5 / 92.5 / 95.0 → **93.3 %** |
| `techdoc-ru.md` | 92.9 / 92.9 / 92.9 → **92.9 %** | 92.9 / 92.9 / 92.9 → **92.9 %** |
| chunks (model-bound) | 5 (3) and 3 (2) | 5 (3) and 3 (2) |
| document terms | 20 and 20 | 20 and 20 |
| `markup` lines | none on any file | none on any file |

Chunking, term counts and markup are **identical**. The single 95.0 % run is the model's own
sampling and is not claimed as an improvement — the other five runs reproduce Run C exactly.

**This run cannot confirm the fix, and says so rather than being read as if it did.** Every file
in `corpus/` is pure LF — checked, zero CR bytes across all five — so none of the paths this
change repairs is reachable from here: no CRLF reply to strip a preamble from, no lone-CR chunk
to mis-pair backticks across. What it establishes is the other half, and the half a refactor of
this shape actually needs: routing four call sites through `LineScanner` changed **nothing** on
the documents the engine already handled. The repaired behaviour is pinned by the offline suite,
where the inputs can be written down.

A CRLF corpus file would close that gap and is worth adding; it is not added here, because a
sixth file changes every future run's comparability and that is a decision of its own.
