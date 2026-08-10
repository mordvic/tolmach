# Ollama stays the runtime; MLX arrives through it, not beside it

The app keeps exactly one LLM runtime: Ollama at `127.0.0.1:11434`, spoken to by `OllamaKit`.
No in-process MLX engine is embedded, no second server backend is wired in, and no
`ModelBackend` abstraction is built in anticipation of one. MLX is expected to reach this app
the way it reached everyone else on Apple Silicon: inside Ollama itself, selected per model,
behind the same API.

Decided 2026-08-10, after a research pass over all four options and two same-day measurements
recorded in `docs/BASELINE.md` (the 2026-08-10 entry) and indexed in `docs/MEASUREMENTS.md`.

## The fact that settles most of it

Ollama has shipped an MLX engine on Apple Silicon since v0.19.0 (March 2026), routed by model
format — GGUF runs on llama.cpp/Metal, MLX-format weights on the MLX runner — with the client
API unchanged: `/api/chat` NDJSON, `/api/tags`, `/api/pull`, `/api/ps`, `keep_alive`,
durations in nanoseconds. Every assumption `OllamaKit` encodes survived the engine change.
So «switch to MLX» is not an architecture decision for this app; it is a future `ModelPolicy`
edit, made the day the pinned models (or their successors) carry MLX-format tags in the Ollama
library — and gated, like any model change, on an acceptance run against `docs/BASELINE.md`.

## The alternatives, and why each lost

- **In-process MLX Swift** (`mlx-swift-lm`, MLXLLM 3.x). The API is genuinely good — streaming
  `AsyncStream`, correct cancellation, per-run stats — and both pinned architectures (`cohere`,
  `gpt_oss`) are registered. It lost on cost, not capability: it breaks `docs/adr/0007` (the
  dependency whitelist would have to admit mlx-swift, swift-syntax and swift-transformers);
  plain `swift build` cannot compile MLX's Metal shaders, so the entire build-and-CI shape —
  `swift build`, `swift test`, the warning gate, `make-app-bundle.sh` — would move to
  `xcodebuild`; mlx-swift is 0.x with upstream itself pinning it `upToNextMinor`; and the model
  weights (4.5–12 GB) would live in the app's own RSS with no documented memory-pressure
  behaviour. What it would buy — no daemon, no cold loads — is real, and priced below.
- **`mlx_lm.server`.** «Not recommended for production» by its own README, one resident model
  per process (the interactive/batch pattern becomes a full reload per switch — the exact cost
  the `batchModel = nil` design exists to avoid), no `keep_alive`, no duration fields at all.
  Kept as what it is good at: a measurement stand.
- **LM Studio.** The only alternative with an Ollama-grade management surface (download with
  status, load/unload, TTL as `keep_alive`), but a proprietary app the user would have to
  install and keep running — a strange dependency for a privacy-positioned tool to require.

## The measurements that priced the decision

Both from the 2026-08-10 baseline entry, Apple M5 Pro, identical prompts to both runtimes:

- **Speed:** MLX ahead by ~20–25 % on fresh-prompt TTFT and ~8–9 % on decode. Both runtimes
  sit far inside the 1000 ms TTFT gate even at ten times the 900-character chunk budget —
  Ollama's worst case on the corpus was 808 ms on a 4.5 KB prompt the app would never send
  whole.
- **Quality:** the full acceptance harness against the MLX aya conversion (through an
  NDJSON↔SSE proxy) came back **ACCEPTED** — `techdoc-en` adherence identical to GGUF to the
  digit, the same two known markup diffs, no new one.

Parity plus a modest speed win does not pay for losing `keep_alive`, the two-model scheduler,
and `/api/pull` + `/api/ps` — nor for reworking the build system. That arithmetic is the
decision.

## What this does *not* decide

- **The seam stays honest.** `Translator` depends on `LLMClient` alone; a second runtime, if
  one is ever warranted, is a new conformance plus a management protocol over what today is
  `models()`/`ps()`/`pull()` — bounded work, deliberately not done speculatively.
- **Two behaviours are load-bearing regardless of engine:** never send `think` (read and
  discard `message.thinking`), and never pull a `-cloud` tag — since v0.12.0 those route
  through the same local endpoint to ollama.com, which would falsify «text never leaves the
  machine» at the API the app trusts.

## What would reopen this

- MLX-format tags for the pinned models appearing in the Ollama library — the cheap, intended
  path; reopens `ModelPolicy`, not this ADR.
- A single-chunk TTFT gate failure on hardware the app is expected to serve.
- Ollama breaking the `/api/chat` contract or retiring the GGUF path.
- The measurements aging badly: they were taken on an M5 Pro, where MLX already uses the GPU
  neural accelerators — the gap may differ in either direction on M1–M4, and a report of the
  gate failing on older silicon is a reason to re-measure, not to argue from this entry.

## Where the code is

`Sources/TranslationCore/LLMClient.swift` (the seam), `Sources/OllamaKit/OllamaClient.swift`
(the only conformance), `Sources/TranslationCore/ModelPolicy.swift` (where a future MLX model
pin lands). The evidence: `docs/BASELINE.md`, 2026-08-10 entry; `docs/MEASUREMENTS.md`, the two
rows pointing at it.
