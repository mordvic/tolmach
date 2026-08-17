# A shortcut of its own for правка — design

Date: 2026-08-15
Status: designed, not implemented

## Status of this document

This is the pre-implementation design for a second system-wide shortcut: one that captures
the selection and **proofreads** it, where ⌥⌘T captures and translates. Once the code
exists, **the code is the authority on behaviour and this document is the authority on
why**.

A claim marked **measured** restates an observation already recorded in the code or in
`docs/`; the citation says where. Everything marked «to be measured» in §8 is exactly that —
it is not a claim, and nothing in the implementation may rest on a guessed answer to it.

This document supersedes one paragraph of
`docs/design/specs/2026-08-10-proofreading-design.md` §8 — «A press of ⌥⌘T behaves
exactly as today: capture → перевод» — and only that paragraph. That spec's reasoning about
*why* the press must be predictable is kept and restated in §4 below; what changes is that
predictability now means «each shortcut has one operation», not «the only shortcut is
перевод». The same spec §8 also predicted this change: «if panel-правка earns traction,
per-panel степень/стиль controls are the expected first ask». They are §6.

## 1. The problem this solves

Правка exists as an engine route (`Translator.proofread`) and on two surfaces: the window's
toolbar switch, and the panel's «Перевод | Правка» segment. What has no route at all is the
thing the panel exists for — select text in another application and act on it — because
`HotkeyCoordinator.handlePress` forces every press to перевод:

```swift
// Every press starts with перевод, whatever the previous presentation's switch
// said: the hotkey is predictable, the switch is per-presentation (spec §8).
panelModel.operation = .translate
```

So proofreading a selection costs the user a translation nobody asked for — waited out or
cancelled with ⌘. — and then a **mouse** click on the segment, because that segment carries
no key equivalent and the panel is a `.nonactivatingPanel` with no menu of its own. The
second run is the one the user wanted; the first is pure waste of the interactive model.

## 2. What the user gets

- A second shortcut, **⌥⌘R** out of the box, configurable. It captures the selection exactly
  as ⌥⌘T does and opens the same panel already performing правка.
- Степень and стиль pickers in the panel, so the operation is adjustable where it is used.
  Their values **persist into the settings** — see §6.
- Everything else about the panel is unchanged: ⏎ copies and closes, Esc cancels and hides,
  «Открыть в окне» hands the whole run over, «Ещё вариант» appears under its existing
  condition.

Explicitly **not** in scope: writing the corrected text back into the other application.
The panel shows the result and offers «Скопировать»; nothing in this app writes into another
application's window, and this change does not open that door.

## 3. Settings

`AppSettings` gains `proofreadHotkey: HotkeyCombo`, shaped exactly like `hotkey`: stored as
JSON under a single key (`"proofreadHotkey"`), `isValid` checked on the way out as well as in,
read and written through `UserDefaults` directly with hand-written `access(keyPath:)` /
`withMutation(keyPath:_:)`.

Its factory value is ⌥⌘R (`kVK_ANSI_R`, `[.option, .command]`), subject to §8.3.

One difference from `hotkey` must be written at the property, because the reasoning there
does not transfer: `hotkey`'s doc comment argues that an unreadable value falls back to the
default rather than to «no hotkey», since «the hotkey is the only way in to the panel». That
door is held open by `hotkey` whatever this property does. The fallback is kept anyway — a
shortcut that silently disappears because of a typo in a plist is bad in either case — but
the reason is «a setting the user cannot see the state of is worse than a wrong one», not
«otherwise the app is unreachable».

**The settings pane** («Основные» → «Сочетание клавиш») grows from one recorder to two,
labelled «Перевод» and «Правка». The existing caption gains one sentence: the two
combinations must differ.

## 4. The coordinator

One `HotkeyCoordinator`, two `HotkeyManager`s, keyed by `TextOperation`.

- `start(onPress:)` takes `@escaping @MainActor (TextOperation) -> Void` and registers both.
- `apply(_:)` and its restore-on-refusal become per-operation. That restore is load-bearing
  and its comment must survive the move: `HotkeyManager.register` tears the live
  registration down *before* it learns whether the new combination is acceptable, so a
  refusal otherwise leaves the user with no shortcut rather than the old one.
- `registeredCombo` becomes `registeredCombo(for:)`.
- `refreshRegistration()` checks both against their settings; each is a no-op when unchanged.
- `stop()` unregisters both and drops both stored actions.
- `handlePress(operation: TextOperation = .translate, willCapture:afterCapture:)` assigns
  `panelModel.operation = operation` where the line quoted in §1 stood. The default argument
  is not decoration: it keeps the twenty existing calls in `HotkeyCoordinatorTests` meaning
  what they already mean.

**Why not two coordinators.** `HotkeyCoordinator` owns `panelModel`; a second one is a second
panel and a second `TranslationViewModel`. CLAUDE.md's rule that the app's three models must
not be merged reads in this direction too — they must not be multiplied either.

**Why not one manager holding several registrations.** That edit lands in `TextCapture`,
where Carbon, `nonisolated(unsafe)` and the C event callback live, to buy nothing: the
callback already compares `signature` and `hotKeyID`, and its comment records — measured —
that a second `HotkeyManager` in the same process installs a second handler on the same
dispatcher target and that every handler there is offered every hot-key event. Two managers
is the arrangement that code was already written for.

**The re-entrancy guard is unchanged and now covers more.** `isCapturing` is per coordinator,
so «⌥⌘T, then ⌥⌘R before the first read returns» is dropped by the same guard that already
drops a double ⌥⌘T — which is what keeps two synthetic ⌘C fallbacks from racing over one
pasteboard.

`TranslatorApp.launch()` passes a closure that closes over the operation;
`observeHotkeyChanges()` observes both properties.

## 5. One press, end to end

The path does not fork. ⌥⌘R enters the same `handlePress` with the same hooks and the same
measured order — hide the previous panel, read the selection off the main actor, show the
panel, run — and differs by the one assignment in §4.

Everything downstream already exists: `runTranslation()` is shared, so `autoCopy` applies to
a finished правка as it does to a translation; `RussianCopy.proofreadHeader` gives «правка ·
русский»; the status rows «Исправляю…» and «Правка готова» are written;
`PanelView.announcement(for:operation:)` knows both operations; `TranslationViewModel.run()`
already dispatches on `operation`.

The «Перевод | Правка» segment stays. A press of ⌥⌘R followed by «Перевод» translates the
**already captured** selection — `switchOperation(to:)`, unchanged, including its refusal to
read a new one.

`Toggle("Копировать перевод по сочетанию клавиш")` in «Основные» becomes «Копировать
результат по сочетанию клавиш»: the setting is read only by `HotkeyCoordinator.runTranslation`
and now governs two operations, and the label promised one.

## 6. The panel's степень and стиль

A pinned row directly under the header, drawn only when `model.operation == .proofread` — and
therefore only inside the `if case .text = selection` branch, so the permission prompt and
the «выделите текст» hint gain nothing.

    ┌───────────────────────────────────────┐
    │ правка · русский   [Перевод|Правка]  ⨯ │
    │ [только ошибки ▾]  [как в оригинале ▾] │
    ├───────────────────────────────────────┤
    │ Исправленный текст…                    │
    ├───────────────────────────────────────┤
    │ Правка готова · 1,2 с                  │
    │      [Скопировать]  [Открыть в окне]   │
    └───────────────────────────────────────┘

Two menu pickers, `.controlSize(.mini)`, both with accessibility labels, both disabled while
a run is in flight — the same condition the operation segment already carries. The style
picker is additionally disabled when the степень does not allow a style, read from
`ProofreadingLevel.allowsRewriteStyle` rather than restated: one rule, three surfaces
(toolbar, settings, panel).

**Pinned, not scrolling**, for the reason the header is: the panel's middle region is where
the reply and the warnings grow, and a control that scrolls away with them is a control the
user cannot reach at the moment they want it.

**The operation must be assigned before `afterCapture()`, which is where the panel is
measured.** Added after review: with the assignment where §5's description put it — after the
hooks, beside `sourceText` — the row was measured against the *previous* press's operation, so
a перевод press following a правка one kept the row's space for the whole presentation (the
height is monotonic within one) and a правка press following a перевод one opened without the
row and grew into it. That growth is «кнопки прыгают», which the reservation exists to remove.
The assignment is safe there because it is neither `state` nor `translatedText` — the two
writes `handlePress`'s own comment forbids before the hooks.

**The values are the settings, not per-run overrides.** The pickers write
`AppSettings.defaultProofreadingLevel` and `AppSettings.defaultRewriteStyle`. The panel's own
model never sets `proofreadingLevelOverride` or `rewriteStyleOverride` — they stay `nil`
there, so `proofread()`'s existing `override ?? setting` resolution reads the setting; the
overrides keep their single meaning, which is «the window's toolbar was used for this run».
Three things follow and are accepted deliberately:

- The choice survives the panel closing, which is the point: a user who always proofreads
  with style sets it once, in the place they use it, instead of opening Settings.
- The window, when it carries no override of its own, follows what was chosen in the panel.
- Nothing needs resetting between presses. §4's «each shortcut has one operation» stays true
  without a second rule about degrees.

**The panel stays a readout.** The pickers call back to `HotkeyCoordinator`, which writes the
setting and re-runs the already-captured selection under `switchOperation(to:)`'s guards —
a captured `.text`, no run in flight, and a value that actually changed.

A consequence worth naming: «Ещё вариант» is offered only for a finished правка at «ошибки и
стиль», and until now that степень was reachable only through Settings. With the picker in
the panel the button stops being theoretical.

## 7. Refusals and edges

| Situation | Behaviour |
|---|---|
| The user records a combination already used by the other shortcut | Refused in `HotkeyRecorder` with a beep, the recorder stays armed, the stored value is untouched. This is the recorder's existing pattern for an invalid combination and its existing reason: «so the user sees the recorder stay open rather than watching a combination be accepted and then not work» — which is precisely what would happen otherwise, since Carbon refuses a combination already held in this process (-9878) and `apply()` then silently restores the previous one |
| The system refuses the правка combination | `apply()` restores the previous one, as for перевод, and the failure is logged at `.error` — **not** `.fault`. `fault` is justified for перевод by «the app has no shortcut and no way into the panel»; that door stays open here, and copying the level would make the log lie about severity. **Corrected during implementation:** the message must also turn on whether the restore *happened*. Written unconditionally it claimed перевод had no shortcut even on the path where `apply` had just put the old one back — true in `launch()`, where the message came from, and false everywhere it was moved to. `HotkeyCoordinator.failure(for:restored:combination:)` is that decision as a value, with a test |
| **Both settings hold the same combination** | Not typable — the recorder refuses it — but reachable by upgrade: `proofreadHotkey` answers its factory ⌥⌘R until the key is set, so a user who had already put перевод on ⌥⌘R inherits a duplicate. Правка's registration is declined outright rather than attempted and refused (`AppSettings.shortcutsCollide`), перевод keeps the combination because it is the only door to the panel, and «Основные» draws an orange row saying правка's shortcut is not in force — the same «say it, do not silently substitute» rule the colliding languages already follow. **Found by review, not by the design** |
| One shortcut moved onto the combination the other holds | Both registrations are brought in line in **two passes** — release what stands in the way, then register what should be. Measured: with one pass in `allCases` order, changing перевод to правка's combination left перевод on its *previous* one, because Carbon refused while правка still held it and `apply` restored. The user's choice was discarded silently. **Corrected again after a second review:** «what stands in the way» is not «what is out of date». A manager can hold a combination its own setting no longer names — that is `apply`'s restore-on-refusal working — and releasing every such registration up front would destroy the guarantee that a rejected change never leaves the user shortcutless. Pass 1 releases only registrations that must not exist at all, or that the *other* operation is about to ask Carbon for. **And corrected a third time:** what pass 1 releases must be *remembered* and handed to `apply` as its fallback. Measured — resolving an inherited collision by moving перевод onto a combination another component holds released перевод's live registration, left `apply` with nothing to restore, and ended with перевод registered to nothing while правка took the combination the user had been pressing for перевод |
| Swapping the two shortcuts | Not possible in one step, and accepted rather than fixed: each recorder refuses what the other holds, so an exchange has to go through a third combination. `docs/reference/OPEN-ITEMS.md` §2 carries the reasoning — a stored duplicate is a shortcut that silently does nothing, which is worse than the friction |
| A press while a run is in flight | Dropped by `isCapturing` / `state != .running`, exactly as a second ⌥⌘T is today |
| No selection, or no Accessibility grant | The existing hint and prompt, with neither the operation segment nor the new row |
| Степень changed to «только ошибки» while a style is selected | The style picker disables; the stored style is left alone, so restoring the степень restores the choice. `PromptBuilder` already ignores a style under `.errorsOnly` |

## 8. To be measured, not assumed

1. **Does the row fit at 300 pt?** `PanelSizer` clamps the width to 300–560 and freezes it
   for a whole presentation, so a row that does not fit widens *every* правка panel. Measure
   with a script in the shape of `Scripts/toolbar-fit.swift`, which exists for this exact
   question about the window's toolbar. If it does not fit: shorten the style picker's
   rendering first, move it to its own row second. Widening the panel's floor is not an
   option this design offers.
2. **Does a pop-up menu open inside a `.nonactivatingPanel`?** The panel becomes key while
   the application stays inactive, and no measurement in this project covers `NSMenu` in that
   state. GUI automation is unavailable here, so this goes to `docs/reference/OPEN-ITEMS.md` as a
   manual check with what to look for. If it fails, the fallback is the segment-plus-menu
   layout from the same design discussion, or a single settings-shaped button.
3. **Is ⌥⌘R free?** A Carbon hot key takes the combination from every application, so a
   factory value must not collide with something common. Probe with a throwaway registration
   before the value reaches the code, and record the result in `docs/reference/MEASUREMENTS.md`.

## 9. Tests

Offline, `FakeLLMClient` and `InMemoryDefaults`, no Ollama. Each written to fail when its
subject is mutated away (`docs/reference/TESTING.md`).

- **Settings**: the factory value; a round trip; an undecodable or invalid stored value
  falling back to the factory one — the three `hotkey` already has.
- **Coordinator**: a press with `.proofread` sets the panel model's operation and runs;
  `handlePress()` with no argument still means перевод; a правка press after a перевод press
  does not inherit, and the reverse; two presses of different shortcuts in flight produce one
  capture.
- **Registration**: both combinations register together; changing one leaves the other
  registered; a refusal on one leaves that one's previous combination in force.
- **Recorder**: a combination equal to the other shortcut's is refused and the bound value is
  unchanged. `@MainActor`, over `RecorderView`, as `WarningsViewTests` is.
- **Panel**: the row is drawn only for правка with a captured `.text`; the style picker is
  disabled at «только ошибки»; a change calls the callback rather than writing anything
  itself.
- **Persistence**: a change made through the panel reaches `AppSettings` and re-runs the
  captured selection; with nothing captured, it does neither.

## 10. What does not change

`TextCapture` — not one line. The engine — `Translator`, `PromptBuilder`, `ModelPolicy` —
not one line; правка already runs on the interactive model and that is where a shortcut
belongs. The file queue, `translate-cli`, `acceptance`, `GlossaryStore`, the terms sheet,
`PanelSizer`'s rules, the panel's measured show order, and the window's toolbar all stay as
they are.

## 11. Documents to update when the code exists

- `CLAUDE.md` — the app-layer section: the hotkey path owns two combinations now, and the
  «every press starts with перевод» fact is superseded.
- `docs/design/specs/2026-08-10-proofreading-design.md` — a correction note on §8
  pointing here, in the shape the other specs use where the code has moved past them.
- `docs/reference/OPEN-ITEMS.md` — §8.2's manual check, and the panel row's appearance at the 300 pt
  floor.
- `docs/reference/MEASUREMENTS.md` — §8.1's width and §8.3's probe.
- `CONTEXT.md` — «сочетание клавиш для правки» as the name of the new setting, so the pane
  and this document cannot drift.
