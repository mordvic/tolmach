# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

«Толмач» (`LocalTranslator`) — a macOS translator running entirely on local LLMs, through
**Ollama** (`127.0.0.1:11434`) or **LM Studio** (`127.0.0.1:1234`), chosen in «Модели» →
«Движок» and defaulting to Ollama. Text never leaves the machine, and that is a property of the
code rather than of a setting: only the port is configurable, the host is loopback in two places
and nowhere else (`docs/adr/0009`). Three surfaces: a global
hotkey that translates the current selection into a floating panel, a main window, and — in
that window's «Файлы» mode — a queue of files translated one after another and written back
to disk.

## Commands

```bash
swift build                       # build everything
swift build --build-tests         # must stay at zero warnings — this is a standing rule
swift test                        # the whole suite, offline (fake LLMClient), ~2 s
swift test --filter someTestName  # one test, by name (Swift Testing function names)
swift test --filter TranslationCoreTests   # one test target

./Scripts/make-app-bundle.sh      # assemble build/LocalTranslator.app (debug); pass "release" for release
swift Scripts/make-icon.swift build/AppIcon.icns   # redraw the icon; make-app-bundle.sh does this itself
swift Scripts/colour-contrast.swift               # re-measure the status colours against both appearances
swiftc -O -o /tmp/ac Scripts/accent-contrast.swift && /tmp/ac   # white on every accent macOS offers
swiftc -O -o /tmp/wt Scripts/window-title.swift && /tmp/wt   # why the window title needs re-asserting
swiftc -O -o /tmp/tf Scripts/toolbar-fit.swift && /tmp/tf   # narrowest width the toolbar fits in
swiftc -O -o /tmp/tbh Scripts/toolbar-height.swift && /tmp/tbh   # what the toolbar band costs, per style
swiftc -O -o /tmp/cf Scripts/content-font.swift && /tmp/cf   # every measurement behind «Шрифт текста»
swiftc -O -o /tmp/vm Scripts/view-menu.swift && /tmp/vm   # which menu the размер items land in, and how ⌘+ is stored
swiftc -O -o /tmp/phf Scripts/pane-header-fit.swift && /tmp/phf   # what the перевод pane's header wants at its narrowest, per picker shape
RENDER_PREVIEW_CHANGES=/tmp/preview swift test --filter renderChangesPreview   # draw a правка's marks at 13 and 22 pt, both views, both appearances
RENDER_PREVIEW_CODE=/tmp/preview swift test --filter renderCodePreview   # word- vs char-wrapped code cards at 560/300 pt, both appearances
RENDER_PREVIEW_TABLE=/tmp/preview swift test --filter renderTablePreview   # a 4-column table at 300/430/560 pt, through the panel's own measuring path
TEXT_DIFF_COST=1 swift test --filter textDiffCost   # what TextDiff costs at the 256 KB ceiling — run on a quiet machine
./Scripts/change-density.sh docs/proofreading-gate   # live: where densityThreshold sits, per степень; needs the release CLI
RENDER_PREVIEW=/tmp/preview swift test --filter renderPreview   # draw the rendered pane to light/dark PNGs and look
swift run translate-cli --to ru --tone technical "text"   # needs a live engine; reads stdin if no text
swift run translate-cli --engine lmstudio --model qwen/qwen3.8-27b --to ru "text"   # the other engine
swift run translate-cli --proofread --level rewrite --style business --from ru "text"   # правка route; --to/--tone are refused here, --level/--style only here
swift run acceptance              # live corpus run; MUST run from the package root (reads ./corpus)
swift run acceptance --model translategemma:12b --chunk 4000   # any installed model / the chunk budget you actually run
swift run acceptance --engine lmstudio --model google/gemma-4-e4b   # the other engine; both gates go info-only
```

No test count here on purpose: it went stale twice in one review cycle, and a number nothing
checks is a contract nobody can keep. The suite is offline and reads **~2.8 s** (2026-08-26;
it read ~2.1 s before that day's review work), so there is no reason not to run it. Most of
that is **two** tests that spend real time on purpose:

- `aFileInterruptedFromTheTermsSheetDoesNotReportTheReadersDeliberation` sleeps a deliberate
  second — the property it pins, that a reader's time in the terms sheet is not reported as the
  machine's, can only be seen by letting real time pass. Alone it reads ~1.13 s, stretched to
  ~2.7 s by contention with `TranslationPanelTests`' real `NSPanel`s.
- `acancelDuringLanguageDetectionStillStopsTheRun` translates a 150 KB source so the detector
  runs long enough for its poll to land inside the window it is about — with a short string the
  window closes in microseconds and the test passes with the fix removed, which was measured
  rather than guessed.

Watch those two figures, not the total; if the suite reads much above ~2.8 s, suspect the
machine before the code — a leaked load generator once made the same commit measure 0.87 s and
3.0 s on the same hardware.

`swift test` never touches the network. `translate-cli` and `acceptance` do — `acceptance` is
the deliberately-not-in-CI harness that measures TTFT, markup integrity and term consistency
against the thresholds in spec §10, and exits 1 on regression. **Its two gates are properties
of `aya-expanse:8b` on Ollama, and the harness says so on its first line**: the TTFT ceiling and
the `known`/`known-limitation` sets apply only when that is the model *and* that is the engine.
Under `--model` anything else, or `--engine lmstudio`, TTFT is printed `info only` and every
markup diff is unaccepted — measured, not certified. `--think` is refused outright on
`--engine lmstudio`: it exists to force a bare value past `ModelPolicy`, and there is no bare
value to force where the server validates against the model's own capabilities.

**There is CI, and it is the offline half only** (`.github/workflows/ci.yml`): build with
tests, a gate that fails on any warning, then `swift test`. `acceptance` stays out for the
reason above. The warning gate enforces the zero-warnings rule, and it runs against a fresh
checkout rather than a cached build because of `docs/reference/TESTING.md`'s tenth shape.

The Accessibility grant is keyed to the code signature. `make-app-bundle.sh` prefers a
self-signed "LocalTranslator Dev" identity precisely so the grant survives rebuilds; with
ad-hoc signing macOS re-asks after every build. The script's header says how to create one.

## Architecture

8 SwiftPM targets, one hard rule: **translation logic knows nothing about Ollama or SwiftUI.**

<!-- The count and the names below are checked against Package.swift by
     DocumentationTests/ArchitectureDriftTests.swift. This block said "Five" and named a
     target that does not exist for long enough that two separate documents repeated it. -->

```
TranslationCore  (pure domain; depends on nothing but Foundation/NaturalLanguage)
      ↑            ↑            ↑              ↑
   OllamaKit  LMStudioKit   MarkupKit    TextCapture (independent; no TranslationCore)
      ↑            ↑            ↑              ↑
        TranslatorApp (SwiftUI) · translate-cli · acceptance
```

- `TranslationCore` — declares the `LLMClient` protocol (`chat` → `AsyncThrowingStream<ChatEvent>`)
  and everything downstream of it: `LanguageDetector`, `Chunker`, `LineScanner`, `TermExtractor`,
  `DocumentGlossary`, `Glossary`, `LemmaMatcher`, `GlossaryVerifier`, `PromptBuilder`,
  `ResponseCleaner`, `MarkupSkeleton`, `ModelPolicy`, and `Translator` orchestrating them.
  Fully testable with `FakeLLMClient`; no Ollama needed.
- `OllamaKit` — thin HTTP client implementing `LLMClient` (`/api/chat`, `/api/tags`, `/api/pull`, `/api/ps`).
- `LMStudioKit` — the same job against LM Studio's native `/api/v1/*`, and the same rule: it
  knows `LLMClient` and nothing about `OllamaKit`. Two facts about that server shape the client
  and are measured, not assumed — an unknown JSON key is **rejected** rather than ignored, so
  the request body is a closed list, and `reasoning: "off"` is **HTTP 400** on a model whose
  `capabilities.reasoning.allowed_options` lacks it, so what to send is resolved from those
  options rather than posted blind. See
  `docs/design/specs/2026-08-21-model-engine-switch-design.md`.
- `MarkupKit` — `MarkdownToAttributed`, the **one** Markdown → `NSAttributedString` converter,
  used by the перевод pane's rendered mode and by its rich «Скопировать» flavour. Blocks come
  from `TranslationCore.MarkdownBlockScanner` — so the renderer draws the document the chunker
  read — and inline spans from Foundation's own parser. It knows `TranslationCore` and AppKit
  and nothing about the app: `MarkdownFontConfig` mirrors `ContentFont` rather than importing
  it. See `docs/design/specs/2026-08-31-formatting-design.md`.
- `TextCapture` — every fragile macOS API, isolated on purpose: Carbon hotkey registration,
  the Accessibility read, the synthetic ⌘C fallback, the whole-pasteboard snapshot, the permission gate.
- `TranslatorApp` — `MenuBarExtra` + panel + window + settings, `LSUIElement`.

### The translation pipeline (`Translator.translate`)

Detect language → chunk → (if >1 chunk and the source language is *recognised*) one preparatory
call that translates an extracted term list into a **document glossary** → *(optional)* a review
of that glossary by a human → per-chunk translation calls → clean → verify glossary + diff markup
skeleton.

Facts that will bite you if you "tidy" them:

- **The two glossaries follow opposite injection rules, deliberately.** The user glossary is
  filtered by occurrence; the document glossary is injected whole into every chunk. See
  `docs/adr/0001-two-glossaries-opposite-injection-rules.md` — unifying them reintroduces
  terminology drift (measured: 64–68% → 88%).
- **The review point is the one place `translate` may suspend on a human, and it sits outside
  the `catch` that swallows a failed term-list call.** At that instant the term-list stream has
  finished and no per-chunk request has been issued, so nothing is in flight. Inside that
  `catch`, a throw from the hook would become an empty glossary and the run would carry on as
  though the user had approved it. `reviewDocumentTerms` defaults to `nil`, and a test pins that
  a hook returning its draft untouched produces the same run as no hook at all.
- **Cancellation must be checked explicitly.** `AsyncThrowingStream` *finishes* on cancellation
  instead of throwing, so without `Task.checkCancellation()` before and after every network call
  a cancelled run returns a truncated document as a success. Cancellation must surface as
  `CancellationError`. The one deliberate exception: a failed document-glossary call is swallowed
  (it is an enhancement, not the result) — but a cancellation inside it still propagates.
  **The same rule applies to the *end of a stream*, not only to the calls around it**: the check
  before `streamChunkReply`'s post-loop emit is what stops a cancelled chunk's partial buffer
  being cleaned, inline-restored and handed to `onToken` as a completed chunk. And it applies at
  the transport: `OllamaChatReader` refuses a stream that ended without its `done` frame, and
  `OllamaStreamParser` throws on an in-stream `{"error": …}` line, because both otherwise report
  half a document as a success — the failure `LMStudioEventReader` has always thrown to prevent.
- **The edges belong to `emit`, not to a trim at the end.** Every buffered path ends at
  `ResponseCleaner.clean`, which trims both edges; the incremental path cannot, because bytes
  handed to `onToken` are unrecallable. So `streamChunkReply` *holds* edge whitespace — it waits
  until it is known to be interior and is dropped if it never is — and the buffer is
  leading-trimmed while buffering, so the streaming decision runs on the same bytes `clean()`
  would decide on. Without that, which path a chunk took changed the bytes in `final`.
- **`final` and the `onToken` stream must agree exactly.** Cleaning (preamble stripping, whole-answer
  fence unwrap) can only be decided on the whole first line / whole reply, so `streamChunkTranslation`
  buffers until the shape is settled, then goes incremental. Chunks are joined by each chunk's
  `separatorBefore` — the source document's own bytes, restored verbatim — in both `final` and the
  stream, plus the source's trailing whitespace at the end; `ChunkPlan`'s invariant is that this
  reassembly is byte-for-byte lossless. `ChunkPlan.assembled(from:)` is that formula and the only
  place it is written — `Translator` and the pinning test both call it, because a test that
  restates the formula pins its own copy. Separators are always whitespace-only, which is what
  lets `TranslationViewModel` tell them from model content; it is asserted in `plan` and pinned.
- **The packing rule is the structure guarantee.** Blocks merge into one chunk only across a
  separator that is **exactly one blank line in the document's own line-ending convention** —
  `LineScanner.isExactlyOneBlankLine`, i.e. two bare line terminators of any recognised
  spelling — and the join uses the document's own separator bytes, so a merged chunk's text is
  byte-identical to its source span. Every other separator (three blank lines, a lone `"\n"`
  before a fence, a blank line carrying spaces) forces a chunk boundary and never reaches the
  model at all. Accepting every convention is not a relaxation: the model may normalise an
  interior `"\r\n"` to `"\n"`, but `MarkupSkeleton` shares `LineScanner`, which reads either as
  one line break, so the diff cannot cry wolf. **`ResponseCleaner`, `InlineCodeRestorer` and
  `streamChunkReply` share it too, since 2026-08-26** — each had its own discipline and each was
  wrong differently: a lone CR paired backticks across a line break and spliced the wrong source
  bytes over real code; `firstIndex(of: "\n")` never matched the single `Character` `"\r\n"`; and
  `components(separatedBy: .newlines)` split `"\r\n"` into two breaks and fabricated a paragraph.
  `LineScanner.pieces` carries each line's own terminator, so a caller that takes a document
  apart puts back the bytes it found — use it wherever `components(separatedBy:)` suggests
  itself. **Do not re-spell this rule as a list of
  literals** — that list was the defect twice over: `"\n\n"` alone cost a CRLF document *every*
  merge (measured: 30 chunks and 31 model calls against the LF copy's 2 and 3), and adding
  `"\r\n\r\n"` left CR-only and mixed-EOL documents in the same hole. **Indentation is not a
  code signal anywhere in the pipeline**: fenced and inline code are the only protected forms,
  indented text is prose and is translated, and its indentation survives because `Block.range`
  moves edge whitespace into the separators. See
  `docs/design/specs/2026-08-07-lossless-chunking-design.md` and its correction note.
- **The model never sees fenced code, and inline code is restored by construction.**
  A fenced block is its own pass-through chunk (`Chunk.passthrough`) — emitted from
  source bytes with no model call, on both routes; inline spans are restored
  positionally from the source under an equal-count gate, on the cleaned reply, and a
  span-bearing chunk buffers whole so `final` and the stream stay byte-identical.
  `TranslationOutcome.modelChunkCount` is what «multi-chunk» means now — the
  document-glossary trigger, the empty-reply ending and the acceptance classification
  all count model-bound chunks. See
  `docs/design/specs/2026-08-10-code-protection-and-styles-design.md`.
- **`translate(source:)` is how a caller states the language, and every caller does** — the
  window, the queue and `translate-cli --from`. Nil means «detect it», but a stated source
  governs everything downstream — the prompt, the tagger `TermExtractor` parses with, and
  `detectedSource`. Before it existed, correcting a misdetection changed only where the text
  went, never how it was read, and `translate-cli --from` was advertised and did nothing.
  A stated source also saves a second full scan of a file up to 2 MB — **but only for a
  language the app can name**: a caller passes nil when its own detect returned nil, so a
  document outside the supported nine is still scanned twice (measured: 2.06 MB of Ukrainian,
  ~48 ms a scan, both off the main actor — a note, not a defect).
- **The user turn hands the text over plainly under one closing line — no `<text>…</text>`
  markers, on either route.** Measured on `translategemma:27b`: a question inside the markers
  was answered as a question 5/5 and the markers were echoed back around 7/15 replies, each
  echo costing the chunk its streaming; 0/15 and 0/15 without them, and the markers — not the
  rules, not the message structure — were isolated as the cause. The whole-answer marker
  unwrap in `ResponseCleaner` and the buffer-to-end it forced went with them, gone rather than
  dead-coded. `PromptBuilder.userPrompt(for:)` carries the measurement; the aya-expanse:8b
  before/after is in `docs/reference/BASELINE.md`.
- `timeToFirstTokenMS` is `nil` when nothing was ever emitted — that nil *is* the empty-reply
  signal. Do not substitute a sentinel; it makes an absent response read as a slow one. It is
  only a *failure* together with `modelChunkCount > 0`, and that pairing is
  `TranslationOutcome.isEmptyReply` — **one place, because it was two and one of them was
  wrong**: the queue checked the nil alone and failed every all-code document, which «Текст»
  translated happily. Whitespace does not stamp it either; invisible content is not an answer.
- `stats` covers the per-chunk translation calls only, never the term-list call.
- **«Оформить» is a third route, and it runs *before* the other two — on the source, in a call
  of its own, under a gate.** `Translator.format` asks the model to add headings, tables, lists
  and code markers to a flat text; `FormattingGate` accepts the reply only if, with its markers
  taken back off (`MarkdownPlainText`, now in `TranslationCore` for exactly this) and whitespace
  collapsed, it is the same text word for word, and every table's rows have equal cell counts.
  Emphasis and links are forbidden in the prompt and stripped if they arrive, never failed on.
  `TranslationViewModel.reconstructIfWanted` decides whether a call is made at all — the
  setting for this surface (`reconstructsStructure`, plus `reconstructsStructureInPanel` for
  the panel, both **off** by default), no markup already present (`MarkdownPresence`), and the
  text fitting one chunk — and a refused, skipped or failed pass runs the operation on the text
  as it was with a `FormattingNotice` under «Оформить не удалось». An accepted result replaces
  the исходник pane's text and marks the reply's Markdown as synthesised, so «Заменить» strips
  it. **Why a separate call and not a clause in the translation prompt** is the 2026-08-31
  design's series B (bold→italic 5/5, invented emphasis 2/3) — `docs/adr/0011`. The threshold
  for turning it on by default and the tool that measures it (`translate-cli --format-only`,
  `Scripts/format-loss.sh`) are in spec #72 and `docs/reference/MEASUREMENTS.md`.
- **Правка is a second route through the same pipeline, not a second pipeline.**
  `Translator.proofread` shares the chunking, the per-chunk streaming
  (`streamChunkReply`), the cancellation discipline and `ChunkPlan.assembled(from:)`
  with `translate`, and runs **no** glossary stage: no term-list call, no review hook,
  no `GlossaryVerifier`. It returns `TranslationOutcome` with honestly empty glossary
  fields (`documentGlossaryAttempted == false` is the marker). The style instruction
  reaches the prompt only where the level allows it — `ProofreadingLevel.allowsRewriteStyle`
  is the one rule, `PromptBuilder` enforces it and the UI disables the control. Three
  levels: `errorsOnly`, `errorsAndStyle`, and `rewrite` («переписать») — a **sentence-level**
  free rewrite whose instruction deliberately never says «structure», because the shared
  protection rules demand exact structure preservation two lines below it and the two must
  not fight (issue #40; merge is gated on the calibration protocol in
  `docs/reference/OPEN-ITEMS.md`). See `docs/design/specs/2026-08-10-proofreading-design.md`.
  **A правка says what it changed, since 2026-09-04, and no model is asked.** `proofread`
  runs `TextDiff.changes(source:result:)` after `final` is assembled — `totalMS` is taken
  *before* it, so «Готово за N мс» and the baseline do not move — and returns the result in
  `TranslationOutcome.changes` (`nil` means «not a правка»; `documentGlossaryAttempted ==
  false` is still the marker). The diff is per block over the plain projections
  (`MarkdownPlainText.plain(_:in:)`), token by token (`TextTokenizer`: words and marks,
  whitespace a boundary, so a collapsed double space is not a change), through
  `CollectionDifference`; code blocks are never compared (they never reached the model).
  **Four constants govern it and each is a parameter with a default, never a literal in the
  algorithm**: `densityThreshold` (a block whose similarity is below it, or whose changed-token
  ratio is above it, becomes *one* change — a «переписать» paragraph reads as rewritten, not
  as confetti), `mergeGap` (two changes with at most one unchanged word between them merge,
  which is what makes «посмотрите, пожалуйста,» one change), `blockTokenLimit` and
  `inspectionLimit` (past them the diff is by equality only, or not run — `notCompared`). The
  figures behind them are in `docs/reference/MEASUREMENTS.md` under «change marks», and
  `changedTokens` is counted **before** the merge on purpose (PR #83): a ratio that moved with
  `mergeGap` would be a poor thing to measure a threshold on. `translate-cli --proofread`
  prints `changes: N`; `--changes-json` is what `Scripts/change-density.sh` reads.
  **The marks are located, not carried** (`MarkupKit.ChangeMarks`): a change names tokens of
  a block's plain projection, the storage holds a rendered document or the raw Markdown, and
  the two are aligned by walking the same tokenizer's tokens — so one change set marks
  «Разметка», «Исходник» and plain prose, and a block the aligner cannot consume is left
  unmarked with the count untouched (a guessed underline is worse than none). They are
  **attributes** — `.underlineStyle`, `.underlineColor`, `ChangeMarks.changeKey` — in
  «Результат», and the «Изменения» view splices the removed words in as characters, struck
  through in the secondary colour: a second document, like «Исходник» is. **The mark is a
  dotted underline in the accent, darkened 35 % in the light appearance, everywhere** —
  measured (`Scripts/accent-contrast.swift`, 2026-09-04): `linkColor` against the blue accent
  is 1.49:1 light / 1.14:1 dark, so a solid accent line *was* the link's underline, and bare,
  three of the eight accents fall under the 3:1 non-text floor on the white pane (жёлтый
  1.51:1); `ChangeMarksColourTests` holds all sixteen cells. `docs/adr/0012` is the decision.
  **Nothing about the marks reaches the pasteboard or «Заменить»**: `PaneRendering.rtf` and
  both `richFlavour()` sites take no change set, pinned by a test. In the window the count and
  a ‹ › stepper sit in `RunStatusBar`'s finished line («Готово за N мс · 6 изменений»,
  «изменений нет»), ⌘G / ⇧⌘G in the «Перевод» menu step too (measured free: SwiftUI's standard
  «Правка» menu binds nothing to `g`), and `TranslationViewModel.changeCursor` is what both
  read; a step selects the range and shows AppKit's find indicator. In the panel a правка reply
  renders at the settle whether or not it has markup (`rendersFinalReply(… hasChanges:)`), the
  степень/стиль row gains «Вид» (`PanelReplyView`: результат / изменения / оригинал — the last
  a per-presentation `HotkeyCoordinator.showsOriginal`, cleared on every press, switch and «Ещё
  вариант», and *not* «исходник», which already means a pane's raw form), and the status row
  says «Исправлено: 6 изменений» (`PanelStatus.Kind.summary`) — the 24 pt the reservation
  already books, so the settle does not grow the panel for it. That row and the third menu are
  why `PanelSizer.dragMinHeight` is **179**, re-measured 2026-09-04. See
  `docs/design/specs/2026-09-04-change-marks-spec.md` and issue #81.

### Engine rules (empirical, non-negotiable)

**There are two engines**, chosen by `AppSettings.engine` and defaulting to Ollama, so an
existing install is unchanged until someone touches the switch. Everything in this section that
names Ollama is about Ollama; the LM Studio half is below it, and the difference between them is
not cosmetic — **the safe direction is inverted**. See
`docs/design/specs/2026-08-21-model-engine-switch-design.md` and `docs/adr/0010`.

- A model's reasoning is read and **discarded** on both — `message.thinking` on Ollama,
  `reasoning.delta` events on LM Studio.
- **In the app, whether the `think` parameter is sent, and what value, is decided per model by
  `ModelPolicy.thinkRequest(for:quiet:level:)` — never sent as a bare, unconditional value.**
  The trap is a property of a model, not of the protocol: `"think": false` genuinely silences
  `qwen3:8b` and `gemma4:26b`, is **ignored** by `gpt-oss:20b`, and on `qwen3:30b` puts 2798
  characters of Russian reasoning into `message.content` — straight into the translation.
  The two directions are asymmetric: `false` is safe on the wire everywhere (HTTP 200 on all
  eight local models, re-measured 2026-08-11 on Ollama 0.31.1) and unsafe in meaning on
  `qwen3:30b`; `true` or a level sent to a model whose `/api/show` capabilities lack
  `thinking` is **HTTP 400**, a failed translation, 4 of 4 such models. Anything that enables
  reasoning must be gated on `capabilities`, which this client cannot read — it calls
  `/api/tags`, `/api/ps`, `/api/pull`, `/api/chat` and nothing else. That is why `ThinkRequest`
  has no «on» case: every request the app can build is one Ollama accepts. Levels grade
  `gpt-oss:20b` and nothing else here (15/441/889 characters of trace at 0.49/1.99/3.77 s to
  first token, warm — its only lever, since it ignores `false`); on `qwen3`/`gemma4` a level
  means no more than «on». The full table is in `docs/reference/PLATFORM-TRAPS.md`.
- **«Длина рассуждения» is drawn from what the model allows, not from its name.**
  `ModelsViewModel.showsReasoningLength(for:)` asks `ModelPolicy`'s prefix table on Ollama and
  `allowed_options` on LM Studio, where no publisher-qualified identifier (`openai/gpt-oss-20b`)
  matches that table. It is offered only for a model that has levels and **cannot** be silenced,
  so the control and the «Отключать рассуждение модели» checkbox can never contradict each other.
- **The controls are `AppSettings.quietThinking` plus `gptOssThinkingLevel`.** `quietThinking`
  defaults to **true** — a deliberate change to what the app does: Ollama enables thinking by
  default for a capable model, so the app was paying for a trace it discards whenever the
  chosen model can reason. `gptOssThinkingLevel` defaults to `low`.
  `AppSettings.chatOptions(model:)` is the only place in the app that builds `ChatOptions`,
  precisely so a new call site cannot opt out of the policy. `acceptance` and `translate-cli`
  stay outside it on purpose — a harness that followed a user setting would move its own
  baseline, and `translate-cli --think` exists precisely to force a bare value past the policy
  and re-take a measurement.
- Ollama reports durations in nanoseconds; convert to ms at the client boundary. LM Studio
  reports seconds and a *rate* rather than a duration, so `LMStudioEventReader` inverts
  `tokens_per_second` — leaving it at zero made a model generating 57.7 tokens a second report a
  flat 0 through `ChatStats.tokensPerSecond`.
- **On LM Studio, what to send about reasoning is read from the model, not guessed.**
  `reasoning: "off"` is HTTP 400 on `openai/gpt-oss-20b` (measured 2026-08-21) — the exact
  inverse of Ollama, where `false` is the safe value everywhere. `ReasoningChoice` sends only a
  member of `capabilities.reasoning.allowed_options`; a model that reports no capabilities, and a
  failed lookup, both send **no key at all**. `AppSettings.thinkRequest(for:)` is where the
  per-engine decision is made, and on LM Studio it carries the user's chosen length as a
  *ceiling*: `.level(x)` means «as quiet as this model allows, no louder than x».
- **An unknown JSON key is rejected by LM Studio, not ignored** — `{"ttl": 1800}` answers HTTP
  400 `unrecognized_keys`. So `LMStudioChatBody` is a closed list of keys, `keepAlive` never
  reaches that wire, and residency there is «loaded until unloaded» rather than a duration:
  `/api/v1/models/load` is what warm-up calls, because a chat JIT-loads and the next JIT load
  evicts it (Auto-Evict exempts an explicit load — measured).
- **Nothing answering on the loopback port is trusted to be the engine.** Redirects are refused
  by a session delegate in each transport module (`RedirectPolicy`) — without one, a `307` from
  anything squatting the port re-POSTs the user's text off-box, and there is no configuration
  flag for it — and a 200 stream's lines are bounded (`BoundedLines`), because `bytes.lines`
  buffers a whole line with no ceiling while every arriving byte resets the inter-data timeout.
  Both are in `docs/adr/0009` with the rest of that promise.
- **`store: false` on every LM Studio request.** It defaults to `true`, i.e. the server keeps
  every translation. `docs/adr/0009` is the decision, together with the rule that only the
  *port* is settable and the host is loopback in code.
- An `error` event mid-stream does **not** end LM Studio's stream — `chat.end` still follows — so
  the reader turns it into a thrown error. A client that merely read to the end would return a
  partial translation as a success, the same shape as the cancellation rule above.
- **The main window's status row has a fourth running state, «Оформляю…»**, drawn without a
  spinner like «Жду ваших правок…» and for the same reason; `PanelStatus.Kind.formatting` is
  its panel twin. Both read `TranslationViewModel.isFormatting`.
- `ModelPolicy` pins `aya-expanse:8b` for the interactive path (TTFT < 1 s is a hard requirement)
  and `gpt-oss:20b` for the background path, and carries a blacklist with measured reasons.
  Those reasons are English and reach `translate-cli`; the settings pane renders
  `RussianCopy.blacklistReasons`, keyed by the same prefixes, falling back to the English.
  **`ModelRole.background` is still policy only** — the file queue reads `AppSettings.batchModel`,
  not `ModelPolicy.defaultModel(for: .background)`, so the recommendation and the setting stay
  separate things. `keep_alive` (default `30m`) is load-bearing, not an optimisation: cold load
  ~2000 ms vs ~155 ms warm. **That measurement is why `AppSettings.batchModel` and
  `AppSettings.proofreadModel` have no fixed default** (optional strings, empty stored as nil;
  `nil` means «the same one the hotkey uses»): a second model costs its residency and, when
  memory is short, a cold load on every switch. Re-measured 2026-08-18 (Ollama 0.32.14, 48 GB):
  two models that fit stayed resident together, so the «one model in memory» this rule was
  first written under is a fact about memory pressure, not about Ollama — the «Файлы» warning
  is conditional now, and «Модели»' правка note says both are warmed at launch. `batchModel`
  is stored under the old `"backgroundModel"` key, as its removal comment promised;
  `proofreadModel` under its own name. **Правка's model is `resolvedProofreadModel`**
  (`TranslationViewModel.proofread`, `warmUp()`), because the model that translates best here
  edits worst — measured 2026-08-18 on the правка corpus, `AppSettings.proofreadModel` has the
  numbers.

### The app layer

- `TranslatorApp` is `LSUIElement`. **Scene order is load-bearing**: `MenuBarExtra` must stay the
  first scene, or SwiftUI opens the main window at every login. `Settings` stays last.
- **The main menu exists, is Russian, and owns every keyboard shortcut the window has.**
  `LSUIElement` governs the Dock tile and whether the bar is *drawn*; it does not stop SwiftUI
  installing `NSApp.mainMenu`, and key equivalents are dispatched through it either way —
  measured by dumping the menu from a copy of these three scenes. So ⌘↩, ⌘., ⌃⌘S, ⇧⌘C, ⌘0 and
  the three размер items (⌘+, ⌘−, ⌃⌘0) are declared once, in `.commands`, and **not** on the
  toolbar buttons that mirror them. «Вид» is **filled** rather than emptied: the same
  `CommandGroup(replacing: .sidebar)` that used to take the empty menu away carries «Крупнее»,
  «Мельче» and «Обычный размер» — measured with `Scripts/view-menu.swift`. ⌃⌘0 and not the
  conventional ⌘0 because ⌘0 is «Открыть окно перевода», the only keyboard route to the window.
  Easy to undo by accident: `Info.plist`'s `CFBundleDevelopmentRegion = ru` plus
  `Resources/ru.lproj` are what make the *standard* menus Russian (without them the bundle
  claims `["en"]` and a fully Russian app carries an English menu bar), and `make-app-bundle.sh`
  must copy that directory in **before** `codesign`, like the icon. `CommandGroup(replacing:)`
  empties a menu but does not remove it, so `pruneEmptyMenus()` takes away whatever is left
  with no items.
- **A run must not straddle two servers.** The router reads «Движок» on every call, which is
  what makes the radio button take effect without a relaunch — but a translation is many calls,
  so each run freezes its target at the start through `LLMClient.pinnedForRun()` (defaulting to
  `self`, so no fake and no plain transport is affected) and `Translator.forRun()`. Before that,
  a flip mid-document sent one engine's model tag and protocol to the other engine's server,
  failed the файл being translated and every файл behind it, and cached a junk client in the
  pool. `EngineTarget` is the pair, because reading «which engine» and «which port» separately
  is what tore.
- **Three** models over one shared `EngineRouter`: two `TranslationViewModel` instances, one for
  the window and one owned by `HotkeyCoordinator` for the panel, plus `FileQueueModel` for the
  file queue. The router is what makes the engine switch take effect without a relaunch — it
  reads the setting on **every** call, so nothing above it has to be rebuilt — and it reads that
  setting out of the defaults store rather than out of `AppSettings`, because it is `Sendable`
  and runs off the main actor while that class is `@Observable`. `ClientPool` holds one client
  per engine per port for the life of the process. They must not be merged: a hotkey translation must never overwrite the window, and
  the re-entrancy guard is per instance. All three are built in `TranslatorApp.init` — the app
  owns the models, the scenes read them. **The toolbar's «Из», «В» and «Тон» belong to whichever
  model owns the visible mode** — `FileQueueModel`'s own in «Файлы», the text model's in
  «Текст». One owner for both modes let `adopt(from:)` reset the language a queue was
  configured with, and the next «Перевести» wrote every file in the settings-default one.
- **The window's left pane has two modes and the primary action follows the visible one.**
  `PrimaryAction.forMode` is that rule, and the toolbar button, ⌘↩ and ⌘. all read it — never
  `TranslationViewModel` directly, which would leave «Файлы» with a button running an empty
  text model and two dead shortcuts. `mode` therefore lives in `TranslatorApp`, not in
  `MainWindowView`: a menu declared in the app's scene cannot read that view's `@State`. The ⌘.
  argument still holds — a disabled menu item declines its equivalent so the panel gets it — but
  its condition is «the *visible mode* is running».
- **The file queue writes to disk, and that is the only place this app does.** `QueueDrop` decides
  what it accepts (a mixed drop is kept, with unreadable files shown as rows — refusing the whole
  drop is the text pane's one-slot rule, which does not transfer to a queue with a slot per file);
  `OutputNaming` decides the name and never overwrites; `TranslatedFileWriter` writes and returns
  where. **Whether TCC permits a sibling write next to a dropped file is unverified** — the app is
  not sandboxed, but a drag grants read, not write — so a refusal falls back to `NSSavePanel`,
  which confers the right itself.
- `HotkeyCoordinator` owns every decision of a press; `PanelView` is a readout. Ordering inside a
  press is measured, not preferred: hide the old panel → read the selection off the main actor →
  show the panel → translate. Showing the panel first breaks the capture, because a
  `.nonactivatingPanel` still becomes *key* and system-wide accessibility focus follows the key window.
- **There are two shortcuts and one coordinator.** A `HotkeyManager` per `TextOperation`
  (⌥⌘T перевод, ⌥⌘R правка by default), and `handlePress(operation:)` assigns the pressed
  shortcut's operation to the panel model — a press never inherits what the previous
  presentation's switch was left on — and assigns it **before** `afterCapture()`, because that
  hook is where the panel is measured and the степень/стиль row is drawn from it. Two managers
  rather than one holding two registrations, because `HotkeyManager`'s handler already tells
  registrations apart by `signature` + `hotKeyID` and its comment carries that measurement;
  two *coordinators* are forbidden for the reason the three models must not be merged — that
  would be a second panel and a second `TranslationViewModel`. Registrations are brought in
  line in **two passes** — release what blocks (remembering it), then register — because Carbon
  refuses a combination still held by the other manager; each half skipped cost a defect (one
  pass silently kept the old combination; releasing without remembering left перевод registered
  to *nothing*). A refused registration is logged inside `apply` through
  `HotkeyCoordinator.failure(for:restored:combination:)`, a value with a test: `.fault` only
  for перевод with nothing restored — the one case where the app really has no way into the
  panel — and `.error` otherwise. If both settings hold the same combination (not typable, but
  inheritable), правка's registration is declined rather than attempted and «Основные» says so.
  The panel's «степень»/«стиль» pickers write `defaultProofreadingLevel` /
  `defaultRewriteStyle` **directly** — they are the settings, not per-run overrides, so a
  choice made where правка is used survives the panel closing and the window follows it
  wherever it has no override of its own. See
  `docs/design/specs/2026-08-15-proofread-hotkey-design.md`.
- **The panel sizes itself to its content, and it *is* `.titled`.** This sentence used to say
  the opposite, and following it would kill hand-resize and flip `canBecomeKey` — the exact
  defect `a57efa1` fixed on 2026-07-31, one day after the wrong sentence was written.
  `.resizable` alone never worked; the 22 pt of titlebar is made invisible by
  `titlebarAppearsTransparent` plus `.fullSizeContentView`, and the three standard buttons are
  hidden. Three types share the job and
  none of them may be collapsed into another: `PanelSizer` owns the rules (width clamped to
  300–560 pt and frozen for a whole presentation; height floored at 120 pt, monotonic within a
  presentation and capped at 0.6 of `visibleFrame`, past which the content scrolls; a
  hand-resize wins until the panel hides), `PanelPlacement` picks the anchor corner nearest the
  pointer so growth moves the *far* edge and not the text already read, and `PanelController`
  does the measuring — with a **second, detached `NSHostingController`** (never the installed
  view), `fittingSize` for the ideal width then `sizeThatFits(in:)` for the height at that
  width, and `layoutSubtreeIfNeeded()` after reassigning `rootView`, which is load-bearing.
  All four measuring facts are in `docs/reference/PLATFORM-TRAPS.md` with their measurements.
- **«Шрифт текста» reaches four surfaces and nothing else, and one of them is invisible.** The
  исходник (`SourceEditor`'s hosted `NSTextView`, not a `Text` at all), the перевод, the panel's
  reply, and the panel's hidden reservation `Text` — that last one being the load-bearing pairing
  and the one an earlier count of «three `Text`s» left out.
  `ContentFont` (гарнитура + размер, 11–32 pt, default 13) reaches those four and nothing
  else — and, since the перевод pane renders Markdown, **every run the renderer draws inside
  that same перевод surface**: headings and code are multiples of `ContentFont.size`
  (×1.6/1.4/1.25/1.1/1.0/1.0 semibold for h1…h6), never sizes of their own, and
  `ContentFont.markdownConfig` is the single bridge that carries the pair into `MarkupKit`. The
  count is still four surfaces; what grew is what «the перевод» means inside one of them.
  Never a label, a button, a status row or a table, because
  `PanelSizer.minHeight` 132 and `dragMinHeight` 179 are measurements of the *pinned* block at
  the system size and would otherwise become functions of a preference. `docs/adr/0008` is the
  decision. Three things about it are load-bearing: the panel's **hidden reservation `Text`
  takes the same font as the visible one** or it stops predicting the reply's height; the font
  must be read **inside `PanelHost`'s body**, because `PanelController` sizes the panel from a
  detached second host built by the same builder; and `reservationLimit` scales by the **square**
  of the size — measured, a line is `size` tall and holds `1/size` characters, and the linear
  version written first predicts less than half the movement. 13 pt is not «about right»: it
  measures identically to `.body`, so an untouched install renders exactly as before.
- **The settings panes already scroll — do not "fix" their fixed frame.** `settingsPane()`'s
  `.frame(width: 560, height: 480)` is what stops the window resizing between tabs, and it does
  **not** clip: `.formStyle(.grouped)` installs an `NSScrollView` of its own, measured, at any
  content size, where a `VStack` and an unstyled `Form` install none. Replacing the frame with
  `minWidth`/`minHeight` reintroduces the resizing for no gain.
- **The glossary pane's language column is derived from the glossary, not from a setting.**
  `GlossaryColumn.language(for:fallback:)` picks the language most entries are actually written
  into; the fallback is `primaryLanguage`, because `targetLanguage(forDetected:)` sends
  everything that is not already in the user's own language *into* it (the old `workingLanguage`
  fallback named the other direction, and on a default install every «перевод» field rendered
  blank). **It must not be recomputed while the user types**: `entryBinding` writes through
  `translations[editingLanguage.rawValue]`, so a column that moved mid-word would split one
  translation across two keys. `SettingsGlossaryView` computes it on appear and on re-read only,
  and holds it in `@State`.
- `SourceEditor` takes a dropped file. What it accepts is `DroppedDocument` — a closed extension
  list, a 256 KB ceiling, UTF-8 or nothing — and a refusal is `false` out of `dropDestination`,
  which makes the system spring the item back. That is the entire error channel and is
  deliberate: there is no error surface in that window, and inventing one to say «this is not
  text» would be worse than the feedback the platform already draws.
  **Its editor is a hosted `SourceTextView`, not a `TextEditor`, since 2026-09-02, for one
  reason: ⌘V reads the pasteboard's HTML and RTF.** A table copied out of a browser is flat in
  `.string` and whole in `.html`, and `TextEditor` pastes the plain flavour with no hook to do
  otherwise. The paste goes through `RichMarkdown.markdown` — the hotkey's converter *and* the
  hotkey's improvement-or-no-op gate — so the two entry points cannot disagree about what a
  selection is; a paste that would gain only bold, or nothing, pastes the plain bytes. The
  text view registers for strings only (`updateDragTypeRegistration` is overridden), because a
  text view registered for file URLs takes a dropped file first and inserts its *path*.
- **An empty `markupDiffs` means «the structure survived», and nothing else may be read into
  it.** `MarkupSkeleton.compare` refuses two skeletons still more than
  `maximumComparisonCells` apart *after* the common prefix and suffix are trimmed — the dense
  LCS matrix is quadratic and the queue takes 2 MB files — and that refusal travels as
  `TranslationOutcome.markupNotCompared`, which every surface rendering «no problems» reads
  (`WarningsView`, `JobResult`, `translate-cli`, `acceptance`). Returning `[]` for it would be
  the quietest possible lie. **Trimming is not output-preserving**: measured over 4000 generated
  pairs, 427 give a different script — same count and same multiset, different order — which is
  why both consumers are order-independent by construction and a test keeps the old algorithm
  beside the new one.
- The main window is a toolbar plus `SourceEditor`/`FileQueuePane` | `TranslationPane` over a
  collapsible `RunStatusBar`. **The translation side draws Markdown when the translation has
  any**, and is a read-only `Text` when it has none — never a `TextEditor`, deliberately,
  because the one it replaced took a caret and discarded typing. The settings are **four**
  tabs — «Основные», «Модели», «Глоссарий», «Файлы» («Дополнительно» was folded into «Модели»
  and stays folded). All four take one 560 × 480 frame from `settingsPane()`, so adding a pane
  means checking it fits rather than sizing it itself.
- **The перевод pane has two modes, and the toggle only exists when there is something to
  choose between.** `MarkdownPresence.hasMarkup` decides; with no markup the pane is a
  selectable `Text` in a `ScrollView` exactly as before, and with markup it is
  `RenderedTextView` — a hosted read-only `NSTextView`, **TextKit 1**, because `NSTextTable`
  lives only there and every table `MarkdownToAttributed` draws is one. «Исходник» is the same
  string in the same view with no conversion, so raw Markdown is still selectable as one
  document; `AppSettings.showsRenderedMarkup` (default true) is where the choice is kept, and
  the pane writes it directly rather than holding a per-run override. One view serves «Текст»
  and «Файлы» both, which is why the queue's pane gained all of this for free.
  **The typography follows the reading surfaces this app is compared with** (GitHub,
  ChatGPT, Claude), since 2026-09-02: a table is rules between rows with a filled semibold header
  and a bottom margin, never a grid; a quote wears a 3 pt bar on its leading edge; the newline
  that ends a block carries no run decoration (a code span at the end of a list item used to
  paint its background to the pane's edge). All of it is in the paragraph style, so the RTF
  flavour carries it. `RENDER_PREVIEW=… swift test --filter renderPreview` draws the pane to
  PNGs; the images are how the pass was judged and are the tool for the next one.
  **Code is syntax-coloured, since 2026-09-02, by a hand-written lexer** — `MarkupKit.
  SyntaxHighlighter`, a profile per language (comments, strings, numbers, keywords, data-format
  keys, capitalised types) over UTF-16 offsets, because the dependency list is closed
  (`docs/adr/0007`) and no highlighting library is coming in. Two rules are load-bearing: **no
  profile, no colours** (a bare fence or an unknown language stays in the label colour — a guess
  about comment syntax is how a URL turns green), and a token is closed only by the syntax that
  opened it. The colours are `SyntaxPalette`'s own per appearance, not the system accents:
  measured, `systemPurple` is 3.34:1 and `systemTeal` 1.73:1 on the light card, and every
  palette value is held to ≥ 4.5:1 on the card in both appearances by `SyntaxPaletteTests` — the
  same discipline as `StatusColour`. Only `.foregroundColor` changes, so `CodeRegion.source`
  and the RTF flavour carry the same bytes with their colours.
  **A code block is a card, since 2026-09-02**: a one-column `NSTextTable` block with a border
  and `MarkdownToAttributed.codeCardHeaderHeight` (24 pt, a constant — the header holds a
  system-sized control, `docs/adr/0008`) of room above the code, in which `CodeBlockTextView`
  draws the fence's language (`CodeRegion.language`) and an **always-visible** «Скопировать»
  as overlays — views, not characters, so the RTF flavour and a drag-selection copy carry the
  code alone. The frame lives in the paragraph style rather than in the view for the reason
  the converter exists at all: one rendering for the pane and for the copy path.
  **«•» and «–» lines are drawn as a list and are not a block**, since 2026-09-02:
  `PlainBulletList` is read by the renderer and by `MarkdownPresence` (so the toggle appears)
  and by nothing else — the scanner hands the paragraph over as a paragraph, so the chunker,
  the skeleton, the model and «Заменить» see the user's own bytes. The «Оформить» pass asks
  `MarkdownPresence` with `countingPlainBullets: false`, because a flat mail with bullets and a
  collapsed table still wants its table back.
  **Since 2026-09-02 the исходник pane reads the same toggle**: `SourcePaneMode.of` hosts the
  same `RenderedTextView` over the source in «Разметка» and the editor in «Исходник», the
  toggle is drawn when *either* pane has markup (`TranslationPane.offersToggle`), and the
  file-drop destination sits on the pane's container so a drop works in both modes — which is
  also why `CodeBlockTextView` registers for no drag types at all.
  During a run only *settled* blocks are drawn and the unsettled tail stays plain characters
  (`MarkdownBlockScanner.settledPrefix`), so a block is never redrawn as something else; the
  update replaces the tail region of the storage and nothing more.
  **«Скопировать» writes two flavours in one write** — `.string` the Markdown bytes as always,
  `.rtf` the attributed document the pane is showing — and plain only while «Исходник» is up or
  there is no markup, because a plain-prose translation must not arrive in Word wearing a font
  this app chose. `PaneRendering` is the one place that rule is written: the pane's button and
  the «Перевод» menu's ⇧⌘C both read it, and a restated condition is how the two come to copy
  different things. See `docs/design/specs/2026-08-31-formatting-design.md`.
  **In правка mode the same picker has a third segment, since 2026-09-04 — «Результат |
  Изменения | Исходник»** — driven by `PaneViewChoice` over the two settings
  `showsRenderedMarkup` and `showsChangeDetail` (a tested mapping; «Исходник» leaves the
  detail alone), and the pane hosts `RenderedTextView` whenever there are changes, markup or
  not. One picker rather than two, because this control governs *both* panes and a second one
  is the shape `Scripts/toolbar-fit.swift` exists to refuse. **The picker is segmented where
  it fits and a `.menu` where it does not, and the pane's floor is 360 pt** — measured
  (`Scripts/pane-header-fit.swift`, 2026-09-04): three segments want 495 pt, перевод's two
  397, the menu form 352, and the old 280 pt floor clipped «Скопировать» in every operation
  since the toggle arrived. `ViewThatFits` holds both pickers over one binding and one item
  list, so the menu cannot say anything the segments do not; 360 is the first round number
  past the narrowest form, and the исходник pane keeps 280 (its header is the mode switch
  alone), so the two panes want 640 of the window's 700.
- Capture order is Accessibility first, synthetic ⌘C fallback second, and the fallback must restore
  the *whole* pasteboard. **One exception since 2026-09-02: a selection inside web content —
  an `AXWebArea` in the focused element's ancestry — skips the Accessibility tier**, because
  Chromium answers it with the blocks run together and no flavours (observed on LM Studio),
  while its ⌘C carries the HTML. `SelectionReader.FocusContext` is the rule, keyed on the role
  and never on a bundle list; `HotkeyCoordinator.logCapture` writes one `.notice` line per
  press with the role chain and two counts, never the text, so the next such application is
  diagnosable from a user's machine. The only path allowed to write the user's clipboard unasked is `autoCopy`,
  off by default — and it is read only by `HotkeyCoordinator`, so it governs the panel and not
  the main window. Its label says so; do not widen one without the other.
- `AppSettings` reads and writes `UserDefaults` directly in every accessor (no stored properties),
  so `@Observable`'s synthesis does not apply — each accessor calls `access(keyPath:)` /
  `withMutation(keyPath:_:)` by hand. Keep that shape when adding a setting. The two shortcut
  keys, `"hotkey"` and `"proofreadHotkey"`, are each one JSON value re-checked for `isValid` on
  the way out. They differ in one argument only — `hotkey` falls back to its default because it
  is the only door to the panel, and `proofreadHotkey` does so for the weaker reason that a
  setting whose stored state and behaviour disagree cannot be reasoned about.
- **Four settings answer per engine, and the Ollama scope is the key an install already wrote.**
  `interactiveModel`, `batchModel` (still stored under `"backgroundModel"`), `proofreadModel`
  **and `enginePort`** gain a `".lmStudio"` suffix for the second engine. This said «three … and
  nothing else» until 2026-08-26, and tooling written from it read the wrong port key. There is
  no migration
  and no risk to a stored value. LM Studio has **no** default translation model: it reads back
  empty, `hasNoTranslationModel` is what the window and the panel key off, and nothing is
  auto-selected, because flipping a radio button may not silently pick a 22.81 GB model and load
  it at the next warm-up. `engine` is the one unsuffixed new key; `AppSettings.engine(in:)`,
  `enginePort(in:)` and `enginePort(in:for:)` are static readers over a store, for
  `EngineRouter`'s sake — the last of them so that «which engine» and «which port» can be **one**
  read. `ModelEngine.portOrDefault` clamps the port in both directions: a stored value outside
  `1...65535` made `URL(string:)` answer nil at two force-unwrapped call sites, and
  `warmUpOnLaunch` turned that into a crash at every launch that survived the crash.
- **`keepAlive` is Ollama's alone.** LM Studio rejects a `ttl` field in a chat request, so the
  «Держать модель в памяти» field is hidden there and `WarmUpPlan` warms one model instead of
  two — 22.81 GB apiece against 48 GB is the reason, and it is about memory rather than
  transport. A queue whose model differs loads it explicitly before the first файл, which puts it
  outside Auto-Evict's reach.
- `GlossaryStore` persists `~/Library/Application Support/LocalTranslator/glossary.json` (hand-editable,
  git-trackable by design). `save()` is gated on a successful `load()` and on a file stamp check, so
  the app cannot overwrite a file edited behind its back.

## Conventions

- Swift 6 tools, `.swiftLanguageMode(.v6)` on **every** target, platform floor macOS 14. Any new
  target repeats both. **`.v6` is enforced, not aspirational** — moving the package off `.v5`
  cost four compile errors in `TextCapture` plus one runtime trap that no build could see.
  Three facts from that move, each recorded at the site it bit: an imported C global
  (`kAXTrustedCheckOptionPrompt`) needs `@preconcurrency import`, not `nonisolated(unsafe)`
  (`PermissionsGate.swift`); a `nonisolated deinit` on a `@MainActor` class may not touch a
  non-`Sendable` stored property without `nonisolated(unsafe)` on it (`HotkeyManager.swift`);
  and a closure written inside a `View` inherits main-actor isolation that Swift 6 checks **at
  run time** with a trap (`Tests/TranslatorAppTests/WarningsViewTests.swift`).
- **No external dependencies.** Foundation, NaturalLanguage, SwiftUI, AppKit, Observation,
  ApplicationServices, CoreGraphics, CoreText, ImageIO, Carbon, os, UniformTypeIdentifiers,
  Swift Testing only — a closed whitelist, not an illustration: adding a framework to it is a
  deliberate edit, not a formality. CoreText and ImageIO are here for `Scripts/make-icon.swift`
  alone; nothing in the shipped targets uses them. `UniformTypeIdentifiers` is here for one
  call — `MainWindowView.addFiles`'s `NSOpenPanel.allowedContentTypes`, which takes `UTType`
  and has no non-deprecated string equivalent; the extension list itself is still
  `DroppedDocument.readableExtensions`, so the panel and the drop cannot come to accept
  different things. `os` is here for `Log` in `TranslatorApp` and nowhere else: it is what
  makes this app's four deliberate swallowed failures diagnosable on a user's machine.
  `TranslationCore` does **not** get it — the engine reports through
  `TranslationOutcome.documentGlossaryFailure` instead, so the domain layer keeps its
  «Foundation and NaturalLanguage only» rule.
  **`MarkupKit` is the first non-app target allowed to import AppKit**, since 2026-08-31, and
  that is a deliberate whitelist edit rather than a leak: an `NSAttributedString` *is* AppKit,
  and the alternative was a second Markdown serialiser inside the app so the rendered pane and
  the rich «Скопировать» flavour could come to disagree. The framework was already on the list;
  what moved is where it may be imported. The arrow still points one way — `MarkupKit` knows
  `TranslationCore`, and nothing below `TranslatorApp` knows `MarkupKit`.
- **Nothing derived from the user's text may be logged.** Not the selection, not the source, not
  the translation, not a glossary term. `Log`'s doc comment carries the reasoning; the short
  version is that a unified-log entry is readable by any admin on the machine and is collected by
  sysdiagnose, so logging content would break «text never leaves the machine» in the one place
  nobody would look. Error descriptions are logged `.public` on purpose, because `<private>` in
  `log show` would make the entries useless for the diagnosis they exist for.
- Tests use **Swift Testing** (`@Test`, `#expect`), not XCTest. Test names are sentences describing
  the behaviour being pinned. `UserDefaults`-backed tests use `InMemoryDefaults`, never a real suite
  (a written suite leaves a plist in `~/Library/Preferences` that nothing reliably removes).
- **The three status colours are `StatusColour`, not `.orange`/`.green`/`.red`.** In the dark
  appearance the system colours are what the design uses and `StatusColour` returns them; in
  the light one it returns the design's darkened values, because `systemOrange` on a white pane
  is 2.31:1 against 11 pt text and this app writes every warning at that size. Measured — the
  table is in the type's doc comment, the probe is `Scripts/colour-contrast.swift`, and
  `StatusColourTests` turns the figures into assertions. Reaching for a bare `.orange` in a new
  view puts one warning back at a quarter of the contrast of the one beside it.
- All user-facing strings are Russian, with «guillemets» and «ё». **No backticks in strings rendered
  by `Text(String)`** — the plain-`String` initialiser does not parse Markdown and they show as
  literal grave accents. Identifiers (`aya-expanse:8b`) and key glyphs (⌥⌘T) stay as they are.
  Russian labels for domain enums live in `RussianCopy.swift`, exhaustive with no `default:`.
- Code comments here carry *why* and the measurement behind it, not what the code does. When changing
  something a comment justifies, update the reasoning or say why the measurement no longer holds.
- **«Measured» and «load-bearing» are a contract, not emphasis.** A comment using either word
  means a specific observation was made — usually with a count, «10 aborts in 10 runs» — and the
  code below it is the way it is *because* of that observation. Changing that code invalidates
  the observation. Either re-measure and update the number, or record why the measurement no
  longer applies. Deleting the line and keeping the comment is the one thing that must not
  happen: it has already cost this project two defects that looked like tidying.
- Commit messages: conventional, scoped by area — `feat(app):`, `fix(capture):`, `feat(ollama):`,
  `test(app):`, `docs(capture):`.
- UI is verified by hand; GUI automation is unavailable in this environment. Never describe UI
  behaviour that was not actually observed — state what indirect evidence was gathered instead.

## Where the reasoning lives

Read the one that answers your question; do not read them all.

| Document | Read it when |
|---|---|
| `docs/reference/RUNBOOK.md` | Building, signing, permissions, running the acceptance harness. |
| `docs/reference/OPEN-ITEMS.md` | «May I change this?» / «Is this unfinished on purpose?» — manual checks owed to a human, accepted limitations, and open questions. |
| `docs/reference/PLATFORM-TRAPS.md` | Before writing a *new* call into `NSPasteboard`, Accessibility, Carbon, `CGEvent`, `NSPanel`, or anything that measures a SwiftUI view. An index of the behaviours that each cost a defect. |
| `docs/reference/TESTING.md` | Writing a test. The mutation rule and nine shapes of test that pass under the defect they name. |
| `docs/reference/MEASUREMENTS.md` | «Where did this number come from?» |
| `docs/reference/BASELINE.md` | After running `swift run acceptance` — whether the result is normal, and where to record it. |
| `docs/adr/` | The code looks inconsistent and you want to know whether it is deliberate. |
| `docs/design/specs/2026-07-24-local-translator-design.md` | Changing engine behaviour. **Note its status header — it is the pre-implementation design, and where it and the code disagree the code is right.** |
| `docs/design/specs/2026-07-30-ui-redesign-design.md` | Changing the panel, the window or the settings: why each surface has the shape it has. Same status header, same rule — the code wins. Its §8 lists what only a human can check; `docs/reference/OPEN-ITEMS.md` §1 is where that list is kept current. |
| `docs/history/` | «What did we already try?» The build ledgers, including rejected approaches and defects found in the plans — and in one case in an audit — themselves. `2026-08-02-audit-and-three-waves-ledger.md` is the newest: read it before touching the settings panes' fixed frame, the glossary's language column, `LemmaMatcher`, or anything that assumes a menu bar. `2026-07-30-ui-redesign-ledger.md` is the account to read for panel sizing and the window's decomposition. |
| `CONTEXT.md` | Writing UI copy or naming something. |
| `docs/design/plans/` | Rarely. The four plans the codebase was built from; parts of them are known wrong where the ledgers record a correction. The UI redesign plan is the worst offender — seven of its defects reached the code verbatim. |

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `mordvic/tolmach`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Traps, by where you are about to write

Pointers, not summaries — the owning file has the measurement and is kept true by sitting next
to the code. `docs/reference/PLATFORM-TRAPS.md` has the same list with the facts attached.

- `NSPasteboard`, anything clipboard → `TextCapture/PasteboardSnapshot.swift`, `GeneralPasteboard.swift`
- Accessibility reads, synthetic key events → `TextCapture/SelectionReader.swift`
- Carbon hotkeys, key codes, modifier masks → `TextCapture/HotkeyManager.swift`, `HotkeyCombo.swift`
- `NSPanel` framing, sizing, key status → `TranslatorApp/TranslationPanel.swift`, `PanelSizer.swift`
- Hosting an `NSTextView`, TextKit 1 vs 2, `NSTextTable`, glyph rects →
  `TranslatorApp/RenderedTextView.swift`
- Measuring SwiftUI content, `NSHostingView`/`NSHostingController` → `PanelController.measure` in
  `TranslatorApp/TranslationPanel.swift`
- App activation, scene order → `TranslatorApp/TranslatorApp.swift`
- Recording a shortcut, `performKeyEquivalent` → `TranslatorApp/HotkeyRecorder.swift`
- `UserDefaults` in tests → `Tests/TranslatorAppTests/InMemoryDefaults.swift`
- Writing a file, naming an output, accepting a drop → `TranslatorApp/TranslatedFileWriter.swift`,
  `OutputNaming.swift`, `QueueDrop.swift`
- Suspending an engine run on a human → `TranslatorApp/DocumentTermsRequest.swift`
- A static function on a `View` called from a test → make the test `@MainActor`;
  `Tests/TranslatorAppTests/WarningsViewTests.swift` and `DocumentTermsViewTests.swift`
