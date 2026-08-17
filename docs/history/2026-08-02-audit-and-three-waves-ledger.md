> Historical record of the build. Where this and the code disagree, the code is right.
>
> Written at the end of the work from the audit report, the five pull requests and the
> measurements taken along the way. It records what was found, what was ruled, and what was
> rejected — including defects in the audit itself. It is not maintained: it is the account of
> a piece of work that has finished.

# Audit ledger — report: docs/audit/architecture-and-ui-review.md

Branch base: `c25328f` (main)
End: `09e6939` (main), through PRs #9, #10, #11, #12 and #13.
Baseline at start: **347 tests**, zero warnings, `.swiftLanguageMode(.v5)` on all 11 targets, no CI.
At the end: **380 tests**, zero warnings on a clean rebuild, `.v6` on all 11 targets, CI green.

A read-only architecture and UI audit, then three waves of work from its own roadmap, then one
defect the waves uncovered. The engine was touched twice, both times for defects found by
tooling rather than by reading: `LemmaMatcher` and `TranslationOutcome`.

---

## The one thing to read if you read nothing else

**The audit's findings were the least reliable part of the audit.** Three of its twenty-one
were wrong — one of them recommended a change that would have reintroduced a defect the code
was already written to prevent. All three were caught by measuring, none by re-reading.

And the two most valuable defects on this branch were not in the report at all. Both were found
by a tool rather than by a person:

- the Swift 6 language mode found a **run-time trap that no build can see** — a clean compile
  and a dead process;
- CI, on its **first run ever**, found `LemmaMatcher` reporting «could not lemmatise» as «term
  missing» — a false warning on a correct translation, and precisely the crying wolf spec §4.6
  forbids.

A third came from rendering the settings pane to a PNG: the glossary showed a column no default
install ever writes into.

The lesson this branch supports is narrow and worth stating plainly: **reading found the
tractable problems; running things found the ones that mattered.** Every finding below marked
«measurement» came from a probe, a build flag, a CI runner or an image — not from the source.

---

## What each wave did

| Wave | PR | Commits | Tests | What it actually did |
|---|---|---|---|---|
| Audit | — | — | 347 | Read-only. `docs/audit/architecture-and-ui-review.md`: findings A1–A10 and U1–U11, a «checked and found no defect» section, modernisation table, three-wave roadmap. Two builds and four standalone probes; no source file touched. |
| 1 | #9 | `a4bfb59..c6fa646` | 352 | Four strict-concurrency errors in `TextCapture`, then `.swiftLanguageMode(.v6)` on all 11 targets. Per-call timeouts (10 / 30 / 120 s) replacing a shared 120. `os.Logger` on the four deliberately swallowed failures; `os` added to the closed whitelist with the rule that no user text may be logged. `TranslationOutcome.documentGlossaryFailure` so the engine reports without importing `os`. |
| 2 | #10 | `4f470af..27c8c86` | 354 | `CFBundleDevelopmentRegion = ru` plus `Resources/ru.lproj`, so the standard menus stop being English. A «Перевод» command menu owning ⌘↩, ⌘., ⌃⌘S, ⇧⌘C and ⌘0 — each declared once, the toolbar giving its two up. `pruneEmptyMenus()`. Reduce Transparency in the panel; a glyph beside every coloured status. |
| 3 | #11 | `4e91803..cbee1a1` | 364 | One `OllamaClient` instead of three plus one per download. Panel accessibility: an announcement on settle, `updatesFrequently`, a container label. `DroppedDocument` and a drop target on the source pane. GitHub Actions: build, a warning gate, tests. |
| Glossary | #12 | `b34974f`, `331ed0f` | 374 | `GlossaryColumn` — the pane's language column derived from the glossary's content. The audit report translated to English. |
| CI fallout | #13 | `c7cff78`, `5b8eb50` | 380 | The two defects CI's first run exposed. |

PR #13 exists because of a mistake, not a plan — see «Process failures».

---

## Where the audit was wrong

**Three of twenty-one findings did not survive contact with a measurement.** In each case the
report had reasoned correctly from the source and the source was not the whole story.

| Finding | What it claimed | What it turned out to be |
|---|---|---|
| **U6** | The settings panes' fixed `.frame(width: 560, height: 480)` clips content; replace it with minimums plus a `ScrollView`. | **Wrong, and the fix would have caused harm.** Control experiment: `.formStyle(.grouped)` installs an `NSScrollView` of its own at *any* content size, where a `VStack` and an unstyled `Form` install none. The panes already scroll. The recommended change would have brought back the window resizing between tabs that the frame exists to prevent, in exchange for nothing. `SettingsPane` is untouched and `CLAUDE.md` now says why it must stay so. |
| **U3** | Remove the empty «Вид» menu with `CommandGroup(replacing: .sidebar) { }`. | **Half wrong.** That empties the group and leaves the menu as a title with no items — worse than the one dead item it replaced. `pruneEmptyMenus()` in AppKit was needed. Measured on the way: the menu is fully built by the time the app's `.task` first runs, so the prune needs no sleep and has none; the removal sticks, with nothing back after 2.5 s. |
| **U4** | Cited `docs/reference/OPEN-ITEMS.md` §2 — «`entire contents` of the panel window is empty through System Events» — as evidence the panel exposes nothing to accessibility. | **The probe cannot see either state.** Walking the real `PanelController`'s tree gives `AXWindow → AXGroup`, no label, zero children — identically with the new modifiers and with them removed, checked both ways. SwiftUI does not materialise its accessibility tree until an assistive client attaches, and a test process is not one. The observation was never evidence about the panel; the `OPEN-ITEMS` entry is corrected. |

### What the audit missed entirely

| Found by | What |
|---|---|
| The `.v6` switch | A closure inside a computed property on a `View` inherits `@MainActor`. Swift 5 never checks it; Swift 6 checks it **at run time**, with a trap. The build stayed clean and the suite died with `signal code 5`, deterministic at 3 runs out of 3 against 0 out of 3 on `main`. |
| CI's first run | `LemmaMatcher.matches` documents `nil` as «cannot verify» and that branch was unreachable: `lemmas(of:)` substitutes the surface form, so the array is never empty. «This machine has no lemma data» reached `GlossaryVerifier` as a confident `.missing`. |
| Rendering to PNG | The glossary pane defaulted to `workingLanguage` while `targetLanguage(forDetected:)` sends everything foreign **into** `primaryLanguage` — so a default install writes `translations["ru"]` and the pane showed the `en` column, blank, with no indication why. |

---

## Over-claims

Claims made during this work that did not survive. All are the author's own; each is recorded
where it was made as well as here.

| Claim | Where | What it actually is |
|---|---|---|
| «`nonisolated(unsafe)` on a `static let` holding `kAXTrustedCheckOptionPrompt` fixes it.» | Audit, A3 | It does not. The diagnostic is about the *read*, so the error moves into the initialiser, and the compiler then also warns the annotation is pointless on a `Sendable` `String`. Four spellings were typechecked at `-swift-version 6`; only `@preconcurrency import` survived. |
| «`isolated deinit` is unavailable at the macOS 14 floor.» | First draft of the `HotkeyManager` comment | It compiles cleanly at `-target arm64-apple-macosx14.0`. It is declined on behaviour instead — it moves teardown onto the main actor, which is the race `OPEN-ITEMS` §3 already tracks. |
| «`qwen3:30b`'s 78 seconds of reasoning are a risk for a 30 s interactive timeout.» | Audit, A6 | Reasoning streams. Measured against a live Ollama with `qwen3:8b`, `keep_alive: 0`: 258 frames, first `thinking` at 2.12 s, first `content` at 7.12 s, **largest gap between frames 62 ms**. The timer counts silence and there is none. |
| «A second process registering the same hotkey will conflict, so the `.fault` log line can be observed that way.» | Install verification | It does not conflict. `RegisterEventHotKey` returns −9878 only within one process — which is exactly what the code comment already said, and the probe was designed against a premise the code had already refuted. |
| «Declaring `WarningsView` `nonisolated` (SE-0449) fixes the run-time trap.» | First attempt at the `.v6` fix | It stops the trap and strips isolation from `body`, where `.buttonStyle(.link)` is a main-actor static. Reverted. |
| «Reading the needle's lemma flag is enough.» | First version of the `LemmaMatcher` fix | It broke `aCoincidentalSubstringDoesNotForgiveARealViolation`: «ID» is an acronym with no lemma on a perfectly equipped machine, and treating that as «cannot verify» switched off a check that exists to catch a real violation. |

---

## Measurements

### Taken

| What | Number |
|---|---|
| Cold `swift build --build-tests` at the start | 0 warnings, 9.32 s |
| `-strict-concurrency=complete` at the start | 8 warnings, 0 errors — 6 in `Sources`, 2 in `Tests` |
| True `-swift-version 6` at the start | 4 errors, all in `TextCapture` |
| Ollama streaming, `qwen3:8b`, `keep_alive: 0` | 258 frames; `thinking` 2.12 s; `content` 7.12 s; largest inter-frame gap 62 ms |
| Menu localisation, one binary, three configurations | system default → English; `-AppleLanguages '(ru)'` with no bundle localisation → still English; `CFBundleDevelopmentRegion=ru` + `ru.lproj` → «Правка / Скопировать / Вставить / Завершить» |
| Empty `ru.lproj/Localizable.strings` | `NSLocalizedString` and `String(localized:)` return the key unchanged, including a key containing `%` |
| `NSScrollView` count in a 560 × 480 frame | plain `VStack` 0; `Form` default style 0; `Form(.grouped)` **1**, at one row and at forty alike; explicit `ScrollView` 1 |
| Settings pane document heights against a 480 pt frame | «Основные» 653 pt; «Модели» **1023 pt**; «Глоссарий» 546 pt — all scroll, none clips |
| Main window content at 900 × 520 | 467 pt — fits without scrolling |
| Panel sizes from the real `PanelSizer` | 326 × 120 empty hint; 347 × 120 running; 384 × 120 short result; 455 × 126 failure; 560 × 128 permission prompt; 560 × 323 long result with warnings |
| `ImageRenderer` and button styles | bare `Image` renders; default and `.plain` buttons render; **`.borderless` and `.link` rasterise as a placeholder** |
| Russian lemmatisation, macOS 26 vs the CI runner | 4 words out of 4 lemmatised here; **none** on `macos-15` |
| CI runner toolchain | Xcode 26.3, Swift 6.2.4 — new enough for `swift-tools-version: 6.0` and `.v6` |
| Frame rounding on the CI display | panel at y = 268.0 against `PanelPlacement`'s 268.5; a 409 pt panel against a 408.6 pt ceiling |
| Deterministic tie-break, mutated to `leaders.first` | caught **16 times out of 20** across fresh processes; the four escapes were not explained |
| Installed bundle | release, 1 994 560 bytes (release binary 1 987 872 + signature; debug would be 3 151 328) |

### Invalidated and re-taken

- **`OPEN-ITEMS` §2's «entire contents is empty through System Events».** Re-taken against the
  real `PanelController` with and without the new accessibility modifiers: identical both ways.
  It never distinguished «the panel exposes nothing» from «this probe sees nothing», and the
  entry now says so.

### Retired as unrepeatable, and deliberately not deleted

- **Nothing.** No measurement in the existing code was found unrepeatable during this work. The
  three that were re-taken (`constrainFrameRect`, `hosting.sizingOptions`, the panel width
  rule) were re-taken by earlier branches and their notes were left exactly as they stood.

---

## Rejected, and why

| Rejected | Why |
|---|---|
| `.frame(minWidth:idealHeight:)` + `ScrollView` in `SettingsPane` | The panes already scroll. The change would only have reintroduced the tab-to-tab resizing the fixed frame prevents. |
| `nonisolated struct WarningsView` (SE-0449) | Stops the run-time trap and breaks `body`, where `.buttonStyle(.link)` is main-actor isolated. The isolation is *true* of that type — every production caller is on the main actor — so the tests were what needed changing. |
| `CommandGroup(replacing: .sidebar) { }` to remove «Вид» | Empties the group, leaves the menu. |
| Rewriting the two Russian `.missing` checks as `!= .satisfied` | `.unverifiable` would then satisfy them everywhere, and nothing would notice the checker going quiet on a machine that *can* lemmatise. Gated on lemma availability instead. |
| `primaryLanguage` as a hardcoded glossary default | Mirrors the defect onto the user who writes Russian and translates to English. The column is derived from the glossary's content instead. |
| Adopting Liquid Glass | Every API is platform 26+; the floor is 14. The guidance context7 returns says not to convert existing UI without an explicit request. |
| Replacing `HSplitView` with `NavigationSplitView` | `HSplitView` is not deprecated and this window is a two-pane editor, not column navigation. |

---

## Deferred, with the reason

- **Services (`NSServices`), the second half of U7.** Not technical debt but a new product
  surface, and it turns on a decision the implementer cannot make: whether «Перевести Толмачом»
  replaces the selection in someone else's document or shows the panel. The first modifies a
  document this app does not own; the second duplicates the shortcut. Also unverifiable from
  here.
- **Observing the four `Log` call sites on the assembled bundle.** All four are failure paths.
  The app was installed and launched, Ollama was up, the hotkey registered — so nothing failed
  and the log is correctly empty. The one attempt to provoke a failure rested on a false premise
  (see «Over-claims»). Recorded in `OPEN-ITEMS` §1 with the predicate to watch.
- **The `maxHeightFraction = 0.6` threshold on an external 4K or a vertical display.** Unchanged
  and still unmeasured.

---

## Process failures

Four, recorded because each is cheap to repeat.

1. **Merging a stack too fast.** PRs #9–#12 were merged six seconds apart. GitHub had not yet
   retargeted each PR's base onto `main`, so only #9 landed there — #10 merged into `wave1`,
   #11 into `wave2`, #12 into `wave3`. All four reported «merged» and the content was intact,
   chained into `wave3`. Caught by the test count on `main` reading 352 where 380 was expected.
   Recovered with PR #13, after a trial merge confirmed the resulting tree was byte-identical
   to `wave3`'s. **Wait for the base to retarget before merging the next PR in a stack.**
2. **A `str.replace` whose anchor did not match.** Inserting a test helper silently did nothing
   because the anchor text was `/// Esc and Enter` where the file said `// MARK: - Esc and Enter`.
   Python's `replace` returns the string unchanged rather than raising. The `subs` list in the
   same script was asserted; the anchor was not. **Assert every anchor, not most of them.**
3. **A probe designed against a premise the code had already refuted.** The second-instance
   hotkey probe — see «Over-claims».
4. **A first fix that broke a passing test.** The `LemmaMatcher` needle-only flag. Caught
   immediately by the suite, which is the cheap kind, but it is the second time on this branch
   that the first attempt at a concurrency- or NaturalLanguage-adjacent fix was too broad.

---

## Hand checks performed

Everything below was actually run. Nothing here was seen on a screen by a human.

| Check | Result |
|---|---|
| Cold `swift build --build-tests` at every wave boundary | 0 errors, 0 warnings each time |
| `swift test`, 3–5 runs per wave | green; 352 → 354 → 364 → 374 → 380 |
| `-strict-concurrency=complete` on top of `.v6` | 0 warnings |
| Bisectability | the `.v6` commit and the one-client commit each build on their own |
| `Scripts/make-app-bundle.sh` | assembles and signs, seal valid, `ru.lproj` inside |
| Bundle localisation on the **assembled** bundle | `preferredLocalizations` `["en"]` → `["ru"]`, by swapping a probe binary into a copy of it |
| `translate-cli` against a live Ollama | «Сервер профилей хранит определения конечных точек», TTFT 2408 ms cold |
| Panel rendered to PNG, 9 states | the permission prompt does not truncate at 560 pt; the pinned button row survives a long result; both new status glyphs appear |
| Main window and settings rendered to PNG | the toolbar is absent from a `cacheDisplay` snapshot (window chrome, not `contentView`); the dark variant of the window could not be captured offscreen at all |
| Mutation testing | 5 mutations on the timeout table, 5 on `DroppedDocument` and the announcement, 6 on `GlossaryColumn`, 1 on the panel geometry tolerance — all killed except the tie-break, at 16/20 |
| Install to `/Applications` and launch | runs background-only from `/Applications`, signature valid at the new path, log subsystem silent |

`docs/reference/OPEN-ITEMS.md` §1 carries what a human still owes. It grew by twelve rows during this
work. The one that decides how much of wave 2 is visible rather than merely correct is whether
an `LSUIElement` app draws a menu bar at all.
