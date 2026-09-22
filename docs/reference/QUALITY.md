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
