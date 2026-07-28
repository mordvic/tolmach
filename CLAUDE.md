# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

«Толмач» (`LocalTranslator`) — a macOS translator running entirely on local LLMs through
Ollama at `http://127.0.0.1:11434`. Text never leaves the machine. Two surfaces ship in v1:
a global hotkey that translates the current selection into a floating panel, and a main
window. Batch file translation is v2.

## Commands

```bash
swift build                       # build everything
swift build --build-tests         # must stay at zero warnings — this is a standing rule
swift test                        # ~289 tests, all offline (fake LLMClient), a few seconds
swift test --filter someTestName  # one test, by name (Swift Testing function names)
swift test --filter TranslationCoreTests   # one test target

./Scripts/make-app-bundle.sh      # assemble build/LocalTranslator.app (debug); pass "release" for release
swift run translate-cli --to ru --tone technical "text"   # needs a live Ollama; reads stdin if no text
swift run acceptance              # live-Ollama corpus run; MUST run from the package root (reads ./corpus)
```

`swift test` never touches the network. `translate-cli` and `acceptance` do — `acceptance` is
the deliberately-not-in-CI harness that measures TTFT, markup integrity and term consistency
against the thresholds in spec §10, and exits 1 on regression.

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
  and everything downstream of it: `LanguageDetector`, `Chunker`, `TermExtractor`,
  `DocumentGlossary`, `Glossary`, `LemmaMatcher`, `GlossaryVerifier`, `PromptBuilder`,
  `ResponseCleaner`, `MarkupSkeleton`, `ModelPolicy`, and `Translator` orchestrating them.
  Fully testable with `FakeLLMClient`; no Ollama needed.
- `OllamaKit` — thin HTTP client implementing `LLMClient` (`/api/chat`, `/api/tags`, `/api/pull`, `/api/ps`).
- `TextCapture` — every fragile macOS API, isolated on purpose: Carbon hotkey registration,
  the Accessibility read, the synthetic ⌘C fallback, the whole-pasteboard snapshot, the permission gate.
- `TranslatorApp` — `MenuBarExtra` + panel + window + settings, `LSUIElement`.

### The translation pipeline (`Translator.translate`)

Detect language → chunk → (if >1 chunk and the source language is *recognised*) one preparatory
call that translates an extracted term list into a **document glossary** → per-chunk translation
calls → clean → verify glossary + diff markup skeleton.

Facts that will bite you if you "tidy" them:

- **The two glossaries follow opposite injection rules, deliberately.** The user glossary is
  filtered by occurrence; the document glossary is injected whole into every chunk. See
  `docs/adr/0001-two-glossaries-opposite-injection-rules.md` — unifying them reintroduces
  terminology drift (measured: 64–68% → 88%).
- **Cancellation must be checked explicitly.** `AsyncThrowingStream` *finishes* on cancellation
  instead of throwing, so without `Task.checkCancellation()` before and after every network call
  a cancelled run returns a truncated document as a success. Cancellation must surface as
  `CancellationError`. The one deliberate exception: a failed document-glossary call is swallowed
  (it is an enhancement, not the result) — but a cancellation inside it still propagates.
- **`final` and the `onToken` stream must agree exactly.** Cleaning (preamble stripping, whole-answer
  fence unwrap) can only be decided on the whole first line / whole reply, so `streamChunkTranslation`
  buffers until the shape is settled, then goes incremental. Chunks are joined with `"\n\n"` in both
  `final` and the stream. There is a test pinning this invariant.
- `timeToFirstTokenMS` is `nil` when nothing was ever emitted — that nil *is* the empty-reply
  signal. Do not substitute a sentinel; it makes an absent response read as a slow one.
- `stats` covers the per-chunk translation calls only, never the term-list call.

### Ollama rules (empirical, non-negotiable)

- `message.thinking` in a response is read and **discarded**.
- The `think` parameter is **never sent**. `"think": false` does not disable reasoning, it moves it
  into `message.content`, i.e. straight into the translation.
- Ollama reports durations in nanoseconds; convert to ms at the client boundary.
- `ModelPolicy` pins `aya-expanse:8b` for the interactive path (TTFT < 1 s is a hard requirement)
  and `gpt-oss:20b` for the background path, and carries a blacklist with measured reasons. Those
  reasons are English and reach `translate-cli`; the settings pane renders
  `RussianCopy.blacklistReasons`, keyed by the same prefixes, and falls back to the English if a
  prefix has no Russian counterpart. **The background role is policy only** — nothing reads it,
  batch translation is v2, and the settings control that implied otherwise was removed.
  `keep_alive` (default `30m`) is load-bearing, not an optimisation: cold load ~2000 ms vs
  ~155 ms warm.

### The app layer

- `TranslatorApp` is `LSUIElement`. **Scene order is load-bearing**: `MenuBarExtra` must stay the
  first scene, or SwiftUI opens the main window at every login. `Settings` stays last.
- Two `TranslationViewModel` instances, one for the window and one owned by `HotkeyCoordinator`
  for the panel, over one shared `OllamaClient`. They must not be merged: a hotkey translation
  must never overwrite the window, and the re-entrancy guard is per instance.
- `HotkeyCoordinator` owns every decision of a press; `PanelView` is a readout. Ordering inside a
  press is measured, not preferred: hide the old panel → read the selection off the main actor →
  show the panel → translate. Showing the panel first breaks the capture, because a
  `.nonactivatingPanel` still becomes *key* and system-wide accessibility focus follows the key window.
- Capture order is Accessibility first, synthetic ⌘C fallback second, and the fallback must restore
  the *whole* pasteboard. The only path allowed to write the user's clipboard unasked is `autoCopy`,
  off by default.
- `AppSettings` reads and writes `UserDefaults` directly in every accessor (no stored properties),
  so `@Observable`'s synthesis does not apply — each accessor calls `access(keyPath:)` /
  `withMutation(keyPath:_:)` by hand. Keep that shape when adding a setting.
- `GlossaryStore` persists `~/Library/Application Support/LocalTranslator/glossary.json` (hand-editable,
  git-trackable by design). `save()` is gated on a successful `load()` and on a file stamp check, so
  the app cannot overwrite a file edited behind its back.

## Conventions

- Swift 6 tools, `.swiftLanguageMode(.v5)` on **every** target, platform floor macOS 14. Any new
  target repeats both.
- **No external dependencies.** Foundation, NaturalLanguage, SwiftUI, AppKit, Observation,
  ApplicationServices, CoreGraphics, Carbon, Swift Testing only.
- Tests use **Swift Testing** (`@Test`, `#expect`), not XCTest. Test names are sentences describing
  the behaviour being pinned. `UserDefaults`-backed tests use `InMemoryDefaults`, never a real suite
  (a written suite leaves a plist in `~/Library/Preferences` that nothing reliably removes).
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
| `docs/PLATFORM-TRAPS.md` | Before writing a *new* call into `NSPasteboard`, Accessibility, Carbon, `CGEvent` or `NSPanel`. An index of the eleven behaviours that each cost a defect. |
| `docs/TESTING.md` | Writing a test. The mutation rule and nine shapes of test that pass under the defect they name. |
| `docs/MEASUREMENTS.md` | «Where did this number come from?» |
| `docs/BASELINE.md` | After running `swift run acceptance` — whether the result is normal, and where to record it. |
| `docs/adr/` | The code looks inconsistent and you want to know whether it is deliberate. |
| `docs/superpowers/specs/…-design.md` | Changing engine behaviour. **Note its status header — it is the pre-implementation design, and where it and the code disagree the code is right.** |
| `docs/history/` | «What did we already try?» The build ledgers, including rejected approaches and defects found in the plans themselves. |
| `CONTEXT.md` | Writing UI copy or naming something. |
| `docs/superpowers/plans/` | Rarely. The three plans the codebase was built from; parts of them are known wrong where the ledgers record a correction. |

### Traps, by where you are about to write

Pointers, not summaries — the owning file has the measurement and is kept true by sitting next
to the code. `docs/PLATFORM-TRAPS.md` has the same list with the facts attached.

- `NSPasteboard`, anything clipboard → `TextCapture/PasteboardSnapshot.swift`, `GeneralPasteboard.swift`
- Accessibility reads, synthetic key events → `TextCapture/SelectionReader.swift`
- Carbon hotkeys, key codes, modifier masks → `TextCapture/HotkeyManager.swift`, `HotkeyCombo.swift`
- `NSPanel` framing, sizing, key status → `TranslatorApp/TranslationPanel.swift`
- App activation, scene order → `TranslatorApp/TranslatorApp.swift`
- Recording a shortcut, `performKeyEquivalent` → `TranslatorApp/HotkeyRecorder.swift`
- `UserDefaults` in tests → `Tests/TranslatorAppTests/InMemoryDefaults.swift`
