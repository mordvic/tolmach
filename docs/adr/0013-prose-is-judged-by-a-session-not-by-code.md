# Prose is judged by a session, not by code — and never an uncommitted text

Date: 2026-09-22. Status: accepted. Spec: GitHub issue #94;
`docs/design/specs/2026-09-22-quality-harness-design.md`.

## Context

Nothing in this repository measured whether a translation means what its source means or
whether a правка in «дружеский» reads friendly; the original design left prose to «a human …
still manual and unautomated». Mechanics cannot close that gap — a `diff` cannot tell a warm
sentence from a stiff one — so the `quality` harness needs a judge.

This is a privacy-positioned app. `docs/adr/0007` closes the dependency list because «that
claim is only as strong as the smallest dependency nobody has read», and `docs/adr/0009` makes
the engine address loopback in code: «nothing in this app can be pointed at a paid API by
configuration». A harness that posted texts to a cloud model would look, from the outside, like
the first crack in both.

## Decision

1. **There is no judge network code in this repository.** `QualityKit` depends on
   `TranslationCore` and nothing else, so nothing in it can open a socket; `quality` adds
   `OllamaKit`, which is loopback by construction. The harness writes **packets** — JSON files —
   and reads **verdicts** — JSON files. What fills the verdicts is a Claude Code *session*
   following `docs/agents/quality-judge.md`, or a person in `quality judge --human`. 0007 and
   0009 are untouched: no dependency, no configurable address, no HTTP client.
2. **Only committed text may be handed to a cloud judge, and the refusal is code.** A run over a
   corpus that is not wholly tracked by git and unmodified is stamped `external: true`, any
   doubt reads as external, and `Packets.build` throws on such a run before a packet exists. The
   committed corpus is already public on GitHub; a user's working texts are not, and the org
   rule `Scripts/format-loss.sh` records — no personal or medical data — applies to them.
3. **The judge is blind, swap-tested and checkable.** A packet names no model, temperature,
   label or commit; every pair is judged in both orders and a preference that flips is a tie;
   meaning is a checklist over the sidecar's facts; a failure counts only with a quotation the
   scorer finds in the text; the judging session is not the session that knows the key.
4. **A judge is unverified until a person agrees with it**: ≥ 80 % over ≥ 20 pairs neither
   called a tie, per axis, reported «N of M». Until then every judged table says «JUDGE
   UNCALIBRATED» on its first line. Below the bar the rubric changes and the calibration is
   repeated on new pairs.
5. **Three axes and never one score** — смысл (a veto), стиль, естественность. A stylish text
   that lost a fact is a failure, and an average is exactly what would hide it.

## Rejected

- **A local LLM judge in v1.** Nothing leaves the machine, but a 20–30B model judges RU↔EN
  style markedly worse than a frontier model, a judge from the family under test favours its
  own, and it would be a second unverified judge beside the first. It can come later, calibrated
  against these verdicts on the committed corpus — and it is the only judge an external corpus
  could ever have.
- **chrF/BLEU against public parallel corpora.** Deterministic and offline, but public
  parallel text is very likely in the models' training data, and an n-gram overlap says
  nothing about register.
- **Absolute 1–5 scores as the comparison instrument.** They drift between sessions and do not
  resolve the small differences a prompt change makes. Pairs do.
- **Automatic prompt optimisation against the judge.** `PromptBuilder` is full of measured
  decisions; an optimiser fitted to forty texts and one judge would undo them where the corpus
  does not look.
- **An exit-1 gate on a judged number.** The number is noisy and the noise is not yet measured;
  a gate on it cries wolf. The harness compares and diagnoses.

## Consequences

Judged figures cost a session's tokens and a person's half hour, so they are taken when a
decision hangs on them, not on every commit. `docs/reference/QUALITY.md` records them
append-only with the rubric version, and entries under different rubric versions are not
compared.
