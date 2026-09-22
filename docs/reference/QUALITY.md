# Quality — what the `quality` harness measured, run by run

**Append, do not edit.** Each entry is what one run — or one judged comparison — actually
printed, with enough about the machine, the model and the rubric to know whether two entries are
comparable. An entry is never revised after the fact: if a figure looks wrong later, that is a
finding, not a typo. The rules are `docs/reference/BASELINE.md`'s, for the same reasons.

An entry names its **model, temperature, chunk, corpus hash and commit** — the harness prints
them on its first line, and that line is pasted in as it is. Entries for different models, or
different temperatures, are different baselines and are not compared with each other, except
where the temperature *is* the variable under test. A judged entry also names the **rubric
version** (`docs/reference/QUALITY-RUBRIC.md`) and opens with the calibration status; judged
figures under an uncalibrated judge are recorded as what they are — a session's reading, not a
measurement — and figures under two rubric versions are never tallied together.

## Reading a mechanics table

One row per model × temperature × language × level × style. `n` answered cells, `err` failed
ones (in no rate). **idle/src** — replies token-identical to the source (the model did
nothing). **idle/ctl** — replies token-identical to the «как в оригинале» reply at the same run
index: **the style was not applied**. **shift/src**, **shift/ctl** — changed tokens over all
tokens, median; **noise** on the control row is the same shift between two control runs of one
text, and a style's shift/ctl means something only above it. The flag columns count replies,
not occurrences, and are for a reader: `num+` is a number the source never states, `added` is
the app's own «похоже, модель ответила на текст» rule asked of the stored bytes (issue #97).

## What a regression looks like

A style whose shift/ctl falls to the noise floor, or whose idle/ctl leaves zero, stopped being
applied. A `num+` or `fact✗` count that appears where the previous entry for the same
configuration had none is a prompt or model change that costs facts. A judged comparison that
flips on смысл between two commits is the finding this file exists for; one that moves on
естественность alone, within a handful of pairs, is the judge's noise until the agreement
figure says otherwise.

---

## 2026-09-22 — stage 1: temperature 0.2 against 0.5 on translategemma:12b

- Machine: Apple M5 Pro / 48 GB, macOS 27.0; Ollama 0.34.0 (server), client 0.34.2
- Commit: a68fe94 (the runs), report and judging under be008d4 / c669a52 — the number check's allowances were read off these very cells, and the tables below are the recomputed ones
- Corpus: `quality-corpus/style`, 20 texts, hash 88e30ba240ec061c; rubric 1; 600 + 600 cells, 0 failed; 80 + 80 minutes
- Why: this install runs temperature 0.5 while every calibration in the repo was taken at 0.2. Hypothesis: a low temperature's likeliest path is «leave it as it is», so 0.5 might help the styles.

```
quality: stage1-t020 · engine ollama 0.34.0 · models translategemma:12b · temperature 0.20 · chunk 4000 · runs 3 · corpus quality-corpus/style (88e30ba240ec061c) · commit a68fe94
mechanics only — no judge has read these replies; смысл, стиль and естественность are not in this table

model               t     lang  level           style         n   err  idle/src  idle/ctl  shift/src  shift/ctl  noise  lang✗  num✗  num+  fact✗  q✗  len✗  empty  added  ms
translategemma:12b  0.20  en    errorsAndStyle  original      30  0    0/30      –         0.32       –          0.02   0      0     0     0      3   0     0      3      6287
translategemma:12b  0.20  en    errorsAndStyle  friendly      30  0    0/30      0/30      0.44       0.19       –      0      0     0     0      3   0     0      3      6790
translategemma:12b  0.20  en    errorsAndStyle  business      30  0    0/30      0/30      0.57       0.28       –      0      0     1     0      6   0     0      9      6874
translategemma:12b  0.20  en    errorsAndStyle  professional  30  0    0/30      0/30      0.43       0.17       –      0      0     0     0      3   0     0      0      6144
translategemma:12b  0.20  en    errorsAndStyle  plain         30  0    0/30      0/30      0.44       0.16       –      0      0     0     0      3   0     0      3      6082
translategemma:12b  0.20  en    rewrite         original      30  0    0/30      –         0.38       –          0.02   0      0     0     0      3   0     0      0      6462
translategemma:12b  0.20  en    rewrite         friendly      30  0    0/30      0/30      0.48       0.27       –      0      0     0     0      3   0     0      0      6838
translategemma:12b  0.20  en    rewrite         business      30  0    0/30      0/30      0.59       0.23       –      0      0     2     0      6   0     0      12     6836
translategemma:12b  0.20  en    rewrite         professional  30  0    0/30      0/30      0.48       0.14       –      0      0     0     0      3   0     0      0      6549
translategemma:12b  0.20  en    rewrite         plain         30  0    0/30      0/30      0.45       0.17       –      0      0     0     0      3   0     0      3      6413
translategemma:12b  0.20  ru    errorsAndStyle  original      30  0    0/30      –         0.14       –          0.03   0      0     0     0      0   0     0      0      7337
translategemma:12b  0.20  ru    errorsAndStyle  friendly      30  0    0/30      0/30      0.25       0.18       –      0      0     0     0      0   0     0      0      7178
translategemma:12b  0.20  ru    errorsAndStyle  business      30  0    0/30      0/30      0.39       0.26       –      0      1     3     0      3   0     0      6      7665
translategemma:12b  0.20  ru    errorsAndStyle  professional  30  0    0/30      0/30      0.34       0.17       –      0      0     0     0      3   0     0      3      7376
translategemma:12b  0.20  ru    errorsAndStyle  plain         30  0    0/30      0/30      0.38       0.25       –      0      0     0     0      3   0     0      0      6781
translategemma:12b  0.20  ru    rewrite         original      30  0    0/30      –         0.32       –          0.04   0      0     0     0      2   0     0      0      7521
translategemma:12b  0.20  ru    rewrite         friendly      30  0    0/30      0/30      0.31       0.22       –      0      0     0     0      0   0     0      0      7556
translategemma:12b  0.20  ru    rewrite         business      30  0    0/30      0/30      0.56       0.30       –      0      0     3     0      3   0     0      12     8547
translategemma:12b  0.20  ru    rewrite         professional  30  0    0/30      0/30      0.38       0.16       –      0      0     0     0      3   0     0      0      7447
translategemma:12b  0.20  ru    rewrite         plain         30  0    0/30      0/30      0.39       0.21       –      0      0     0     0      3   0     0      0      7097

quality: stage1-t050 · engine ollama 0.34.0 · models translategemma:12b · temperature 0.50 · chunk 4000 · runs 3 · corpus quality-corpus/style (88e30ba240ec061c) · commit a68fe94
mechanics only — no judge has read these replies; смысл, стиль and естественность are not in this table

model               t     lang  level           style         n   err  idle/src  idle/ctl  shift/src  shift/ctl  noise  lang✗  num✗  num+  fact✗  q✗  len✗  empty  added  ms
translategemma:12b  0.50  en    errorsAndStyle  original      30  0    0/30      –         0.31       –          0.05   0      0     0     0      3   0     0      2      6182
translategemma:12b  0.50  en    errorsAndStyle  friendly      30  0    0/30      0/30      0.47       0.25       –      0      0     0     0      3   0     0      3      6660
translategemma:12b  0.50  en    errorsAndStyle  business      30  0    0/30      0/30      0.55       0.28       –      0      0     0     0      5   0     0      10     6647
translategemma:12b  0.50  en    errorsAndStyle  professional  30  0    0/30      0/30      0.43       0.17       –      0      0     0     0      3   0     0      0      6084
translategemma:12b  0.50  en    errorsAndStyle  plain         30  0    0/30      0/30      0.43       0.15       –      0      0     0     0      3   0     0      3      6037
translategemma:12b  0.50  en    rewrite         original      30  0    0/30      –         0.38       –          0.08   0      0     0     0      3   0     0      0      6484
translategemma:12b  0.50  en    rewrite         friendly      30  0    0/30      0/30      0.51       0.25       –      1      0     0     0      3   0     0      2      6763
translategemma:12b  0.50  en    rewrite         business      30  0    0/30      0/30      0.60       0.28       –      0      0     3     0      4   0     0      11     6694
translategemma:12b  0.50  en    rewrite         professional  30  0    0/30      0/30      0.53       0.14       –      0      0     0     0      3   0     0      1      6124
translategemma:12b  0.50  en    rewrite         plain         30  0    0/30      0/30      0.45       0.18       –      0      0     0     0      3   0     0      3      6026
translategemma:12b  0.50  ru    errorsAndStyle  original      30  0    0/30      –         0.15       –          0.06   0      0     0     0      0   0     0      0      7397
translategemma:12b  0.50  ru    errorsAndStyle  friendly      30  0    0/30      0/30      0.25       0.19       –      0      0     0     0      0   0     0      0      7106
translategemma:12b  0.50  ru    errorsAndStyle  business      30  0    0/30      0/30      0.40       0.28       –      0      0     3     0      4   0     0      6      7665
translategemma:12b  0.50  ru    errorsAndStyle  professional  30  0    0/30      0/30      0.34       0.20       –      0      0     1     0      3   0     0      3      7322
translategemma:12b  0.50  ru    errorsAndStyle  plain         30  0    0/30      0/30      0.34       0.27       –      0      0     0     0      3   0     0      1      6709
translategemma:12b  0.50  ru    rewrite         original      30  0    0/30      –         0.30       –          0.12   0      0     0     0      3   0     0      0      7386
translategemma:12b  0.50  ru    rewrite         friendly      30  0    0/30      0/30      0.38       0.24       –      0      2     0     0      0   0     0      0      7609
translategemma:12b  0.50  ru    rewrite         business      30  0    0/30      0/30      0.59       0.35       –      0      0     3     0      3   0     0      9      8270
translategemma:12b  0.50  ru    rewrite         professional  30  0    0/30      0/30      0.40       0.18       –      0      1     0     0      3   0     0      1      7409
translategemma:12b  0.50  ru    rewrite         plain         30  0    0/30      0/30      0.36       0.19       –      0      0     0     0      2   0     0      0      7071
```

Flagged lines are in the run directories (`quality report`); what they say is below.

```
JUDGE UNCALIBRATED — no axis has ≥ 80 % agreement with a person over ≥ 20 decided pairs; read every figure below as unverified
agreement with a person (pairs neither called a tie): смысл 0 of 0 · стиль 0 of 0 · естественность 0 of 0

A  quality: stage1-t020 · engine ollama 0.34.0 · models translategemma:12b · temperature 0.20 · chunk 4000 · runs 3 · corpus quality-corpus/style (88e30ba240ec061c) · commit a68fe94
B  quality: stage1-t050 · engine ollama 0.34.0 · models translategemma:12b · temperature 0.50 · chunk 4000 · runs 3 · corpus quality-corpus/style (88e30ba240ec061c) · commit a68fe94
pairs: 24 · judged both ways by claude: 24 · by a person: 0 · identical replies, not judged: 21

claude:
  смысл           A 2 · B 0 · равны 22 (из них перевернулись при смене порядка: 1) · вето 0
  стиль           A 2 · B 2 · равны 20 (из них перевернулись при смене порядка: 2) · вето 0
  естественность  A 1 · B 3 · равны 20 (из них перевернулись при смене порядка: 3) · вето 0
  pairs with a lost fact: A 3 · B 4
  failures A: factLost 6 · grammar 11 · meaningDistorted 5 · needlessEdit 3 · registerMissed 10 · styleNotApplied 1
  failures B: factInvented 1 · factLost 6 · grammar 7 · llmCliche 2 · meaningDistorted 10 · needlessEdit 3 · registerMissed 5 · styleNotApplied 1

```

### What this entry says

**Temperature is not the lever.** Over 24 blind pairs judged both ways, 22 tie on смысл, 20 on стиль, 20 on естественность; the four decided style pairs split 2–2. 21 of the 45 shared cells that differed by nothing were token-identical at the two temperatures. Mechanically the two runs are the same table to within a cell or two — the same idle rates (zero everywhere), the same shift/ctl per style to ±0.05 — while the noise floor doubles at 0.5 (0.02–0.04 → 0.05–0.12) and 0.5 adds a `wrongLanguage` (an English «дружеский» reply the detector could not place) and two lost numbers on Russian «дружеский». Stage 2 runs at **0.2**: it costs nothing the styles want and keeps the series comparable with every earlier one. The install's 0.5 is a setting with no measured benefit here, and a note rather than a defect.

**No style is idle on this model, in either language** — idle/ctl is 0/30 in all 32 style rows. The 2026-08-10 finding (byte-identical «дружеский» and «простой») was `aya-expanse:8b`'s; `translategemma:12b` moves every style off its control. How *far* is another matter: shift/ctl is 0.25–0.35 for «деловой», 0.18–0.29 for «дружеский», 0.14–0.21 for «профессиональный», 0.13–0.27 for «простой», against a noise floor of 0.02–0.12 — «профессиональный» and «простой» sit within two or three noise floors of the control. Whether that movement is the *right* movement is what the judge's `registerMissed` (15 quotations over 24 pairs, both sides — «Угадайте, что произошло 19-го?» kept under «деловой»; «поставка будет осуществлена в две партии» under a style that asked for less bureaucratese) says it often is not.

**What the model loses is the same at both temperatures, and it is the finding of the night.** Under «деловой» it invents dates the source does not state («Yesterday, September 20th», «17 сентября», «21-го») — 6 replies of 30 on the complaint at 0.2, 9 of 30 at 0.5 — and drops questions into statements (`q✗`: 3–6 replies per style on the two texts that ask something). The judge's `meaningDistorted` (15) is the sharper version: «хотя мне трижды обещали, что перезвонят» became «было обещано, что звонок будет осуществлен трижды» on both sides; «на всех ручках» became «на всех серверах»; «дней за пять» became «a few days in advance» (`factLost`, 12). None of this is temperature.

**The «model answered» rule of PR #93 fires on 57 of 600 honest replies** (`added`), 39 of them under «деловой», where the model adds a salutation line — issue #97.

**The judge is uncalibrated**: no human verdicts yet. Every figure in the judged block is a session's reading. `quality judge --human build/quality-runs/cmp-t020-vs-t050` is the half hour owed; the 48 packets are on disk.

**A reading of the Russian replies, not a measurement:** the model drops «ё» throughout («придется», «еще», «приема») and «дружеский» on a status report came back as a bulleted list — structure the source did not have, which `MarkupSkeleton` reports and the judge should see as `registerMissed` rather than warmth.
