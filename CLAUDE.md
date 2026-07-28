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
swift test                        # ~280 tests, all offline (fake LLMClient), a few seconds
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
  and `gpt-oss:20b` for the background path, and carries a blacklist with measured reasons shown
  in settings. `keep_alive` (default `30m`) is load-bearing, not an optimisation: cold load ~2000 ms
  vs ~155 ms warm.

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
- Commit messages: conventional, scoped by area — `feat(app):`, `fix(capture):`, `feat(ollama):`,
  `test(app):`, `docs(capture):`.
- UI is verified by hand; GUI automation is unavailable in this environment. Never describe UI
  behaviour that was not actually observed — state what indirect evidence was gathered instead.

## Where the reasoning lives

- `docs/superpowers/specs/2026-07-24-local-translator-design.md` — the design of record: measurements,
  rejected alternatives (two-pass refinement was measured and cut from v1), error-handling table,
  test thresholds, and §11a's list of known, deliberately-unfixed v1 limitations. Read it before
  changing engine behaviour.
- `docs/adr/` — decisions whose code looks inconsistent without them.
- `CONTEXT.md` — the project's ubiquitous language (Russian), including terms to avoid. Use these
  words in docs and commit messages: чанк, корректор, дрейф терминологии, документный глоссарий.
- `docs/superpowers/plans/` — the three implementation plans the codebase was built from.
