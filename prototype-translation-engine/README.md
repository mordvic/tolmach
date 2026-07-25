# Prototype: translation engine

**Throwaway.** This exists to answer one question, then to be deleted or parked on a
throwaway branch. Do not build on it.

## The question

Are local models served by Ollama good enough for the three content types this project
targets — technical documentation with code, business correspondence, and long-form
articles — and is the engine shaped correctly?

Concretely, five things that cannot be settled on paper:

1. **Markup survival.** Do fenced code blocks, inline code and URLs come back byte-identical,
   or does the model "helpfully" translate them?
2. **Chunking.** Does keeping a fenced code block atomic actually hold, and does carrying the
   previous translated paragraph forward keep terminology consistent across chunks?
3. **Glossary.** Does supplying only the terms that occur in the text get honoured, and how
   often does the model ignore it anyway?
4. **Two-pass.** Does the self-review pass improve the result enough to justify roughly
   doubling the wall-clock time?
5. **Latency.** What is time-to-first-token with `keep_alive` holding the model resident —
   the number that decides whether a global-hotkey workflow feels instant or broken.

## Run it

```bash
cd ~/Documents/Projects/local-translator/prototype-translation-engine && swift run PrototypeTUI
```

Requires `ollama serve` to be running with at least one model pulled.

## What is and is not throwaway

`Sources/TranslationEngine` is the part meant to survive — pure logic, no I/O, and it depends
on the `LLMClient` protocol rather than on Ollama. `Sources/OllamaClient` is a thin adapter
that implements that protocol. `Sources/PrototypeTUI` is the throwaway shell.

## Answers

All five questions answered on 2026-07-24, hardware M5 Pro / 48 GB.

**1. Markup survival — holds, but the check is too weak.** Across every run (RU and DE, both
models) fenced code blocks, inline code and URLs came back intact. Two structural defects that
a presence-only check does not catch: `aya-expanse:8b` rewrites bare URLs as markdown links
(`[https://…](https://…)`), and `qwen3:30b` corrupted a blockquote by leaking a stray `>` into
the middle of a line. The integrity check needs to compare structure, not just substring presence.

**2. Chunking — code fences atomic ✓, terminology continuity ✗.** A 2100-char article at 600
chars/chunk produced 5 chunks with the code block intact. But "local language models" became
«местные языковые модели» in chunk 1 and «локальный переводчик» in chunks 4–5. Passing the
previous translated paragraph as context did **not** hold terminology together. Needs an
explicit term list, pinned after the first chunk and injected into every later prompt.

**3. Glossary — filtering works, verification produces false positives.** Supplying only the
terms present in the text was honoured: 5/5 in German. But the Russian run reported
`implementation guide` as violated when the model had translated it correctly as
«руководств**а** по реализации» — genitive case. Naive substring matching cannot verify a
glossary in an inflected language. Needs stem matching or `NLTagger` lemmatisation.

**4. Two-pass — 1.8× the time, and a net loss as prompted.** 12.3 s → 22.3 s on the same text.
Real wins: it fixed calques («доминируется» → «зависит от»), broken grammar («переводческих
памяти» → «памяти перевода») and a meaning error («плохо уступает» → «уступать»). Real losses:
it paraphrased freely, compressing the final paragraph and dropping content, and turned
«спецификацию» into «задание» — a new meaning error the first pass had not made. It did not fix
the cross-chunk terminology split. The refine prompt behaves like an editor; it has to be
constrained to a corrector before this feature earns its cost.

**5. Latency — hotkey is viable.** Warm `aya-expanse:8b`: time-to-first-token 330–570 ms,
41–46 tok/s, a 700-char doc in 5.7 s. Cold load costs ~2000 ms versus ~155 ms warm, so
`keep_alive` is load-bearing, not an optimisation.

**7. Model shortlist — all four installed candidates measured.**

| Model | TTFT warm | Total (700-char doc → DE) | Verdict |
|---|---|---|---|
| `aya-expanse:8b` | 0.55 s | 5.7 s | Only sub-second option. Fast slot. |
| `gemma3n:e4b` | 2.7 s (cold load) | 6.9 s | **Disqualified — corrupts identifiers.** |
| `gpt-oss:20b` | 7.5–25 s | 28.7 s | Best quality. Batch slot only. |
| `qwen3:30b` | 78.6 s | 82.4 s | Disqualified on latency. |

`gemma3n:e4b` is out on a hard failure, not a preference: it emitted
`` `StructureDefiinition` `` and `Implemenentierungsleitfadens` — character-level corruption of
an identifier *inside inline code* and of a glossary term. For a translator whose main content
type is technical documentation this is the worst available failure mode.

`gpt-oss:20b` produced the best output of the four. On the German doc it was the only model to
get `jede Ressource, die fehlschlägt, wird` agreement right, keep the URL bare and leave the
blockquote intact. On the Russian article it fixed six distinct errors `aya-expanse:8b` made —
the `восьмибиллионная` calque, `плохо уступает`, `пятнадцатистраничное спецификацию`,
`переводческих памяти`, `способного многоязычного модели` and `выгнанная из памяти`. It costs
4.4× the wall-clock (54 s vs 12 s on the chunked article) and its reasoning correctly lands in
`message.thinking`, so the content stream stays clean.

This vindicates having two model slots, but on a different axis than assumed: not 8B versus
30B, but **interactive versus background**. Sub-second TTFT is a hard requirement for the
hotkey and nothing else matters there; for the main window and the v2 batch mode, 25 s of
deliberation is an acceptable price for measurably better prose.

**8. The chunk-continuity failure is architectural, not a model deficiency.** `gpt-oss:20b`
produced «**Местные** языковые модели» in chunk 1 and «локальный перевод» in chunk 5 — the exact
same split as `aya-expanse:8b`, on the same input. Two models of very different capability fail
identically, which rules out model choice as the fix. It also introduced a structural artifact
`aya` did not: trailing double-spaces turning one paragraph into four hard-broken lines, which
the presence-only integrity check again failed to notice.

**6. Unplanned finding: reasoning models are disqualified from the hotkey path.** `qwen3:30b` spent **78 seconds**
deliberating before emitting the first character of translation — 82 s total against 5.7 s for
`aya-expanse:8b` on identical input, burning 4738 tokens where aya used 226. Ollama 0.31.1
returns that deliberation in a separate `message.thinking` field, and passing `"think": false`
makes it **worse**: the reasoning moves into `message.content` and pollutes the translation
directly. Its German was not better than aya's — it was differently flawed. The "quality model"
slot must not hold a reasoning model.
