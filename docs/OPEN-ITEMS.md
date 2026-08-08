# Open items

What is unfinished, what a human still has to look at, and what is deliberately left alone.

This exists because the agent environment has **no GUI automation**: an agent can build the app,
launch it, read logs, drive Accessibility probes and enumerate windows, but it cannot see the
screen or press a physical key. Everything that can only be established by looking is listed
here rather than assumed.

Engine-level limitations are not repeated here — they are in §11a of the design spec, which
owns them.

Last reviewed against the code at commit `75d9be1`, the final fix wave that closed the UI
redesign branch's whole-branch review. This line is a commit later than the code it names,
because a file cannot cite the hash of the commit that writes it.

---

## 1. Owed to a human

### What a person has already seen

A person verified the following during the Plan 3 acceptance pass. The UI redesign rewrote the
code under half of them, so the list is split. Anything below the second heading has been
verified *once*, against code that no longer exists.

**Still standing — the code under these was not touched by the redesign:**

- The capture itself, in a native app, a browser and an Electron app: TextEdit took the
  Accessibility path, Safari and Obsidian both fell back to the synthetic ⌘C.
- The clipboard surviving the ⌘C fallback, checked with a real ⌘V against a marker.
- The hotkey recorder, including ⌘W/⌘Q being captured rather than firing menu items, and a
  bare key being refused.
- Live re-registration after changing the shortcut.
- The permission prompt at first launch.
- The Accessibility grant surviving a rebuild under the stable signing identity.

**Invalidated by the UI redesign — seen once, on code that has since been replaced:**

- Hotkey → capture → translation → panel, end to end. The capture half stands; the panel half
  does not. The panel lost `.titled`, gained `.resizable`, sizes itself from a measurement and
  had its content rebuilt around a header and a ⨯.
- Esc, Enter and ⌘. on the panel, and «Скопировать». Those presses were made on a `.titled`
  panel. See the note under the Task 4 table: the panel's *key status* is no longer owed to a
  human, but a physical key press on the untitled panel is.
- The permission prompt in the panel and as a standing indicator. The panel's prompt lost the
  fixed frame it was read inside, and in «Основные» the «Доступ» row is now rendered whether
  or not the grant is missing — only its explanation and its button are conditional.
- All four settings tabs, and the main window end to end. There are **three** tabs now:
  «Дополнительно» was folded into «Модели» and its view deleted. Every pane of the window and
  of the settings was rewritten.

### Not yet seen by anyone

These changed after the acceptance pass and no one has looked at them.

| What to check | Why it needs eyes | Code |
|---|---|---|
| A finished translation with **no** warnings fills the panel | The empty warnings slot used to eat 86 pt of a fixed 260; the fix gates the slot on `WarningsView.hasContent`. The panel is no longer 260 pt tall, so the original arithmetic no longer applies — what is owed now is simply that a finished result with no warnings looks whole | `PanelView.swift`, `WarningsView.swift` |
| «Открыть в окне» with a **finished** translation already in the window | The hand-off moves `outcome`, `resolvedTarget` and `state` together; the failure it fixes was the window showing the previous run's elapsed time and warnings under the new text. The window it hands to has since been rebuilt | `TranslationViewModel.adopt(from:)` |
| «Открыть в окне» while the window is **busy** | The button should be disabled with «Окно занято своим переводом» beneath it, and re-enable itself when the window finishes | `PanelView.swift`, `AdoptionRefusal` |
| The window and Settings actually coming **forward** | `NSApp.activate(ignoringOtherApps:)` does not activate on macOS 14; replaced with cooperative activation, which no one has watched work | `activateThisApp()` in `TranslatorApp.swift` |
| The permission row clearing after granting and returning | It is refreshed on `didBecomeActiveNotification`; the failure it fixes was telling the user their grant had not worked | `SettingsGeneralView.swift` |
| The icon in Finder, Spotlight and the Accessibility list | Nothing here can see the screen; the rendered PNGs were checked, how macOS composites and caches them was not. Finder caches icons aggressively — a blank sheet right after the first build is a cache artefact, not a failure | `Scripts/make-icon.swift` |
| The ink tile against a **dark** desktop background | The dark ground was chosen over the parchment one with this trade-off stated and accepted; whether it separates well enough in practice has not been looked at | `Scripts/make-icon.swift`, spec §2.4 |

**Owed by the UI redesign, Task 4 — the panel sized to its content.** The tests pin the
numbers the controller computes; none of them can say what the panel looks like.

| What to check | Why it needs eyes | Code |
|---|---|---|
| ⌥⌘T on a one-word phrase, then on a long paragraph | The whole point of the task: two visibly different panel sizes, neither of them 380 × 260. The measurement is checked in the test process, but nothing here has seen it reach a real screen | `PanelController.measure`, `show(at:)` |
| **The panel widening while the first line or two of a reply arrives** | New in the final fix wave, and the one part of it that changes what a user sees. The panel now opens at a provisional width and reaches its real one as the reply comes in, instead of being frozen at `show(at:)` against content that had not arrived. Whether that reads as the panel finding its size or as a flinch is exactly the thing no test can say, and it is the trade the fix rests on | `PanelSizer.fit`'s width rule, `PanelController.applyFit` |
| Esc closing the panel and Enter copying and closing, from a **physical** keyboard | Narrowed deliberately. The panel's key status is **not** owed to a human: `theUntitledPanelStillTakesKeyStatusWithoutItsProcessBecomingActive` runs at `.prohibited` activation policy, where activation is impossible, so `isKeyWindow == true` there has exactly one possible cause. What that test cannot do is press a key. Plan 3's manual pass pressed them on a `.titled` panel | `TranslationPanel.canBecomeKey`, `cancelOperation`, `keyDown` |
| The corner nearest the pointer staying put while text streams | The reason the panel was fixed-size for so long. The frames are asserted; whether the already-read lines actually hold still is a thing you have to watch | `applyFit`, `PanelPlacement.reframe` |
| The rounded corners, with no grey notch behind them — **now under `.titled` again** | `isOpaque = false` / `backgroundColor = .clear` / `hasShadow` are what make the material corner work, and a square window background showing through is invisible to every test. Sharper than before: `.titled` was dropped in the first place on the reasoning that a titled panel cannot hold a corner radius, and that reasoning was never checked on a screen. It has been taken back to restore hand-resizing, on the grounds that the two lines above are the standard answer to exactly that problem and postdate the decision. If the corners are wrong, this is why | `TranslationPanel.init` |
| The panel not shivering while a run streams | Growth is deliberately unanimated during a run and animated once on the settle. Both the 100 ms throttle and the 150 ms tween are chosen against each other, and only watching a real stream says whether that was right | `contentDidChange`, `applyFit` |
| **Dragging the panel's edge at all**, then more text arriving, **and then the next press sizing itself again** | The first part is no longer a formality: it was reported broken and is the reason `.titled` came back. `.resizable` without `.titled` is a flag with no implementation — drag tracking lives in `NSThemeFrame`, and a borderless window gets `NSNextStepFrame`, which has none — so `isResizable` answered `true` for weeks while nothing happened when an edge was pulled. `thePanelCarriesBothFlagsThatHandResizingNeeds` now pins the mask, but no test here can pull an edge, so the whole `userSized` path — `windowDidEndLiveResize`, `PanelSizer`'s user branch, and the reset in `show(at:)` — is still exercised by nobody | `PanelController.windowDidEndLiveResize`, `show(at:)`, `TranslationPanel.init` |
| A translation past the ceiling scrolling inside the panel | The scrolling variant is swapped in from the measurement. `PanelSizer` decides it and is tested; the swap reaching the screen is not | `setScrolling`, `PanelView.scrolls` |
| **The chrome staying put while that translation scrolls** | The `ScrollView` used to wrap the whole panel, so the ⨯, both buttons and — worst — «Отмена» scrolled away with the text; a run at the ceiling pushed its own stop button further out of reach with every token. Only the middle scrolls now. **Nothing in the suite guards this**: putting the `ScrollView` back around the whole content was applied and the full suite run, 346 tests, zero failures. Both arrangements size identically, because the measured variant is flat either way; all that differs is which rows are on screen once the user scrolls, and no test here can see a row's position. This row is the only guard. Look for: a translation long enough to scroll, then the ⨯ and both buttons still visible without scrolling, and «Отмена» still reachable while it streams | `PanelView.scrollingMiddle`, `translation` |
| The permission prompt and the empty hint each getting a panel that **fits** | Spec §8 asks for three states, not two. The one-word and long-paragraph sizes are measured; `.notPermitted` and `.empty` are the two states a new user meets first and neither has been seen at any size | `PanelView.permissionPrompt`, `emptyHint` |
| **The measurement holding up in the assembled bundle, not just in the test process** | Spec §8, and it has bitten once already: the 380 × 120 hosting-view collapse reproduced in the bundle and not in a test process. Every size in this section was taken in-process | `PanelController.measure` |
| **Re-measure `hosting.sizingOptions = []`** | Its evidence — 380 × 120 before, 380 × 260 after, on the running bundle — was taken on a `.titled` panel against a fixed size, and **neither condition exists any more**, so the numbers cannot be reproduced from here. The mechanism it records is sound and the line stays on that basis; someone with the bundle on a screen should take the number again, or delete it | `PanelController.init` |
| **A hand-dragged panel taller than the screen** | `PanelSizer.fit`'s `userSized` branch now honours the user on both axes — floors only, no ceilings — so nothing stops a drag from producing a frame taller than `maxHeightFraction` would allow, and `PanelPlacement.clamp` only moves the origin, it does not shrink the frame. The one mitigation is that `show(at:)` clears `userSized` on the next press. Whether an over-tall hand-dragged panel actually reads as a problem worth a shrink-back is a thing only someone looking at a screen can judge | `PanelSizer.fit`, `PanelPlacement.clamp` |

**Owed by the UI redesign, Task 3 — the panel's content.** The header, the ⨯ and the material
are all new, and the suite can only prove the closure is stored, not that the button calls it.

| What to check | Why it needs eyes | Code |
|---|---|---|
| The ⨯ in the panel header actually closing the panel | `thePanelOffersACloseControlOfItsOwn` proves `onClose` is stored and callable. A copy-paste wiring the button to a different closure would pass it. Inherent to an environment with no GUI automation | `PanelView.header` |
| The ⨯'s appearance and hit area beside the direction line | Borderless, an `xmark` glyph, `accessibilityLabel("Закрыть")`. Nothing has rendered it | `PanelView.header` |

**Owed by the UI redesign, Tasks 5–7 — the main window.** The window was rebuilt around a
toolbar, two panes and a collapsible status bar. Nothing in it has been rendered.

| What to check | Why it needs eyes | Code |
|---|---|---|
| **The translation pane refusing the caret** | Spec §8 names this one specifically, because the defect being fixed is precisely that the old pane accepted a caret and silently discarded typing. The replacement is a read-only `Text`, which should have no caret by construction — but that was reasoned from the type, not observed | `TranslationPane.swift` |
| Text in the translation pane still being selectable by hand | `.textSelection(.enabled)` is what is supposed to keep copying possible once the `TextEditor` is gone. Never exercised | `TranslationPane.swift` |
| The toolbar: two language pickers, the tone picker and ⇄ on the leading side, «Перевести»/«Отмена» on the trailing side | `.navigation` and `.primaryAction` were checked for availability against the macOS 14 floor by reading the SDK interface, not by looking at a window | `MainWindowView.toolbar` |
| ⇄ enabled and disabled at the right moments, and swapping what it says it swaps | `canSwapLanguages` and `swapLanguages()` are unit-tested; the button's own disabled state and the pickers updating under it are not | `TranslationViewModel.swapLanguages`, `MainWindowView` |
| The status bar collapsing and expanding, and its disclosure triangle appearing only when there is something to disclose | The triangle's condition and the warning count are tested as values. Whether the row reads as one line of status, and whether the expanded warnings stop at the 200 pt cap instead of eating the window, is a thing you have to see | `RunStatusBar.swift` |
| «Скопировать» in the window putting the translation on the real pasteboard | The write now goes through `GeneralPasteboard.write(_:to:)` and is tested against a scratch board, never against `NSPasteboard.general` | `TranslationViewModel.copyToPasteboard`, `GeneralPasteboard.swift` |
| The two pane headers, the source placeholder and the empty translation state | Placeholder position and its padding, the empty state's centring, and whether `PaneHeader`'s divider and tint read correctly side by side — all five were listed as unobserved when they were written | `SourceEditor.swift`, `TranslationPane.swift` |

**Owed by the UI redesign, Tasks 9, 10 and 12 — the settings.** All three panes now share one
`settingsPane()` frame, and two of them grew sections while that frame stayed fixed.

| What to check | Why it needs eyes | Code |
|---|---|---|
| **The settings window no longer resizing between tabs** | Spec §8. The three panes used to fix 420, 420, 520 × 440 and 420 of their own; they now all take 560 × 480 from one modifier. That the resizing actually stopped has not been seen | `SettingsPane.swift` and its three call sites |
| «Основные» — five sections at 560 × 480 without clipping, and the hotkey recorder still behaving inside a `Section` | The pane went from one flat `Form` to five sections and a fixed height in the same change | `SettingsGeneralView.swift` |
| The «Доступ» row reading correctly **when the grant is present** | It used to exist only when the permission was missing; it is now always rendered, and the granted state has never been rendered at all | `SettingsGeneralView.swift` |
| «Модели» — five sections at the same 560 × 480 | This pane gained two sections after the height was fixed by Task 9, and nothing has checked that they fit | `SettingsModelsView.swift` |
| «в памяти» appearing against the right models, against a **live** Ollama | The residency list is only ever exercised through an offline `StubProbe`. No live server has been in the loop | `ModelsViewModel.resident`, `SettingsModelsView` |
| Model sizes rendering as «4,8 ГБ» in the list | `RussianCopy.modelSize` is pinned to `ru_RU` and unit-tested; the column it feeds has not been seen | `RussianCopy.modelSize`, `SettingsModelsView` |
| The fourth tab actually being gone | Established by reading the source and by `git rm`, not by opening the window | `TranslatorApp.swift` |
| **The «Адрес» row in the «Ollama» section** | New in the final fix wave, to close spec §5.3, which asks that section for the address as well as the state and the re-check. It reads `OllamaClient.defaultBaseURL` so it cannot disagree with the address being called. Whether it fits the row, and whether a fifth control pushes «Модели» past its fixed 560 × 480, has not been seen | `SettingsModelsView.swift`, `OllamaClient.defaultBaseURL` |
| «Глоссарий» — the header row, and multi-selection by ⌘-click, ⇧-click and marquee | Selection is a `Set<Int>` over shifting indices. The rule that keeps it honest is now a tested pure function, but `List`'s own selection gestures have never been performed | `GlossaryList.swift`, `SettingsGlossaryView.swift` |
| The ± buttons' disabled state and tooltips, and whether the language picker's 140 pt frame fits the longest Russian language name | Layout arithmetic no test can reach. The picker's hidden label and its new `.help` tooltip are in the same position: the strings are in the source, nothing has hovered them | `GlossaryList.swift` |
| The empty-glossary message and «Ничего не найдено» being distinguishable | Two different empty states, one string each, never rendered | `SettingsGlossaryView.swift` |

**Owed by the Mac-idioms wave — the menu bar, the Russian bundle, and two accessibility
settings.** Every item here was established structurally (a menu dump, a bundle read, a
compile check) and none of it has been *looked at*.

| What to check | Why it needs eyes | Code |
|---|---|---|
| **⌘. while the panel is running and the window is idle** | The sharpest of these. «Перевод» → «Отмена» now declares ⌘., and so does the panel's own button. The menu item is disabled unless the *window* is running, and a disabled item declines its key equivalent so the key window's handler gets it — which is the whole argument that these do not collide. Nothing here can press a key to confirm the order. Look for: start a hotkey translation, press ⌘. while the panel has focus, and see the panel stop rather than nothing happening | `TranslatorApp.body`'s `.commands`, `PanelView.translation` |
| ⌘↩ still translating from the window, now that the toolbar no longer declares it | The equivalent moved to the menu and the toolbar button lost it. The button still works by click; the shortcut is now the menu's | `MainWindowView.toolbar`, `.commands` |
| The menu bar reading Russian at all | Measured on the assembled bundle only as far as `Bundle.main.preferredLocalizations == ["ru"]`, by swapping a probe binary into a copy of it. That the standard menus then *draw* «Правка / Скопировать / Вставить» was measured on a stand-in bundle, not on this one | `Info.plist`, `Resources/ru.lproj`, `Scripts/make-app-bundle.sh` |
| «Вид» and «Справка» actually gone from the bar | `pruneEmptyMenus()` removes them from `NSApp.mainMenu` and the removal was measured to stick for 2.5 s in a probe. An `LSUIElement` app's bar is only drawn while it is active, and nobody has watched it | `pruneEmptyMenus()` |
| **Whether an `LSUIElement` app draws a menu bar at all** | The open question underneath the two rows above. Everything here rests on the menu being *installed*, which is measured; whether the user ever sees it is not, and it decides how much of this wave is visible rather than merely correct | — |
| The panel with «Уменьшение прозрачности» on | The material becomes an opaque `windowBackgroundColor` clipped to the same rounded rectangle. Whether the corner still reads correctly against a dark desktop, and whether the panel still looks like a panel rather than a plain box, is exactly what no test sees | `PanelView.background` |
| The two new glyphs in the panel's status row | `exclamationmark.triangle.fill` for an interrupted run, `xmark.octagon.fill` for a failure, in the row's own colour. The table is unit-tested; the row has never been rendered | `PanelStatus.Kind.symbol`, `PanelView.statusLine` |
| «Скопировать перевод» ⇧⌘C not shadowing ⌘C in the source editor | They are different equivalents, so this should be free — but the source pane is a `TextEditor` and ⌘C on a selection inside it is the one thing that must keep working | `.commands`, `SourceEditor` |

**Owed by the file queue.** The queue, its mode switch and the fourth settings tab were built
with the suite green and **nothing rendered**. The bundle assembles and signs; no one has looked
at it.

| What to check | Why it needs eyes | Code |
|---|---|---|
| **The «Текст / Файлы» switch in the pane header, and both headers reading as one row** | The one control this implementation adds that the design document does not draw. `PaneHeader.height` is pinned at 28 pt to fit a `.small` segmented control beside the right pane's caption — **that number is chosen, not measured**, and if it is wrong the divider between the panes has a visible step in it | `PaneHeader`, `MainWindowView` |
| **The toolbar button and both menu items following the mode** | Nothing here can press a key. Look for: «Перевести» starting the queue in «Файлы» and the text run in «Текст», ⌘↩ and ⌘. doing the same, and ⌘. still reaching the panel while the window is idle. That last one rests on a disabled menu item declining its equivalent, and this change altered *when* the item is disabled | `PrimaryAction.forMode`, `TranslatorApp.body`'s `.commands` |
| **The warnings disclosure across two runs** | Expand the warnings on a file that has some, then select a clean one. The chevron and the region it opens read one property, so they cannot disagree — but `expanded` is `@State` and survives the change, and only a screen shows whether the region actually goes away | `RunStatusBar.canDisclose` |
| A queue of three files end to end | Rows updating, the bar moving, the right pane streaming, the status bar counting «2-й файл из 3 — 9 частей из 13» | `FileQueuePane`, `RunStatusBar` |
| **A mixed drop** | Ten `.md` and one `.pdf` should leave eleven rows, the last saying «не удалось прочитать». The rule is tested; the row has never been drawn | `QueueDrop.accept`, `FileQueueRow` |
| Selecting a finished file while another streams | The pane must show the selected file, not the running one. Tested as a value; never seen | `FileQueueModel.selectedText` |
| **A translation actually appearing beside its source in Finder** | And the numbered name when one is taken. `OutputNaming` is tested against an injected existence check, not against a real directory a user chose | `TranslatedFileWriter`, `OutputNaming` |
| **Whether TCC permits the write at all** | Spec §9.1, and the reason the fallback exists. The app is not sandboxed, but a drag grants read, not write, and macOS 14 gates `~/Documents`, `~/Desktop` and `~/Downloads` separately. Nothing here can raise a TCC prompt or see one. Drop a file from `~/Documents`, run the queue, and record what actually happened — a prompt, a silent success, or a refusal | `TranslatedFileWriter.write` |
| **The `NSSavePanel` fallback after a refused write** | The recovery path for the row above, and the only one. Press «Сохранить как…» on a row whose write was refused and check that the panel appears, that the suggested name is the one the automatic save would have used, and that the file lands where it was pointed | `FileQueuePane.saveAs`, `TranslatedFileWriter.write(_:to:)` |
| «Сохранить рядом с исходником» with the toggle **off** | The only way a translation reaches disk in that configuration. Turn it off, run a file, press the link | `FileQueueModel.saveBesideSource` |
| «сохранено как …» revealing the file in Finder | Names the file rather than saying «сохранено», because a taken name gets a number — so this is also how a user finds out the name changed | `FileQueuePane.reveal` |
| **The fourth settings tab at 560 × 480** | Spec §9.2. `.formStyle(.grouped)` scrolls, so the question is whether it *should have to*, and whether four tab items still fit the row | `SettingsFilesView`, `settingsPane()` |
| The orange caption when the batch model differs from the interactive one | The condition is tested; the sentence has never been rendered | `SettingsFilesView`, `AppSettings.batchModelDiffersFromInteractive` |
| All of the above in dark mode | Every new surface | — |
| VoiceOver on the queue | A row should announce its file, its state and its progress, and not re-read on every token. `.accessibilityElement(children: .combine)` is the intent; nothing has listened | `FileQueueRow` |

**Owed by the document-terms review.** Same story: built with tests green, nothing rendered.
The toggle ships **off**, so none of this is on a default install's path.

| What to check | Why it needs eyes | Code |
|---|---|---|
| **«Жду ваших правок…» in the panel and in the status bar** | Turn the gate on, press ⌥⌘T on a long selection, and look at what is *behind* the sheet. The panel used to say «Перевожу…» with a spinner while the model sat idle. Check the new row has no spinner, and that `square.and.pencil` actually renders — an unresolved SF Symbol name draws an empty image rather than failing | `PanelStatus.Kind.awaitingUser`, `RunStatusBar` |
| **«Перевести» in the sheet drawn as the primary button** | The drawing gives it the same blue fill the window's «Перевести» has. `.borderedProminent` is set explicitly rather than left to `.defaultAction` to imply, because nothing here can render the difference — look at the two side by side and check they match | `DocumentTermsView` |
| The sheet at a dozen terms | Three columns, an editable «перевод» cell that actually takes typing, and the table scrolling at its 260 pt cap without the buttons going with it — the same failure the panel's `ScrollView` once had | `DocumentTermsView` |
| **Esc cancelling the run from the sheet** | The whole escape, and the sharpest thing on this list. The sheet has no cancel button by design, `.interactiveDismissDisabled()` is applied, and it is window-modal — so the toolbar's «Отмена» is behind it and unreachable. If Esc does not route to `onExitCommand`, the run sits on `DocumentTermsRequest.answer()` forever under a sheet that cannot be dismissed: the «suspended forever» failure that type prevents, moved one layer up. A `request.cancel()` on `onDisappear` is the insurance if the sheet ever goes away unanswered, but nothing here can press a key to find out whether it does | `DocumentTermsView.onExitCommand`, `MainWindowView`'s `.sheet` |
| **⌘W while a terms sheet is up, then reopening the window** | The sheet no longer cancels the run when it disappears — that turned an ordinary action into a silent kill of the whole queue. The request lives on its model, and `presented` is `@State` that dies with the view, so a reopened window should find the request waiting and present it again. Nothing here can close a window and look | `MainWindowView`'s `.sheet`, `TranslatorApp.launch()` |
| **A sheet dismissed with the window still open** | The insurance that used to cover this was removed with the ⌘W kill. `termsRequest`'s getter keeps returning the pending request, so SwiftUI should re-present it — but «should» is the word that needs a screen. If it does not, the run waits on a continuation with no sheet, which is the failure `DocumentTermsRequest` exists to prevent | `MainWindowView`'s `.sheet` |
| **«Сохранить как…» when the write is refused** | Its `.atomic` form needs the destination's *directory*; the panel's grant is for the *file*. The code tries atomic and falls back to a direct write, so it does not depend on which the grant covers — but only a real refusal shows whether the fallback is ever reached, and it belongs with the TCC probe above | `TranslatedFileWriter.write(_:to:)` |
| **The second and third terms sheet of one queue run, with the window already open** | The escalation's `openWindow` + `activateThisApp()` force a presentation update for the first sheet and change nothing for the ones after it. `termsRequest` is read inside `body` so the observation registers there rather than inside a binding getter SwiftUI invokes when it likes — but whether that is enough is a presentation-update detail nothing here can render. If it is not, the run sits on a continuation with no sheet on screen | `MainWindowView`'s `.sheet`, `DocumentTermsRequest` |
| **«Открыть в окне» with the window sitting in «Файлы»** | It switches the window back to «Текст» so the handed-over translation is on screen. Nothing here can press that button; what to look for is the pane actually changing, and the queue continuing behind it | `handOffToWindow`, `MainWindowView`'s mode picker |
| **Switching modes while one side is running** | Now allowed — the mode switch is no longer what stops a second run, `PrimaryAction.canStart` is. Look for: «Перевести» greyed out in «Текст» while a queue runs and in «Файлы» while a text run does, and the switch itself never locked | `PrimaryAction.forMode`, `MainWindowView` |
| ⇄ in «Файлы» exchanging the pickers and leaving the text panes alone | It is routed through `PrimaryAction` now and unit-tested as a value; that the toolbar button reaches that path, and that the hidden panes really are untouched, has not been seen | `PrimaryAction.swap`, `TranslationViewModel.swapOverrides` |
| **The ⌥⌘T escalation** | Press the shortcut on a >900-character selection in another app with the toggle on. The main window should come forward — opening if closed — and show the sheet, with the panel still behind it. `activateThisApp()` is cooperative activation that no one has watched work, and this is a second caller for it | `TranslatorApp.body`'s `.onChange`, `activateThisApp()` |
| ⌘. while the sheet is open | Should interrupt the run rather than doing nothing. The ordering is unit-tested through `cancel()`; the key press is not | `TranslationViewModel.cancel`, `FileQueueModel.cancel` |
| «Больше не спрашивать в этом прогоне» appearing only in a queue run | `showsSuppress` is passed from the window; nothing has rendered either state | `MainWindowView`'s `.sheet`, `DocumentTermsView` |
| «Добавить в пользовательский глоссарий» and then the «Глоссарий» tab | The promotion rule is tested; that the terms actually appear in the pane, and that the file on disk gains them, is not | `GlossaryPromotion`, `GlossaryStore.replaceEntries` |
| The «термины не удалось подготовить» notice | Only reachable with the toggle on and a term-list call that fails, which needs a live Ollama misbehaving | `TranslationViewModel.documentTermsUnavailable`, `FileJob.documentTermsUnavailable` |

**Owed by the settings/accessibility/CI wave.**

| What to check | Why it needs eyes | Code |
|---|---|---|
| **VoiceOver on the panel, end to end** | The only way to know whether any of the new accessibility work reaches a user. Press the shortcut with VoiceOver running and listen for: the panel announcing itself, «Перевод готов» once the run settles, and the translation *not* being re-read on every token. The announcement's wording is unit-tested; that it is spoken at all is not, and cannot be from here — see §2 | `PanelView.announcement(for:)`, `configurePanel`'s `onRunFinished` |
| Dropping a `.md` file on the source pane | The decision — which files, how large, what counts as text — is `DroppedDocument` and is tested against real temp files. What no test can do is drag something: whether the pane shows a drop target, whether the refusal springs back the way the platform draws it, and whether dropping onto the *translation* side does nothing | `SourceEditor`, `DroppedDocument` |
| **The CI workflow's first run** | Written but never executed. Two things could be wrong and neither is knowable from here: whether `macos-15` ships an Xcode new enough for `swift-tools-version: 6.0` and `.swiftLanguageMode(.v6)`, and whether `ls -d /Applications/Xcode*.app \| sort -V \| tail -1` picks the right one on that image. If it fails, the fix is a pinned `xcode-version`, not a change to the package | `.github/workflows/ci.yml` |
| ⇧⌘C and the drop target not fighting the `TextEditor` | Both are new on a pane that already owns the keyboard | `SourceEditor`, `.commands` |

**Owed by the UI redesign, Task 13 — the menu bar glyph and status row.** The whole visible
result of this task is unobserved: it is a menu-bar icon and a new first row of menu text, and
nothing in this environment can see either.

| What to check | Why it needs eyes | Code |
|---|---|---|
| The `MenuBarExtra` glyph actually switching between `character.bubble` and `exclamationmark.bubble` as Ollama is stopped and started | `menuBarSymbol` is unit-tested; whether `Image(systemName:)` picks up the new value and repaints the real status item is not | `OllamaStatus.menuBarSymbol`, `TranslatorApp.body` |
| The new first menu row (`Text(status.label)`) rendering above the divider, at a sane width, without truncating or pushing the existing items around | Never opened on a real status item | `MenuContent` in `TranslatorApp.swift` |
| **A launch loop from `.task { await launch() }` re-running.** Before this task the label view had a constant body with no observation dependencies; it now reads `statusModel.status`, and `launch()` — which the same `.task` calls — writes that property via `statusModel.refresh(...)`. SwiftUI's documented contract re-runs `.task` on the *view's identity* changing, not on every body re-evaluation, so this should be safe, and it is exactly the same shape the `Window` and `Settings` scenes already use with their own `.task`s reading and writing through `statusModel`. But nobody has watched it run. If it is not safe, the failure is not cosmetic: a re-triggered `launch()` re-runs `configurePanel()`, re-registers the hotkey through `coordinator.start`, and re-awaits `warmUp()`, on every status change | `TranslatorApp.body` (the `MenuBarExtra` label), `launch()` |

---

## 2. Known and accepted

- **Esc in the «Термины документа» sheet ends the whole queue, not just that file.**
  *Flagged by three separate reviews, which is why it stopped being defended and got a
  control instead.* The scope is unchanged and deliberate — «Перевести» already **is** «skip
  the review for this file», so «stop» is the only other thing the sheet can mean — but Esc
  is no longer the only way to say it: the sheet carries a button labelled «Остановить
  очередь» in a queue run and «Отмена» otherwise, with Esc as its shortcut. What is owed to
  a human is whether that label makes the effect readable *before* it is pressed, which is
  the whole point of adding it.

  `askAboutTerms` throws `CancellationError`, which is the engine's «abort this run», and
  `run()` returns. It is the same contract `queue.cancel()` has and the same one the spec
  gives the sheet — a refusal is a refusal of the run — but it is the one place a gesture
  made about a single file stops all the others, with nothing on screen warning of it
  first. Left as it is because the alternative is worse in a way that is easy to miss:
  «skip this file and carry on» would leave the queue running under a user who has just
  said no, and the файл it skipped would look interrupted for a reason it did not have.
  What is owed is a human's judgement of whether that reads as expected in practice, not
  a change made from here.

Deliberate, with the reason. Do not "fix" these without reading the reason first.

- **The panel is sized to its content, within bounds it will not leave.** This entry used to
  say the opposite — a fixed 380 × 260 that nothing resized — and that was retired by the UI
  redesign's Task 4, which took the candidate measurement the old entry pointed at and wired
  it up. What is deliberate now: the width is clamped to 300–560 pt; the height has a 120 pt
  floor, is monotonic within a presentation and is capped at 0.6 of `visibleFrame`, past which
  the content scrolls instead; and dragging an edge hands the size to the user until the panel
  hides. `PanelSizer` owns all four rules and is where to change them.
  Measured through the two calls `PanelController.measure` makes, on the real `PanelView`:
  274 × 94 for a one-word translation, 6929 × 302 for a forty-sentence one — which clamp to
  the width floor and the width ceiling respectively. The old entry's ideal heights (97 pt
  short, 301 pt long) are gone with the doc comment that held them.
- **The width is chosen while the reply arrives and frozen at the settle — not chosen up
  front.** This entry said the opposite until the final fix wave: that the width was «frozen
  for a whole presentation», which is what `show(at:)` did. It could not be right.
  `HotkeyCoordinator.handlePress` assigns `panelModel.sourceText` *after* the `afterCapture()`
  that shows the panel, and the translation streams in after that, so at `show(at:)` the panel
  is being measured against the previous press's result — or, on the first press of a session,
  against nothing. The first hotkey translation of every session came up at the 300 pt floor
  and compensated with height, which on a laptop display crosses the 0.6 ceiling and swaps in
  the scrolling variant for content that would have fitted unscrolled.
  Spec §3.3 puts the freeze on «the first content update after `show(at:)`». That is not
  enough either, and the measurement is in `PanelSizer.fit`'s width rule: the real `PanelView`
  asks for 347 pt before a single character has arrived and 6929 once the whole reply has, and
  every point in between is a wrong answer — an independent probe measured a forty-sentence
  reply frozen at 330/347 pt as 462 pt tall, against 560 × 302 correct, a much worse shape (not,
  as this entry said until now, a case that crosses the 0.6 ceiling on a laptop display: that
  probe's own numbers need `visibleFrame.height` ≤ 770 pt to scroll at 330/347, and a 14-inch
  MacBook Pro reports ≈ 875, a 13-inch Air ≈ 850 — the only width that scrolls on every current
  laptop is the 300 pt floor above, the defect's width, not a candidate freeze point).
  **No early moment knows the final width.** So the width now tracks the content —
  monotonically, never shrinking — and `frozenWidth` pins it at the settle, which is when the
  reader starts reading. Measured per streaming run, repeated and stable to ±1: flowing prose
  at ~125 chars/s re-wraps 4–5 times over 48 ms–0.9 s with 86–89 chars on screen when it stops;
  slow prose at ~25 chars/s re-wraps 8 times over 48 ms–3.4 s with 79 chars on screen; hard-broken
  short lines (a list, a poem, dialogue) re-wrap 12 times over 42 ms–6.7 s with 626 chars on
  screen. The first re-wrap always happens with zero characters on screen, and flowing prose
  pins at `maxWidth` once its longest unwrapped line passes ~80 characters, so most of a long
  reply arrives at a fixed width — the bad case is content whose lines are individually short.
  From the settle the width does not move again for the rest of the presentation, including
  through a «Повторить».
  **This is a deliberate deviation from the review that asked for the fix**, which required the
  width to be frozen from the moment it is first set. It was refused on the measurement above
  and the reason is recorded here rather than only in the fix report.
  `aPanelShownBeforeItsTranslationArrivesEndsUpAsWideAsThatTranslationNeeds` is the guard.
- **Growth can now move the anchored corner near the right edge of a screen, and that is
  accepted.** New with the width rule above, and the same family as the three imprecisions
  below. `show(at:)` picks the anchor from a *provisional* size, so a panel that opened narrow
  enough to fit to the right of the pointer and then grew to 560 pt can overflow the screen,
  at which point `PanelPlacement`'s clamp — the only thing that pulls a grown panel back on
  screen — slides it left, taking the already-read lines with it. Re-running `place` from the
  stored cursor at the first width change would fix it and was not done: it would re-decide
  the *vertical* placement too, at the one moment the panel has just appeared. Never observed;
  nothing here can see a screen.
- **Three small imprecisions in the panel's resize path, left alone with the reason.** All
  three were found by review during the UI redesign and judged not worth the machinery:
  a trailing-fit `Task` scheduled in one presentation can be consumed by the next when a hide
  and a show land inside 100 ms (benign — `applyFit` re-measures live state — but it jitters
  the throttle, and a generation token would make it exact); `lastFit` is not reset in
  `show(at:)`, so a presentation opening within 100 ms of the previous one's last fit has its
  first growth delayed by up to that interval; and `windowDidEndLiveResize` sets `userSized`
  but never re-fits, so **dragging a finished panel smaller clips its content, with no scroll
  view, until the panel hides**. The last of these is the one a user could actually meet.
- **The stale-measuring comment in `PanelController.measure` is left as written, including the
  word «every».** The UI redesign's own ledger proposed narrowing it — claiming that because
  `PanelHost` hands `selection` to `PanelView` as a stored value, a change of *selection kind*
  re-evaluates without a layout pass, so `.empty` and `.notPermitted` presses were never sized
  against the previous press. **That claim is retracted.** Settled against the real `PanelHost`,
  driven through the real `HotkeyCoordinator.handlePress` with an injected `SelectionReader`,
  reading the frame at `show(at:)`. Five presses — short text, long text, `.empty`,
  `.notPermitted`, short text — with `measuring.view.layoutSubtreeIfNeeded()` in place:
  300 × 120 / 300 × 120 / 326 × 120 / 560 × 131 / 560 × 305. With it commented out:
  300 × 120 / 300 × 120 / **560 × 305 / 326 × 120 / 560 × 131**. Deterministic over repeated
  runs, identical whether or not the panel is hidden between presses. So a selection-*kind*
  change is stale too, and `.empty` and `.notPermitted` are exactly the presses that never run
  a translation and so never get a second chance. The stale size also **changes press to
  press** rather than freezing — presses 4 and 5 are each precisely the previous press's size —
  which makes «sizes every press against the previous one» the accurate wording. Reproducing
  this needs `PanelHost`'s `private` lifted so `@testable import` can see it; two earlier probes
  that used a stand-in instead each got a different wrong answer, which is the lesson worth
  keeping. One qualification since the final fix wave: those frames are the size at `show(at:)`,
  and for a `.text` press that is now **provisional** — the width is no longer frozen there, so
  such a press does get a second chance, in both axes. For an `.empty` or a `.notPermitted`
  press nothing changes, and they are the two the entry turns on.
- **`TranslationPanel.constrainFrameRect`'s two observations no longer have equal standing, and
  the comment now says so.** Task 4 re-measured the constraint against the current mask: the
  menu-bar-band pull-down reproduces, the Stage Manager case — a frame at x = 19 coming back at
  x = 221 — does **not**, consistent with the original note saying it was taken on a machine
  with Stage Manager on. For a while only the first half reached the comment while the second
  lived in a task report, which is where measurements go to be lost. Both are in the comment
  now. The override stands on the first alone.
- **A refused `start()` at launch is swallowed.** If `HotkeyManager.register` ever fails the
  user gets no shortcut and no message. Unreachable today: `AppSettings.hotkey` guarantees a
  valid combination, and the only other failure is `-9878` for a combination another component
  of this process already holds — nothing else in this process registers one.
- **The panel's accessibility is now stated, and only half of it is checkable.** This entry
  used to read «the panel exposes almost nothing to accessibility — `entire contents` of the
  panel window is empty through System Events». The panel now declares a container label, marks
  the translation `updatesFrequently` so an assistive technology is not made to follow ten
  rewrites a second, and announces a settled run through
  `AccessibilityNotification.Announcement`. What it says is `PanelView.announcement(for:)`, a
  value, and it is unit-tested.
  **The «empty through System Events» observation is retired rather than fixed, because it
  never distinguished the two things it was read as distinguishing.** Measured now, walking the
  real `PanelController`'s tree in the test process: `AXWindow → AXGroup`, no label, zero
  children — **identically with the new modifiers and with them removed**, checked both ways.
  SwiftUI does not materialise its accessibility tree until an assistive client attaches, and a
  test process has none, so that probe reports «empty» whatever the view says. It was never
  evidence about the panel. What is owed is VoiceOver on the assembled bundle, and nothing
  short of that will do.
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
- **Glossary verification is weaker on a machine without lemma data for the target language,
  and now says so instead of crying wolf.** `NLTagger` returns no lemma at all for some
  language/OS combinations — measured on a `macos-15` CI runner, where Russian produced none.
  `LemmaMatcher.lemmas` falls back to the surface form in that case, which used to make
  `matches` answer `false` («absent») where it meant «could not normalise», and
  `GlossaryVerifier` then reported `.missing` on a correct translation. It now answers `nil`
  when **neither** the term nor the translation produced a single lemma, so the check degrades
  to `.unverifiable`. The consequence to accept: on such a machine an inflected term is never
  confirmed *or* reported — the checker goes quiet rather than wrong, which is the trade spec
  §4.6 asks for. Which macOS versions lack which language's data was not enumerated.
- **`swift run acceptance` is not in CI, deliberately.** It needs a live Ollama and a resident
  model. The rest of the checks *are* — see `.github/workflows/ci.yml`; «no CI for that
  harness» was never «no CI».
- **`swift run acceptance` owed after the lossless-chunking wave.** The markup-integrity
  measurement now diffs against the raw source (it previously diffed against the chunker-normalised
  text), so the baseline may shift. Run against a live Ollama from the package root and record the
  result per `docs/BASELINE.md`.
- **Cosmetics on the Модели tab** — the `aya-expanse:8b` value wraps to three lines. The other
  half of this entry, «the settings window changes size between tabs», is retired: all three
  panes now take one 560 × 480 frame from `settingsPane()`. Whether the resizing has actually
  stopped is in §1, unobserved.
- **One regression guard is strengthened rather than proven deterministic.**
  `aReusedControllerMeasuresThePressItIsShowingNotThePreviousOne` catches the removal of
  `measuring.view.layoutSubtreeIfNeeded()` by observing that a reused measuring host is stale.
  With one long press and one short one it caught that mutation 3/3 under `--filter Panel` and
  **39/40 under the full suite**, which is the suite this project gates on. The escape is per
  *measurement*, not per run: on the one escaping run of forty,
  `aPanelShownBeforeItsTranslationArrivesEndsUpAsWideAsThatTranslationNeeds` caught the same
  mutation in the same process, so something outside the test freshened one host and not the
  other. What that something is was **not isolated** — the test has no suspension point of its
  own, so it is inside AppKit or SwiftUI. The guard now alternates five times instead of once,
  which measured 0 escapes in 40 runs. That is a reduction, not a proof, and it is written here
  rather than left as a guard that «usually works».
- **Two copy strings ship differently from the spec, on purpose.** Spec §5.4 names the glossary
  header's language control «Показывать перевод на»; it ships with that wording but
  `.labelsHidden()`, so the string is the accessibility label and a `.help` tooltip rather than
  a visible one — the header already carries a search field, a term count and two buttons, and
  the picker itself is capped at 140 pt, which is listed in §1 as not yet known to fit the
  longest Russian language name. Spec §5.3 names the download section «Загрузка»; it ships as
  «Загрузить модель», because this pane says «модель в памяти» and «модель не загружена» a few
  rows above, so the bare noun reads as «loading into memory» as readily as «downloading».
- **The smaller findings the UI redesign deferred are listed in its ledger**, not repeated
  here: `docs/history/2026-07-30-ui-redesign-ledger.md`. They are test-coverage gaps and
  comment imprecisions rather than behaviour, with the exception of the resize items above,
  which are here because a user could meet them. Most of that list was closed by the final fix
  wave; the ledger's own «Deferred» section says which.

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
- **Whether `MenuBarExtra` caches its content view.** `TranslatorApp.swift` states it as fact.
  The claim is inherited from general SwiftUI behaviour, not measured on this system, and it is
  part of why «when the menu opens» is not one of the glyph's refresh points.
- **Whether the four new `Log` call sites actually emit on the assembled bundle.** `Log` is
  wired into the refused hotkey registration, the failed warm-up, an unencodable hotkey and the
  swallowed document-glossary failure. All four are compiled and none has been observed in
  `log show` — the first two need a real launch, the third needs a corrupt value, and the
  fourth needs a multi-chunk run whose term-list call fails. The predicate to watch is
  `subsystem == "com.mordvic.localtranslator"`.

---

## 4. Housekeeping

`Scripts/make-app-bundle.sh` depends on a «LocalTranslator Dev» certificate in the login
keychain. If it is deleted the script silently falls back to ad-hoc signing, and the
Accessibility grant starts dying on every rebuild — which makes the whole hotkey path
unverifiable. The recipe for recreating it is in the script's own header.
