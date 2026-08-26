# 2026-08-26 — xhigh code review: findings ledger

Whole-tree review at `3af1f37` (main, clean tree), requested focus: correctness errors,
security, memory leaks. Method: five finder angles (core pipeline, invariant audit,
cross-file tracing, Swift concurrency/platform pitfalls, engine-wrapper correctness) →
cross-angle dedup → twelve adversarial verifiers. **Every finding below is CONFIRMED**:
mechanism checked against the code, several reproduced by probes compiled from the repo's
own sources (Swift 6 mode), two behaviours measured live against Ollama 0.32.14. Ranked
most-severe first within each section. Fix shapes are suggestions, not designs.

Issues live in GitHub (`mordvic/tolmach`, see `docs/agents/issue-tracker.md`); §1 entries
are written to be filed nearly verbatim.

---

## 1. Ranked findings (issue drafts)

### 1. HTTP redirects can send the user's text off-box

**Where:** `Sources/OllamaKit/OllamaClient.swift:90` (same at `Sources/LMStudioKit/LMStudioClient.swift:65`) · **Category:** security

Both engine `URLSession`s are built with no delegate, so HTTP redirects are followed by
default. A `307/308` from a process squatting the loopback port re-POSTs the request body
to the redirect target — defeating «text never leaves the machine», which the code
otherwise enforces structurally (ADR 0009 never mentions redirects).

*Scenario:* Ollama is not running; any unprivileged process binds `127.0.0.1:11434` and
answers every request `307 Location: https://evil/collect`. The user presses the hotkey;
`URLSession` transparently re-POSTs the full chat body (selection + glossary + prompt) to
the remote host — no error, no UI trace.

*Fix shape:* a session delegate that refuses redirects (or allows only same-origin
loopback); note the decision in ADR 0009.

### 2. Mid-stream Ollama error is swallowed — truncated translation returned as success

**Where:** `Sources/OllamaKit/OllamaStreamParser.swift:17` + `Sources/OllamaKit/OllamaClient.swift:152` · **Category:** correctness

A mid-stream NDJSON `{"error": "…"}` line has no `message` and no `done`, so `parse`
returns `[]` and the line is dropped; `chat` then reaches end-of-stream and calls
`continuation.finish()` without checking that a `.done` frame ever arrived. This is the
exact «partial translation returned as a success» trap the LM Studio reader deliberately
throws for (`LMStudioEventReader.swift:13–14`) and that CLAUDE.md names for the other
engine.

*Scenario:* the Ollama runner dies mid-generation (GPU/CPU OOM — plausible with
`translategemma:27b` under memory pressure) and writes `{"error":…}` into the already-200
stream. TTFT is non-nil (tokens arrived), so the empty-reply guards pass; the window shows
a truncated document as «Готово», and «Файлы» writes the truncated file to disk as
`.finished`.

*Fix shape:* an `error`-key branch in the parser that throws, plus «stream ended without
`.done`» treated as an error in `chat`. The offline suite cannot pin this today —
`FakeLLMClient` can neither emit tokens-then-error nor end a stream without `.done`
(see §2 item 10's note on the fake).

### 3. Quadratic LCS matrix in the markup diff — up to ~80 GB on a 2 MB file

**Where:** `Sources/TranslationCore/MarkupSkeleton.swift:144` · **Category:** memory

`diff()` allocates a dense `(want+1)×(got+1)` matrix of `Int` — quadratic in token count,
with no equal-sequence fast path, no common prefix/suffix trimming, and no token ceiling;
the only guard (line 145) sits *after* the allocation. The DP loop writes every row, so
CoW does not save it: full quadratic memory is realized.

*Scenario:* the queue accepts 2 MB files (`QueueDrop.maximumBytes`); a fully-bulleted 2 MB
changelog emits ~80–100k tokens per side → ~51–80 GB matrix plus ~10¹⁰ DP iterations,
past the 48 GB machine. The app swap-deaths or is jetsammed at the very end of an
otherwise successful ~2300-call run — on both `translate` and `proofread` routes, and a
byte-perfect translation pays the same cost. Even the window's 256 KB ceiling reaches
~1.3 GB transient.

*Fix shape:* equal-sequence early-out, prefix/suffix trim, then Myers/Hirschberg
(linear-space) or a token ceiling above which the diff degrades to counts-only.

### 4. Force-unwrapped URL from the unvalidated stored port — crash loop at launch

**Where:** `Sources/TranslatorApp/EngineRouter.swift:211` (both branches; also `Sources/LMStudioKit/LMStudioClient.swift:20`) · **Category:** crash

`URL(string: "http://127.0.0.1:\(port)")!` force-unwraps a URL built from the stored
`enginePort`, which nothing clamps (contrast `contentFontSize`). A negative port makes
`URL(string:)` return nil → trap.

*Scenario:* the user types `-1` into «Порт» (the `.number` TextField parses negatives —
probe-confirmed) or `defaults write … enginePort -int -1`. The value persists;
`warmUpOnLaunch` (default true) routes through the pool at every start, so the app crashes
at every launch until the default is hand-edited — a crash loop that survives restart.

*Fix shape:* clamp on write and on read (1…65535), fall back to the engine default.

### 5. Inline-code restore splices wrong source bytes on lone-CR chunks

**Where:** `Sources/TranslationCore/InlineCodeRestorer.swift:41` (+ `sourceSpanCount`, `Sources/TranslationCore/Translator.swift:593`) · **Category:** correctness

`spans(of:)` splits lines on `"\n"` only, unlike `LineScanner`, so on chunk text whose
interior break is a lone CR (or NEL/U+2028) backticks pair *across* the line break into a
phantom span. If the model's LF reply happens to match the count, the equal-count gate
passes and `restore()` splices the wrong source bytes — line terminator included — over a
real code span. Reproduced end-to-end against the repo's own sources (the real `Chunker`
legitimately produces such a chunk).

*Scenario:* source ``…5` tall\r`code`…`` flat-splits into one phantom span `" tall\r"`; the
model normalises `\r`→`\n` (which the rest of the pipeline *expects*), reply span count
1 == source 1, and the real `` `code` `` span is overwritten with `" tall\r"` — code
destroyed, a CR injected into `final`. `MarkupSkeleton` (LineScanner-based) counts 0
spans for the same bytes, so the layers disagree.

*Fix shape:* share `LineScanner`'s line discipline in `spans(of:)` and `sourceSpanCount`.

### 6. All-passthrough file is marked failed by the queue and never written

**Where:** `Sources/TranslatorApp/FileQueueModel.swift:706` · **Category:** correctness

The queue's empty-reply guard treats `timeToFirstTokenMS == nil` as failure without the
`modelChunkCount == 0` check that `TranslationOutcome`'s doc comment declares mandatory —
and that `TranslationViewModel.execute` (`TranslationViewModel.swift:544`) already
performs.

*Scenario:* drop a `.md` whose whole content is one fenced code block into «Файлы».
`Chunker` yields only passthrough chunks, no model call is made, TTFT is nil by design,
`final` is byte-correct — yet the job lands `.failed("Модель вернула пустой ответ.")`,
the file is never written (even with «Рядом с исходником» on), and every retry fails
identically, while the same document succeeds in «Текст» mode.

*Fix shape:* `guard outcome.modelChunkCount > 0, outcome.timeToFirstTokenMS == nil else …`
— same predicate as the window.

### 7. Symlink bypasses the 256 KB drop ceiling — unbounded load into memory

**Where:** `Sources/TranslatorApp/DroppedDocument.swift:49` · **Category:** memory

The size gate checks `attributesOfItem(atPath:)`, which reports on the symlink itself,
not its target; `Data(contentsOf:)` then loads the full target, and there is no post-read
`data.count` re-check. `QueueDrop.swift:92` fixes exactly this with
`resolvingSymlinksInPath()` — `DroppedDocument` got neither half, and has no symlink test.

*Scenario:* a symlink named `notes.md` pointing at a multi-GB file is dropped on the
source pane. Probe: `attributesOfItem` reported 102 bytes for the link while
`Data(contentsOf:)` loaded the full target — the multi-GB load hangs or jetsams the app,
against the code's own comment «an enormous file is refused without ever being loaded».

*Fix shape:* resolve symlinks before the attribute check *and* re-check `data.count`
after the read, as `QueueDrop` does.

### 8. Incremental streaming path keeps trailing newlines the buffered path trims

**Where:** `Sources/TranslationCore/Translator.swift:668` · **Category:** correctness

The incremental path returns `collected` untrimmed, so a chunk reply ending in newline(s)
survives into `final` — unlike the identical reply on any buffered path, which
`ResponseCleaner.clean` trims. `MarkupSkeleton.diff`'s own comment assumes the trim
happened.

*Scenario:* multi-chunk document; a non-final chunk's reply is multi-line with no
preamble (goes incremental) and ends `"…текст.\n"`. Probe: `final` gains a spurious extra
blank line (`reply + "\n" + "\n\n"` separator) and the markup diff reports a phantom
«added paragraphBreak» on a faithful translation. Output bytes depend on token timing.

### 9. A leading newline defeats both preamble stripping and the fence unwrap

**Where:** `Sources/TranslationCore/Translator.swift:631` (fence check at `:626`) · **Category:** correctness

The streaming first-line decision runs on the *untrimmed* buffer (`clean()` trims first),
so a reply beginning `"\n"` yields `firstLine == ""` — not a preamble — and the whole
buffer, preamble line included, streams as content. And `"\n```"` never matches the fence
check, because line 626 trims only `.whitespaces`, which excludes newlines, so the
whole-answer unwrap is skipped.

*Scenario:* probe: `"\nHere is the translation:\nПривет…"` → `final ==
"\nHere is the translation:\nПривет, мир."` — preamble leaked. `"\n```\n…\n```"` ships
literal fence markers into the translation plus a phantom `codeBlock` diff. The buffered
`clean()` path handles both correctly. The first emit can also be whitespace-only,
stamping `timeToFirstTokenMS` on invisible content.

### 10. Cancelled chunk's partial buffer is emitted as a completed chunk

**Where:** `Sources/TranslationCore/Translator.swift:687` · **Category:** correctness

There is no `Task.checkCancellation()` between the stream loop and `emit(restored)`.
Cancellation silently *finishes* the stream (the project's own rule), so on a buffered
path the partial buffer is cleaned, inline-restored and emitted to `onToken` as if the
chunk had completed — only after which the caller's check throws.

*Scenario:* probe: single-line reply at 15 ms/token, cancelled at ~120 ms — the task threw
`CancellationError` (rule kept) **but** `onToken` received `"Привет,"` in one call, after
cancellation landed. On the `bufferedToEnd` inline path a coincidentally equal span count
can even splice source bytes into a truncated reply. The existing test
(`cancellingDuringThePerChunkLoopThrowsInsteadOfReturningATruncatedDocument`) passes only
because its cancel lands before the first token — the comment «no chunk had finished, so
onToken never fired» is true of the fixture, not of the mechanism.

*Fix shape:* `try Task.checkCancellation()` before the post-loop emit.

### 11. Unbounded line buffer on the 200 stream — loopback memory DoS

**Where:** `Sources/OllamaKit/OllamaClient.swift:152` (LM Studio: `Sources/LMStudioKit/LMStudioClient.swift:130/162`) · **Category:** security

The chat stream iterates `bytes.lines` (`AsyncLineSequence`), which buffers a whole line
unboundedly before yielding; the 64 KB bound applies only to non-200 error bodies.

*Scenario:* a rogue or wedged process on the configured loopback port answers 200 and
streams newline-free bytes. Each arriving byte resets the inter-data timeout (documented
in the code's own comment), so it never fires; the buffer grows to memory exhaustion at
loopback throughput, long before the 900 s resource timeout — a hung translation plus
memory DoS from one malformed response.

*Fix shape:* a byte ceiling per line (or per stream) on the success path too.

### 12. Settled `task` handle pins the whole previous outcome — «nil» release is illusory

**Where:** `Sources/TranslatorApp/TranslationViewModel.swift:532` (same shape: `Sources/TranslatorApp/FileQueueModel.swift:689`, `current`) · **Category:** memory-leak

`task = run` is never nilled after a run settles, and a finished `Task` retains its
result — so each model permanently pins the previous run's entire `TranslationOutcome`
(`final` + `chunks` + `translatedChunks`), even on paths that deliberately set
`outcome = nil`.

*Scenario:* one hotkey translation of a large selection leaves ~2 document copies alive
via the retained handle until the next press — indefinitely for a menu-bar app idle for
days. `swapLanguages()` sets `outcome = nil` but the Task keeps it reachable. The queue's
`current` pins the last file's ~3 copies that the trimmed `JobResult` was explicitly
designed to avoid.

*Fix shape:* nil the handle where the run settles (both models).

### 13. ⌘C-fallback poll misattributes a concurrent pasteboard write, then destroys it

**Where:** `Sources/TextCapture/SelectionReader.swift:196` · **Category:** correctness

The synthetic-⌘C poll accepts *any* pasteboard change (`changeCount` differs + non-nil
string) as the selection, and the unconditional deferred restore then clears and rewrites
the board without re-checking `changeCount` — a third-party write in the ≤0.5 s window is
both returned as «the selection» and then wiped.

*Scenario:* while the poll runs (up to 500 ms, sampled every 10 ms — fully exposed when
the target app ignores ⌘C), Universal Clipboard delivers a copy from the user's iPhone.
That content is sent to the model and shown in the panel as the translation source; the
restore then overwrites it with the stale snapshot, so the user's next ⌘V pastes old
content. ADR 0005 documents two adjacent failure modes; this concurrent-write case is
recorded nowhere.

### 14. CRLF replies: preamble never stripped; fence unwrap fabricates blank lines

**Where:** `Sources/TranslationCore/ResponseCleaner.swift:26` and `:45` (streaming twin at `Translator.swift:631`) · **Category:** correctness

Two different line disciplines inside `clean()`, neither matching `LineScanner` — the
type built precisely so line disciplines could not drift. Preamble detection uses
`firstIndex(of: "\n")`, a grapheme search that never matches the single `Character`
`"\r\n"`; the fence unwrap splits on `CharacterSet.newlines` (scalars — `"\r\n"` becomes
two breaks with an empty line between) and rejoins with `"\n"`.

*Scenario:* probes: `"Here is the translation:\r\nText"` → `firstIndex` nil → preamble
ships in `final`; `` "```\r\na\r\nb\r\n```" `` unwraps to `"a\n\nb"` — a paragraph break
that existed nowhere, plus a phantom «added» diff. Nothing upstream normalises (`grep` of
both clients finds no `\r` handling), and `ResponseCleanerTests` has no CRLF fixture.
*Trigger caveat:* requires the model to emit `\r\n` in its own reply — mechanism proven,
in-the-wild frequency unmeasured (CLAUDE.md itself records that models tend to normalise
to `\n`); a hexdump of a raw stream from a CRLF document run would settle it.

### 15. Failed `/api/pull` reads as a silent success

**Where:** `Sources/OllamaKit/OllamaClient.swift:192` · **Category:** correctness

`PullProgressParser.parse` requires a `status` key, so Ollama's in-stream `{"error":…}`
line on a 200 pull response is dropped and `pull` finishes without throwing — unlike
`LMStudioDownload.swift:78`, which throws on `status == "failed"`.

*Scenario:* measured live against Ollama 0.32.14: `POST /api/pull` for a nonexistent
model answers HTTP 200, then streams `{"error":"pull model manifest: file does not
exist"}`. The parser drops the line, `ModelsViewModel.pull` clears the bar, sets no
error, reloads — the failed download reads as a success and the model simply isn't there.

*Fix shape:* an `error`-key branch that throws, mirroring finding 2.

---

## 2. Confirmed, below the cap

Also CONFIRMED by verifiers; outranked by everything above, recorded so they are not lost.

1. **Torn engine/port read mid-run** — `Sources/TranslatorApp/EngineRouter.swift:87`.
   Every router method reads the engine key once to pick the branch and again inside
   `AppSettings.enginePort(in:)` to pick the port key, and re-reads both per chunk while
   `ChatOptions` were resolved once at run start — a «Движок»/port flip mid-run sends one
   engine's protocol (or model tag) to the other engine's server; the current file fails
   mid-document, the rest of the queue follows, and a junk client is cached in the pool.
   Nothing locks the radio during a run. *Fix shape:* read the engine once per call and
   derive the port from that value; freeze both for the duration of a run.
2. **⌘C fallback exposes the selection beyond the app** — `Sources/TextCapture/SelectionReader.swift:191`.
   The synthetic-⌘C path necessarily places the selection on the general pasteboard,
   where clipboard-history managers and Universal Clipboard capture it — an inherent cost
   of the fallback, but undocumented anywhere («text never leaves the machine» has a
   caveat nobody wrote down). *Fix shape:* document it (ADR 0005 §), and consider
   `org.nspasteboard.ConcealedType` to opt out of well-behaved history managers.
3. **`GlossaryStore.save()` TOCTOU + symlink blindness** — `Sources/TranslatorApp/GlossaryStore.swift:113`.
   The stamp check and the atomic write are not one transaction (a hand edit landing
   between them is overwritten), the atomic replace turns a symlinked `glossary.json`
   into a regular file, and the stamp guard reads the link, not the target.
4. **Stale-write race in `EngineStatusModel.refresh`** — `Sources/TranslatorApp/EngineStatusModel.swift:63`.
   No re-entrancy or generation guard; a slow probe (10 s timeout against a hung server)
   overwrites the answer of a fresher one, and with no polling timer the wrong «не
   отвечает» (or the inverse — healthy status for a dead engine) persists until the next
   manual trigger. Reachable from at least five overlapping trigger points. *Fix shape:*
   a generation counter checked before each write.
5. **Server-supplied error text logged `.public`, uncapped** — e.g.
   `Sources/TranslatorApp/TranslationViewModel.swift:413` (the `documentGlossaryFailure`
   entry). Error descriptions are `.public` by design (diagnosability), but an LM Studio
   mid-stream error message is a server-controlled string of unbounded length flowing
   into the unified log. *Fix shape:* cap the interpolated length; prefer domain+code for
   server-supplied text. (The original log-injection candidate had the engines inverted —
   Ollama's chat-path message is a constant.)
6. **`NSRegularExpression`/`NSDataDetector` built per line, uncached** —
   `Sources/TranslationCore/MarkupSkeleton.swift:213/222/275`. Three per-call
   constructions on essentially every non-blank line, twice per run (source +
   translation), on the unconditional tail of both routes — ~2×100k regex + ~2×100k
   detector constructions for a 2 MB run. *Fix shape:* `static let`.
7. **`GlossaryVerifier` re-tags the whole translation per entry** —
   `Sources/TranslationCore/GlossaryVerifier.swift:24`. Each `LemmaMatcher.matches` call
   re-runs a full `NLTagger` lemma pass over the entire translation → O(entries ×
   document) after the last token has streamed; a 2 MB file with 20 terms pays 20+ full
   passes while the job sits in `.running`. *Fix shape:* tag the translation once, match
   all needles against the one pass.
8. **`LanguageDetector.detect` on the main actor for pasted text** —
   `Sources/TranslatorApp/TranslationViewModel.swift:335`. A 256 KB paste runs a full
   scan on the UI thread (the queue and the hotkey path both moved this off-main; the
   window's paste path did not).
9. **`ClientPool` never evicts** — one client per engine per port for the life of the
   process. Documented trade; bounded by hand-typed ports. Note only, no action.
10. **Both-ends trim of a partial buffer after a stripped preamble** —
    `Sources/TranslationCore/Translator.swift:642`. CONFIRMED by the streaming verifier
    (probe: events `["Here is the translation:\nПривет ", "мир"]` → `final ==
    "Приветмир"`, vs `"Привет мир"` from the buffered path) but absent from the
    consolidated report — recorded here for completeness. Trigger needs a single stream
    event spanning the preamble's newline *and* ending in whitespace with more content
    following: impossible with the character-per-token `FakeLLMClient`, rare with BPE
    deltas, legal per the `LLMClient` contract (a batching server or proxy delivers it).
    *Fix shape:* trim the leading edge only at the mid-stream decision point.

---

## 3. Documentation drift (CONFIRMED against code and git history)

1. **«The panel … is not `.titled`» — false.** `CLAUDE.md` vs
   `Sources/TranslatorApp/TranslationPanel.swift:47`: `.titled` was deliberately
   reinstated in `a57efa1` (2026-07-31, one day after the CLAUDE.md sentence), because
   `.resizable` alone never worked. The stale `PanelController.init` comment at
   `TranslationPanel.swift:313` («the title bar is gone with `.titled`») says the same
   wrong thing and is contradicted by the `safeAreaRegions` comment ~15 lines below it.
   Danger: «restoring» the documented invariant silently kills hand-resize and flips
   `canBecomeKey` — the exact defect `a57efa1` fixed, with documentation on its side.
2. **`ResponseCleaner.clean`'s `allowFenceUnwrap` contract describes a caller gate that
   no longer exists.** `Sources/TranslationCore/ResponseCleaner.swift:19–21` claims
   «`Translator` always passes `!chunk.passthrough`»; since the 2026-08-18 marker removal
   `Translator.streamChunkReply` passes the constant `true` (`Translator.swift:680`).
   Safe today only because passthrough chunks never reach `streamChunkReply`; a future
   change letting a fenced chunk become model-bound would trust the stated contract and
   strip a real code block's fences.
3. **«Loopback in two places» is actually four.** `CLAUDE.md` / ADR 0009 vs
   `Sources/OllamaKit/OllamaClient.swift:25` (`defaultBaseURL`, used by `translate-cli`
   and `acceptance`) and `Sources/OllamaKit/OllamaError.swift:11` (a hard-coded
   «127.0.0.1:11434» in an error string — which also misdiagnoses any client on a
   non-default port). The loopback-only invariant itself still holds; the «checkable by
   reading two lines» promise does not.
4. **`enginePort` is also engine-scoped.** `Sources/TranslatorApp/AppSettings.swift:100`
   and `:117` suffix the key per engine, contradicting CLAUDE.md's «three settings …
   gain a `.lmStudio` suffix … and nothing else» and the implication that `enginePort`
   is one key. Tooling written from the doc reads/writes the wrong key.
5. **`Language.from`'s `default: nil`** (`Sources/TranslationCore/Language.swift:31`) —
   flagged by the review's consolidation pass as a latent gap (an NL tag outside the
   mapped set silently reads as «undetected»). Carried by name only; confirm the intended
   behaviour before filing.
6. *(minor)* **«Шрифт текста reaches three `Text`s» miscounts.** The font reaches four
   surfaces — panel visible `Text`, panel hidden reservation `Text`, `TranslationPane`'s
   `Text`, and `SourceEditor`'s hosted `NSTextView` (not a `Text` at all) — and the
   invisible reservation (the actually load-bearing pairing) is not among the listed
   three. Code and ADR 0008 are internally consistent; only CLAUDE.md's sentence is off.

---

## 4. Verified clean

Checked deliberately and found sound — so the next review does not re-litigate them:
cancellation checks before/after the term-list call, at the top of every chunk loop and
after every `streamChunkReply`, both routes (with the `Translator.swift:687` exception in
§1.10); the review point outside the swallowing `catch`, cancellation rethrown inside it;
`ChunkPlan.assembled(from:)` single-sourced, separators asserted whitespace-only;
`onToken`/`final` agreement by construction; `AppSettings.chatOptions(model:)` as the
only `ChatOptions` construction in the app; no user-derived text in any log call site;
`ThinkRequest` with no «on» case, `ModelPolicy` table order matching its comment;
`ReasoningChoice` only ever sending a member of `allowed_options` (no key on absence or
failure); `store: false` on every LM Studio chat body, `keepAlive`/`ttl` never on that
wire, `WarmUpPlan` warming one model there; LM Studio mid-stream error frames thrown
before `chat.end`, `tokens_per_second` inversion zero-guarded; ns→ms at the Ollama client
boundary; two-pass hotkey release/register with remembered restores, panel operation
assigned before `afterCapture()`; `PrimaryAction.forMode` read by the toolbar button and
all shortcuts; `GlossaryStore` fail-closed load + stamp gating (modulo §2.3);
`OutputNaming`/`TranslatedFileWriter` never overwriting; glossary column recomputed on
appear/reload only; per-engine key suffixes with `batchModel` under `"backgroundModel"`;
`resolvedProofreadModel` at all three правка sites; `ClientPool` an actor keyed per
engine per port; `ModelCatalogue` in-flight request sharing; acceptance's three-way
`modelChunkCount` split; `translate-cli --think` refused on `--engine lmstudio`. Classic
leak sweep (Carbon handler lifetimes, observer removal, `@unchecked Sendable` boxes,
retain cycles): nothing beyond the accepted `HotkeyManager` deinit race already recorded
in `docs/reference/OPEN-ITEMS.md` §3.

---

*Disposition appended the same day — see §5 before trusting any «fix shape» above.*

*Produced 2026-08-26 by `/code-review xhigh` (five finder angles, twelve adversarial
verifiers). Probes were compiled from the repo's own sources into the session scratchpad
and touched nothing in the tree; live measurements ran against the local Ollama 0.32.14
(a pull of a nonexistent model). The tree at review time was clean at `3af1f37`.*

---

## 5. Disposition (2026-08-26, same day)

Every §1 finding was re-verified against the code independently of this document before being
fixed. All 31 were confirmed. Four fix shapes stated above are **wrong** and were corrected in
the work; they are listed here because this file is what the next reader will find.

| Where | What this document said | What is true |
|---|---|---|
| §1.6 | `guard outcome.modelChunkCount > 0, outcome.timeToFirstTokenMS == nil else …` | `guard A, B else` fires on `!(A && B)` and would fail a *normal* run. The window's spelling is right; the rule now lives once, on `TranslationOutcome.isEmptyReply`. |
| §1.8 | «the incremental path returns `collected` untrimmed» — implying a trim at the end | Bytes handed to `onToken` cannot be recalled; trimming `collected` breaks `theStreamReconstructsExactlyWhatFinalContains`. Only **held-back** edge whitespace works. |
| §1.3 | «degrades to counts-only» | An empty `[MarkupDiff]` means «structure preserved», and `MarkupDiff(expected: nil, actual: nil)` renders as «неизвестное расхождение» — a defect in the translation. The refusal needed its own signal, `markupNotCompared`. |
| §1.13 | reads as though the misattribution could be fixed | It cannot: `NSPasteboard` has no owner. Two halves were fixable — not destroying a newer clipboard, and refusing `com.apple.is-remote-clipboard` — and the residual is recorded in ADR 0005. |

### Two claims made while fixing, and then measured instead

- **«Prefix/suffix trimming is output-preserving.»** Written as a comment, then checked against
  the untrimmed algorithm over 4000 generated pairs: **427 differ**. Same count and same
  multiset every time, different order. The comment and a test now say that.
- **§3.5, `Language.from`'s `default: nil`.** Carried by name only, as this document says. It is
  the **design**, not a gap: the app names nine languages and «undetected» is a state the whole
  pipeline handles deliberately. Recorded at the site so the next review does not re-raise it.
  No issue filed.

### Three fixtures that passed under the defect they named

Each looked correct, and each is `docs/reference/TESTING.md`'s first rule failing out loud:

1. The `DroppedDocument` symlink test asserted only «refused», which the post-read `data.count`
   check satisfied one step later. Fixed by splitting `plausible(_:)` out, as `QueueDrop` had.
2. The `EngineStatusModel` staleness test gave both refreshes the same answer; rewritten, it
   keyed the answer on a counter both had advanced. Only «the stale call fails» distinguishes
   them — and the success-path guard needed a second, mirrored test.
3. The cancel-during-detection test used a short source, so the window closed in microseconds.
   At 150 KB it is 8/8 green and 5/5 red under the mutation.

A fourth test was **deleted** rather than kept: `DroppedDocument`'s post-read re-check is
refused by `plausible` one step earlier in every case a test can construct, so nothing could
pin it. The code says so where the line is.

### What was fixed where

| Finding | PR |
|---|---|
| §1.4, §1.6, §1.7, §1.12, §2.5, §3.3 | #59 |
| §1.2, §1.11, §1.15, §2.1 | #60 |
| §1.5, §1.14, §1.9 (fence half), §3.2 | #62 |
| §1.8, §1.9 (trim half), §1.10, §2.10 | #63 |
| §1.3, §2.6, §2.7, §2.8 | #64 |
| §1.1, §1.13, §2.2, §2.3, §2.4 | #65 |
| §3 (all six) | #66 |

§2.9 (`ClientPool` never evicts) is a documented trade and was left alone, as this document
recommends.

### One finding this review did not have

`RussianCopy.lmStudioRefusal` is never called from `Sources/` — LM Studio's refusals reach the
user in English while the Russian copy written for them is dead. Filed as its own issue; §4's
«verified clean» list does not cover it either way.
