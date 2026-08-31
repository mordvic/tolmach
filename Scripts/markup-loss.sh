#!/bin/zsh
# Scripts/markup-loss.sh
#
# The live markup-loss measurement behind §2 of
# `docs/design/specs/2026-08-31-formatting-design.md`: how much Markdown structure the
# installed models actually lose in translation and in правка, counted per form.
#
#     ./Scripts/markup-loss.sh                 # A-series: translation, shipped prompt
#     ./Scripts/markup-loss.sh --proofread     # C-series: правка over a RU translation
#
# Needs a live Ollama and the release CLI (`swift build -c release --product translate-cli`).
# It is a probe, not a gate: it prints per-run survival against the reference counts and
# judges nothing. 2026-08-31 results, 5×translategemma:12b / 3×translategemma:27b /
# 3×aya-expanse:32b, EN→RU: zero block-token losses (headings, lists, nesting, quote, code,
# all table rows) in 11/11; bold 6/6 in 11/11; italic 4/5 on 12b (always `*read-only*`) and
# on aya-32b (always `*first*`), 5/5 on 27b — systematic, not noise. The same doc through
# правка: every form survived 6/6 while 15–19 lines were genuinely edited. And the obvious
# prompt rule («preserve inline emphasis…») measured HARMFUL: 12b degraded `**staging**` to
# `*staging*` 5/5 and still lost `*read-only*`; aya-32b fabricated emphasis 2/3 — which is
# why no such rule ships. A trailing-newline difference shows up as one extra blank line;
# ignore it, it is the CLI's trailing separator, not structure.
set -u
cd "$(dirname "$0")/.."
CLI=.build/release/translate-cli
[[ -x $CLI ]] || { echo "build first: swift build -c release --product translate-cli"; exit 1; }
WORK=$(mktemp -d)
MODELS=("translategemma:12b 5" "translategemma:27b 3" "aya-expanse:32b 3")

cat > $WORK/source.md <<'EOF'
# Deployment guide

This section explains how the **staging** environment differs from *production*, and why the `deploy.sh` script refuses to run on Fridays.

## Requirements

Before you start, make sure that:

- the **API token** is present in the vault
- the *read-only* replica is healthy
  - its lag is below `500ms`
- the backup finished

1. Stop the ingest workers.
2. Run the migration with **exactly one** retry.
3. Restart the workers and *watch the queue*.

> Never skip the second step: a failed migration leaves the schema **half-updated**, and the workers will crash on the *first* message.

| Environment | Replicas | Auto-deploy |
|---|---|---|
| staging | 2 | **yes** |
| production | 6 | *no* |

The table above is updated **manually** after every release.
EOF

cat > $WORK/check.py <<'EOF'
import sys, re, json
text = sys.stdin.read()
lines = text.split('\n')
print(json.dumps({
    'h1': sum(1 for l in lines if l.startswith('# ')),
    'h2': sum(1 for l in lines if l.startswith('## ')),
    'bold_pairs': len(re.findall(r'\*\*[^*\n][^\n]*?\*\*', text)),
    'italic_pairs': len(re.findall(r'(?<!\*)\*(?!\*)[^*\n]+\*(?!\*)', text)),
    'code_spans': len(re.findall(r'`[^`\n]+`', text)),
    'bullets': sum(1 for l in lines if l.lstrip().startswith('- ')),
    'nested_bullets': sum(1 for l in lines if l.startswith('  - ')),
    'ordered': sum(1 for l in lines if re.match(r'\d+\. ', l.lstrip())),
    'quotes': sum(1 for l in lines if l.startswith('> ')),
    'table_rows': sum(1 for l in lines if l.lstrip().startswith('|')),
}))
EOF

MODE=${1:-}
SRC=$WORK/source.md
if [[ $MODE == --proofread ]]; then
    # Правка is measured over a RU rendition so the route has real errors of register to
    # touch; the 27b translation is the cleanest of the measured set.
    $CLI --to ru --from en --tone technical --model translategemma:27b --chunk 4000 < $WORK/source.md > $WORK/source-ru.md
    SRC=$WORK/source-ru.md
fi
echo "reference: $(python3 $WORK/check.py < $SRC)"

for entry in $MODELS; do
    name=${entry%% *}; runs=${entry##* }
    for i in $(seq 1 $runs); do
        out=$WORK/out-${name//[:\/]/-}-$i.md
        if [[ $MODE == --proofread ]]; then
            $CLI --proofread --level errorsAndStyle --from ru --model "$name" --chunk 4000 < $SRC > $out
        else
            $CLI --to ru --from en --tone technical --model "$name" --chunk 4000 < $SRC > $out
        fi
        echo "$name run $i: $(python3 $WORK/check.py < $out)"
    done
done
echo "outputs kept in $WORK"
