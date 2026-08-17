# Architecture and UI review

> **Status: all three waves are done.** `wave1/observability-and-swift6` (PR #9),
> `wave2/mac-idioms` (PR #10), `wave3/settings-a11y-and-ci` (PR #11) and
> `fix/glossary-language-default` (PR #12) — a stack, none of them merged.
>
> Closed: **A1, A2, A3, A4, A5, A6, A7/M1, M2, M5, M11** and **U1/M3, U2, U3/M4, U4, U5/M6,
> U8**, plus the drag & drop half of U7. **U6 is refuted** (below); Services from U7 are
> deferred, with a reason. Verified: cold `swift build --build-tests` — 0 errors, 0 warnings;
> `swift test` — 374 tests green on 3 runs out of 3; `-strict-concurrency=complete` — 0
> warnings; `translate-cli` end to end against a live Ollama; the localisation checked on the
> **assembled bundle**; the code signature intact.
>
> ### Three places where this report was wrong, and measurement is what showed it
>
> 1. **U6 is refuted outright.** It claimed the fixed `.frame(width:height:)` in the settings
>    clips content, and recommended replacing it with `minWidth/minHeight` plus a `ScrollView`.
>    Control experiment: `.formStyle(.grouped)` **installs an `NSScrollView` of its own** — at
>    any content size — where a `VStack` and an unstyled `Form` install none. The settings
>    already scroll. The recommended change would have brought back the window resizing between
>    tabs that the frame exists to prevent, in exchange for nothing. `SettingsPane` is untouched.
> 2. **U3 is partly wrong.** `CommandGroup(replacing: .sidebar) { }` does not remove the empty
>    «Вид» menu — the group is emptied but the title stays, which is worse than before.
>    `pruneEmptyMenus()` in AppKit was needed instead.
> 3. **U4 cannot be verified with the tool the project itself used.** `OPEN-ITEMS` §2 cited
>    «`entire contents` of the panel window is empty through System Events». Checked: walking
>    the tree gives `AXWindow → AXGroup`, no label, no children — **identically with the new
>    modifiers and with them removed**. SwiftUI does not materialise the tree until an assistive
>    client attaches. That observation was never evidence about the panel; the `OPEN-ITEMS`
>    entry is corrected.
>
> ### A finding that was not in the report at all
>
> **The glossary defaulted to the wrong column — U12.** Found by rendering rather than by
> reading: the settings pane, captured with four populated entries, showed a blank «перевод»
> field on every one. The cause is that `editingLanguage` took `settings.workingLanguage`
> (English), while `targetLanguage(forDetected:)` sends everything that is not in the user's own
> language **into** it — that is, into Russian. On a default install the glossary fills with
> `translations["ru"]` while the pane showed the `en` column. Nothing explained it: the language
> picker is `.labelsHidden()` and carries only a tooltip.
>
> Fixed by `GlossaryColumn` — the language is derived from the glossary's content rather than
> from a setting, so both directions of translation work. Branch
> `fix/glossary-language-default`.
>
> **Deferred with a reason:** Services from U7. Not technical debt but a new product surface,
> and it turns on a decision I cannot make: what «Перевести Толмачом» does with the result —
> returns a replacement for the selected text in someone else's document, or shows the panel.
> The first modifies a document this app does not own; the second duplicates the shortcut. There
> is also no way to verify it from here.
>
> **What turned up while fixing** (neither was in the report — the move to `.v6` surfaced both):
>
> 1. **A run-time trap in `WarningsView`.** A closure inside a computed property on a `View`
>    inherits `@MainActor`; Swift 5 does not check that, Swift 6 checks it **at run time** and
>    dies with `signal code 5`. The build stays clean. Deterministic at 3/3 against 0/3 on
>    `main`. Exactly the two tests that pass a non-empty `checks` died — an empty collection
>    hides the defect completely, because the closure never runs. Written up at the top of
>    [WarningsViewTests.swift](../../Tests/TranslatorAppTests/WarningsViewTests.swift).
> 2. **This report's own claim about `qwen3:30b` and the timeout, retracted by measurement.** I
>    recorded «does reasoning stream?» as a question in `OPEN-ITEMS`, then measured it against a
>    live Ollama: 258 frames, first `thinking` at 2.12 s, first `content` at 7.12 s, **largest
>    gap between frames 62 ms**. There is no silence — a reasoning model cannot trip the
>    timeout. The debt was removed from `OPEN-ITEMS` and the numbers moved into the comment on
>    [`OllamaClient.Timeout`](../../Sources/OllamaKit/OllamaClient.swift).
>
> Below is the original report as it was written, before any of the fixes.

---

An external, read-only audit of «Толмач». No source file was modified.

Identifiers, API names and paths are left as they are. Russian strings are quoted verbatim
where the string itself is the thing being discussed.

**The environment every measurement was taken in** (`sw_vers`, `xcodebuild -version`,
`swift --version`):

| | |
|---|---|
| macOS | 26.6 (25G72) |
| Xcode | 26.6 (17F113) |
| Swift toolchain | 6.3.3, target `arm64-apple-macosx26.0` |
| Project floor | macOS 14.0, `swift-tools-version: 6.0`, `.swiftLanguageMode(.v5)` ×11 |
| Code | 50 files / 6881 lines in `Sources`, 38 / 5847 in `Tests`, 347 `@Test` |
| Date | 2026-08-01, `main` @ `c25328f` |

**What was run** (with the owner's permission; both builds into isolated `--scratch-path`
directories, the working `.build` untouched):

| Run | Result |
|---|---|
| `swift build --build-tests`, cold | **0 warnings**, 9.32 s — the «zero warnings» rule holds |
| `swift build --build-tests -Xswiftc -strict-concurrency=complete`, cold | 8 warnings (6 in `Sources`, 2 in `Tests`), 0 errors, the build succeeds |

Beyond that, **four probes were written outside the repository** (in a scratchpad) to turn
guesses into measurements: the SwiftUI menu for this scene configuration, menu localisation
under three bundle configurations, the availability of the recommended accessibility APIs at the
macOS 14 floor, and the safety of adding `ru.lproj`. Their results are marked «measurement» in
the source column.

---

## 1. Executive summary

- **The layer boundary is real rather than declared.** `TranslationCore` imports nothing but
  Foundation and NaturalLanguage; `TextCapture` does not even depend on `TranslationCore`; the
  inversion goes through `LLMClient`. No view reaches directly into the network or the disk.
  Confirmed from the manifest and by reading, not taken on trust.
- **The project is already close to Swift 6.** Strict concurrency produces **six** sites in
  `Sources` — all in two `TextCapture` files and two calls around `NSPasteboard`. That is a
  day's work, not a migration.
- **The one critical hole in operability is the complete absence of logging.** Zero `os.Logger`
  anywhere in `Sources`, against four deliberately swallowed failures. A menu-bar app that stays
  resident for days has no way at all to report what went wrong on a user's machine.
- **The application menu exists and it is English.** Measured: SwiftUI installs a full main menu
  (`Правка` with ⌘C/⌘V/⌘Z, `Настройки… ⌘,`), but the bundle declares no localisation, so the
  menu stays English even on a Russian system. The fix is two keys in `Info.plist`, checked
  experimentally.
- **The comment at `TranslatorApp.swift:466` is refuted by measurement**: «there is no
  application menu, so the standard ⌘, does not exist» — the menu is there, and so is ⌘,. By
  `CLAUDE.md`'s own rules this is not a triviality: «measured» is a contract here.
- **Not a single `.commands` in the whole app.** Neither «Перевести», nor «Открыть окно», nor
  «Показать панель» reaches a menu; the `View` menu is installed and **empty**.
- **Accessibility is the weakest part of the UI.** Four explicit labels across 4421 lines of
  interface. Reduce Motion is honoured, **Reduce Transparency is not**, although the API is
  available at the macOS 14 floor (checked by compiling).
- **The Ollama client multiplies**: the comment at `TranslatorApp.swift:27` justifies sharing
  the client so as not to stand up a second `URLSession`, while the app stands up **three** at
  launch and one more per model download.
- **Security is clean on every axis that applies here**: no secrets, no keychain use (nothing to
  store), a single network address of `127.0.0.1:11434`, and ATS is empirically not in the way.
  There are no entitlements at all — which is right for an app that posts `CGEvent`s and reads
  system Accessibility, but is nowhere recorded as a decision.
- **The quality of the comments and tests is far enough above the norm to change the character
  of this audit.** `docs/reference/OPEN-ITEMS.md` already contains most of what an ordinary review would
  call findings. Below I separate what is new from what is already known — repeating the known
  would be noise.

---

## 2. Findings

Severity: **Critical** — breaks the user or their data; **High** — a real defect or a blocking
risk; **Medium** — noticeable but workable; **Low** — a triviality or documentation
correctness. Items marked **[style]** are preferences rather than defects; they are separated
into §3 and are not in the table.

### 2.1 Architecture

| ID | Area | Severity | Location | Problem | Recommendation | Source |
|---|---|---|---|---|---|---|
| A1 | Concurrency | High | [GeneralPasteboard.swift:63](../../Sources/TextCapture/GeneralPasteboard.swift#L63), [TranslationViewModel.swift:74](../../Sources/TranslatorApp/TranslationViewModel.swift#L74), [HotkeyCoordinator.swift:220](../../Sources/TranslatorApp/HotkeyCoordinator.swift#L220) | `NSPasteboard` is not `Sendable`, and `write(_:to:)` hands it to `Task.detached`. Three warnings, `#SendingRisksDataRace` / `#SendingClosureRisksDataRace`, which are errors in Swift 6 | Box the board in a `struct UncheckedBoard: @unchecked Sendable { let board: NSPasteboard }` inside `GeneralPasteboard` — the serialisation is already provided by `NSLock`, so `@unchecked` is honest here and the justification is already written in the type's doc comment | measurement (strict-concurrency build) |
| A2 | Concurrency | High | [HotkeyManager.swift:39-40](../../Sources/TextCapture/HotkeyManager.swift#L39) | `deinit` is nonisolated, and `EventHotKeyRef?`/`EventHandlerRef?` (`OpaquePointer`) are not `Sendable`. An error in Swift 6 | Declare both fields `nonisolated(unsafe) private var`. The comment already inside `deinit` («the Carbon calls are thread-agnostic») is the required justification | measurement |
| A3 | Concurrency | High | [PermissionsGate.swift:17](../../Sources/TextCapture/PermissionsGate.swift#L17) | `kAXTrustedCheckOptionPrompt` is imported as a mutable global → «not concurrency-safe» | Read the value once into `nonisolated(unsafe) private static let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String` | measurement |
| A4 | Observability | High | all of `Sources` | **Zero** `os.Logger`/`OSLog`. `print` exists only in `acceptance`. Meanwhile four paths swallow a failure deliberately: a refused `coordinator.start` ([TranslatorApp.swift:169](../../Sources/TranslatorApp/TranslatorApp.swift#L169)), a failed `warmUp()` ([:368](../../Sources/TranslatorApp/TranslatorApp.swift#L368)), a failed document glossary ([Translator.swift:225](../../Sources/TranslationCore/Translator.swift#L225)), and `try? JSONEncoder` ([AppSettings.swift:159](../../Sources/TranslatorApp/AppSettings.swift#L159)). Each is individually justified; together they make an app whose failures cannot be learned about at all | Introduce `Logger(subsystem: "com.mordvic.localtranslator", category: …)` and log exactly those four sites at `.error`/`.notice`. User-visible behaviour does not change — what changes is that `log show --predicate 'subsystem == …'` becomes possible | measurement (grep over `Sources`) |
| A5 | Network/IO | Medium | [OllamaStatusModel.swift:59](../../Sources/TranslatorApp/OllamaStatusModel.swift#L59), [ModelsViewModel.swift:50](../../Sources/TranslatorApp/ModelsViewModel.swift#L50), against [TranslatorApp.swift:27](../../Sources/TranslatorApp/TranslatorApp.swift#L27) | The comment justifies sharing `OllamaClient` on the grounds that it «holds the `URLSession`» and a second one need not be raised. In fact **three** are created at launch (`TranslatorApp`, the default `LiveOllamaProbe` in `OllamaStatusModel`, another in `ModelsViewModel`), and the default `puller` constructs an `OllamaClient()` **per** model download | Thread one `OllamaClient` from `TranslatorApp.init` into both view models, as is already done for `Translator`. Or drop the justification from the comment — as it stands it describes something that is not happening | reading + grep |
| A6 | Network/IO | Medium | [OllamaClient.swift:33](../../Sources/OllamaKit/OllamaClient.swift#L33) | `timeoutIntervalForRequest = 120` on every call, including the interactive hotkey translation whose stated target is TTFT < 1 s. The project's own comments ([TranslatorApp.swift:157](../../Sources/TranslatorApp/TranslatorApp.swift#L157), [:205](../../Sources/TranslatorApp/TranslatorApp.swift#L205)) treat those 120 s as a hazard — but only for launch ordering, not for the user-facing path | Split the configurations: a short timeout for the interactive `chat`, a long one for `pull`. As it stands a hung Ollama holds the panel for two minutes and the only way out is «Отмена» | reading |
| A7 | Build | Medium | [Package.swift:8-24](../../Package.swift#L8) | `.swiftLanguageMode(.v5)` on all 11 targets against a 6.3.3 toolchain. [Translator.swift:41-46](../../Sources/TranslationCore/Translator.swift#L41) already documents a consumer that would not compile without it | Switch to `.v6` after A1–A3. Measured: with `-strict-concurrency=complete` the build succeeds with 8 warnings and **zero errors**, so the path to `.v6` is short | measurement |
| A8 | Security | Medium | no `*.entitlements` file; [make-app-bundle.sh](../../Scripts/make-app-bundle.sh) | No App Sandbox, no Hardened Runtime, no `--options runtime`. For an app that posts `CGEvent`s through `.cghidEventTap` and reads system AX this is **right** — a sandbox would forbid both — but it is nowhere recorded as a decision with a reason | Add an ADR (`docs/adr/` already holds seven): «why there is no sandbox and no hardened runtime». Otherwise the next person will try to «bring it up to best practice» and break the capture | reading |
| A9 | Testability | Low | [ModelsViewModel.swift:50](../../Sources/TranslatorApp/ModelsViewModel.swift#L50) | The default `puller` constructs a client inside a closure — the one dependency in the app that is not created in `init` and so cannot be substituted with a single argument | Reduce it to `probe`-shaped injection. The tests already substitute it, so this is DI cosmetics rather than a hole | reading |
| A10 | Security | — | the whole repository | **No findings.** No secrets (grep over `git ls-files`), no keychain (nothing to store), a single network host of `http://127.0.0.1:11434` ([OllamaClient.swift:25](../../Sources/OllamaKit/OllamaClient.swift#L25)). No ATS exception is needed or declared — loopback works empirically (the project runs `acceptance` against a live Ollama) | — | measurement (grep) |

### 2.2 UI / UX

| ID | Area | Severity | Location | Problem | Recommendation | Source |
|---|---|---|---|---|---|---|
| U1 | Localisation | High | [Info.plist](../../Sources/TranslatorApp/Info.plist) | The bundle declares no localisation, so `Bundle.main.preferredLocalizations == ["en"]`. The main menu SwiftUI installs stays English **even on a Russian system** — measured by forcing `-AppleLanguages '(ru)'`: `Edit / Copy / Paste / Quit`. This is also why [SettingsModelsView.swift:192](../../Sources/TranslatorApp/SettingsModelsView.swift#L192) and [RussianCopy.swift:189](../../Sources/TranslatorApp/RussianCopy.swift#L189) are forced to pin `Locale(identifier: "ru_RU")` by hand | Add `CFBundleDevelopmentRegion` = `ru` to `Info.plist` and place an empty `Contents/Resources/ru.lproj/`. **Checked on the same binary**: the menu becomes «Правка / Скопировать / Вставить / Завершить» and `preferredLocalizations` becomes `["ru"]`. `make-app-bundle.sh` must copy `ru.lproj` in **before** `codesign`, for the same reason it does that with the icon (see the script's comment about the seal) | measurement (probe, 3 configurations) |
| U2 | Documentation correctness | Medium | [TranslatorApp.swift:466-467](../../Sources/TranslatorApp/TranslatorApp.swift#L466) | The comment says «There is no application menu in an `LSUIElement` app, so the standard ⌘, does not exist». Measured on a copy of this same scene configuration: the application menu **is** in `NSApp.mainMenu` and carries `Settings…` with ⌘,. The conclusion (use `SettingsLink`) still holds; the premise does not | Rewrite the justification. By `CLAUDE.md` («„measured" is a contract, not emphasis») a false premise in a comment costs more than a missing comment | measurement |
| U3 | Mac idioms | Medium | all of `Sources` (grep: zero `commands`/`CommandGroup`/`CommandMenu`) | Not one menu command. «Перевести» ⌘↩ and «Отмена» ⌘. live only as `.keyboardShortcut` on toolbar buttons — they work, but they are undiscoverable and do not exist while the window is closed. The `View` menu is installed by the system and **empty** | Add `.commands { }` to the `Window` scene: a `CommandMenu("Перевод")` with «Перевести» / «Отмена» / «Поменять языки местами» / «Скопировать перевод», a `CommandGroup(replacing: .help)` with something meaningful, and `CommandGroup(replacing: .sidebar) { }` to remove the empty `View`. Key equivalents are dispatched through `NSApp.mainMenu` anyway, so this is a clean gain | context7 `/websites/developer_apple_swiftui` → `building-and-customizing-the-menu-bar-with-swiftui`; the empty `View` is a measurement |
| U4 | Accessibility | High | 4 labels across 4421 lines: [TranslatorApp.swift:98](../../Sources/TranslatorApp/TranslatorApp.swift#L98), [PanelView.swift:135](../../Sources/TranslatorApp/PanelView.swift#L135), [RunStatusBar.swift:35](../../Sources/TranslatorApp/RunStatusBar.swift#L35), [HotkeyRecorder.swift:90-93](../../Sources/TranslatorApp/HotkeyRecorder.swift#L90) | The panel tells VoiceOver neither the direction of the translation nor that it has finished. Already recorded in `docs/reference/OPEN-ITEMS.md` §2 as «known and accepted» | **Move it from «accepted» to «planned».** At minimum: an `accessibilityLabel` on `Text(model.translatedText)`, `accessibilityAddTraits(.updatesFrequently)` on the same while streaming, and an announcement of the result on settling. It is not much work, and the panel is the product's main surface | reading + `OPEN-ITEMS.md` §2 |
| U5 | Accessibility | Medium | [PanelView.swift:64](../../Sources/TranslatorApp/PanelView.swift#L64), [SourcePane.swift:89](../../Sources/TranslatorApp/SourcePane.swift#L89), [RunStatusBar.swift:69](../../Sources/TranslatorApp/RunStatusBar.swift#L69) | Reduce Motion is honoured ([TranslationPanel.swift:420](../../Sources/TranslatorApp/TranslationPanel.swift#L420)), **Reduce Transparency is not**. `.regularMaterial` and `.quaternary.opacity(0.25)` draw identically with «Reduce transparency» switched on | Checked by compiling at the macOS 14 floor that both `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` and `@Environment(\.accessibilityReduceTransparency)` are available. Swap `.regularMaterial` for an opaque `Color(nsColor: .windowBackgroundColor)` when the flag is on. Symmetrical with what is already done for Reduce Motion | measurement (compile probe) |
| U6 | Layout | Medium | [SettingsPane.swift:18](../../Sources/TranslatorApp/SettingsPane.swift#L18) | `.frame(width: 560, height: 480)` — a fixed frame with no `ScrollView`. Content that does not fit is clipped rather than scrolled. `OPEN-ITEMS.md` §1 records that two panes grew sections **after** the height was fixed, and that nobody has looked at it | `.frame(minWidth: 560, idealHeight: 480)` plus a `ScrollView` inside the modifier. But: the frame exists precisely so the window does not jump between tabs ([SettingsPane.swift:6-8](../../Sources/TranslatorApp/SettingsPane.swift#L6)) — minimum width and height preserve that invariant while removing the clipping | reading + `OPEN-ITEMS.md` §1 |
| U7 | Mac idioms | Medium | all of `Sources` (grep: zero `onDrop`/`dropDestination`/`draggable`/`contextMenu`) | The translator window does not accept a dropped `.txt`/`.md`; the source pane has no context menu; the app provides no **Service** at all — although it is a textbook candidate («Перевести Толмачом» in any app's Services menu), and the `Services` submenu is already present in `NSApp.mainMenu` (measured) | In order of payoff: (1) `.dropDestination(for: URL.self)` on `SourcePane`; (2) `NSServices` in `Info.plist` plus a service provider — literally a second way into the product, cheaper than it looks; (3) `.contextMenu` on both panes | measurement (grep + menu probe) |
| U8 | Accessibility | Low | [PanelView.swift:299-304](../../Sources/TranslatorApp/PanelView.swift#L299) | The panel's status («interrupted» / «failed») is distinguished by **colour alone** — `.orange` against `.red`, with no glyph. Everywhere else colour is always paired with an SF Symbol ([SettingsGeneralView.swift:42/45](../../Sources/TranslatorApp/SettingsGeneralView.swift#L42), [SettingsModelsView.swift:34](../../Sources/TranslatorApp/SettingsModelsView.swift#L34)), so this is the single exception | Add an icon to `statusLine`, as `SettingsNote` does. It also closes Differentiate Without Color | reading |
| U9 | State restoration | Low | no `defaultSize`/`windowResizability`/`defaultPosition`/`restorationBehavior` | `Window` is a singleton scene and AppKit saves its size and position itself; the content (`sourceText`) is not restored | For a translator, not restoring the text is arguably right. Noted for completeness; no action needed | grep |
| U10 | Localisation/RTL | — | — | **Not a finding.** RTL does not apply: `Language` lists ru/en/de/fr/es/pt/it/zh/ja — no RTL language among them. The absence of `.xcstrings` is a decision recorded in `CLAUDE.md`, not an omission | — | reading |
| U11 | Layout | — | [PanelView.swift:168](../../Sources/TranslatorApp/PanelView.swift#L168), [:200](../../Sources/TranslatorApp/PanelView.swift#L200), [:268](../../Sources/TranslatorApp/PanelView.swift#L268), [:290](../../Sources/TranslatorApp/PanelView.swift#L290), [SettingsGeneralView.swift:57](../../Sources/TranslatorApp/SettingsGeneralView.swift#L57), [RunStatusBar.swift:101](../../Sources/TranslatorApp/RunStatusBar.swift#L101) | **A positive finding.** Robustness against long text is worked out better than the norm: every `fixedSize(horizontal: false, vertical: true)` carries a measured example of the truncation it prevents | Leave alone | reading |

### 2.3 What the audit checked and found **no** defect in

Recorded separately, because mistakenly «modernising» these would cost more than leaving them
out of the report.

| What | Verdict | Source |
|---|---|---|
| `HSplitView` rather than `NavigationSplitView` ([MainWindowView.swift:30](../../Sources/TranslatorApp/MainWindowView.swift#L30)) | **Correct.** `HSplitView` is macOS 10.15+ and not deprecated. `NavigationSplitView` is for column *navigation* (sidebar → detail); this window is a two-pane editor, not navigation | context7 `/websites/developer_apple_swiftui` → `hsplitview`, `bringing-robust-navigation-structure-to-your-swiftui-app` |
| ⌘C/⌘V/⌘Z/⌘A in the source pane's `TextEditor` | **They work.** SwiftUI installs a full `Edit` menu with `undo:`/`cut:`/`copy:`/`paste:`/`selectAll:` for this scene configuration, and key equivalents are dispatched through `NSApp.mainMenu` regardless of whether the menu bar is drawn | measurement (menu probe) |
| `@Observable` plus hand-written `access`/`withMutation` in `AppSettings` | **Correct and necessary.** The properties are computed over `UserDefaults`, so `@Observable`'s synthesis does not apply to them. The `@ObservationIgnored @AppStorage` alternative would lose the main property — picking up a value changed by `defaults write` | reading + context7 `/avdlee/swiftui-agent-skill` → `state-management.md` |
| Two `TranslationViewModel`s | **Correct**, ADR 0004 plus [HotkeyCoordinator.swift:38-43](../../Sources/TranslatorApp/HotkeyCoordinator.swift#L38) | reading |
| No retry/backoff | **Correct** for a local server: «Повторить» on the panel and in the status bar is the retry, initiated by the user | reading |
| Secrets, keychain, ATS | Clean (see A10) | measurement |
| Files over 400 lines | Only two: [TranslatorApp.swift](../../Sources/TranslatorApp/TranslatorApp.swift) (515) and [TranslationPanel.swift](../../Sources/TranslatorApp/TranslationPanel.swift) (522). Both are cohesive — a whole scene and a whole panel; there are no God objects | measurement |
| Duplicated logic | None found. The copy paths are unified in `GeneralPasteboard.write`; the warning count lives in the single `WarningsView.warningCount`, which `RunStatusBar.summary` also reads | reading |

---

## 3. Style preferences (not defects)

Separated at the owner's request. I recommend changing none of these without a separate
decision.

- **Liquid Glass is not adopted.** Every API (`glassEffect`, `GlassEffectContainer`) requires
  platform 26+, and the floor is 14. The guidance context7 returns says outright not to convert
  existing UI to Liquid Glass without an explicit request. The panel already uses
  `.regularMaterial`, which is the documented fallback. Source: context7
  `/avdlee/swiftui-agent-skill` → `references/liquid-glass.md`.
- **Comment density.** The comment-to-code ratio in `TranslatorApp` is noticeably above normal.
  That is a deliberate `CLAUDE.md` policy and it pays off: half the findings in this audit were
  found *because* a comment named a measurement that could be re-checked.
- **`AnyView` in `PanelController`** ([TranslationPanel.swift:237](../../Sources/TranslatorApp/TranslationPanel.swift#L237)) —
  type erasure costs performance, but two different builds of one content are needed here, and
  threading a generic parameter through `NSHostingController` into two properties does not work
  without more complexity than it saves.
- **No CI.** Recorded in `OPEN-ITEMS.md` §2 with a reason (`acceptance` needs a live Ollama). I
  only note that `swift test` and `swift build --build-tests` are *entirely offline* — 0
  warnings, 9 seconds — and would be enough for GitHub Actions on their own, without touching
  `acceptance`.
- **`prototype-translation-engine/`** contains only `.build/` and `.swiftpm/` — the sources are
  deleted and ignored leftovers remain, which is why `git status` looks clean. Cosmetic.

---

## 4. Modernisation: old pattern → current

| # | From | To | Effort | Blast radius | Blockers |
|---|---|---|---|---|---|
| M1 | `.swiftLanguageMode(.v5)` ×11 | `.v6` | **M** | All 11 targets in `Package.swift`; behaviour does not change | A1–A3 first. Measured: 8 warnings, 0 errors — so after three fixes, 2 remain in the tests |
| M2 | `NSPasteboard` in `Task.detached` | An `@unchecked Sendable` box inside `GeneralPasteboard` | **S** | `TextCapture/GeneralPasteboard.swift` plus 2 call sites; `PasteboardSnapshot` untouched | none |
| M3 | no bundle localisation | `CFBundleDevelopmentRegion=ru` + `ru.lproj/` | **S** | `Info.plist`, `Scripts/make-app-bundle.sh` (copy before `codesign`). **Verified by measurement: an empty `ru.lproj/Localizable.strings` does not break the Russian literals** — `NSLocalizedString`/`String(localized:)` return the key unchanged, including a key containing a `%` | none |
| M4 | no `.commands` | `CommandMenu("Перевод")` + `CommandGroup(replacing: .sidebar) { }` | **S** | `TranslatorApp.swift`, the `Window` scene. Risk: `CommandGroup(replacing:)` may disturb menu order — checkable with the same probe | none |
| M5 | no logging | `os.Logger` on the 4 swallowing paths | **M** | Cross-cutting but purely additive — no branch of behaviour changes | none |
| M6 | no Reduce Transparency | `@Environment(\.accessibilityReduceTransparency)` | **S** | `PanelView`, `SourcePane`, `RunStatusBar`. API checked by compiling at the 14 floor | none |
| M7 | `.frame(width:height:)` in the settings | `.frame(minWidth:idealHeight:)` + `ScrollView` | **S** | `SettingsPane.swift` plus 3 panes. **Regression risk**: the frame exists so the window does not jump between tabs — all three tabs need a manual pass | none |
| M8 | `withObservationTracking` re-arming itself ([TranslatorApp.swift:233](../../Sources/TranslatorApp/TranslatorApp.swift#L233)) | `Observations` (AsyncSequence) | **S** | One function | **Blocked**: `Observations` is macOS 26 and the floor is 14. The comment in the code already knows this and names it correctly |
| M9 | scene order as a load-bearing invariant | `Scene.defaultLaunchBehavior(.suppressed)` on `Window` | **S** | Removes the most fragile constraint in the whole app layer | **Blocked**: macOS 15+. The comment in the code already knows this |
| M10 | no Services / drag & drop | `NSServices` + `.dropDestination` | **L** | A new entry surface: `Info.plist`, a service provider, `SourcePane`. Needs its own design and a manual pass | none, but this is a feature rather than a migration |
| M11 | no CI | GitHub Actions on `swift build --build-tests` + `swift test` | **S** | A new file, touches no code. `acceptance` stays out of CI, as recorded | none |

Estimates: **S** — half a day or less, **M** — 1–2 days, **L** — a week plus its own design.

---

## 5. Prioritised roadmap

### Wave 1 — «make failures visible» (≈ 2–3 days)

Everything standing between you and the ability to learn that something does not work for a
user.

1. **A4 / M5 — `os.Logger` on the four swallowing paths.** First, because every other finding
   is easier to diagnose once it exists. Today a refused hotkey registration — the complete loss
   of the only entry point into the product — leaves no trace at all.
2. **A1–A3 / M1–M2 — the six strict-concurrency sites, then `.v6`.** Exactly six, all local, and
   the compiler has already listed them. The longer this waits the more it costs: every new line
   is written against `.v5` and accumulates debt.
3. **A6 — the interactive path's timeout.** A cheap change with a direct user-visible effect: a
   hung Ollama currently holds the panel for two minutes.

### Wave 2 — «make the app feel like a Mac app» (≈ 3–4 days)

The best return per unit of effort in this report.

4. **U1 / M3 — bundle localisation.** Two keys, with a verified effect: the menu stops being an
   English island in a Russian app. As a side effect it removes the need to pin `ru_RU` by hand
   in two places.
5. **U3 / M4 — `.commands`.** The empty `View` menu goes, and «Перевести» and «Отмена» become
   discoverable and keep working while the window is closed.
6. **U2 — fix the refuted comment.** Five minutes, but by the project's own rules it is an
   obligation: a measurement refuted the premise.
7. **U5 / M6 + U8 — Reduce Transparency and an icon in the panel's status row.** Symmetrical
   with what is already done for Reduce Motion.

### Wave 3 — «raise the ceiling» (as decided)

8. **U4 — panel accessibility.** The largest remaining gap. It needs a manual VoiceOver pass
   that a human has to do anyway, which is why it sits in the third wave rather than earlier.
9. **U6 / M7 — scrolling in the settings.** Needs a manual pass over all three tabs; connected
   to an `OPEN-ITEMS.md` §1 item that is already waiting for a human.
10. **A5 — reduce to one `URLSession`.** Or drop the justification from the comment.
11. **M11 — offline CI.** Cheap, and it protects the «zero warnings» rule that currently rests
    on discipline alone.
12. **U7 / M10 — Services and drag & drop.** A product decision, not technical debt.

**Explicitly not recommended:** moving to Liquid Glass, replacing `HSplitView`, or raising the
floor to macOS 15/26 for the sake of M8–M9. The macOS 14 floor is a deliberate constraint; M8
and M9 are worth keeping as recorded wins for the day the floor rises for another reason.

---

## 6. Unverified / needs discussion

Labelled honestly: none of this is an established defect, and none of it is established as safe.

1. **Whether an `LSUIElement` app draws a menu bar at all.** It is measured that the menu is
   *installed* in `NSApp.mainMenu` and that its key equivalents work. It is **not** measured
   whether it is drawn on screen when the app activates — this environment cannot see that. The
   answer decides the severity of U1 and U3: if the menu is never visible, U1 is about
   `preferredLocalizations` and number formatting (real, but smaller) and U3 is about
   discoverability (also smaller). **This is the first question worth closing by a human at a
   screen.**
2. **The menu probe reproduces the scene configuration, not the bundle itself.** `MenuBarExtra`
   → `Window` → `Settings`, with the `LSUIElement`-equivalent `.accessory` policy. Agreement
   with the real `LocalTranslator.app` is likely but unchecked.
3. **context7 returns the Liquid Glass documentation in iOS 26 wording.** macOS specifics
   (panels, toolbars, `NSGlassEffectView`) were not fetched. Immaterial for the «do not adopt»
   recommendation; needed for the opposite decision.
4. **The run-time semantics of `@Environment(\.accessibilityReduceTransparency)` on macOS.** It
   compiles at the 14 floor (measured); that it follows the system «Reduce transparency» toggle
   specifically, rather than something else, was not cross-checked against
   `NSWorkspace.accessibilityDisplayShouldReduceTransparency`. Both flags returned `false` on
   this machine, so the two cannot be told apart right now.
5. **The whole of `docs/reference/OPEN-ITEMS.md` §1** — thirty-odd items waiting for a human at a screen.
   This audit neither duplicates nor closes them. I note only that the item about a **possible
   `.task { await launch() }` loop** (`OPEN-ITEMS.md` §1, Task 13) is the one on the list whose
   realisation would not be cosmetic: a re-triggered `launch()` re-registers the hotkey and
   re-awaits `warmUp()`. It is checkable with a single log line (A4/M5) — one more argument for
   putting logging first.
6. **The `maxHeightFraction = 0.6` threshold** ([PanelSizer.swift:25](../../Sources/TranslatorApp/PanelSizer.swift#L25))
   and the 300–560 pt widths are derived from measurements on particular displays. Nobody has
   measured the behaviour on an external 4K or a vertical monitor.
7. **The open question in `OPEN-ITEMS.md` §3 about `NSMouseInRect`** for screen selection
   ([TranslationPanel.swift:324](../../Sources/TranslatorApp/TranslationPanel.swift#L324)) — I
   confirm it as real, and cannot confirm it myself: it needs a multi-monitor setup.
8. **Whether U7 (Services) should be adopted at all.** That is a product extension rather than
   debt repayment. The owner's decision; the technical cost is low, and a second entry point for
   a translator is a strong argument.
