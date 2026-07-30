# Open items

What is unfinished, what a human still has to look at, and what is deliberately left alone.

This exists because the agent environment has **no GUI automation**: an agent can build the app,
launch it, read logs, drive Accessibility probes and enumerate windows, but it cannot see the
screen or press a physical key. Everything that can only be established by looking is listed
here rather than assumed.

Engine-level limitations are not repeated here — they are in §11a of the design spec, which
owns them.

Last reviewed against the code at commit `5a4d5f8`.

---

## 1. Owed to a human

Verified by a person during the Plan 3 acceptance pass and **not** re-checked since — the code
under them has not changed:

- Hotkey → capture → translation → panel, in a native app, a browser and an Electron app.
- Esc, Enter and ⌘. on the panel; «Скопировать»; the clipboard surviving the ⌘C fallback.
- The hotkey recorder, including ⌘W/⌘Q being captured rather than firing menu items, and a
  bare key being refused.
- Live re-registration after changing the shortcut.
- The permission prompt at first launch, in the panel, and as a standing indicator.
- All four settings tabs, and the main window end to end.
- The Accessibility grant surviving a rebuild under the stable signing identity.

**Not yet seen by anyone.** These changed after that pass and no one has looked at them:

| What to check | Why it needs eyes | Code |
|---|---|---|
| A finished translation with **no** warnings fills the panel | The empty warnings slot used to eat 86 of 260 pt; the fix gates the slot on `WarningsView.hasContent`, and only a screenshot confirms the nine lines came back | `PanelView.swift`, `WarningsView.swift` |
| «Открыть в окне» with a **finished** translation already in the window | The hand-off now moves `outcome`, `resolvedTarget` and `state` together; the failure it fixes was the window showing the previous run's elapsed time and warnings under the new text | `TranslationViewModel.adopt(from:)` |
| «Открыть в окне» while the window is **busy** | The button should be disabled with «Окно занято своим переводом» beneath it, and re-enable itself when the window finishes | `PanelView.swift`, `AdoptionRefusal` |
| The window and Settings actually coming **forward** | `NSApp.activate(ignoringOtherApps:)` does not activate on macOS 14; replaced with cooperative activation, which no one has watched work | `activateThisApp()` in `TranslatorApp.swift` |
| The permission row clearing after granting and returning | It is refreshed on `didBecomeActiveNotification`; the failure it fixes was telling the user their grant had not worked | `SettingsGeneralView.swift` |

**Owed by the UI redesign, Task 4 — the panel sized to its content.** The tests pin the
numbers the controller computes; none of them can say what the panel looks like. Task 14 is
where these are meant to be answered.

| What to check | Why it needs eyes | Code |
|---|---|---|
| ⌥⌘T on a one-word phrase, then on a long paragraph | The whole point of the task: two visibly different panel sizes, neither of them 380 × 260. The measurement is checked in the test process, but nothing here has seen it reach a real screen | `PanelController.measure`, `show(at:)` |
| Esc closes the panel, Enter copies and closes | `.titled` left the style mask, and without it a stock `NSPanel` answers `canBecomeKey == false` — measured. The override restores it and the test says the panel is key, but no one has pressed a physical key on the untitled panel | `TranslationPanel.canBecomeKey` |
| The corner nearest the pointer staying put while text streams | The reason the panel was fixed-size for so long. The frames are asserted; whether the already-read lines actually hold still is a thing you have to watch | `applyFit`, `PanelPlacement.reframe` |
| The rounded corners, with no grey notch behind them | `isOpaque = false` / `backgroundColor = .clear` / `hasShadow` are what make the material corner work, and a square window background showing through is invisible to every test | `TranslationPanel.init` |
| The panel not shivering while a run streams | Growth is deliberately unanimated during a run and animated once on the settle. Both the 100 ms throttle and the 150 ms tween are chosen against each other, and only watching a real stream says whether that was right | `contentDidChange`, `applyFit` |
| Dragging the panel's edge, then more text arriving | `.resizable` is new to the mask, and `windowDidEndLiveResize` is the only thing that sets `userSized`. Nothing in the suite performs a live resize, so the delegate hookup itself is unexercised | `PanelController.windowDidEndLiveResize` |
| A translation past the ceiling scrolling inside the panel | The scrolling variant is swapped in from the measurement. `PanelSizer` decides it and is tested; the swap reaching the screen is not | `setScrolling`, `PanelView.scrolls` |

---

## 2. Known and accepted

Deliberate, with the reason. Do not "fix" these without reading the reason first.

- **The panel is a fixed 380 × 260.** Nothing resizes it. A one-line result leaves the lower
  half empty; a long translation scrolls inside it. `PanelController.resize(to:)` existed,
  was never called, and was deleted rather than wired up. The reasoning and the measured
  ideal heights (97 pt short, 301 pt long) are in `TranslationPanel.init`'s doc comment.
  `NSHostingController.sizeThatFits(in:)` with an unbounded height proposal is the candidate
  measurement if this is revisited — `fittingSize` and `intrinsicContentSize` are both known
  useless here.
- **A refused `start()` at launch is swallowed.** If `HotkeyManager.register` ever fails the
  user gets no shortcut and no message. Unreachable today: `AppSettings.hotkey` guarantees a
  valid combination, and the only other failure is `-9878` for a combination another component
  of this process already holds — nothing else in this process registers one.
- **The panel exposes almost nothing to accessibility.** `entire contents` of the panel window
  is empty through System Events; VoiceOver on it is unexamined. The hotkey recorder, by
  contrast, does declare role, label and value.
- **The permission row lags a grant made without leaving the app.** It refreshes on appearance
  and on activation; TCC publishes no notification this app subscribes to, and polling a
  privileged call on a timer for a cosmetic gain was rejected.
- **There is one model picker, not two.** A «Модель для фонового перевода» control existed and
  did nothing — both surfaces build `ChatOptions` from `interactiveModel`. It and
  `AppSettings.backgroundModel` were removed rather than labelled, because a stored value that
  nothing reads is a defect a reader cannot see. `ModelRole.background` and
  `ModelPolicy.defaultModel(for: .background)` are kept: the two-path policy is §5 of the spec
  and the background path is batch translation in v2. Any value a user already stored stays in
  `UserDefaults`, unread. Found while correcting §5 against the code.
- **`swift run acceptance` is not in CI, deliberately.** It needs a live Ollama and a resident
  model. There is no CI at all for that reason.
- **Cosmetics on the Модели tab** — the `aya-expanse:8b` value wraps to three lines, and the
  settings window changes size between tabs.

---

## 3. Unresolved

Open questions, honestly labelled. None of these is known to be a defect; none is known not
to be.

- **Why the clipboard fallback also returned nothing when the panel was shown before the
  capture.** The Accessibility half is measured and understood — the panel becomes the key
  window and system-wide AX focus follows the key window, so `kAXSelectedTextAttribute`
  answers `-25205`. The ⌘C fallback failing in the same runs was never isolated. The obvious
  candidate is the synthetic ⌘C landing on the panel rather than on the source application.
  `HotkeyCoordinator.swift` records this as "a suspicion, not a finding" and it should keep
  that status until someone measures it.
- **The one-point band on a multi-monitor rig.** `PanelController.show(at:)` picks the screen
  with `NSScreen.screens.first { $0.frame.contains(cursor) }`. A cursor exactly on a shared
  edge can resolve to the wrong display. `NSMouseInRect` is the fix; it is unverifiable on a
  single-display machine and was therefore not applied blind.
- **A narrow off-main teardown race in `HotkeyManager`.** `Unmanaged.passUnretained` means the
  Carbon callback's pointer is non-owning, so a last release landing off the main actor could
  interleave with an executing handler. It needs an off-main release of a `@MainActor` object;
  the failure mode is a trap, not corruption. 300 dropped managers and 200 off-main releases
  did not reproduce it.
- **Whether the OS posts real hot-key presses into `GetMainEventQueue()`.** A background-posted
  event demonstrably drains on the main thread with the handler seeing `isMainThread`, which is
  what `MainActor.assumeIsolated` in the Carbon callback relies on. That the *OS* uses the same
  queue for a genuine press could not be established from a test process. If it does not, the
  failure is a loud trap rather than silent misbehaviour.

---

## 4. Housekeeping

`Scripts/make-app-bundle.sh` depends on a «LocalTranslator Dev» certificate in the login
keychain. If it is deleted the script silently falls back to ad-hoc signing, and the
Accessibility grant starts dying on every rebuild — which makes the whole hotkey path
unverifiable. The recipe for recreating it is in the script's own header.
