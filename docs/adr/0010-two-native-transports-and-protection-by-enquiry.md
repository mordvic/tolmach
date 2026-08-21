# Two native transports, and a reasoning guarantee that changes shape between them

The app talks to two servers, through two clients that share only `LLMClient`: `OllamaKit`
against `/api/*` and `LMStudioKit` against `/api/v1/*`. There is deliberately no third client
speaking the OpenAI-compatible `/v1/chat/completions` that both servers also offer, and would
have covered `mlx_lm.server` and `llama-server` as well.

## Why not the one client that would have covered everything

The obvious economy — one OpenAI-shaped client, three servers, no new module — fails on the one
property this app cannot trade away: **that a model's reasoning does not end up in the
translation.**

Measured 2026-08-21 and read from each vendor's own documentation:

| Server | Where a model's reasoning goes on the OpenAI-compatible endpoint |
|---|---|
| LM Studio | into `reasoning_content` **only if** the user has ticked a box in *its* App Settings → Developer; otherwise into `content` |
| `mlx_lm.server` | into `content`, always — it has no separate field |
| `llama.cpp` | into `content` unless the server was started with `--reasoning-format deepseek` |

So on default settings a reasoning model writes `<think>…</think>` straight into the reply. This
project has a name and a number for that: `qwen3:30b` under `"think": false` put 2798 characters
of Russian reasoning where a one-sentence answer belonged (`MEASUREMENTS.md`). Supporting the
compatible endpoint would mean stripping `<think>` inside `ResponseCleaner` — changing the
**domain layer** to accommodate the weakest transport, and doing it on a heuristic that cannot
distinguish a model's trace from a translation of a document that discusses one.

Both native endpoints separate it structurally instead: Ollama in `message.thinking`, LM Studio
in `reasoning.delta` events. Both are read and thrown away, and `TranslationCore` needs to know
nothing.

What the refusal costs: `mlx_lm.server` and `llama-server` are not supported. It is smaller than
it sounds, because LM Studio runs MLX models itself — every LLM on the install this was written
against reports `format: "mlx"` — so «MLX locally» is the second engine rather than a third one.
If a third is ever wanted it is another `LLMClient` at the same seam, and this file is where the
price of admission is written down.

## The guarantee is by construction on one engine and by enquiry on the other

`ThinkRequest` has no «on» case, and `docs/design/specs/2026-08-11-thinking-control-design.md`
§4.1 calls that protection by construction: `false` was accepted by all eight models measured,
`true` is HTTP 400 on a model whose capabilities lack `thinking`, so no value the app can build
can fail. That reasoning is about **Ollama's** transport, and it does not transfer.

On LM Studio the safe direction is inverted. Measured 2026-08-21:

```
POST /api/v1/chat  {"model":"openai/gpt-oss-20b", …, "reasoning":"off"}
→ HTTP 400  "Reasoning setting 'off' is not supported by model 'openai/gpt-oss-20b'.
             Supported settings: 'low', 'medium', 'high'."
```

`off` — the value that is safe everywhere on Ollama — is refused. So the guarantee is rebuilt on
a different foundation: the server states `capabilities.reasoning.allowed_options` per model, and
`ReasoningChoice` sends only a member of that list. Three consequences worth keeping:

- **Absent means unknown, and unknown means send nothing.** `qwen3.5-27b` on this install
  reports no `capabilities` object at all. Guessing `off` there is the request that returns 400.
- **A failed lookup is the same answer.** Paying for a trace is recoverable; a refused value
  costs the whole translation. This is the same trade `ModelPolicy.thinkingDisableLeaks` already
  makes for `qwen3:30b`, arrived at from the other direction.
- **`thinkingLevelsOnly` is not extended with LM Studio names.** «This family only grades, it
  cannot be silenced» stops being a table when the server will answer the question. The table
  stays because Ollama cannot be asked; on LM Studio it is not consulted, and it would not match
  a publisher-qualified identifier if it were.

The intent the app sends is therefore richer than a value: `.level(x)` reads «as quiet as this
model allows, and no louder than x if it cannot be silenced». `AppSettings` sends that on LM
Studio and `ModelPolicy`'s answer on Ollama, which is the whole of the per-engine difference.

## Consequences

- Two `URLSession`s where there was one, plus one client per port actually used
  (`ClientPool`). The comment on `TranslatorApp.client` used to be proud of having one; the
  alternative is rebuilding three view models when a radio button moves.
- `LMStudioKit` may not depend on `OllamaKit` and does not — stated in `Package.swift`. Where
  their vocabularies meet, the app layer adapts: `ModelDownloadProgress` → `PullProgress` in
  `EngineRouter`, which is the one place that already knows which engine is selected.
- «Длина рассуждения» is drawn from `allowed_options` on LM Studio rather than from a name, and
  only for a model that offers levels and **cannot** be silenced — otherwise the control would
  offer a value the app then ignores.

## Where the code is

`Sources/LMStudioKit/ReasoningChoice.swift` (the enquiry),
`Sources/LMStudioKit/LMStudioEventReader.swift` (the discard),
`Sources/TranslatorApp/AppSettings.swift` (`thinkRequest(for:)`),
`Sources/TranslatorApp/EngineRouter.swift` (the two clients), and
`docs/design/specs/2026-08-21-model-engine-switch-design.md` §2.1, §2.5 and §5.5.
