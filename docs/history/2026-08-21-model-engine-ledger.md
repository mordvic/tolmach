> Historical record of the build. Where this and the code disagree, the code is right.
>
> Written as the four waves landed, from the spec, the measurements taken against a live server,
> and three review passes. It records what was found, what was ruled, and what was rejected —
> including defects in the spec itself and in this work's own review fixes. It is not
> maintained: it is the account of a piece of work.

# Engine-switch ledger — spec: docs/design/specs/2026-08-21-model-engine-switch-design.md

Branch: `feat/lmstudio-kit`, stacked on `docs/model-engine-switch-spec` (PRs #36 and #37).
Baseline at start: **804 tests**, zero warnings, 6 SwiftPM targets, one engine.
At the end of wave 4: **7 targets**, two engines, and the counts in the PR rather than here —
`CLAUDE.md` forbids a test count in documentation, and this file shipped one stale already.

---

## The one thing to read if you read nothing else

**The safe direction is inverted between the two servers, and every design decision here follows
from that one fact.** On Ollama nothing the app can build may *enable* reasoning — `false` is
accepted by every model measured, `true` is HTTP 400 on a model without the capability — which is
why `ThinkRequest` has no «on» case, and the thinking-control design calls that protection by
construction. On LM Studio it is `off` that is refused:

```
POST /api/v1/chat  {"model":"openai/gpt-oss-20b", …, "reasoning":"off"}
→ HTTP 400  "Reasoning setting 'off' is not supported … Supported settings: 'low', 'medium', 'high'."
```

So the guarantee had to be rebuilt on a different foundation — read
`capabilities.reasoning.allowed_options` and send only a member of it — and «absent» and «lookup
failed» both had to mean «send nothing», because paying for a trace is recoverable and a refused
value costs the whole translation. That is `docs/adr/0010`.

---

## What the documentation got wrong

Three disagreements between LM Studio's own documentation and its running server. Two of them
would have shipped a client that parses nothing, and all three were found by asking the server
rather than by reading more carefully.

| Question | Documented | Measured 2026-08-21 |
|---|---|---|
| Does `/api/v1/chat` accept `ttl`? | yes, for both APIs | **no** — HTTP 400 `unrecognized_keys`, and unknown keys are *rejected* rather than ignored |
| What carries a token? | `content` (docs site) / `delta` (context7 index) | **`content`** |
| Shape of `chat.end`? | flat `message` / `usage` | everything nested under **`result`** |

The `ttl` answer decided residency: it cannot be a duration attached to a request, so it is
«loaded until unloaded», so warm-up calls `/api/v1/models/load`, so Auto-Evict leaves it alone.
One refusal shaped three decisions.

---

## Rejected

- **A third, OpenAI-compatible engine** covering `mlx_lm.server` and `llama-server`. It cannot
  promise that reasoning stays out of the translation: LM Studio splits `reasoning_content` only
  when a box is ticked in *its* settings, `mlx_lm.server` never does, `llama.cpp` only under
  `--reasoning-format deepseek`. Supporting it meant stripping `<think>` inside `ResponseCleaner`
  — changing the domain layer to accommodate the weakest transport. The reach lost is small
  because LM Studio runs MLX itself. `docs/adr/0010`.
- **Stopping or starting a server.** Asked for, argued against, and the user accepted the
  argument: 63 MB for a server holding no model against 17.4 GB for one model, a server shared
  with other clients (LM Studio's own documentation names Zed, Cline and Continue), and the one
  operation that does not undo itself. «Открыть …» instead, which also closes design spec §8's
  never-implemented «Запустить Ollama».
- **A blanket «Выгрузить всё из памяти».** Designed, then removed before it was written: a loaded
  instance reports its id and configuration and nothing about *who* loaded it, so the button could
  only reach another application's model or lie about its own scope.
- **A free-text address field.** Only the port is settable. `docs/adr/0009`.
- **Capping `context_length` to save memory.** Measured and killed: 10.19 GB at the model's
  maximum against 10.21 GB at 8192, because MLX allocates its KV cache lazily. A setting that
  would have done nothing but truncate prompts when set too low.
- **Warming both models on LM Studio**, which the spec asked for on the strength of the
  Auto-Evict exemption. The exemption is real; the memory is not — 22.81 GB apiece against 48 GB.
  The exemption protects a *queue run* instead.

---

## Defects found in this work, by the harness that was supposed to find them

Every property was mutation-checked: 19 mutations over the transport, 11 over the review fixes,
11 over the app layer. Three of them killed something of this work's own.

- **A test that proved nothing.** `theListingCallUsesTheSameBuilderAsEveryOtherCall` called the
  request builder directly, so reverting `models(from:session:)` to hand-building its own request
  left it green. `docs/reference/TESTING.md`'s fifth shape, written by the person who had just
  read that document. Deleted, with the honest sentence put in the builder test instead.
- **Four lines that looked load-bearing and were not.** Explicit `access(keyPath: \.engine)`
  calls were added to four per-engine getters «so a picker notices a switch». The mutation
  changed nothing: each getter already *reads* `engine`, whose own getter registers it. Removed,
  and the doc comment now says where the dependency actually comes from.
- **A failed unload reporting success.** `unload` recorded the failure and then called `reload()`,
  which clears `error` when it succeeds. Caught by the test written for it, before the comment
  about it existed.

---

## The review disagreement, and how it was settled

Two independent reviews looked at the transport. Both flagged the same line and drew opposite
conclusions: a requested reasoning level the model does not offer fell back to the *quietest*
option, so `.level(.high)` against `qwen/qwen3.8-27b` returned `off`. One called the behaviour
wrong; the other called the comment wrong, since the spec said «quietest».

The first fix chose transport-literal semantics — «the nearest level not louder than asked» —
and it was wrong for a reason that only appeared when the app layer was built: with a *target*,
the app cannot express «quiet, but no louder than x» without knowing each model's capabilities,
and those live in the transport. The final reading is a **ceiling**: `.level(x)` means «as quiet
as this model allows, no louder than x». The contradiction the reviews worried about is settled
in the pane instead — «Длина рассуждения» is drawn only for a model that offers levels and cannot
be silenced, so a control whose value would be ignored is never shown.

Worth recording because the sequence is the lesson: a review found a real defect, the first fix
was locally reasonable and globally wrong, and the layer above is what revealed it.

---

## A claim rejected with evidence

One review reported that an in-stream `error` frame carries no top-level `type`, so the reader's
throw would never fire and a partial translation would finish as a success. The parameter table
for that event says «The type of the event. Always `error`», so the fixture was the documented
shape and the throw does fire. The finding was still worth its weight: the *failure direction* it
described is real, so a payload carrying an error object without a type is now treated as an
error anyway — the two mistakes are not equally bad.

---

## What a person still owes

`docs/reference/OPEN-ITEMS.md` gained two blocks: six live-server behaviours no offline test can
reach (Ollama's unload round trip, an `error` event mid-stream, a real download polled to
completion, a 401, whether an explicit load survives the 60-minute idle TTL, and
`qwen/qwen3.8-27b` under `off`), and seven drawn things — the pane at 560 × 480 with two new
controls, the per-row «Выгрузить», «Открыть LM Studio», the panel's «Настройки» button, the
pickers redrawing on a switch, the «Длина рассуждения» row appearing and disappearing, and the
port field's behaviour under a typo.

Accepted rather than owed: `ModelPolicy.blacklist` and the think tables match no
publisher-qualified LM Studio name, so a blacklisted model carries no warning there. Extending
those tables by guesswork would put a false warning beside a model nobody measured.
