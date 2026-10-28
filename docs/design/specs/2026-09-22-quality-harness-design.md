# The `quality` harness — design

**Status: agreed 2026-09-22, in a question-by-question design session; 25 decisions, each
confirmed by the user.** Where this document and the code come to disagree, the code is right
and this file wants a correction note, the same rule as every spec beside it.

## 1. The gap

`acceptance` measures time to first token, markup integrity and term consistency. Nothing in
this repository measures whether a translation *means* what its source means, or whether a
правка in «дружеский» reads friendly. The original design said so — «the prose is judged by a
human … still manual and unautomated» — and it has stayed true. No document here mentions chrF,
BLEU, COMET, back-translation or a model as a judge: the idea was never rejected, it was never
written down.

What *is* known, from the правка calibration of 2026-08-10 and 2026-08-25
(`docs/reference/OPEN-ITEMS.md`):

- On `aya-expanse:8b`, «дружеский» and «простой» produced output byte-identical to «как в
  оригинале», 3 runs of 3. Four prompt rewrites moved nothing by a byte.
- On `translategemma:12b`, «деловой» and «простой» shift the register 3/3; «дружеский» was
  excluded as a known model limitation. `gpt-oss:20b` moved Russian «дружеский» 2/3.
- The model that translates best edits worst: `translategemma:12b` made 21 word-edits beyond
  the seeded errors where `gemma4:26b` made 6 (`AppSettings.proofreadModel`).
- Two readings are still owed to a human: zero lost facts on «переписать», and whether each
  accepted change explanation is true (≈85 % on 18 of 103 read).

And two facts about the install this is being built for, read on 2026-09-22: it runs
`temperature = 0.5` while every calibration above was taken at 0.2, and its правка model is
`translategemma:12b` — the one measured to over-edit.

## 2. What the harness is for

1. **A comparison stand and a diagnostic, not a gate.** It answers «which of two
   configurations is better, and by how much» and «where exactly does the app do badly» — a
   list of failures with a category and a quotation each. It does **not** exit 1 on a
   threshold in its first version: a judged score is noisy, and a gate on a noisy number
   cries wolf. Paired comparison is steadier than an absolute score.
2. **It measures; it does not optimise.** Prompts are changed by a person (or by an agent a
   person asked), then re-measured. No automatic prompt search: `PromptBuilder` is full of
   measured decisions an optimiser fitted to forty texts would undo.
3. **RU→EN and EN→RU only**, правка in those two languages. The corpus format does not
   hard-code the pair.
4. **The existing five rewrite styles and five translation tones, as they are.** The first
   question about a style is whether it is applied *at all*; how well comes second.
5. **Three axes, never one score**: **смысл** (meaning — a veto: a stylish text that lost a
   fact is a failure), **стиль** (does it read as the chosen register), **естественность**
   (does it read as written by a native — «sounds like an LLM» is a failure category inside
   this axis). «The author's voice» is deliberately not judged in v1: it pulls against
   «стиль» and is hard to judge. The word «quality» never appears in a report as a number.

## 3. Who judges

Three layers, cheapest first.

1. **Mechanics** — deterministic, offline-testable, in code: is the reply in the right
   language, did the digits and the sidecar's literal facts survive, did a question stay a
   question, is the length sane, and the two idle measures of §5.
2. **Claude, in a session, over artifacts.** The harness writes JSON; a **fresh sub-agent**
   given only a blind packet and the rubric judges it — not the session that knows which
   configuration is which, or the blindness is fiction. **There is no judge network code in
   this repository at all**, so `docs/adr/0007` and `docs/adr/0009` are untouched. Blind pairs
   (source + replies X/Y in random order, the key in a file the judge is not given), each
   judged **twice with the order swapped**; a verdict that flips is recorded as «равны».
   Meaning is judged as a checklist over the sidecar's fact list, so it is a count rather than
   an opinion. Failure categories are a **closed list** and a verdict without a quotation
   from the text does not count.
3. **The user, for calibration.** `quality judge --human` shows the same blind packets in the
   terminal. 24 pairs per stage; the bar is **≥ 80 % agreement with Claude over pairs neither
   called a tie**, recorded as «N of M». Below the bar the *rubric* is changed and the
   calibration repeated **on new pairs**. Until it passes, every report's first line says the
   judge is uncalibrated, the way `acceptance` prints `info only`.

**The boundary that is code, not agreement**: a run over a corpus outside the repository is
stamped `external: true` in its manifest, and `quality blind` refuses to build a packet from
it. Committed corpus text is already public on GitHub; a user's working texts are not, and the
org rule `Scripts/format-loss.sh` records — no personal or medical data — applies.

No local LLM judge in v1: it would be a second unverified judge. It can be added later and
calibrated against Claude's verdicts on the committed corpus.

Rejected: chrF against public parallel corpora (very likely in the models' training data, and
useless for style); absolute 1–5 scales as the comparison instrument (they drift between
sessions and do not resolve small differences).

## 4. Shape

**Two SwiftPM targets**: `QualityKit`, a library that knows `TranslationCore` and nothing
else — corpus, matrix, mechanical checks, records, report — and `quality`, the executable
that adds `OllamaKit`, the file system and the clock. The split exists for one reason:
`main.swift`'s top-level statements cannot be linked into a test
(`Tests/DocumentationTests/TranslateCLIExplainFlagTests.swift` records that), and every
mechanical check here is a gate that the mutation rule in `docs/reference/TESTING.md` wants
pinned. The harness calls `Translator` directly through the same clients the app uses, so it
is loopback-only by construction. It is not in CI, like `acceptance`.

Subcommands: `quality run` (the matrix → a run directory), `quality report <run>…`
(mechanics, and verdicts when present → a table), and in PR 2 `quality blind <runA> <runB>`
and `quality judge --human`.

**A prompt change is compared across two commits, not two builds in one process**: the
manifest records the commit and a dirty flag, and `blind`/`report` compare directories.

### Corpus

```
quality-corpus/
  style/            ru-*.txt · en-*.txt  + <name>.meta.json     (PR 1)
  translate/ru-en/  translate/en-ru/                            (PR 3)
docs/proofreading-gate/     stays where it is — three scripts and recorded measurements
corpus/                     untouched — `acceptance` reads every .md in it
```

Metadata is a **sidecar**, never a header inside the text, for the reason
`docs/reference/OPEN-ITEMS.md` already gives: the file's bytes are the model's input. A
sidecar names the genre, the language, the source register, the facts that must survive, and
the traps. A fact is `literal` (a number, a name, a date, a URL — checked mechanically against
its `anyOf` spellings) or `semantic` (the judge's checklist only).

The style corpus is **ten mirrored ru/en texts with a declared source register**, so the shift
can be asked for in both directions — «chatty → деловой» and «dry → дружеский» — which is what
tells a model that can only formalise from one that can change register. The texts are
synthetic and committed; **the Russian ones are owed the user's reading for naturalness**, because
an unnatural source devalues everything measured on it. The user's own working texts plug in
as an optional external directory, judged by mechanics and by the user only.

### Artifacts

`build/quality-runs/<stamp>-<label>/` (`build/` is already ignored): `manifest.json` —
commit, dirty flag, engine, Ollama version, chunk budget, temperature, corpus hash, the matrix
filter, `external` — and one JSON per call under `cells/`: source, reply, mechanics, timings.
Verdicts go beside them under `verdicts/`. A run is **resumable**: a cell whose file exists is
not called again, and a manifest that differs from the directory's is refused.

## 5. The mechanical layer (PR 1)

| Check | What it says |
|---|---|
| idle against the source | the reply has no token-level change from the source (`ChangeSet.count == 0`) — «холостой ход» |
| idle against the control | the reply under a named style has no token-level change from the reply under «как в оригинале», same level, same run index — **the style was not applied**, even though the level changed the text |
| shift against the source / the control | changed tokens over all tokens, from `TextDiff`'s own `BlockPair`s — the ratio `Scripts/change-density.sh` reads |
| noise floor | the same shift measured between two control runs — what «different» has to exceed before it means anything |
| reply language | `LanguageDetector` on the reply against the expected language |
| digits | every digit run in the source appears in the reply |
| literal facts | each sidecar `literal` fact is present in one of its `anyOf` spellings |
| questions | the reply has no fewer question marks than the source — the cheap probe for «answered instead of processing» |
| length | reply tokens over source tokens, flagged outside 0.5…2.0 |

«Как в оригинале» is therefore always in the matrix when any named style is: it is the control,
not a fifth style under test.

**Three runs per cell, counted per run** — «the user gets one run, not the best of three»
(`Scripts/format-loss.sh`). `--temperature` defaults to 0.2, which is what every earlier
series was taken at; temperature is written to the manifest and two series at different
temperatures are compared only when temperature *is* the variable. Reasoning is requested
through `ModelPolicy.thinkRequest` with the app's **defaults** (quiet, `low`) rather than a
user's settings: the harness measures the product as shipped, and a harness that followed a
setting would move its own baseline.

## 6. The first campaign

Everything multiplied out is 7 680 calls. So `quality run` takes `--models`, `--levels`,
`--styles`, `--only`, `--runs`; the filter is in the manifest; and the campaign is staged,
each stage narrowing the next:

| Stage | What runs | Answers |
|---|---|---|
| 1 | `translategemma:12b` · style corpus · 2 levels · 4 styles + control · 3 runs · **0.2 and 0.5** | does temperature help a style or hurt the facts — the hypothesis being that a low temperature's likeliest path is «leave it as it is» |
| 2 | five models · «переписать» · 4 styles + control · 3 runs, at the temperature stage 1 favours | which model changes register at all |
| 3 | the best two · «ошибки и стиль» | does a style work at the gentle level |
| 4 | five models · `docs/proofreading-gate` · «только ошибки» | edits beyond the seeded errors — 21 against 6, re-taken |

Models: `translategemma:12b` (what this install runs), `:27b`, `aya-expanse:32b`, and —
to be pulled — `gpt-oss:20b` and `gemma4:26b`. Ollama only. `docs/proofreading-gate` is not run
across styles: it is a corpus of errors, not of registers.

## 7. Translation (PR 3)

About 25–30 synthetic texts over five genres and both directions, each sidecar naming its
**natural tone**, which is what the main run uses. A separate small **tone probe** — 4 texts ×
5 tones — asks the judge to *guess* the tone blind: a judge that cannot tell `formal` from
`neutral` is the translation route's «idle», which no `diff` can see. Its calibration is its
own 24 pairs; agreement on style does not transfer to meaning.

## 8. Where results go

`docs/reference/QUALITY.md`, under `BASELINE.md`'s discipline: append, never edit; the
manifest's first line, date, Ollama version, commit, the raw table, then prose. Entries for
different models or rubric versions are not compared. `MEASUREMENTS.md` gets a pointer;
`OPEN-ITEMS.md`'s debts are closed by reference to an entry, when one actually closes them.

Vocabulary, for `CONTEXT.md`: **прогон** (one run of a matrix, one directory), **ячейка**
(text × configuration × run index), **пакет** (a blind pair for the judge), **вердикт**,
**рубрика** (versioned; its version is in every verdict), **холостой ход** (idle).

## 9. Order of work

1. **PR 1** — `QualityKit` + `quality run`/`report`, the mechanical layer with its tests, the
   style corpus. Useful alone: a table of style × model × temperature → idle rate and shift.
2. **PR 2** — `blind`, `judge --human`, the rubric, the `external` refusal, `docs/adr/0013`
   (the judge is a session, not code; where the boundary is; what was rejected), the first
   `QUALITY.md` entry.
3. **PR 3** — the translation corpus, its rubric, its calibration, the tone probe.
4. **PR 4** — whatever the measurements say about the app: the default правка model, the
   style prompts, the debts in `OPEN-ITEMS.md`.
