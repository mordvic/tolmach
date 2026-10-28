# Judging a comparison — the protocol a session follows

`quality blind` writes a comparison directory: `packets/pNNNN.json`, `key.json`, and empty
`verdicts/claude/` and `verdicts/human/`. This is how the Claude half gets filled. It is a
protocol for a session and not code, on purpose: there is no judge network code in this
repository (`docs/adr/0013`).

## Rules

1. **The session that ran the comparison does not judge it.** It knows which side is which.
   It launches **fresh sub-agents** and gives each nothing but a list of packet files and the
   rubric. Never `key.json`, never a run directory, never a manifest, never the words for what
   is being compared («the 0.5 run», «the new prompt»).
2. **Never for an external corpus.** `quality blind` refuses to build packets from a run
   stamped `external: true`; do not work around it by hand. Those texts are judged by mechanics
   and by their owner.
3. **One sub-agent judges at most ~12 packets**, so that a pair's two orderings usually land in
   different contexts and no context drifts. Split `packets/` into batches in id order — ids
   are already shuffled.
4. The sub-agent writes one verdict file per packet and nothing else. Afterwards run
   `quality judged <dir>`: it lists every verdict with a problem (a quotation not found in the
   text, a fact id the packet does not list, a wrong rubric version). Re-judge those packets
   with a fresh sub-agent; do not edit a verdict by hand.

## The prompt

> You are judging pairs of edited texts for a quality harness. Read
> `docs/reference/QUALITY-RUBRIC.md` first and follow it exactly.
>
> Then judge each of these packet files: `<absolute paths>`. Each holds a `source`, the `level`
> and `requestedStyle` the editor was asked for, the `facts` that had to survive, and two
> replies, `x` and `y`. You are not told what produced either and must not try to find out: read
> no file other than the rubric and these packets.
>
> For each packet write `<comparison-dir>/verdicts/claude/<packet id>.json` in the rubric's
> format, with `"judge": "claude"` and `"rubric"` set to the rubric's version. Judge the three
> axes separately. Go through `facts` one by one for each side. Every failure needs a short
> verbatim quotation from the reply it is about — copied, never paraphrased. «tie» is a real
> answer.
>
> Judge every packet on its own; do not carry a preference from one to the next. When done,
> reply with one line: how many verdicts you wrote.
