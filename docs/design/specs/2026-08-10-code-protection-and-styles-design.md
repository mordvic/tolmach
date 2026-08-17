# Code protection by construction, and unblocking the rewrite styles — design

Date: 2026-08-10
Status: designed, not implemented

## Status of this document

This design answers the three failures the правка calibration measured
(`docs/reference/OPEN-ITEMS.md` §5) and re-diagnoses two of them: the protected-span corruption is
not a prompt problem, and the style no-ops were largely a flawed experiment plus a real
prompt contradiction. Once the code exists, **the code is the authority on behaviour and
this document is the authority on why**.

## 1. The re-diagnosis (what the evidence actually says)

- **Protected-span corruption (4/4 code-bearing texts).** Every surveyed mature tool
  protects untranslatable content *structurally*, not by instruction: DeepL extracts text
  out of XML and re-inserts it (`tag_handling`, `ignore_tags`); the LanguageTool ecosystem
  strips code blocks from Markdown before checking. Asking a model to echo code
  byte-for-byte and hoping is the outlier approach, and it measurably fails on an 8b
  model. This project already trusts construction over obedience everywhere else —
  «the packing rule is the structure guarantee», `ChunkPlan.assembled(from:)` — and code
  protection is the last place still resting on the model's word.
- **Style no-ops («дружеский», «простой» byte-identical to «как в оригинале», 3/3).**
  Two causes, neither «the model cannot restyle»:
  1. *The probe was flawed.* The single probe text is already informal and already plain
     («Привет! Глянь, пожалуйста…»), so a correct model leaves it unchanged under
     «дружеский» and «простой» — the experiment could not distinguish «style works» from
     «nothing to do». Only «деловой» faced a real register gap, and it worked (3/3).
  2. *The prompt contradicts itself.* `ProofreadingLevel.errorsAndStyle.instruction` ends
     «Preserve the author's meaning, **voice**, and overall structure», and the style line
     appended right after it demands «**Rewrite** in a … register». «Keep the voice» and
     «change the register» are mutually exclusive; a small model at temperature 0.2
     resolves the conflict conservatively — no change — except where the gap is trained
     deep (formal address for «деловой»). None of the four reverted calibration
     candidates touched the conflicting *level* line; they all edited the style lines.
- **What remains genuinely model-shaped:** the minimal-diff violations under «только
  ошибки» (file 02 verb reorder, file 06 «Thanks for»→«Thank you for», 3/3 each). This
  design does not fix those; §5 bounds what is done about them now, and the structured-
  edits investigation (proofreading spec §10.1) remains the designated real fix.

## 1a. Sequencing — where this lands, said out loud

Part A fixes a defect of the **shipped** translation route (§11a's
inside-code-translation limitation), yet this design builds on `worktree-proofreading` —
inside PR #21, whose merge is gated on the правка quality decision. That coupling is
accepted knowingly, not by accident: the shared streaming machinery this design extends
(`streamChunkReply`, the правка route, the calibration corpus and its records) exists
only on that branch, and landing Part A on `main` separately would fork `Translator`
into a guaranteed conflict. The consequence is stated plainly: **if PR #21 stalls, the
translation-route fix stalls with it** — and that trade is the user's to reverse (a
`main`-first split is possible at the cost of the conflict work) rather than a surprise
to discover at merge time.

## 2. Part A — protect code by construction

Two mechanisms, one per protected form. The prompt's protection rules stay as they are —
defence in depth — but the *guarantee* moves into code, on **both** routes (translate and
proofread), because the mechanism lives below the prompt.

### 2.1 Fenced blocks: pass-through chunks

A fenced code block becomes **its own chunk, never merged with prose**, marked
pass-through; the engine copies its bytes straight to `final` and the token stream
**without a model call**. The model never sees fenced code at all — nothing to obey,
nothing to mangle.

- `Chunker`: a `fencedCode` piece no longer merges with neighbours (today it can, across
  one blank line — `containsCodeFence` accumulates through merges). It forms a chunk with
  a new flag (`passthrough: Bool` on `Chunk`; `containsCodeFence` is subsumed and its
  remaining consumers migrate — the load-bearing one is `allowFenceUnwrap:
  !chunk.containsCodeFence` in `Translator`, which becomes unconditional because a
  model-bound chunk can no longer contain a fence). Sentence-splitting already never
  splits fenced code.
- `Translator` (both routes): a pass-through chunk emits `separatorBefore` + its source
  bytes to `onToken` and contributes them verbatim to the assembly; no request is issued;
  `onProgress` still counts it as a completed part. `stats` and `timeToFirstTokenMS`
  keep their model-call meaning: a pass-through emission does **not** stamp the first
  token (it is not a model token; TTFT keeps measuring the model).
- **The nil-TTFT contract must be renegotiated, not inherited.** Today «`timeToFirstTokenMS
  == nil` is the empty-reply signal» holds because every chunk goes to the model —
  `TranslationViewModel` fails a run on that nil (`TranslationViewModel.swift:502`,
  «Модель вернула пустой ответ»). A 100 %-code document under pass-through finishes with
  nil TTFT *and a correct result*, so the old reading would fail a successful run on both
  surfaces. New contract: `TranslationOutcome` gains `modelChunkCount: Int` (chunks that
  were model-bound); the empty-reply ending fires only when `modelChunkCount > 0 &&
  timeToFirstTokenMS == nil`; zero model-bound chunks is a trivially successful run. One
  pinned test per surface-visible half (outcome fields; the view model ending).
- **Every «is this multi-chunk?» decision counts model-bound chunks, not chunks.** The
  document-glossary trigger (`Translator.swift:220`, `chunks.count > 1`) — and with it
  the terms-review suspension — must not start firing because a code block became its own
  chunk: a «code + one paragraph» document has one model-bound chunk and gets no term-list
  call, no review sheet, exactly as today. The acceptance harness classifies files as
  single-chunk (TTFT gated) by the same count and migrates to model-bound counting too.
- The reassembly invariant (`ChunkPlan.assembled(from:)`, byte-lossless) is untouched:
  pass-through chunks go through the same formula with «translated text» = source bytes.
- Consequences stated so nobody reads them as defects: a code-heavy document gains chunk
  boundaries (more, smaller model calls — each extra call pays prompt-prefill overhead),
  and a «run the following:» sentence loses its code block from the model's context
  window. Against that stands the dominant saving: the model stops **regenerating code
  token by token** — on long blocks that decode time dwarfs the added call overhead, so
  the latency story cuts both ways. Whether and which way it moves the acceptance
  numbers is measured, not guessed (§4.1).
- The §11a limitation «the model translates human-readable text inside code» becomes
  structurally impossible for fenced blocks on both routes; §11a is updated to say the
  mechanism removed it (and what remains for inline spans).
- **An all-code selection comes back byte-identical, instantly — stated so nobody reads
  it as a defect.** A user who presses ⌥⌘T on a pure code block gets their own bytes
  under a «перевод» header with no model call. That is the protection rules' own
  long-stated contract (code, including its comments and string literals, is never
  translated) finally enforced rather than hoped for. Consistently, «Ещё вариант» is
  offered only when `modelChunkCount > 0` — re-running an identity is not a variant.

### 2.2 Inline code: positional restore

Inline spans sit inside sentences and cannot be cut out without destroying the grammar
the model needs, so they stay visible — but their content is **restored from the source
after the fact**. The calibration showed the model keeps the backtick delimiters and
edits only the contents (3/3 on every failing file), which is exactly the case positional
restore handles.

- Rule, applied identically to `final` and the stream so they agree byte-for-byte:
  **restore only when the reply's span count equals the source chunk's** — then the N-th
  reply span gets the N-th source span's content, byte-for-byte. On any count mismatch,
  restore **nothing** in that chunk. Rationale: a model in correction mode plausibly
  *adds* backticks around a word, and a greedy N-th↔N-th alignment would then inject
  source content into the wrong span — worse than no restore. The measured failure mode
  is exactly the equal-count case (delimiters kept, content edited, 3/3 on every failing
  file), so the safe rule covers everything actually observed.
- Streaming: the equal-count gate is decidable only when the chunk's reply is complete,
  and emitted bytes cannot be recalled — so **a chunk whose *source* contains inline
  spans is buffered whole**: cleaned, restored, then emitted once. Chunks without source
  spans stream incrementally exactly as today. The buffering is bounded by the chunk
  budget (≤ `maxChunkCharacters` of source, a comparable reply), it is the same
  buffer-until-decidable shape the cleaner already uses for the first line and the fence
  unwrap, and it makes «`final` and the stream agree byte-for-byte» trivially true. The
  UX cost — a code-bearing paragraph appears per-chunk instead of per-token — is
  accepted, stated here so nobody reads it as a streaming regression. Span *parsing*
  stays per-line (`MarkupSkeleton.inlineTokens(in line:)`): a backtick with no close on
  its own line is not a span, in source and reply alike.
- **Restore operates on the cleaned reply**, downstream of `ResponseCleaner`'s decisions
  (preamble strip, whole-answer fence unwrap) in both `final` and the stream — cleaning
  shifts bytes, and a restore that ran before it would misplace every span after the
  shift. The order is: clean, then restore, then emit; one order, both paths.
- The span definition is **`MarkupSkeleton`'s** (`inlineTokens`) — shared, not a new
  regex, so restore and diff cannot disagree about what an inline span is. Whatever that
  definition says about double-backtick spans (`` `code with a ` inside` `` exists in the
  wild) and about odd backtick parity **in the source itself** («don't use ` alone»
  shifts span boundaries before the model is even involved) is what restore does —
  pinned by tests that go through the shared definition, not a restatement of it.
- A span-count mismatch is already visible through `MarkupSkeleton.diff` (inline tokens
  are part of the skeleton); no new warning surface.

## 3. Part B — unblock the styles

### 3.1 Resolve the voice contradiction

`errorsAndStyle` gets two wordings, chosen by whether a style instruction accompanies it
(`PromptBuilder` already knows: `level.allowsRewriteStyle && style.instruction != nil`):

- Style «как в оригинале» (no style line): today's wording, unchanged — «Preserve the
  author's meaning, voice, and overall structure.»
- A named style follows: «Preserve the author's meaning and overall structure.» — the
  style owns the voice, the level stops defending it.

`errorsOnly` is untouched. Shape: `ProofreadingLevel.instruction(styleGovernsVoice:)`;
the parameterless `instruction` remains for `errorsOnly` and the no-style case, so
existing call sites and pins keep meaning what they said.

### 3.2 Re-probe with a matrix, not one text

Each style is probed on a text with a real register gap to close, 3 runs each, current
runner:

| Style | Probe text | Gap it must close |
|---|---|---|
| «дружеский» | new `12-style-probe-formal-ru.txt` — a stiff, formal notice | formal → warm |
| «деловой» | `11-style-probe-ru.txt` (informal, existing) | informal → formal (re-confirm) |
| «профессиональный» | `11-style-probe-ru.txt` | informal → workplace register |
| «простой и ясный» | `02-ru-bureau.txt` (bureaucratese, existing) | канцелярит → plain |

Plus one EN spot-check: «дружеский» on `07-en-bureau.txt` (formal EN → warm), so the
conclusion is not silently RU-only.

The matrix runs twice: once on the current prompt (does the matrix alone change the
baseline conclusions?) and once with §3.1's fix. A style that still does not move under
the correct probe *and* the resolved contradiction is then honestly a model limitation.

## 4. Measurement protocol

«Improved» without a number does not count.

### 4.1 Translation (Part A touches this route)

`swift run acceptance` before Part A lands is already recorded (BASELINE 2026-08-10
entries); run again after. Gates: adherence ≥ 80 %, single-chunk TTFT < 1000 ms, markup
diffs — with one expected *improvement*: the known-limitation «translated commit message
inside a code block» should disappear. Its disappearance is recorded in the BASELINE
entry; its §11a entry is rewritten per §2.1.

**The after-entry is a re-basing, and must say so.** Part A changes the chunking of every
code-bearing corpus file, so adherence is computed over a different chunk set and files
may migrate between the single-chunk and multi-chunk classes (`snippet-en.md` is the
obvious candidate to leave the TTFT-gated class — under model-bound counting per §2.1 it
may stop being «multi-chunk» at all). Percent-to-percent comparison against the older
entries is therefore qualitative (the 80 % floor still binds absolutely); the entry lists
which files changed class, so the next reader does not misread the shift as a prompt
regression.

### 4.2 Правка

The scratchpad corpus and runner from the calibration are reused:

- Code-bearing texts (03, 04, 08, 09): after Part A, `codeIntact` must read `true` 3/3 on
  all four — that is the headline number this design exists for.
- The style matrix per §3.2.
- The «только ошибки» texts re-run to confirm no regression from the prompt change
  (§3.1 does not touch `errorsOnly`, so any change is noise to investigate).
- Results recorded in `docs/reference/OPEN-ITEMS.md` §5 as a dated follow-up subsection; the §1
  escalation entry is closed with a pointer to it (the protectionRules decision the
  escalation asked for is: **moot for fenced, restored-by-code for inline**).

### 4.3 Model benchmark (bounded)

The same corpus and runner, `options.model` varied over locally installed candidates —
at least `gpt-oss:20b` (the policy's background model), optionally `qwen3:8b` /
`gemma4:26b` — one matrix + errorsOnly pass each, 3 runs per text. Purpose: facts for a
future model-policy decision about правка, **not** a policy change now. Warm TTFT is
noted per model (the interactive path's < 1 s bound and the one-model-in-memory
`keep_alive` economics both constrain any future switch). `gpt-oss:20b` is a
reasoning-prone model and `OllamaKit` discards `message.thinking` by standing rule — its
TTFT figures will carry that cost; the record says so, so the numbers do not surprise.
Recorded in the same OPEN-ITEMS subsection.

## 5. Deliberately not done here

- **Structured edits / change highlighting** (proofreading spec §10.1) — the real fix
  for the remaining minimal-diff violations; a separate investigation.
- **Any model-policy change** — §4.3 gathers facts; the decision is the user's.
- **Prompt-wording changes on the translation route** — the protection rules' wording
  stays; only the guarantee moves.
- **Masking/placeholder schemes** (DeepL-style `<x>` tags) — strictly weaker than
  pass-through for fenced code (the model can still mangle a placeholder) and
  unnecessary for inline spans given positional restore.

## 6. Testing

Offline, Swift Testing, `FakeLLMClient`, the standing rules and `docs/reference/TESTING.md` shapes
(assembly pinned via `ChunkPlan.assembled(from:)`, never a restated formula).

- **Chunker**: a fenced block never merges with prose in either direction; it forms a
  pass-through chunk; prose-only merging across one blank line is byte-identical to
  today (the existing pins must keep passing untouched); the whitespace-only separator
  assertion holds around the new boundaries.
- **Translator, both routes**: a pass-through chunk issues no model call — pinned in the
  strong form: **no message ever sent to the fake client contains the fenced block's
  bytes** (a call-count pin alone survives the defect «called, with the wrong chunk» —
  `docs/reference/TESTING.md`'s shape); its bytes reach `final` and the stream verbatim; `final` equals
  `plan.assembled(from:)`; the stream reconstructs `final` byte-for-byte; an all-code
  document yields `timeToFirstTokenMS == nil`, empty `stats`, `modelChunkCount == 0` —
  and the **view model treats it as success, not «пустой ответ»** (the renegotiated
  contract, pinned on both halves); a document glossary is never attempted below two
  model-bound chunks; cancellation before and after pass-through emission still surfaces
  as `CancellationError`.
- **Inline restore**: an altered span is restored in `final` and in the stream when
  counts match; **any count mismatch restores nothing in that chunk** (a reply that adds
  a span must not shift source content into the wrong place — pinned with an added-span
  case); the hold flushes at end of line, and a lone backtick is not a span; restore uses
  `MarkupSkeleton`'s span definition, including its double-backtick behaviour (a span the
  skeleton would not count is not restored).
- **Prompt**: `errorsAndStyle` wording with and without «voice» switches exactly on a
  non-nil style instruction; `errorsOnly` and the translation prompt byte-unchanged.
- **App layer**: the «Ещё вариант» condition additionally requires `modelChunkCount > 0`
  (pinned); everything else — `RussianCopy`, panes, panel chrome — untouched, and nothing
  else user-visible changes shape.

## 7. Documentation updates shipped with the code

- `CLAUDE.md`: the pipeline section — pass-through chunks and inline restore are new
  load-bearing facts (the model never sees fenced code; inline content is restored
  positionally; both routes).
- `docs/design/specs/2026-07-24-local-translator-design.md` §11a: the
  inside-code-translation entry rewritten per §2.1/§4.1.
- `docs/reference/OPEN-ITEMS.md`: §1 escalation closed, §5 follow-up subsection with all §4
  results.
- `docs/reference/BASELINE.md`: the after-Part-A acceptance entry.
