#!/bin/zsh
# Scripts/format-loss.sh
#
# The measurement behind the «Оформить» pass (spec #72, step 3): how often the installed
# models reconstruct a flat text's structure *without* changing a word, as judged by the same
# `FormattingGate` the app applies. The pass ships off by default; this is what would turn it
# on. Threshold, agreed 2026-09-02: the table comes back with the right column count and the
# gate accepts in at least 8 of 10 texts on translategemma:12b, three runs each.
#
#     ./Scripts/format-loss.sh corpus-dir            # every *.txt in the directory, 3 runs × 2 models
#     ./Scripts/format-loss.sh corpus-dir 12b        # one model, by the short name below
#
# The corpus is NOT in the repository: it is ten flat texts from real work, and real work is
# what must not be committed (no personal or medical data — org rule). Keep it outside the
# tree and point this script at it. `corpus/markup-en.md` is not a candidate: it already has
# its structure, and the app skips the pass on such a text.
#
# Needs a live Ollama and the release CLI (`swift build -c release --product translate-cli`).
# It is a probe, not a gate: it prints one line per run and a total per model, judges nothing,
# and leaves every output in a temp directory for reading. Record the totals in
# `docs/reference/MEASUREMENTS.md` with the date, the Ollama version and the corpus size.
set -u
cd "$(dirname "$0")/.."
CLI=.build/release/translate-cli
[[ -x $CLI ]] || { echo "build first: swift build -c release --product translate-cli"; exit 1; }
CORPUS=${1:?usage: format-loss.sh <corpus-dir> [12b|27b]}
WHICH=${2:-}
WORK=$(mktemp -d)
RUNS=3
case $WHICH in
    12b) MODELS=("translategemma:12b");;
    27b) MODELS=("translategemma:27b");;
    "")  MODELS=("translategemma:12b" "translategemma:27b");;
    *)   echo "unknown model short name: $WHICH"; exit 2;;
esac

for name in $MODELS; do
    accepted=0; total=0; texts_passing=0; texts=0
    for src in "$CORPUS"/*.txt; do
        [[ -f $src ]] || continue
        texts=$((texts + 1)); ok_here=0
        for i in $(seq 1 $RUNS); do
            out=$WORK/$(basename "$src" .txt)-${name//[:\/]/-}-$i.md
            if $CLI --format-only --model "$name" --chunk 4000 < "$src" > "$out" 2> "$out.err"; then
                verdict=accepted; accepted=$((accepted + 1)); ok_here=$((ok_here + 1))
            else
                # The token after «rejected:» is a `FormattingRejection` raw value.
                verdict=$(grep -o 'rejected: [a-zA-Z]*' "$out.err" || echo failed)
            fi
            total=$((total + 1))
            rows=$(grep -c '^|' "$out" || true)
            echo "$name $(basename "$src") run $i: $verdict · $rows table rows · $(tail -1 "$out.err")"
        done
        # A text counts as passing when every one of its runs was accepted: the user gets one
        # run, not the best of three.
        [[ $ok_here -eq $RUNS ]] && texts_passing=$((texts_passing + 1))
    done
    echo "== $name: $accepted/$total runs accepted; $texts_passing/$texts texts accepted in all $RUNS runs"
done
echo "outputs kept in $WORK — read the accepted ones: the gate proves the words, not that the table is the right shape"
