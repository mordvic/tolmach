# Switching the model engine: Ollama or LM Studio — design

Date: 2026-08-21
Status: pre-implementation

## Status of this document

This is the pre-implementation design for one setting — which local server the app talks to.
Once the code exists, **the code is the authority on behaviour and this document is the
authority on why**.

Every figure below was measured on 2026-08-21 against a live **LM Studio 0.4.21** (server on
port 1234, no authentication) and **Ollama 0.32.14**, on this project's usual M5 Pro / 48 GB.
Where the vendor's documentation and the live server disagree, the live server is what is
written here and the disagreement is named — there are three of them, and two would have
produced broken code.

---

## 1. Vocabulary

`CONTEXT.md` owns the app's words and gains one, and two of its existing entries stop being
true as written.

| Word | Means | Never |
|---|---|---|
| **движок** | the local server the app sends requests to: Ollama or LM Studio. Selected in «Модели» → «Движок» | «бэкенд», «провайдер», «сервер» (that is the process, not the choice), «API» |

- **рассуждение** currently reads «what a model emits into `message.thinking`». That names
  Ollama's field. It becomes «what a model emits before its answer — `message.thinking` on
  Ollama, the `reasoning.delta` event stream on LM Studio — which the app reads and throws
  away».
- **длина рассуждения** currently reads «Only `gpt-oss` has this control, because it is the one
  family that ignores being switched off». On LM Studio the control's presence is not a fact
  about a family: the server states per model which settings it accepts (§2.1), so the row is
  drawn from that answer rather than from a name.

---

## 2. What this rests on

### 2.1 The models this user actually has, and what they accept

`GET /api/v1/models`, verbatim from the live server:

| Model | Format | On disk | `capabilities.reasoning.allowed_options` | default |
|---|---|---|---|---|
| `qwen/qwen3.8-27b` | mlx | 22.81 GB | `off, low, medium, xhigh, on` | **`xhigh`** |
| `openai/gpt-oss-20b` | mlx | 12.10 GB | `low, medium, high` — **no `off`** | `low` |
| `google/gemma-4-e4b` | mlx | 8.97 GB | `off, on` | `on` |
| `qwen3.5-27b` | mlx | 22.80 GB | **absent — no `capabilities` at all** | — |

Three things follow, and each one kills a design that would otherwise look obvious.

**The safe direction is inverted from Ollama's.** On Ollama, `"think": false` is accepted by
every model measured and `true` is HTTP 400 on a model without the capability
(`docs/reference/PLATFORM-TRAPS.md`, sweep of 2026-08-11) — which is why `ThinkRequest` has no
«on» case. On LM Studio it is **`off` that is refused**:

```
POST /api/v1/chat  {"model":"openai/gpt-oss-20b", …, "reasoning":"off"}
→ HTTP 400
{"error":{"message":"Reasoning setting 'off' is not supported by model 'openai/gpt-oss-20b'.
  Supported settings: 'low', 'medium', 'high'.","type":"invalid_request",
  "param":"reasoning","code":"invalid_value"}}
```

So «protection by construction» does not transfer. Here protection is **protection by
enquiry**: read `allowed_options` and send only a member of it. That is not a weaker guarantee —
it is a stronger one, because it also covers the model whose answer nobody anticipated.

**A model may decline to say.** `qwen3.5-27b` reports no `capabilities`. Absent means unknown,
and unknown must mean «send nothing», never «send `off` and hope».

**Reasoning is on by default, and on one model it is on at maximum.** `qwen/qwen3.8-27b`
defaults to `xhigh`. `AppSettings.quietThinking` defaults to `true`; on this engine that
default earns more than it does on Ollama.

### 2.2 The transport, and where the documentation is wrong

| Question | Documented | Measured |
|---|---|---|
| Does `/api/v1/chat` accept `ttl`? | «works for requests targeting both the OpenAI compatibility API and LM Studio's REST API» | **No.** HTTP 400, `"Unrecognized key(s) in object: 'ttl'"`, `code: unrecognized_keys`. Unknown keys are rejected, not ignored |
| What carries a token in the stream? | `message.delta` with `content` (docs site); with `delta` (context7 index) | **`content`** |
| What shape is `chat.end`? | flat `message` / `finish_reason` / `usage` | **`{"type":"chat.end","result":{"model_instance_id","output":[…],"stats":{…}}}`** — everything nested under `result` |

The first of those three decides §5.4; the other two would each have shipped a client that
parses nothing.

One raw exchange, for the record — a translation on `google/gemma-4-e4b` with
`reasoning: "off"`, `store: false`:

```
event: chat.start          {"type":"chat.start","model_instance_id":"google/gemma-4-e4b"}
event: model_load.start    …
event: model_load.progress ×113   {"progress":0 … 1}
event: model_load.end      {"load_time_seconds":7.183}
event: prompt_processing.start / .progress ×2 / .end
event: message.start       {}
event: message.delta ×7    {"content":"Привет"} {"content":","} {"content":" мир"} …
event: message.end         {}
event: chat.end            {"result":{…,"output":[{"type":"message","content":"Привет, мир. Это тест."}],
                             "stats":{"input_tokens":35,"total_output_tokens":8,
                                      "reasoning_output_tokens":0,"tokens_per_second":57.7,
                                      "time_to_first_token_seconds":0.107,
                                      "model_load_time_seconds":7.183}}}
```

And the same on `openai/gpt-oss-20b` with `reasoning: "low"`: 16 `reasoning.delta` events
carrying 57 characters of trace, 5 `message.delta` events carrying «Привет, мир.»,
`reasoning_output_tokens: 16`. **The separation the app depends on holds on this transport** —
measured, on the one model here that reasons hardest.

Two lesser observations from the same runs, both of which a parser must survive:
`prompt_processing.end` arrived **twice** in the `gpt-oss` stream, and `message.start` /
`message.end` / `prompt_processing.end` carry `{}`.

### 2.3 Residency

| Fact | Figure |
|---|---|
| JIT loading (a chat request loads the model) | on by default |
| Idle TTL for a JIT-loaded model | 60 minutes, app default |
| Auto-Evict | on by default: **at most one** JIT-loaded model in memory |
| Auto-Evict against an explicitly loaded model | **does not touch it.** Measured: `gemma-4-e4b` loaded via `POST /api/v1/models/load`, then `gpt-oss-20b` JIT-loaded by a chat request — `/api/v1/models` then reported **both** loaded |
| Cold load, explicit | 5.603 s (`gemma-4-e4b`, 8.97 GB); 8.134 s (`gpt-oss-20b`, 12.10 GB) |
| `POST /api/v1/models/unload` | HTTP 200; resident set went 10.19 GB → 0.37 GB |

That fourth row is what makes a *long* run safe — it is why the file queue loads its model
explicitly (§7.3) — and it is emphatically **not** a licence to warm two models at launch. The
arithmetic forbids that on this machine: `qwen/qwen3.8-27b` is 22.81 GB, and two models of that
class do not fit in 48 GB beside anything else. Ollama's re-measurement of 2026-08-18 («two
models that fit stayed resident together») is a fact about memory pressure, and on this engine
the models are larger, so the pressure arrives sooner. Hence §7.3 warms **one** model.

Note the cold-load figures against `MEASUREMENTS.md`'s **~2000 ms** for Ollama: the model that
*is* warmed matters more on this engine, not less — and the one that is not warmed pays 5.6–8.1 s
once, which is the trade §7.3 states outright.

`context_length` was measured and deliberately **not** turned into a setting: an explicit load
defaults to the model's maximum (131072 for `gemma-4-e4b`), and loading at 8192 instead changed
the resident set by 0.02 GB — 10.19 against 10.21, i.e. nothing. MLX allocates its KV cache
lazily, so the obvious «cap the context to save memory» buys nothing and would add a control
whose only effect is to truncate a prompt when set too low.

### 2.4 Errors

Two channels, and a client needs both:

- **Before the stream** — ordinary HTTP with a JSON body:
  `{"error":{"message","type","param","code"}}`. Seen: `400 unrecognized_keys`,
  `400 invalid_value`, `404 model_not_found` (`"Invalid model identifier \"translategemma:27b\""`).
- **Inside the stream** — `event: error` with the same object. The documentation is explicit
  that this does **not** end the stream: «the final payload will still be sent in `chat.end`».
  A client that merely reads to the end therefore returns a **partial translation as a
  success**. This is the same hazard as `AsyncThrowingStream` finishing rather than throwing on
  cancellation (`CLAUDE.md`, the cancellation rule), and it gets the same treatment: an
  explicit check that turns it into a thrown error.

### 2.5 What was considered and rejected: a third, «OpenAI-compatible» engine

An `/v1/chat/completions` client would have covered `mlx_lm.server` (installed here, port 8080)
and `llama-server` as well. It is rejected, for one reason that outweighs the reach:

**it cannot promise that reasoning stays out of the translation.** LM Studio only splits it
into `reasoning_content` when the user has ticked a box in *its* App Settings → Developer;
`mlx_lm.server` never splits it; `llama.cpp` splits it only under `--reasoning-format deepseek`.
On default settings a reasoning model writes `<think>…</think>` straight into `content`, which
is the `qwen3:30b` leak (`MEASUREMENTS.md`: 2798 characters of reasoning in place of an answer)
reintroduced as the normal case and unfixable from this side of the wire. Supporting it would
have meant stripping `<think>` inside `ResponseCleaner` — i.e. **changing the domain layer to
accommodate the weakest transport**.

The reach lost is small: LM Studio runs MLX models itself — every LLM on this machine reports
`format: "mlx"` — so «MLX through LM Studio» is the second engine, not a third one. If
`mlx_lm.server` is ever wanted, it is a third `LLMClient` at the same seam, and this section is
where the price is written down.

Also rejected: stopping or starting an engine's server from the app. §3.3.

---

## 3. What the user gets

### 3.1 The switch

«Модели» → the section currently titled «Ollama» becomes «Движок»:

```
Движок:        (•) Ollama        ( ) LM Studio
Состояние:     ● Ollama работает, модель в памяти          [Проверить снова]
Порт:          [11434]
```

When the selected engine does not answer, the state row gains **[Открыть Ollama]** /
**[Открыть LM Studio]**, which reveals the application rather than launching a server (§3.3).
That also closes design spec §8's «Ollama not running → a «Запустить Ollama» button», which has
never existed in the code.

### 3.2 Unloading a model

«Установленные модели» already prints «· в памяти» beside a resident model. That row gains a
**[Выгрузить]** button, and the section header gains nothing.

**There is deliberately no «Выгрузить всё из памяти».** Measured: a loaded instance in
`GET /api/v1/models` carries `id` and `config` and nothing else — the server does not say who
loaded a model or whether it was JIT-loaded. So a blanket button has only two possible
implementations, and both are dishonest: unload everything, which reaches models LM Studio
loaded for another client (its own documentation names Zed, Cline and Continue), or unload the
ids this process remembers loading, which forgets them at every relaunch and would leave the
button claiming an authority it has for one session. A per-row button says exactly what it
unloads, and repeating it is the entire cost.

Three rules, each of which is a defect if dropped:

1. **Disabled while a translation is running** — in the window, in the panel or in the file
   queue. Unloading mid-queue truncates a document.
2. **The status is refreshed straight after**, or the menu-bar glyph keeps claiming the model is
   resident: it refreshes at known moments only, by design (`OllamaStatus`' doc comment).
3. **Nothing is re-warmed.** Warm-up happens at launch; a button that unloads and then reloads
   is a button that does nothing.

### 3.3 Why there is no «stop the server»

Neither engine can be stopped over HTTP. The only route is running another program —
`lms server stop`, or killing `ollama serve` — and the app has never started a process: there
is not one `Process()` in the source. Measured on this machine, that new power would buy:

| | Resident |
|---|---|
| `ollama serve`, no model in memory | **63 MB** |
| LM Studio, all processes, no model loaded | 0.36 GB |
| `translategemma:27b`, one model | **17.4 GB** |

The server is ~1/275 of a model. Everything worth freeing is freed by §3.2's button.

Two further reasons: the server is **shared** — LM Studio's own documentation names Zed, Cline
and Continue as its clients, and a translator that stops it breaks work it knows nothing about —
and stopping is the one operation that does not undo itself: an unloaded model returns on the
next request, a stopped server does not, and the app may not start it either.

So «Открыть LM Studio» / «Открыть Ollama», by the same mechanism `PermissionsGate.openSettings()`
already uses. The user stops the server where they started it.

### 3.4 Switching to an engine with no model chosen

The first press after switching lands here, because LM Studio's model settings start empty
(§6.2) and nothing is auto-selected: flipping a radio button may not silently pick a 22.81 GB
model and then load it at the next warm-up.

| Surface | What it says |
|---|---|
| «Модели» | the picker is empty and offers what is installed |
| The window | the primary action is disabled, and the status bar names the setting to fill |
| The panel | «Модель для перевода не выбрана» plus a **[Настройки]** button that opens Settings on the «Модели» tab |

The panel gets a button rather than only a message because it is the one surface with no way
out: it has a message row and a button row already, and a hotkey press that opened the settings
window *instead of* translating would substitute one action for another. The window and the pane
need no button — the user is already in reach of the picker.

---

## 4. Engine — `TranslationCore`

**Nothing in `TranslationCore` changes.** Not a type, not a field. This section exists to say
why, because three plausible changes present themselves and each is wrong.

- **No new `ChatOptions` field.** `keepAlive` is simply not sent by the new client (§5.4);
  `think` keeps its meaning as an *intent* — «quieten the reasoning as far as this model
  allows» — and the transport turns that intent into a value its server accepts (§5.5).
- **No new `ThinkRequest` case, despite `xhigh` existing.** The app never asks for *more*
  reasoning, so a level it cannot spell is a level it never wants. `.off` means «the quietest
  setting this model offers».
- **No `<think>` stripping in `ResponseCleaner`.** That would only have been needed for the
  engine §2.5 rejects.

`ModelPolicy`'s tables stay as they are, and their behaviour on LM Studio identifiers is worth
stating plainly rather than fixing:

- `thinkRequest(for:quiet:level:)` returns `.off` for `openai/gpt-oss-20b`, because the
  `gpt-oss` prefix does not match a publisher-qualified name. That is the **right** answer under
  the new meaning of `.off`: the client resolves it to `low`, the quietest this model offers.
  The prefix table is not consulted twice and is not extended.
- `blacklist` will likewise not match LM Studio names, so a blacklisted model carries no warning
  there. Accepted, not fixed: those reasons are measurements taken on Ollama tags, and a table
  extended by guesswork would put a *false* warning next to a model nobody tested. Recorded in
  `docs/reference/OPEN-ITEMS.md`.

---

## 5. Transport — a new target, `LMStudioKit`

`.swiftLanguageMode(.v6)`, macOS 14 floor, no dependencies — a new target repeats both, per
`CLAUDE.md`. `OllamaKit` is not touched. The package goes from 6 targets to 7.

### 5.1 `SSEFrameParser`

Pure function over one line, in the shape `OllamaStreamParser` already has, because that shape
is what let this project test its wire format at all. It folds `event:` / `data:` / blank-line
framing into a value:

```swift
enum SSEFrame: Equatable { case event(name: String, json: [String: Any]) }
```

`data:` payloads are JSON; a blank line terminates a frame; an unparseable payload yields
nothing rather than throwing, exactly as `OllamaStreamParser` treats a bad line.

### 5.2 `LMStudioEventReader`

Turns frames into `ChatEvent`, and this is where §2.2's and §2.4's measurements live:

| Event | Becomes |
|---|---|
| `message.delta` | `.token(content)` — the field is `content` |
| `reasoning.delta` | **nothing.** Read and discarded, by the standing rule that governs `message.thinking` |
| `chat.end` | `.done(stats)`, read out of `result.stats` |
| `error` | a thrown error — *not* a finish. §2.4 |
| `chat.start`, `model_load.*`, `prompt_processing.*`, `message.start`, `message.end`, `reasoning.start`, `reasoning.end`, `tool_call.*` | nothing. Repeats are legal: `prompt_processing.end` was observed twice in one stream |

`ChatStats` is filled from `result.stats` where the fields correspond and left at zero where
they do not: `input_tokens` → `promptEvalCount`, `total_output_tokens` → `evalCount`,
`model_load_time_seconds` → `loadDurationMS`. Durations for the eval and prompt phases are not
reported and are zero. This costs nothing today — **`TranslationOutcome.stats` is read by
nobody**: not the app, not `translate-cli`, not `acceptance`, and `tokensPerSecond` appears
nowhere but its own declaration.

**`stats.time_to_first_token_seconds` is deliberately not used.** `docs/adr/0006` defines this
project's TTFT as the first *visible* emission after cleaning, and the server's figure is the
first token off the wire — on the `gpt-oss` run it read 3.182 s while the reasoning was still
streaming. Substituting it would move the gate that guards the sub-second requirement, which is
the defect ADR 0006 was written after.

### 5.3 `LMStudioClient: LLMClient`

`POST /api/v1/chat`, `stream: true`. Body, and **only** these keys — unknown keys are rejected
(§2.2), so the body is a closed list rather than a best effort:

| Key | From |
|---|---|
| `model` | `ChatOptions.model` |
| `system_prompt` | the `system` message from `messages` |
| `input` | the `user` message from `messages` |
| `stream` | always `true` |
| `temperature` | `ChatOptions.temperature` |
| `reasoning` | §5.5, and omitted entirely when that resolves to «send nothing» |
| `store` | always **`false`** |

Two of those rows are decisions rather than mappings.

**`store: false` is mandatory.** Its default is `true`, i.e. LM Studio keeps the conversation
and hands back a `response_id`. The text never leaves the machine either way, but a second copy
of every translation would accumulate inside another application's storage — and this app writes
to disk in exactly one place, `TranslatedFileWriter`. It does not get to acquire a second one by
omission.

**`messages` collapses into `system_prompt` + `input`.** The app's prompts are one system turn
and one user turn (`PromptBuilder`), which is exactly what this endpoint takes. A conversation
with assistant turns is not representable here and is not built here; if one ever is, this is
the line that has to change.

Timeouts carry over from `OllamaClient.Timeout` unchanged — 30 s interactive, 10 s probe — and
for its stated reason: the interval is a *gap* between arriving bytes, and this stream is
chattier than Ollama's, not quieter (113 `model_load.progress` events in one 7 s load).

### 5.4 Residency: `load`, `unload`, and the absence of `ttl`

- `POST /api/v1/models/load` — `{"model": …}`. Used by warm-up (§7.3). Returns
  `load_time_seconds`, which is logged at `.debug` and nothing else.
- `POST /api/v1/models/unload` — `{"instance_id": …}`. Behind §3.2's button.
- **No `ttl` anywhere.** It is refused by `/api/v1/chat` (§2.2), and an explicit load needs
  none: Auto-Evict does not touch explicitly loaded models (§2.3). `ChatOptions.keepAlive` is
  therefore not sent, and «Держать модель в памяти» is hidden on this engine (§6.2). Residency
  here is «loaded until unloaded», not «loaded for a duration».

### 5.5 The reasoning decision, and its fail-safe

A small actor caches `key → allowed_options` from the same `GET /api/v1/models` the probe
already calls. Given `ChatOptions.think`:

| `think` | capabilities | `reasoning` sent |
|---|---|---|
| `nil` (user wants reasoning left alone) | any | **omitted** |
| `.off` or `.level` | `allowed_options` contains `off` | `"off"` |
| `.off` or `.level` | no `off`, levels present | the **lowest** level present |
| `.off` or `.level` | `capabilities` absent | **omitted** |
| `.off` or `.level` | the capability lookup **failed** | **omitted** |

The last row is the fail-safe, and it follows this project's existing reasoning about the
`qwen3:30b` leak — «leaving the model reasoning costs time; disabling it costs the
translation». A refused `reasoning` value is HTTP 400, i.e. a failed translation; an unsent one
is a slower one. So when in doubt, pay the time.

Note what this replaces: `ModelPolicy.thinkingLevelsOnly` exists because Ollama cannot be asked.
Here the server answers, so «this family only grades, it cannot be silenced» stops being a
table and becomes the third row above — which is why §4 leaves the table alone instead of
extending it with LM Studio names.

> **Corrected during implementation (2026-08-21).** The table collapses `.off` and `.level` into
> one column, which would send the *lowest* level to a model offering several — and that makes
> «Длина рассуждения» inert on this engine, the very control §6.3 draws from `allowed_options`.
> `ReasoningChoice` therefore honours a requested level when the model allows it (`.level(.high)`
> on `gpt-oss` sends `"high"`) and falls back to the quietest option only when the requested one
> is not on offer; `.off` behaves exactly as the table says. What this leaves open is an
> **app-layer** question for the settings wave rather than a transport one:
> `ModelPolicy.thinkRequest` answers `.off` for every LM Studio identifier, because its prefix
> table matches no publisher-qualified name — so as things stand nothing would ever *pass* a
> level, and the control §6.3 draws would be read by nobody. However that is resolved, the
> transport already does the right thing with either intent.

### 5.6 Models, downloads, errors

- `GET /api/v1/models` → the probe's `installedModels()` and `residentModels()`. `key` is the
  identifier, `size_bytes` the size the pane already shows, and residency is
  `loaded_instances` being non-empty. `format` (`"mlx"` / `"gguf"`) is available and §10 keeps
  it out of the pane for now.
- **Downloads.** `POST /api/v1/models/download` `{model}` answers `{job_id, status,
  total_size_bytes, started_at}`; progress comes from `GET /api/v1/models/download/status/<job_id>`
  — note the id is a **path** component, not a query — carrying `downloaded_bytes`,
  `total_size_bytes` and `bytes_per_second`. There is **no stream**: unlike `/api/pull`, this
  has to be polled. `ModelsViewModel.Puller` is already
  `(String) -> AsyncThrowingStream<PullProgress, Error>`, so the client synthesises the stream
  by polling and the app layer does not learn that the two engines differ.

  > **Corrected during implementation (2026-08-21).** The synthesised stream carries
  > `ModelDownloadProgress`, a value of this module's own with `PullProgress`'s shape, **not**
  > `PullProgress` itself — that type lives in `OllamaKit`, and `LMStudioKit` deliberately does
  > not depend on it (`Package.swift` says why). The adaptation therefore happens in the engine
  > router, which is the one place that already knows which движок is selected; the view model
  > still does not learn. The alternative — moving `PullProgress` down into `TranslationCore` —
  > would put a transport concern in the domain layer to save one adapter.

  Three decisions rather than measurements, because there is nothing here to measure:

  | | |
  |---|---|
  | Poll interval | **1 s.** These are multi-gigabyte downloads and the server reports `bytes_per_second`, so a faster poll buys a smoother bar and nothing else |
  | `status: "paused"` | reported **in words**. A user can pause a download in LM Studio's own window, and a bar that simply stops moving reads as a hang |
  | `status: "already_downloaded"` | immediate success. The response carries no `job_id` in this case, so there is nothing to poll — and «уже установлена» is not a failure |

  `failed` becomes a thrown error. The five statuses join `RussianCopy.pullStatus` **beside**
  Ollama's, not instead of them: that function translates the server's own words, and now there
  are two servers with two vocabularies.
- Errors map by `code` — not by message text — into Russian through the existing
  `OllamaErrorBridge` protocol, which is declared in the app layer and simply gains a second
  conformer. `model_not_found`, `invalid_value`, `unrecognized_keys`, `internal_error`, plus a
  fallback carrying the server's own `message`.

---

## 6. Settings

Three new keys. No new pane, no new tab.

### 6.1 New

| Property | Key | Default |
|---|---|---|
| `engine: ModelEngine` | `"engine"` | `.ollama` |
| `ollamaPort: Int` | `"ollamaPort"` | 11434 |
| `lmStudioPort: Int` | `"lmStudioPort"` | 1234 |

`.ollama` as the default is the whole of the migration story: an existing install behaves
exactly as before until someone touches the switch.

**Only the port is settable, not the address.** The base URL is built as
`http://127.0.0.1:<port>`. A free-text address field is the one place where «text never leaves
the machine» would stop being a property of the code and become a matter of what the user
typed, and this app's central promise is not worth a text field.

`ModelEngine` lives in `TranslatorApp`, not in `TranslationCore`: it names transports, and the
domain layer does not know transports exist.

### 6.2 Existing settings that become per-engine

`interactiveModel`, `batchModel`, `proofreadModel` — a model name is meaningless on the other
engine (`translategemma:27b` does not exist in LM Studio; `openai/gpt-oss-20b` does not exist in
Ollama).

The existing keys stay **as the Ollama scope**, and LM Studio gets new ones
(`"interactiveModel.lmStudio"`, `"backgroundModel.lmStudio"`, `"proofreadModel.lmStudio"`). No
migration code, and no risk to a stored value. There is precedent for the key not matching the
property: `batchModel` is stored under `"backgroundModel"`.

`interactiveModel` has no sensible default on LM Studio — `ModelPolicy.defaultModel(for:)` names
Ollama tags — so it reads back **empty** until chosen, and empty must disable the primary action
with a message that says so. An engine switch that silently translates nothing is worse than one
that says «выберите модель».

### 6.3 Existing settings whose meaning becomes engine-dependent

| Setting | On Ollama | On LM Studio |
|---|---|---|
| `keepAlive` («Держать модель в памяти», «30m») | unchanged | **hidden.** Residency is «loaded until unloaded» (§5.4) |
| `quietThinking` («Отключать рассуждение модели») | unchanged — decided blind | decided from `allowed_options` (§5.5). Its caption gains nothing; the honesty is in the behaviour |
| `gptOssThinkingLevel` («Длина рассуждения») | row shown when a selected model has the `gpt-oss` prefix (`usesGptOss`) | row shown when a selected model's `allowed_options` has levels but no `off` |

The property behind that last row is renamed from `usesGptOss` to something that states the
question — `offersReasoningLevelsOnly` — while the stored key `"gptOssThinkingLevel"` stays put,
because renaming a key discards what a user chose.

### 6.4 Untouched

Languages, tone, правка degree and style, `contentFont`, both shortcuts, `autoCopy`,
`warmUpOnLaunch`, `chunkSize`, `temperature`, `saveNextToSource`, `stopOnWarnings`,
`reviewDocumentTerms`, the glossary, everything in «Файлы» other than the model picker.

`AppSettings.chatOptions(model:)` keeps its signature and its role as the only place the app
builds `ChatOptions`, for the reason it was introduced: a new call site cannot opt out of the
think decision. The engine-specific part of that decision is now behind the client, not behind
another call site.

---

## 7. The app layer

### 7.1 One router, no second client per model

`TranslatorApp.init` builds three `Translator`s over one client and must keep doing so, so the
thing it hands them cannot be a concrete client:

```swift
struct EngineClient: LLMClient {           // reads the setting on every call
    let ollama: OllamaClient
    let lmStudio: LMStudioClient
    let engine: @Sendable () -> ModelEngine
}
```

Reading the setting **per call** rather than at construction is what makes the switch take
effect without a relaunch, and it is why this is a router rather than a stored choice. Both
clients exist for the whole process — two `URLSession`s instead of one, which is the one place
this design spends something the old comment on `TranslatorApp.client` was proud of not
spending. It is worth it: the alternative is rebuilding three view models when a radio button
moves.

The same shape covers the probe and the puller, which are protocols already
(`OllamaProbe`, `ModelsViewModel.Puller`) — they gain an engine-routing implementation, not a
second call site.

### 7.2 Status

`OllamaStatus` becomes `EngineStatus`, renamed and **not** widened:

```swift
enum EngineStatus { case unknown, notAnswering, running(modelResident: Bool) }
```

An earlier draft of this design made that `Bool?`, with `nil` for «running, and residency is not
knowable» — reserved for an engine that cannot answer the question. Both engines here answer it
(`/api/ps`, `loaded_instances`), and §2.5 closes the third engine on the merits rather than
deferring it, so `nil` would have had **no producer at all**. This project already has a rule
for that shape and states it on `ThinkRequest`: only what is reachable should be
representable. An unreachable case in a type all three surfaces read is worse than a widening
someone can perform later, with a producer in hand.

Labels move into `RussianCopy`, keyed by engine, and take a **single form for both**: «Нет связи
с Ollama» / «Нет связи с LM Studio». This replaces «Ollama не запущена» — a per-engine template
would otherwise have to inflect («LM Studio не запущен», «Ollama не запущена»), and a template
that inflects is a template that will be wrong for the third name.

`menuBarSymbol` is unchanged and stays two-valued: the glyph answers «can I translate», which
has the same two answers on every engine.

### 7.3 Warm-up

`warmUp()` keeps `warmUpOnLaunch`, keeps swallowing failures at `.debug`, and changes both *how*
it warms and *how much*:

| | How | What |
|---|---|---|
| Ollama | unchanged: a one-token chat carrying the run's real `ChatOptions` | unchanged: both hotkey-reachable models, one after the other |
| LM Studio | `POST /api/v1/models/load` | **the перевод model only** |

Why explicit rather than a chat: a chat request JIT-loads, and JIT-loaded models are exactly
what Auto-Evict evicts (§2.3), so a warm-up by chat would be undone by the next JIT load.

Why one model and not two: 22.81 GB apiece for the 27B class, against 48 GB of machine. Two
models of that size do not co-reside, so warming both would either fail or push the system into
swap — and it would do so at *login*, before the user has asked for anything. The правка model
loads on the first ⌥⌘R instead and pays 5.6–8.1 s once. This is a deliberate asymmetry with the
Ollama path, which warms both, and the reason is memory rather than transport.

The comment on `warmUp` that reads «Ollama serialises loads anyway» stays true of Ollama only,
and the one below it — «Ollama keeps both resident when they fit» — is exactly the condition
that fails here. Both comments must name the engine they describe.

### 7.4 The file queue's model, and the eviction it would otherwise meet

A consequence of §7.3 that is easy to miss and expensive to hit. When
`AppSettings.batchModel` differs from the перевод model, it is not warmed, so it JIT-loads when
the queue starts — and a JIT-loaded model is evictable. A single ⌥⌘T on a *third* model during
the run would then evict the queue's model between files, and the next file pays a cold load.

So: **when the queue's model differs from the перевод model, the queue loads it explicitly at
the start of the run** (`POST /api/v1/models/load`), which puts it outside Auto-Evict's reach
(§2.3, measured). When they are the same — the default, `batchModel` being `nil` — nothing
happens at all: the model is already loaded and already exempt.

It is not unloaded at the end of the run. The app cannot honestly reclaim it: the server does
not report who loaded a model (§3.2), and by the time a queue finishes another client may be
using it. The per-row button is the reclaim mechanism, and it is the user's.

---

## 8. The pane

«Модели» carries seven sections today in `settingsPane()`'s fixed 560 × 480, and
`docs/reference/OPEN-ITEMS.md` already records that nobody has checked whether five of them fit.
This design therefore adds **no section**:

| Section | Change |
|---|---|
| «Ollama» → «Движок» | gains the engine picker and the port field, and «Открыть …» when the engine is silent; keeps state and «Проверить снова»; «Адрес» becomes «Порт» |
| «Модель для перевода», «Модель для правки» | unchanged, reading per-engine settings |
| «Установленные модели» | each resident row gains «Выгрузить». The empty-state line «Ollama не сообщила ни одной модели.» becomes engine-named |
| «Скачать модель» | unchanged, and keeps working on both engines (§5.6). The section's own comment about «скачать» vs «загрузка» stands and matters more now: this pane will say «выгрузить», «загрузить» and «скачать» in one column |
| «Модель в памяти» | shown on Ollama only |
| «Качество перевода» | «Длина рассуждения» row's condition changes (§6.3) |

Net section count: 7 on Ollama, 6 on LM Studio. **Whether it fits is still a manual check**, and
this design does not claim it — `OPEN-ITEMS` §1 gains the line, as the thinking-control design
had to.

---

## 9. `translate-cli` and `acceptance`

Both gain `--engine ollama|lmstudio`, defaulting to `ollama`, and both bypass `AppSettings`
exactly as they do today — a harness that followed a user setting would move its own baseline.

`--think` keeps working on Ollama, where it exists to force a bare value past the policy and
re-take a measurement. On `--engine lmstudio` it is **rejected with the usage text**, not
silently ignored: §2.1's HTTP 400 is precisely what an unchecked value produces here, and a
flag that quietly did nothing would make a mistyped measurement look like a result.

`acceptance` extends the rule it already has for `--model`: its two gates are properties of
`aya-expanse:8b` on Ollama, so under any other engine the TTFT ceiling prints `info only` and
every markup diff is unaccepted. The first line of output must name the engine as well as the
model.

---

## 10. What does not change

- `TranslationCore`. §4.
- `OllamaKit`, except for one addition: `unload(model:)`, which builds `/api/chat` with
  `messages: []` and `keep_alive: 0` — the documented way, answering `done_reason: "unload"`.
  **Not exercised against a live server yet**; `OPEN-ITEMS` carries it.
- `glossary.json`, the pipeline, the panel, the file queue, both hotkeys.
- The menu-bar glyph's two states. §7.2.
- `TranslationOutcome.stats` staying unread. §5.2 notes it rather than fixing it.
- `format: "mlx" | "gguf"` is available and not shown. It answers a question nobody asked yet,
  and «Установленные модели» is the row that would have to grow.
- `model_load.progress` is parsed away, not surfaced. A progress bar for an 8-second cold load
  is worth having and is a separate change: it needs a place in `RunStatusBar`, and this design
  is already touching six sections of one pane.

---

## 11. Testing

Offline, Swift Testing, sentence-named, per `docs/reference/TESTING.md` — and each of these must
be watched to fail under the defect it names, mutating the implementation rather than the
assertion.

**`LMStudioKitTests` — the wire format, which is where two documented facts turned out wrong.**
- a message delta yields a token from its «content» field
- a reasoning delta yields no token at all
- an error event inside a stream throws rather than finishing the stream
- statistics are read from chat.end's nested result rather than from its top level
- a repeated prompt_processing.end does not disturb the token order
- a frame whose data is not JSON is ignored rather than throwing
- the request body carries only the documented keys, and «ttl» is not among them
- the request body always carries store: false
- a system and a user message become system_prompt and input

**`LMStudioKitTests` — the reasoning decision, one test per row of §5.5.**
- a model that allows «off» is asked for «off»
- a model that allows only levels is asked for its lowest level, not «off»
- a model that reports no capabilities is sent no reasoning key
- a failed capability lookup sends no reasoning key
- an unquiet run sends no reasoning key whatever the model allows

That third and fourth pair matter most: both are cases where the *absence* of a key is the
behaviour, and a test asserting a dictionary's contents will pass under a mutation that adds
one. Assert the key is absent, not that the rest is right.

**`LMStudioKitTests` — downloads, which are polled rather than streamed.**
- a download job's byte counts become a fraction, and a status without counts leaves the bar
  where it was (the shape `PullProgressParser` tests already have, and shape 1 of
  `docs/reference/TESTING.md` — assert between the lines, not after the stream)
- a paused download reports its state rather than reporting nothing
- a response with no job id, because the model is already downloaded, completes rather than
  polling a nil id
- a failed status ends the stream with an error

**`TranslatorAppTests` — routing and settings, `InMemoryDefaults` only.**
- the engine is read on every chat call, so a switch takes effect without rebuilding the client
- the Ollama model settings are untouched by choosing LM Studio, and vice versa
- an unchosen LM Studio translation model reads back empty rather than an Ollama default
- an empty model disables the primary action
- «Держать модель в памяти» is offered on Ollama and not on LM Studio
- the «Длина рассуждения» row follows what the model allows, not what it is called
- every error code reaches the user in Russian (extending
  `everyOllamaErrorCaseReachesTheUserInRussian`, exhaustive with no `default:`)
- every LM Studio download status reaches the user in Russian, alongside Ollama's
- unloading is refused while a run is in flight
- a queue whose model differs from the перевод model loads it explicitly before the first file
- a queue whose model is the перевод model loads nothing extra
- warm-up on LM Studio asks for the перевод model and not for the правка model

**`OllamaKitTests`.**
- an unload body carries an empty message list and a zero keep-alive

Deliberately **not** written: a test that asserts `gpt-oss` resolves to `low`. It would pass for
the wrong reason — through `ModelPolicy`'s prefix table missing, not through §5.5's rule — and go
on passing if the rule inverted. The rule is tested against synthetic capability lists instead.

**What cannot be tested here**, stated rather than faked: everything drawn (the pane's six
changed sections, the buttons' disabled states), and every live-server behaviour in §2 — those
are `docs/reference/OPEN-ITEMS.md` entries and the standalone-probe technique, not tests.

---

## 12. Documentation shipped with the code

- `CLAUDE.md` — «Ollama rules» splits into what is true of any engine and what is Ollama's;
  the target count goes 6 → 7; `AppSettings`' paragraph gains the three keys and the per-engine
  scoping.
- `CONTEXT.md` — §1: «движок», and the two corrected entries.
- `docs/adr/0009-loopback-and-no-conversation-store.md` — why only a port is settable and why
  `store: false` is not optional.
- `docs/adr/0010-two-transports-and-protection-by-enquiry.md` — why a second native client
  rather than one OpenAI-compatible client (§2.5), and why the reasoning guarantee changes shape
  from construction to enquiry (§2.1).
- `docs/adr/0004` — «they share the `OllamaClient`» becomes «they share one `LLMClient`».
- `docs/adr/0007` — the HTTP-client bullet: one endpoint family becomes two.
- `docs/design/specs/2026-08-11-thinking-control-design.md` — a correction note in its own
  house style: §4.1's «protection by construction» is a property of Ollama's transport, and
  §2's asymmetry is inverted on LM Studio.
- `docs/design/specs/2026-07-24-local-translator-design.md` — §1's «through Ollama», and §8's
  two rows about a not-running server and a missing model.
- `docs/design/specs/2026-07-30-ui-redesign-design.md` — §5.3's «Ollama» section.
- `docs/reference/MEASUREMENTS.md` — new durable rows: the `allowed_options` table, cold loads
  of 5.603 / 8.134 s, Auto-Evict's exemption, unload's 10.19 → 0.37 GB, the 63 MB / 17.4 GB
  ratio behind §3.3, and `context_length`'s 0.02 GB non-effect. The `keep_alive` row gains
  «Ollama only».
- `docs/reference/PLATFORM-TRAPS.md` — three new entries: unknown JSON keys are rejected, not
  ignored; an `error` event does not end the stream; the documentation's own three
  disagreements with the server (§2.2).
- `docs/reference/BASELINE.md` — a run on the new engine, once a model is chosen.
- `docs/reference/OPEN-ITEMS.md` — the pane's fit at 560 × 480; Ollama's `unload` unverified;
  `blacklist` silent on LM Studio names; whether `qwen/qwen3.8-27b` under `"off"` keeps its
  reasoning out of `message` (measured on `gpt-oss-20b`, not on this one); the panel's
  «Настройки» button and the per-row «Выгрузить» button, neither of which any test can see;
  whether an explicit load survives LM Studio's 60-minute idle TTL, which is documented for
  `lms load` and has no `ttl` field on the API (§5.4) and would take an hour to observe.
- `docs/history/2026-08-21-model-engine-ledger.md` — kept as the waves land, and it already has
  content: the three disagreements between LM Studio's documentation and its server (§2.2), the
  inverted `off` asymmetry (§2.1), the `context_length` hypothesis that measurement killed
  (§2.3), and the four places this design was corrected before any code existed — warming two
  models, the blanket unload button, the queue's model against Auto-Evict, and the unreachable
  `Bool?`.

---

## 13. Deliberately not in scope

- A third, OpenAI-compatible engine — `mlx_lm.server`, `llama-server`. §2.5.
- Starting or stopping a server. §3.3.
- A blanket «Выгрузить всё из памяти». §3.2.
- Warming the правка model on LM Studio, and unloading anything automatically. §7.3, §7.4.
- LM Studio's API tokens. Authentication is off by default and was measured off here; a 401
  must produce a clear Russian message telling the user to turn it off or that this is
  unsupported, and storing a token is a separate decision (it does not belong in
  `UserDefaults`).
- `/v1/responses`, `/v1/messages`, MCP integrations, tool calls, stateful chats
  (`previous_response_id`), `/api/v0/*`.
- `context_length` as a setting. §2.3.
- A model-load progress bar, and showing `mlx`/`gguf`. §10.
- Deleting models from the pane — still out of scope, as in the UI redesign.
