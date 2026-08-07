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
swift test                        # ~341 tests, all offline (fake LLMClient), a few seconds
swift test --filter someTestName  # one test, by name (Swift Testing function names)
swift test --filter TranslationCoreTests   # one test target

./Scripts/make-app-bundle.sh      # assemble build/LocalTranslator.app (debug); pass "release" for release
swift Scripts/make-icon.swift build/AppIcon.icns   # redraw the icon; make-app-bundle.sh does this itself
swift run translate-cli --to ru --tone technical "text"   # needs a live Ollama; reads stdin if no text
swift run acceptance              # live-Ollama corpus run; MUST run from the package root (reads ./corpus)
```

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
  buffers until the shape is settled, then goes incremental. Chunks are joined by each chunk's
  `separatorBefore` — the source document's own bytes, restored verbatim — in both `final` and the
  stream, plus the source's trailing whitespace at the end; `ChunkPlan`'s invariant is that this
  reassembly is byte-for-byte lossless. There is a test pinning this invariant.
- **The packing rule is the structure guarantee.** Blocks merge into one chunk only across an
  exactly-`"\n\n"` separator, so the model always sees canonical spacing and every other separator
  never reaches it at all. Indented code (≥ 4 spaces or a tab, after a blank line) is code, and
  goes further: such a block never merges in either direction, so it is always a solo chunk
  (`Chunk.isIndentedCode`), and **`Translator` reproduces it itself instead of calling the model**.
  The prompt's «lines indented by four or more spaces» rule could never protect the block's first
  line — a chunk never begins with whitespace, so that indentation lives in `separatorBefore` and
  the model saw the line dedented — and byte-for-byte reproduction of code the engine already holds
  must not depend on model discipline. No LLM call means no `stats` entry for that chunk, but
  `timeToFirstTokenMS` is still stamped: it is content a consumer can see. `MarkupSkeleton`
  tokenises the block the same way, and shares `Chunker.scanLines` so the two layers read the same
  lines. See `docs/superpowers/specs/2026-08-07-lossless-chunking-design.md`.
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
- Two `TranslationViewModel` instances, one for the window and one owned by `HotkeyCoordinator`
  for the panel, over one shared `OllamaClient`. They must not be merged: a hotkey translation
  must never overwrite the window, and the re-entrancy guard is per instance.
- `HotkeyCoordinator` owns every decision of a press; `PanelView` is a readout. Ordering inside a
  press is measured, not preferred: hide the old panel → read the selection off the main actor →
  show the panel → translate. Showing the panel first breaks the capture, because a
  `.nonactivatingPanel` still becomes *key* and system-wide accessibility focus follows the key window.
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
- `SourcePane` takes a dropped file. What it accepts is `DroppedDocument` — a closed extension
  list, a 256 KB ceiling, UTF-8 or nothing — and a refusal is `false` out of `dropDestination`,
  which makes the system spring the item back. That is the entire error channel and is
  deliberate: there is no error surface in that window, and inventing one to say «this is not
  text» would be worse than the feedback the platform already draws.
- The main window is a toolbar plus `SourcePane` | `TranslationPane` over a collapsible
  `RunStatusBar`; the translation side is a read-only `Text`, deliberately, because the
  `TextEditor` it replaced took a caret and discarded typing. The settings are **three** tabs,
  not four — «Дополнительно» was folded into «Модели» — and all three take one 560 × 480 frame
  from `settingsPane()`, so adding a pane means checking it fits rather than sizing it itself.
- Capture order is Accessibility first, synthetic ⌘C fallback second, and the fallback must restore
  the *whole* pasteboard. The only path allowed to write the user's clipboard unasked is `autoCopy`,
  off by default — and it is read only by `HotkeyCoordinator`, so it governs the panel and not
  the main window. Its label says so; do not widen one without the other.
- `AppSettings` reads and writes `UserDefaults` directly in every accessor (no stored properties),
  so `@Observable`'s synthesis does not apply — each accessor calls `access(keyPath:)` /
  `withMutation(keyPath:_:)` by hand. Keep that shape when adding a setting.
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
  ApplicationServices, CoreGraphics, CoreText, ImageIO, Carbon, os, Swift Testing only. This list is
  a closed whitelist, not an illustration: adding a framework to it is a deliberate edit, not a
  formality. CoreText and ImageIO are here for `Scripts/make-icon.swift` alone — glyph layout and
  PNG encoding for the icon — and nothing in the shipped targets uses them. `os` was added
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
