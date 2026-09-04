#!/bin/zsh
# Scripts/explanation-quality.sh
#
# The live measurement phase 3 of the change-marks work is offline without: whether
# `ExplanationGate` actually holds up against a real model, and whether an accepted sentence is
# *true* of the change it explains. `Translator.explain`, the gate and the CLI plumbing are
# built and tested against `FakeLLMClient` (issue #81 phase 3) — this script is what turns the
# gate's acceptance rate from a hope into a number, in the manner of `Scripts/change-density.sh`.
#
#     ./Scripts/explanation-quality.sh docs/proofreading-gate          # every *.txt, 3 степени × 3 runs × 2 models
#     ./Scripts/explanation-quality.sh docs/proofreading-gate 12b      # one model, by the short name below
#
# For every text × степень × run, `--proofread --explain --changes-json` is asked for the
# правка's own model (`AppSettings.proofreadModel` names it; this script takes it as an
# argument because it has no access to the app's settings store) and the `explanations: …`
# line on stderr is read: `accepted N`, `rejected: <reason>` or `skipped: <reason>`. The pass
# criterion, agreed alongside the route (see the CLAUDE.md pipeline note and
# `docs/reference/MEASUREMENTS.md`'s "Owed" section this script's header is copied into): the
# gate must accept in at least 80 % of runs on the правка model, and a person reading the kept
# accepted outputs must judge at least 90 % of the accepted sentences true of their change — the
# second half is not something this script can measure, only prepare for; it prints the accepted
# outputs' paths and stops.
#
# Needs a live Ollama and the release CLI (`swift build -c release --product translate-cli`).
# It is a probe, not a gate: it prints one line per run and a total per model, judges only the
# first half of the criterion, and leaves every output in a temp directory for reading. Record
# the totals in `docs/reference/MEASUREMENTS.md` with the date, the Ollama version, the corpus
# size and the model — the same discipline `change-density.sh` and `format-loss.sh` follow.
set -u
cd "$(dirname "$0")/.."
CLI=.build/release/translate-cli
[[ -x $CLI ]] || { echo "build first: swift build -c release --product translate-cli"; exit 1; }
CORPUS=${1:?usage: explanation-quality.sh <corpus-dir> [12b|27b]}
WHICH=${2:-}
WORK=$(mktemp -d)
RUNS=3
LEVELS=(errorsOnly errorsAndStyle rewrite)
case $WHICH in
    12b) MODELS=("translategemma:12b");;
    27b) MODELS=("translategemma:27b");;
    "")  MODELS=("translategemma:12b" "translategemma:27b");;
    *)   echo "unknown model short name: $WHICH"; exit 2;;
esac

for name in $MODELS; do
    accepted=0; rejected=0; skipped=0; total=0
    typeset -A rejected_reasons skipped_reasons
    for src in "$CORPUS"/*.txt; do
        [[ -f $src ]] || continue
        base=$(basename "$src" .txt)
        lang=${base%%-*}
        from=(); [[ $lang == ru || $lang == en ]] && from=(--from "$lang")
        for level in $LEVELS; do
            for i in $(seq 1 $RUNS); do
                out=$WORK/$base-${name//[:\/]/-}-$level-$i.json
                if $CLI --proofread --level "$level" "${from[@]}" --model "$name" --chunk 4000 \
                        --explain --changes-json < "$src" > "$out" 2> "$out.err"; then
                    line=$(grep -o 'explanations: .*' "$out.err" || echo "explanations: ?")
                else
                    line="FAILED: $(tail -1 "$out.err")"
                fi
                echo "$name $base $level run $i: $line"
                total=$((total + 1))
                case $line in
                    "explanations: accepted "*)
                        accepted=$((accepted + 1));;
                    "explanations: rejected: "*)
                        rejected=$((rejected + 1))
                        reason=${line#explanations: rejected: }
                        rejected_reasons[$reason]=$(( ${rejected_reasons[$reason]:-0} + 1 ));;
                    "explanations: skipped: "*)
                        skipped=$((skipped + 1))
                        reason=${line#explanations: skipped: }
                        skipped_reasons[$reason]=$(( ${skipped_reasons[$reason]:-0} + 1 ));;
                esac
            done
        done
    done
    pct=0
    (( total > 0 )) && pct=$(( 100 * accepted / total ))
    echo "== $name: $accepted/$total runs accepted (${pct}%), $rejected rejected, $skipped skipped"
    for reason in "${(@k)rejected_reasons}"; do echo "   rejected: $reason × ${rejected_reasons[$reason]}"; done
    for reason in "${(@k)skipped_reasons}"; do echo "   skipped: $reason × ${skipped_reasons[$reason]}"; done
done
echo
echo "outputs kept in $WORK — read the accepted ones' \"explanations\" object: the gate proves"
echo "the shape held, not that a sentence is true of its change. That judgement is the second"
echo "half of the pass criterion and is a human's to make."
