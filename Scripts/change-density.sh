#!/bin/zsh
# Scripts/change-density.sh
#
# Measurement item 1 of the change-marks spec (issue #81, `docs/design/specs/2026-09-04-change-
# marks-spec.md`): where `TextDiff.densityThreshold` should sit. The rule it calibrates turns a
# paragraph into ONE block-scope change once more than the threshold of its tokens moved — so a
# «переписать» paragraph reads as «rewritten» rather than as confetti — and it ships at the start
# value 0.5 until this script has been run and its figures recorded.
#
#     ./Scripts/change-density.sh docs/proofreading-gate          # every *.txt, 3 levels × 3 runs × 2 models
#     ./Scripts/change-density.sh docs/proofreading-gate 12b      # one model, by the short name below
#
# For every text × степень × run the release CLI is asked for `--changes-json`, and the
# `blocks[]` records — one per compared block pair, with `sourceTokens`, `resultTokens`,
# `changedTokens` and `similarity` — are pooled per степень. Two ratios are read for each block,
# the two the code applies in turn: `1 − similarity` (the pre-check, over token multisets) and
# `changedTokens / (sourceTokens + resultTokens)` (the post-check, over the folded edits, counted
# before the merge — PR #83's stated deviation). The report prints their distribution per степень
# and, for a grid of candidate thresholds, how many «только ошибки» blocks fall below and how many
# «переписать» blocks that changed at all fall above. The spec's criterion is ≥ 90 % on both; the
# script prints the table and judges nothing.
#
# The language is taken from the file name's prefix (`ru-`, `en-`), because a stated source
# governs the prompt and `translate-cli --from` is how a caller states it. Needs a live Ollama and
# the release CLI (`swift build -c release --product translate-cli`). Outputs are kept in a temp
# directory for reading. Record the totals in `docs/reference/MEASUREMENTS.md` with the date, the
# Ollama version, the corpus size and the model.
set -u
cd "$(dirname "$0")/.."
CLI=.build/release/translate-cli
[[ -x $CLI ]] || { echo "build first: swift build -c release --product translate-cli"; exit 1; }
CORPUS=${1:?usage: change-density.sh <corpus-dir> [12b|27b]}
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
    for src in "$CORPUS"/*.txt; do
        [[ -f $src ]] || continue
        base=$(basename "$src" .txt)
        lang=${base%%-*}
        from=(); [[ $lang == ru || $lang == en ]] && from=(--from "$lang")
        for level in $LEVELS; do
            for i in $(seq 1 $RUNS); do
                out=$WORK/$base-${name//[:\/]/-}-$level-$i.json
                if $CLI --proofread --level "$level" "${from[@]}" --model "$name" --chunk 4000 \
                        --changes-json < "$src" > "$out" 2> "$out.err"; then
                    summary=$(grep -o 'changes: .*' "$out.err" || echo "changes: ?")
                else
                    summary="FAILED: $(tail -1 "$out.err")"
                fi
                echo "$name $base $level run $i: $summary"
            done
        done
    done
done

python3 - "$WORK" <<'EOF'
import json, sys, glob, os, statistics
work = sys.argv[1]
pool = {}   # (model, level) -> list of (pre, post, changed>0)
for path in glob.glob(os.path.join(work, "*.json")):
    parts = os.path.basename(path)[:-5].rsplit("-", 3)   # base, model, level, run
    if len(parts) < 4: continue
    model, level = parts[1], parts[2]
    try:
        d = json.load(open(path))
    except Exception:
        continue
    for b in d.get("blocks", []):
        s, r, c = b["sourceTokens"], b["resultTokens"], b["changedTokens"]
        if s + r == 0: continue
        pool.setdefault((model, level), []).append((1 - b["similarity"], c / (s + r), c > 0))

def pct(xs, p):
    if not xs: return float("nan")
    xs = sorted(xs); k = (len(xs) - 1) * p; f = int(k); c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)

grid = [0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.7]
for model in sorted({m for m, _ in pool}):
    print(f"\n== {model} ==")
    print("  level           blocks  changed  pre p50/p90/p95/max        post p50/p90/p95/max")
    for level in ["errorsOnly", "errorsAndStyle", "rewrite"]:
        rows = pool.get((model, level), [])
        pre = [x[0] for x in rows]; post = [x[1] for x in rows]; ch = sum(1 for x in rows if x[2])
        fmt = lambda xs: "/".join(f"{pct(xs, p):.2f}" for p in (0.5, 0.9, 0.95)) + f"/{max(xs):.2f}" if xs else "-"
        print(f"  {level:<15} {len(rows):>6} {ch:>8}  {fmt(pre):<26} {fmt(post)}")
    eo = pool.get((model, "errorsOnly"), []); rw = [x for x in pool.get((model, "rewrite"), []) if x[2]]
    print("\n  threshold   errorsOnly blocks below (pre / post)   rewrite blocks that changed, above (pre / post)")
    for t in grid:
        def below(xs, i): return 100 * sum(1 for x in xs if x[i] <= t) / len(xs) if xs else float("nan")
        def above(xs, i): return 100 * sum(1 for x in xs if x[i] > t) / len(xs) if xs else float("nan")
        print(f"  {t:<10.2f}  {below(eo,0):6.1f} % / {below(eo,1):6.1f} %                {above(rw,0):6.1f} % / {above(rw,1):6.1f} %")
print(f"\nraw outputs kept in {work}")
EOF
