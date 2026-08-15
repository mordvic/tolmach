# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

«Толмач» (`LocalTranslator`) — a macOS translator running entirely on local LLMs through
Ollama at `http://127.0.0.1:11434`. Text never leaves the machine. Three surfaces: a global
hotkey that translates the current selection into a floating panel, a main window, and — in
that window's «Файлы» mode — a queue of files translated one after another and written back
to disk.

## Commands

```bash
swift build                       # build everything
swift build --build-tests         # must stay at zero warnings — this is a standing rule
swift test                        # the whole suite, offline (fake LLMClient), ~1.5 s
swift test --filter someTestName  # one test, by name (Swift Testing function names)
swift test --filter TranslationCoreTests   # one test target

./Scripts/make-app-bundle.sh      # assemble build/LocalTranslator.app (debug); pass "release" for release
swift Scripts/make-icon.swift build/AppIcon.icns   # redraw the icon; make-app-bundle.sh does this itself
swift Scripts/colour-contrast.swift               # re-measure the status colours against both appearances
swiftc -O -o /tmp/ac Scripts/accent-contrast.swift && /tmp/ac   # white on every accent macOS offers
swiftc -O -o /tmp/wt Scripts/window-title.swift && /tmp/wt   # why the window title needs re-asserting
swiftc -O -o /tmp/tf Scripts/toolbar-fit.swift && /tmp/tf   # narrowest width the toolbar fits in
swiftc -O -o /tmp/tbh Scripts/toolbar-height.swift && /tmp/tbh   # what the toolbar band costs, per style
swift run translate-cli --to ru --tone technical "text"   # needs a live Ollama; reads stdin if no text
swift run acceptance              # live-Ollama corpus run; MUST run from the package root (reads ./corpus)
```

No count here on purpose: it went stale twice in one review cycle, and a number nothing
checks is a contract nobody can keep. What is worth stating is what the line above already
says — the suite is offline and finishes in about two seconds, so there is no reason not to
run it. That number has a floor and a reason: one test
(`aFileInterruptedFromTheTermsSheetDoesNotReportTheReadersDeliberation`) sleeps a deliberate
second, because the property it pins — that a reader's time in the terms sheet is not reported
as the machine's — can only be seen by letting real time pass in the sheet. Its two runs go
concurrently, so the floor is ~1.05 s rather than ~1.1 s.

That floor has since become the *whole* of the figure rather than most of it. The suite reads
**~2.1 s** now, and the reason is contention rather than any test being slow: `TranslationPanelTests`
shows real `NSPanel`s and lays out real `NSHostingController`s — 22 tests, 0.75 s on their own —
and running beside them stretches the sleeping test's own two runs from ~1.05 s to ~1.97 s. So the
number to watch is still that one test's, not the total. If the suite ever reads much above this,
suspect the machine before the code: a leaked load generator from an earlier session made the same
hardware measure 0.87 s and 3.0 s on the same commit.

`swift test` never touches the network. `translate-cli` and `acceptance` do — `acceptance` is
the deliberately-not-in-CI harness that measures TTFT, markup integrity and term consistency
against the thresholds in spec §10, and exits 1 on regression.

**There is CI, and it is the offline half only** (`.github/workflows/ci.yml`): build with
tests, a gate that fails on any warning, then `swift test`. `acceptance` stays out for the
reason above — «no CI for that harness» was never «no CI». The warning gate is the point: zero
warnings is a standing rule that until now nothing could enforce, and `docs/TESTING.md`'s tenth
shape is why it runs against a fresh checkout rather than a cached build.

The Accessibility grant is keyed to the code signature. `make-app-bundle.sh` prefers a
self-signed "LocalTranslator Dev" identity precisely so the grant survives rebuilds; with
ad-hoc signing macOS re-asks after every build. The script's header says how to create one.

## Architecture

6 SwiftPM targets, one hard rule: **translation logic knows nothing about Ollama or SwiftUI.**

<!-- The count and the names below are checked against Package.swift by
     DocumentationTests/ArchitectureDriftTests.swift. This block said "Five" and named a
     target that does not exist for long enough that two separate documents repeated it. -->

```
TranslationCore  (pure domain; depends on nothing but Foundation/NaturalLanguage)
      ↑                    ↑
   OllamaKit          TextCapture (independent; no TranslationCore)
      ↑                    ↑
        TranslatorApp (SwiftUI) · translate-cli · acceptance
```

- `TranslationCore` — declares the `LLMClient` protocol (`chat` → `AsyncThrowingStream<ChatEvent>`)
  and everything downstream of it: `LanguageDetector`, `Chunker`, `LineScanner`, `TermExtractor`,
  `DocumentGlossary`, `Glossary`, `LemmaMatcher`, `GlossaryVerifier`, `PromptBuilder`,
  `ResponseCleaner`, `MarkupSkeleton`, `ModelPolicy`, and `Translator` orchestrating them.
  Fully testable with `FakeLLMClient`; no Ollama needed.
- `OllamaKit` — thin HTTP client implementing `LLMClient` (`/api/chat`, `/api/tags`, `/api/pull`, `/api/ps`).
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
  `LineScanner.isExactlyOneBlankLine`, i.e. two bare line terminators of any recognised spelling —
  and the join uses the document's own separator bytes, so a merged chunk's text is byte-identical
  to its source span. Every other separator (three blank lines, a lone `"\n"` before a fence, a
  blank line carrying spaces) forces a chunk boundary and never reaches the model at all.
  Accepting every convention is not a relaxation: the model may normalise an interior `"\r\n"` to
  `"\n"`, but `MarkupSkeleton` shares `LineScanner`, which reads either as one line break, so the
  diff cannot cry wolf. **Do not re-spell this rule as a list of literals** — that list was the
  defect twice over: `"\n\n"` alone cost a CRLF document *every* merge (measured: 30 short
  paragraphs at a 900-character budget gave 30 chunks, 31 model calls, against the 2 chunks and 3
  calls of an LF copy of the same document), and adding `"\r\n\r\n"` to it left CR-only and
  mixed-EOL documents in the same hole (measured: 2 chunks against the LF twin's 1).
  **Indentation is not a code signal anywhere in the pipeline**: fenced and inline code are the
  only protected forms, indented text is prose and is translated, and its indentation survives
  because `Block.range` moves edge whitespace into the separators. See
  `docs/superpowers/specs/2026-08-07-lossless-chunking-design.md` and its correction note.
- **The model never sees fenced code, and inline code is restored by construction.**
  A fenced block is its own pass-through chunk (`Chunk.passthrough`) — emitted from
  source bytes with no model call, on both routes; inline spans are restored
  positionally from the source under an equal-count gate, on the cleaned reply, and a
  span-bearing chunk buffers whole so `final` and the stream stay byte-identical.
  `TranslationOutcome.modelChunkCount` is what «multi-chunk» means now — the
  document-glossary trigger, the empty-reply ending and the acceptance classification
  all count model-bound chunks. See
  docs/superpowers/specs/2026-08-10-code-protection-and-styles-design.md.
- **`translate(source:)` is how a caller states the language, and every caller does** — the
  window, the queue and `translate-cli --from`. Nil still
  means «detect it», but a stated source governs everything downstream — the prompt, the tagger
  `TermExtractor` parses with, and `detectedSource`. It used to be resolved in the app to pick a
  *target* and then dropped, so the toolbar's «Из» changed where the text went and nothing about
  how it was read: correcting a misdetection left the model told «translate from …» whatever the
  detector had guessed. `translate-cli` was the worst of the three: it parsed `--from` into a
  variable with one occurrence in the file, so the flag was advertised and did nothing at all.
  It also removes a second full scan of a file up to 2 MB — but **only for a language the app
  can name**. `detected` is `source ?? LanguageDetector.detect(text)`, and a caller passes nil
  when its own detect returned nil, so a document in a language outside the supported nine is
  still scanned twice. Measured: 2.06 MB of Ukrainian detects as nil in 48 ms (best of
  three), so such a file pays ~96 ms of scanning instead of ~48. Both scans are off the main actor, which is why this is a note and
  not a defect — but it is not «no second scan».
- `timeToFirstTokenMS` is `nil` when nothing was ever emitted — that nil *is* the empty-reply
  signal. Do not substitute a sentinel; it makes an absent response read as a slow one.
- `stats` covers the per-chunk translation calls only, never the term-list call.
- **Правка is a second route through the same pipeline, not a second pipeline.**
  `Translator.proofread` shares the chunking, the per-chunk streaming
  (`streamChunkReply`), the cancellation discipline and `ChunkPlan.assembled(from:)`
  with `translate`, and runs **no** glossary stage: no term-list call, no review hook,
  no `GlossaryVerifier`. It returns `TranslationOutcome` with honestly empty glossary
  fields (`documentGlossaryAttempted == false` is the marker). The style instruction
  reaches the prompt only under `.errorsAndStyle` — `PromptBuilder` enforces it and the
  UI disables the control. See `docs/superpowers/specs/2026-08-10-proofreading-design.md`.

### Ollama rules (empirical, non-negotiable)

- `message.thinking` in a response is read and **discarded**.
- **In the app, whether the `think` parameter is sent, and what value, is decided per model by
  `ModelPolicy.thinkRequest` — never sent as a bare, unconditional `false` or `true`.**
  `translate-cli --think` and `acceptance` are the deliberate exceptions: the CLI's flag exists
  precisely to force a bare value past that policy and re-take a measurement like the one below.
  Re-measured 2026-08-11 against Ollama 0.31.1 across all eight locally installed models, four
  to six values of `think` each. `"think": false` genuinely silences `qwen3:8b` (2621 → 0
  characters of trace) and `gemma4:26b` (721 → 0); it is **ignored** by `gpt-oss:20b` (563
  characters with it); and on **`qwen3:30b` — the model the original rule was taken on — it puts
  2798 characters of Russian reasoning into `message.content`**, i.e. straight into the
  translation. So the trap is real and is a property of a model, not of Ollama, and the old
  spelling of this rule as a fact about the protocol was wrong. See the `AppSettings.quietThinking`
  bullet below for the control that now decides this per request.
- **The two directions are asymmetric, which is what any future control has to respect.** `false`
  is safe on the wire everywhere — HTTP 200 on all eight, including the four that cannot reason
  at all — and unsafe in meaning on `qwen3:30b`. Turning reasoning *on* is the opposite: `true`
  or a level sent to a model whose `/api/show` capabilities lack `thinking` is **HTTP 400**
  `"…" does not support thinking`, i.e. a failed translation, 4 of 4 such models. Anything that
  enables it must be gated on `capabilities`, which this client cannot read yet — it calls
  `/api/tags`, `/api/ps`, `/api/pull` and `/api/chat` and nothing else.
- **Levels grade `gpt-oss:20b` and nothing else here.** `low`/`medium`/`high` give it 15 / 441 /
  889 characters of trace at 0.49 / 1.99 / 3.77 s to first token, warm — and they are its only
  lever, since it ignores `false`. On `qwen3` and `gemma4` a level means no more than «on» and
  is not monotonic. Ollama enables thinking by default for a capable model, so the app already
  pays for a trace it discards whenever the chosen model can reason: `aya-expanse:8b` cannot, so
  the interactive path is unaffected, but the recommended background model `gpt-oss:20b` can.
  The table with every figure is in `docs/PLATFORM-TRAPS.md`.
- **The control over it is `AppSettings.quietThinking` plus `gptOssThinkingLevel`, and the
  decision is `ModelPolicy.thinkRequest(for:quiet:level:)`.** `AppSettings.chatOptions(model:)`
  is the only place in the app that builds `ChatOptions`, precisely so a new call site cannot
  opt out of it; `acceptance` and `translate-cli` stay outside it on purpose, the first because
  a harness that followed a user setting would move its own baseline and the second because
  `--think` is how a measurement is re-taken. `ThinkRequest` has no «on» case: that is what
  makes every request the app can build one Ollama accepts, and it is why there is still no
  `/api/show` call anywhere in `OllamaKit`.
- Ollama reports durations in nanoseconds; convert to ms at the client boundary.
- `ModelPolicy` pins `aya-expanse:8b` for the interactive path (TTFT < 1 s is a hard requirement)
  and `gpt-oss:20b` for the background path, and carries a blacklist with measured reasons. Those
  reasons are English and reach `translate-cli`; the settings pane renders
  `RussianCopy.blacklistReasons`, keyed by the same prefixes, and falls back to the English if a
  prefix has no Russian counterpart. **`ModelRole.background` is still policy only** — the
  file queue reads `AppSettings.batchModel` (see below), not `ModelPolicy.defaultModel(for:
  .background)`, so the recommendation and the setting stay separate things.
  `keep_alive` (default `30m`) is load-bearing, not an optimisation: cold load ~2000 ms vs
  ~155 ms warm. **That measurement is why `AppSettings.batchModel` has no fixed default**: one
  model lives in memory, so a batch model differing from the interactive one costs two cold loads
  on every ⌥⌘T pressed during a queue run. `nil` means «the same one the hotkey uses», and the
  settings pane warns when the user picks otherwise. The property is stored under the old
  `"backgroundModel"` key, as its removal comment promised.

### The app layer

- `TranslatorApp` is `LSUIElement`. **Scene order is load-bearing**: `MenuBarExtra` must stay the
  first scene, or SwiftUI opens the main window at every login. `Settings` stays last.
- **The main menu exists, is Russian, and owns every keyboard shortcut the window has.**
  `LSUIElement` governs the Dock tile and whether the bar is *drawn*; it does not stop SwiftUI
  installing `NSApp.mainMenu`, and key equivalents are dispatched through it either way — measured
  by dumping the menu from a copy of these three scenes. So ⌘↩, ⌘., ⌃⌘S, ⇧⌘C and ⌘0 are declared
  once, in `.commands`, and **not** on the toolbar buttons that mirror them. Two things follow that
  are easy to undo by accident: `Info.plist`'s `CFBundleDevelopmentRegion = ru` plus
  `Resources/ru.lproj` are what make the *standard* menus Russian (without them the bundle claims
  `["en"]` and a fully Russian app carries an English menu bar), and `make-app-bundle.sh` must copy
  that directory in **before** `codesign`, like the icon. `CommandGroup(replacing:)` empties a menu
  but does not remove it, so `pruneEmptyMenus()` takes away whatever is left with no items.
- **Three** models over one shared `OllamaClient`: two `TranslationViewModel` instances, one for
  the window and one owned by `HotkeyCoordinator` for the panel, plus `FileQueueModel` for the
  file queue. They must not be merged: a hotkey translation must never overwrite the window, and
  the re-entrancy guard is per instance. All three are built in `TranslatorApp.init` — the app
  owns the models, the scenes read them.
- **The window's left pane has two modes and the primary action follows the visible one.**
  `PrimaryAction.forMode` is that rule, and the toolbar button, ⌘↩ and ⌘. all read it. They used
  to reach `TranslationViewModel` directly, which would have left «Файлы» with a button that ran
  an empty text model and two dead shortcuts. `mode` therefore lives in `TranslatorApp`, not in
  `MainWindowView`: a menu declared in the app's scene cannot read that view's `@State`. The ⌘.
  argument still holds — a disabled menu item declines its equivalent so the panel gets it — but
  its condition is now «the *visible mode* is running».
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
  presentation's switch was left on. Two managers rather than one holding two registrations,
  because `HotkeyManager`'s handler already tells registrations apart by `signature` +
  `hotKeyID` and its comment carries that measurement; two *coordinators* are forbidden for the
  reason the three models must not be merged — that would be a second panel and a second
  `TranslationViewModel`. Registrations are brought in line in **two passes** — release what
  blocks (remembering it), then register — because Carbon refuses a combination still held by
  the other manager. Both halves cost a defect: one pass made «move перевод onto правка's
  combination» silently keep the old one, and releasing without remembering left перевод
  registered to *nothing* when the new combination was then refused. `handlePress` assigns
  `panelModel.operation` **before** `afterCapture()`, because that hook is where the panel is
  measured and the степень/стиль row is drawn from it. A refused
  registration is logged inside `apply` through `HotkeyCoordinator.failure(for:restored:
  combination:)`, which is a value with a test: `.fault` only for перевод with nothing restored
  — the one case where the app really has no way into the panel — and `.error` otherwise. If
  both settings hold the same combination (not typable, but inherited by any install whose
  перевод was already ⌥⌘R), правка's registration is declined rather than attempted and
  «Основные» says so. The panel's «степень»/«стиль» pickers write
  `defaultProofreadingLevel` / `defaultRewriteStyle` **directly** — they are the settings, not
  per-run overrides, so a choice made where правка is used survives the panel closing and the
  window follows it wherever it has no override of its own. See
  `docs/superpowers/specs/2026-08-15-proofread-hotkey-design.md`.
- **The panel sizes itself to its content and is not `.titled`.** Three types share the job and
  none of them may be collapsed into another: `PanelSizer` owns the rules (width clamped to
  300–560 pt and frozen for a whole presentation, height floored at 120 pt, monotonic within a
  presentation and capped at 0.6 of `visibleFrame`, past which the content scrolls; a
  hand-resize wins until the
  panel hides), `PanelPlacement` picks the anchor corner nearest the pointer so growth moves the
  *far* edge and not the text already read, and `PanelController` does the measuring.
  It measures with a **second, detached `NSHostingController`** — never the installed view,
  which measures what it is showing rather than what the content wants — and the two passes use
  `fittingSize` for the ideal width and `sizeThatFits(in:)` for the height at that width,
  because a greedy SwiftUI view hands a proposal straight back. `layoutSubtreeIfNeeded()` after
  reassigning `rootView` is load-bearing, not tidy-up: without it the measuring host never sees
  content that changed through `@Observable`. All four facts are in `docs/PLATFORM-TRAPS.md`
  with their measurements.
- **The settings panes already scroll — do not "fix" their fixed frame.** `settingsPane()`'s
  `.frame(width: 560, height: 480)` is what stops the window resizing between tabs, and it does
  **not** clip: `.formStyle(.grouped)` installs an `NSScrollView` of its own, measured, at any
  content size, where a `VStack` and an unstyled `Form` install none. Replacing the frame with
  `minWidth`/`minHeight` reintroduces the resizing for no gain.
- **The glossary pane's language column is derived from the glossary, not from a setting.**
  `GlossaryColumn.language(for:fallback:)` picks the language most entries are actually written
  into; the fallback is `primaryLanguage`, because `targetLanguage(forDetected:)` sends
  everything that is not already in the user's own language *into* it. It used to default to
  `workingLanguage`, which named the other direction — so on a default install every «перевод»
  field rendered blank. **It must not be recomputed while the user types**: `entryBinding`
  writes through `translations[editingLanguage.rawValue]`, so a column that moved mid-word would
  split one translation across two keys. `SettingsGlossaryView` computes it on appear and on
  re-read only, and holds it in `@State`.
- `SourceEditor` takes a dropped file. What it accepts is `DroppedDocument` — a closed extension
  list, a 256 KB ceiling, UTF-8 or nothing — and a refusal is `false` out of `dropDestination`,
  which makes the system spring the item back. That is the entire error channel and is
  deliberate: there is no error surface in that window, and inventing one to say «this is not
  text» would be worse than the feedback the platform already draws.
- The main window is a toolbar plus `SourceEditor`/`FileQueuePane` | `TranslationPane` over a collapsible
  `RunStatusBar`; the translation side is a read-only `Text`, deliberately, because the
  `TextEditor` it replaced took a caret and discarded typing. The settings are **four** tabs —
  «Основные», «Модели», «Глоссарий», «Файлы». They were three: «Дополнительно» was folded into
  «Модели» and stayed folded, and «Файлы» is new with the queue. All four take one 560 × 480
  frame from `settingsPane()`, so adding a pane means checking it fits rather than sizing it
  itself.
- Capture order is Accessibility first, synthetic ⌘C fallback second, and the fallback must restore
  the *whole* pasteboard. The only path allowed to write the user's clipboard unasked is `autoCopy`,
  off by default — and it is read only by `HotkeyCoordinator`, so it governs the panel and not
  the main window. Its label says so; do not widen one without the other.
- `AppSettings` reads and writes `UserDefaults` directly in every accessor (no stored properties),
  so `@Observable`'s synthesis does not apply — each accessor calls `access(keyPath:)` /
  `withMutation(keyPath:_:)` by hand. Keep that shape when adding a setting. Two of its keys
  are `"quietThinking"` (default **true** — a deliberate change to what the app does, see the
  Ollama rules above) and `"gptOssThinkingLevel"` (default `low`). Two more are the shortcuts:
  `"hotkey"` and `"proofreadHotkey"`, each one JSON value re-checked for `isValid` on the way
  out. They differ in one argument only — `hotkey` falls back to its default because it is the
  only door to the panel, and `proofreadHotkey` does so for the weaker reason that a setting
  whose stored state and behaviour disagree cannot be reasoned about.
- `GlossaryStore` persists `~/Library/Application Support/LocalTranslator/glossary.json` (hand-editable,
  git-trackable by design). `save()` is gated on a successful `load()` and on a file stamp check, so
  the app cannot overwrite a file edited behind its back.

## Conventions

- Swift 6 tools, `.swiftLanguageMode(.v6)` on **every** target, platform floor macOS 14. Any new
  target repeats both. **`.v6` is enforced, not aspirational** — the package built at `.v5` until
  the observability wave, and moving it cost four compile errors in `TextCapture` plus one runtime
  trap that no build could see. Three facts from that move are worth knowing before writing a new
  target: an imported C global (`kAXTrustedCheckOptionPrompt`) needs `@preconcurrency import`, not
  `nonisolated(unsafe)`; a `nonisolated deinit` on a `@MainActor` class may not touch a
  non-`Sendable` stored property without `nonisolated(unsafe)` on it; and a closure written inside
  a `View` inherits main-actor isolation that Swift 6 checks **at run time** with a trap. Each is
  recorded at the site it bit — `PermissionsGate.swift`, `HotkeyManager.swift`,
  `Tests/TranslatorAppTests/WarningsViewTests.swift`.
- **No external dependencies.** Foundation, NaturalLanguage, SwiftUI, AppKit, Observation,
  ApplicationServices, CoreGraphics, CoreText, ImageIO, Carbon, os, UniformTypeIdentifiers,
  Swift Testing only. This list is
  a closed whitelist, not an illustration: adding a framework to it is a deliberate edit, not a
  formality. CoreText and ImageIO are here for `Scripts/make-icon.swift` alone — glyph layout and
  PNG encoding for the icon — and nothing in the shipped targets uses them. `UniformTypeIdentifiers` was added for one
  call: `MainWindowView.addFiles`'s `NSOpenPanel.allowedContentTypes`, which takes `UTType`
  and has no string-based equivalent that is not deprecated — the extension list itself is
  still `DroppedDocument.readableExtensions`, so the panel and the drop cannot come to
  accept different things. `os` was added
  deliberately, for `Log` in `TranslatorApp` and nowhere else: it is what makes this app's four
  deliberate swallowed failures diagnosable on a user's machine. `TranslationCore` does **not** get
  it — the engine reports through `TranslationOutcome.documentGlossaryFailure` instead, so the
  domain layer keeps its «Foundation and NaturalLanguage only» rule.
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
| `docs/RUNBOOK.md` | Building, signing, permissions, running the acceptance harness. |
| `docs/OPEN-ITEMS.md` | «May I change this?» / «Is this unfinished on purpose?» — manual checks owed to a human, accepted limitations, and open questions. |
| `docs/PLATFORM-TRAPS.md` | Before writing a *new* call into `NSPasteboard`, Accessibility, Carbon, `CGEvent`, `NSPanel`, or anything that measures a SwiftUI view. An index of the behaviours that each cost a defect. |
| `docs/TESTING.md` | Writing a test. The mutation rule and nine shapes of test that pass under the defect they name. |
| `docs/MEASUREMENTS.md` | «Where did this number come from?» |
| `docs/BASELINE.md` | After running `swift run acceptance` — whether the result is normal, and where to record it. |
| `docs/adr/` | The code looks inconsistent and you want to know whether it is deliberate. |
| `docs/superpowers/specs/2026-07-24-local-translator-design.md` | Changing engine behaviour. **Note its status header — it is the pre-implementation design, and where it and the code disagree the code is right.** |
| `docs/superpowers/specs/2026-07-30-ui-redesign-design.md` | Changing the panel, the window or the settings: why each surface has the shape it has. Same status header, same rule — the code wins. Its §8 lists what only a human can check; `docs/OPEN-ITEMS.md` §1 is where that list is kept current. |
| `docs/history/` | «What did we already try?» The build ledgers, including rejected approaches and defects found in the plans — and in one case in an audit — themselves. `2026-08-02-audit-and-three-waves-ledger.md` is the newest: read it before touching the settings panes' fixed frame, the glossary's language column, `LemmaMatcher`, or anything that assumes a menu bar. `2026-07-30-ui-redesign-ledger.md` is the one before it and still the account to read for panel sizing and the window's decomposition. |
| `CONTEXT.md` | Writing UI copy or naming something. |
| `docs/superpowers/plans/` | Rarely. The four plans the codebase was built from; parts of them are known wrong where the ledgers record a correction. The UI redesign plan is the worst offender — seven of its defects reached the code verbatim. |

### Traps, by where you are about to write

Pointers, not summaries — the owning file has the measurement and is kept true by sitting next
to the code. `docs/PLATFORM-TRAPS.md` has the same list with the facts attached.

- `NSPasteboard`, anything clipboard → `TextCapture/PasteboardSnapshot.swift`, `GeneralPasteboard.swift`
- Accessibility reads, synthetic key events → `TextCapture/SelectionReader.swift`
- Carbon hotkeys, key codes, modifier masks → `TextCapture/HotkeyManager.swift`, `HotkeyCombo.swift`
- `NSPanel` framing, sizing, key status → `TranslatorApp/TranslationPanel.swift`, `PanelSizer.swift`
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
