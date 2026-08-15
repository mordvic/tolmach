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
| A drop of **only** unreadable files | «Файлы · N» counts `translatable`, so a drop where every file is refused now shows no count at all where it used to show one — the rows are still listed, and the pane says why each was refused. Whether the bare «Файлы» over three red rows reads as right is a judgement about the drawing, not about the rule | `MainWindowView.swift` |
| A refused glossary save shown in **«Текст»** | `promoteToGlossary`'s three failures are raised from the terms sheet, which the ⌥⌘T panel opens over a window whose own text model may never have run. The sentence is now an always-visible orange row in both modes rather than a count under a chevron; what needs eyes is that it does not push the status bar's own line out of shape when it wraps | `RunStatusBar.swift` |
| «Файлы · N» beside a queue containing **unreadable** rows | Both the header and the status line now count `translatable`, so a drop of five files of which two are unreadable should read «Файлы · 3» over «…из 3». Only the model half is testable — the header is SwiftUI | `MainWindowView.swift`, `FileQueueModel.translatable` |
| A finished translation with **no** warnings fills the panel | The empty warnings slot used to eat 86 pt of a fixed 260; the fix gates the slot on `WarningsView.hasContent`. The panel is no longer 260 pt tall, so the original arithmetic no longer applies — what is owed now is simply that a finished result with no warnings looks whole | `PanelView.swift`, `WarningsView.swift` |
| «Открыть в окне» with a **finished** translation already in the window | The hand-off moves `outcome`, `resolvedTarget` and `state` together; the failure it fixes was the window showing the previous run's elapsed time and warnings under the new text. The window it hands to has since been rebuilt. Since 2026-08-15 it also pins «Степень» and «Стиль» to what the adopted правка actually used, so «Ещё вариант» re-runs what is on screen, and it clears «Из», «В» and «Тон» — which now describe only the text pane's own run, the queue having its own three. What to look at: after «Открыть в окне» the toolbar in «Текст» should describe the adopted run, and switching to «Файлы» should show the queue's own pickers exactly as they were left | `TranslationViewModel.adopt(from:)`, `FileQueueModel.sourceOverride` |
| «Открыть в окне» while the window is **busy** | The button should be disabled with «Окно занято своим переводом» beneath it, and re-enable itself when the window finishes | `PanelView.swift`, `AdoptionRefusal` |
| The window and Settings actually coming **forward** | `NSApp.activate(ignoringOtherApps:)` does not activate on macOS 14; replaced with cooperative activation, which no one has watched work | `activateThisApp()` in `TranslatorApp.swift` |
| The permission row clearing after granting and returning | It is refreshed on `didBecomeActiveNotification`; the failure it fixes was telling the user their grant had not worked | `SettingsGeneralView.swift` |
| The icon in Finder, Spotlight and the Accessibility list | Nothing here can see the screen; the rendered PNGs were checked, how macOS composites and caches them was not. Finder caches icons aggressively — a blank sheet right after the first build is a cache artefact, not a failure | `Scripts/make-icon.swift` |
| The ink tile against a **dark** desktop background | The dark ground was chosen over the parchment one with this trade-off stated and accepted; whether it separates well enough in practice has not been looked at | `Scripts/make-icon.swift`, spec §2.4 |
| **The panel's floor actually stopping a drag** | `contentMinSize` states the sizer's floors to AppKit, and that is where the guarantee lives — a programmatic frame ignores it, measured: `setContentSize(10, 10)` on a shown panel gives a 10 × 10 frame, and `constrainFrameRect` is overridden to return frames untouched. So a test can assert the minimum is set and nothing more; whether the drag stops there, and how the stop feels, needs a hand on the mouse | `TranslationPanel.init` |
| **Dragging the panel's edge**, in both directions and past the floor | The end of a drag is pinned by a test — dragged 150 pt shorter, the panel switches to the scrolling variant and keeps the height the user chose. What no test here can reach is the drag *itself*: `inLiveResize` cannot be simulated, so whether the content follows the edge smoothly rather than in throttled steps, and what dragging below the 132 pt floor feels like when `PanelSizer` pushes back, are both owed to a hand on the mouse | `PanelController.windowDidResize` |
| The panel saying «Перевожу…» **from the first frame** | It now reports progress for as long as the reply to the current selection is outstanding, rather than from `.running` — which arrives after the panel is on screen. That is what makes `show(at:)` measure the row it is about to grow, and it also stops the previous press's `.finished` or `.failed` status being shown under a new selection. What needs eyes is the first frame itself: a spinner that appears with the panel rather than a beat later | `PanelView.status` |
| «Перевести» on **macOS 15**, where the dark window ground is lighter | CI caught what one machine could not: the fill separates from the dark window at 3.51 on macOS 26 and **2.70** on macOS 15, under the 3:1 a control wants. It is not a colour to be tuned — on that ground the arithmetic has no solution, because separating at 3:1 needs a fill luminance of at least 0.196 while carrying a white label at 4.5:1 allows at most 0.183. The label was chosen over the separation, since illegible text is the complaint this colour answers and a filled capsule with a word in it is not identified by its boundary alone. Someone on macOS 14 or 15 should say whether the button still reads as a button there | `PrimaryButtonColour.fillColour` |
| «Перевести» **no longer following the accent**, and its teal against the success green | The button is the app's own `#15807E` rather than `controlAccentColor`, which is a deliberate step away from the HIG: the accent could not carry a readable label (4.02:1 at best, 1.41 on yellow) and the primary action is the one control worth owning. Two judgements a person should make. Whether a fixed teal reads as the app's colour or as a control that has stopped responding to their setting; and whether it is far enough from `StatusColour.success` — 74 in sRGB, the one number here with slack in it, though the two never share a shape (a filled button carrying a verb against an 11 pt label with a ✓) | `PrimaryButtonColour.swift` |
| A prominent button under a **non-blue accent** | `AccentLabel` still governs any control filled with the system accent, though «Перевести» is no longer one. The label goes black instead of white on the orange, yellow, green and graphite accents, because white on those measures 1.41–2.87:1 against a 13 pt label. The arithmetic is settled and the taste is not: a black-lettered button is unusual on macOS, and whether it reads as deliberate or as broken is a judgement. Change System Settings → Внешний вид → Акцентный цвет to check | `AccentLabel.swift` |
| The running queue row's **accent tint**, deliberately left as it is | Measured against the pane it sits on: the 8% fill is 1.11:1 and the 35% border 1.60:1, where a non-text indicator wants 3:1. Not raised, because the row already says «Перевожу часть 4 из 7» and draws a progress bar — the colour reinforces rather than carries, so WCAG 1.4.1 is met, and a tint strong enough to reach 3:1 would read as an alarm. If a person finds it invisible rather than merely subtle, that is the reason to change it | `FileQueuePane.swift` |
| A **multi-page** selection opening the panel at 60% of the screen | Measured: 2 000 characters opens it at 550 pt, and 8 000, 16 000 and 100 000 all open it at 998 — the 0.6-of-screen ceiling. The 16 000-character cap bounds what the measurement costs, not the height it reaches, and an earlier comment implied otherwise. This is the reservation working: a reply to pages of text needs that room, and opening there is the alternative to climbing there during the run. What it costs is a panel over most of the document from its first frame, which is a judgement rather than a number | `PanelView.selectionAwaitingReply` |
| Clicking the source pane's **top 8 pt** | The strip is padding, so it is outside the editor's hit region; a tap gesture gives it back, but a gesture can only set focus — it cannot place the caret where the click landed. Clicking a margin and getting focus is defensible and strictly better than a click that does nothing, but whether it feels right needs a hand on the mouse | `SourceEditor.swift` |
| «Перевести» **disabled** | The label used to keep an explicit white through `.disabled()`, because SwiftUI dims a button's default foreground and an explicitly styled `Text` has none — white semibold on the desaturated prominent fill, in the state a user with Ollama stopped meets first. It hands the colour back now: rendered and counted, an enabled button has 953 near-white label pixels and a disabled one none. What that leaves on screen is the platform's own dimming, which nothing here can judge | `PrimaryButtonColour.Label` |
| **The gap under the panel's buttons matching the gap above its header** | Reported from a screenshot and confirmed by measurement: the installed hosting view was taking a 24 pt title-bar safe area the measured copy knew nothing about, so content shifted down and the bottom padding went — 28 above against 2 below, and −2 after the settle shrink, with the buttons past the frame. `safeAreaRegions = []` fixes it: on a live translation the gaps read 14 and 14 through the run, and `wants == panel` at the settle with nothing overhanging. Two things a person should still confirm: that the settled panel looks even — the topmost leaf sits 2 pt lower after a settle than during the run, which is below what these measurements can attribute — and that this holds on a display with a different backing scale | `PanelController.init` |
| **The button row sitting at the bottom of the panel**, at several heights | The regression that survived a whole review pass: a misplaced brace closed the middle section's `VStack` early, so `scrollingMiddle` returned three siblings — the translation, the warnings **and the button row** — and `.frame(maxHeight: .infinity)` on that splits the slack between them instead of stacking them. Measured by the review in hosts of 132, 300 and 500 pt with a one-line reply: the row landed at y = 79, 163 and 263 rather than at the bottom. The nesting is corrected and no test pins it — finding the row in the rendered hierarchy costs more than it returns here, so this is the check a pair of eyes owes | `PanelView.translation` |
| **The warnings scrolling with the translation** rather than sitting above the buttons | A deviation from the three-section shape as it was asked for — status, warnings and buttons all pinned — and the arithmetic is why: the warnings are the only part with no length of its own, and a ceiling for them (160 pt) is larger than the panel's whole floor (132), so at the smallest size the user may drag to, the pinned block alone outgrew the window. They belong to the translation, they describe it, and inside the scrolling region their length costs only itself. Whether that reads right is the judgement | `PanelView.swift` |
| The ⌥⌘T panel **dragged to its floor** with a failure showing | The floor is 132 pt now, measured as what the panel pins at its narrowest — a failure message wrapping to two lines in a 300 pt panel needs 130. At exactly that size the translation section is left with nothing, which is a consequence of the size the user asked for rather than a defect: the error explaining the empty pane, and both buttons, stay visible. Raising the floor further would clear a line of translation too (~148) at the price of ~54 pt of hole under every short reply, which is the defect the panel was rebuilt to remove. Whether that trade reads right is the judgement | `PanelSizer.minHeight` |
| **A reply much shorter than its source**, in the ⌥⌘T panel | The panel now reserves the reply's room from the selection, so it opens at the size the reply will need and the buttons stop travelling — pinned at 198 pt opening against 174 settled for a six-sentence paragraph, verified by `thePanelOpensAtTheSize…`. What no test can say is how the slack reads when the estimate is generous: a source that translates much shorter, or one the model answers in a word, leaves the panel taller than its content with the buttons held at the bottom edge | `PanelView.swift` |
| **How the toolbar reads now that each control carries its own label** | The structure is settled and the taste is not. Measured on the bundle: each item's host is the same size as the single control inside it — 124 × 36 holding 124 × 36 — which is the shape the ⇄ button and «Перевести» always had, and the nesting that made a pill inside a pill is gone. At 700 pt, with four selections including the longest language name on both sides, 5 of 5 items are visible and no title is drawn. What a person has to say is whether «Из русский» reads as one control or as a run-on, and whether the row moving as the selection changes — a `Menu` is as wide as its title — is distracting | `MainWindowView.swift` |
| «китайский» in the pickers and in «будет переводиться на …» | The one user-facing string this work changed, and it is what buys the drawing's own 700 pt minimum: with «(упрощённый)» the row needs 740 pt with Chinese chosen once and 810 with it chosen twice. Nothing here can judge whether a reader loses something the prompt's own «Chinese (Simplified)» does not cover — the app offers one Chinese, so it distinguished nothing on offer | `Language.russianName` in `RussianCopy.swift` |
| The window still named «Толмач» in the «Окно» menu, in Mission Control and to VoiceOver | `titleVisibility = .hidden` is chosen over `.navigationTitle("")` precisely to keep the name everywhere except the title bar, and that claim is about three surfaces none of which can be read from here. The «Окно» menu is the one that matters — this app adds «Открыть окно перевода» to it | `WindowTitleHidden` in `MainWindowView.swift` |
| The window **opening** at 900 × 520 | `.defaultSize` is the drawing's number, and nothing here can see a window. Two things it does not answer and a person can: where `HSplitView` puts the divider at that width — the drawing gives «Файлы» a 344 pt left pane and «Текст» an even split — and whether a default is honoured at all on a `Window` scene the user has already resized once, since SwiftUI restores the remembered frame in preference to it | `TranslatorApp.swift` |
| A queue row as a **card**, and the selection still visible under a running one | The tint moved out of `.listRowBackground` into a fill inside the card precisely so `List` keeps drawing its selection — the pane on the right shows the *selected* задание, so a selection hidden under the running row's tint is a user who cannot tell whose translation they are reading. What needs eyes is the coincident case: the running файл selected, both the accent fill and the selection on one row | `FileQueuePane.swift` |
| A card holding a row at its **tallest** — полоса, «Перевожу часть 4 из 7 · 12 терминов документа», предупреждение and «Сохранить рядом с исходником» at once | The 9 × 8 padding and radius 6 were read off the drawing, where every row is two or three lines. A six-fragment row is the case the drawing does not contain, and whether the border still reads as one card rather than as a box around a paragraph is a judgement about the drawing | `FileQueuePane.swift` |
| «Повторить» actually drawn **smaller** than the buttons around it, in both the window and the panel | The drawing gives it 19 pt against everything else's 22, and `.controlSize(.small)` is the claim that produces it — a claim nothing here can render. Two things a person can settle: whether the small bezel still reads as a button beside a red sentence rather than as a badge, and whether it stays legible in the panel, where it sits directly above «Скопировать» and «Открыть в окне» at full size | `RunStatusBar.swift`, `PanelView.swift` |
| **«Отключать рассуждение модели» and «Длина рассуждения у gpt-oss»** in «Модели» | Two controls added to the «Качество перевода» section, which was already the tallest in that pane. Nothing here can see them. Three things a person settles: that the section still reads well inside `settingsPane()`'s 560 × 480 — `.formStyle(.grouped)` scrolls, so the question is legibility rather than clipping; that the depth row is absent with `aya-expanse:8b` selected on both paths and appears when either becomes `gpt-oss`; and that unticking the checkbox greys the row rather than removing it, which is the distinction the code makes on purpose. The rule behind the row's visibility is pinned by `theDepthRowIsOfferedOnlyWhileAGptOssModelIsSelectedOnEitherPath`; its drawing is not | `SettingsModelsView.swift`, `AppSettings.usesGptOss` |
| A glossary row's two fields against the search field above them | They now ask for `.roundedBorder` explicitly instead of taking `.automatic`, which inside a `List` inside a grouped `Form` is a container's answer rather than the row's. The expectation is that nothing moves — macOS's automatic style is bordered too — so what needs eyes is exactly that: the row not growing taller and the four columns still lining up with the header | `GlossaryList.swift` |
| **Whether 4.20:1 is enough for «нет доступа» and the queue's warnings** | The one judgement in `StatusColour` a number cannot settle. The light warning colour is the drawing's `#c26100`, which is 4.20:1 on a white pane — nearly double `systemOrange`'s 2.31:1, and still short of WCAG AA's 4.5:1 for text this size. It is kept as drawn because this type exists to implement the drawing, and closing the gap is a change to one constant plus one threshold in `StatusColourTests`. A person reading an 11 pt orange caption on a bright display is the only one who can say whether it needs closing | `StatusColour.swift`, `Scripts/colour-contrast.swift` |
| All three status colours **in the panel**, over `.regularMaterial` | The contrast figures are computed against a flat white pane and a flat `#1e1e1e`. The panel is neither: it is a blurred sample of whatever document is behind it, so its actual ground is unknown and changes as the user moves the window. `PanelView` writes «Перевод прерван…» and «Ollama не запущена…» in these colours, and whether they hold up over a bright page is the case the arithmetic cannot reach | `PanelView.swift`, `StatusColour.swift` |
| The warnings' 16 pt indent under a **wrapping** summary line | The indent puts «Разметка изменилась» under «Готово за 4 812 мс» rather than under the chevron. What it was not checked against is the line wrapping — «Готово за 4 812 мс · 4 предупреждения» is long, and a summary on two lines changes what the block is indented *under* | `RunStatusBar.swift` |

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

**Owed by «Шрифт текста».** The setting reaches three text sites, a settings section and three
menu items. What the suite can hold is that the panel is *measured* in the chosen font and that
the reservation shares it; everything below needs a screen or a physical key.

| What to check | Why it needs eyes | Code |
|---|---|---|
| **⌘+ and ⌘− actually firing** | `Scripts/view-menu.swift` records what SwiftUI stores: key `'+'` with mask `⌘`, i.e. the shifted character with no ⇧ in the mask. Whether AppKit then matches a physical ⇧⌘= is a question about key-equivalent matching that no dump can answer and no keystroke can be sent from here. If it does not fire, the fallback spelling is `"="` — displayed as ⌘=, matched unshifted | `TranslatorApp.commands` |
| **⌘+ reaching the панель while the app is inactive** | The panel is key without its process being active, which is the whole point of `.nonactivatingPanel` — but menu key equivalents are dispatched through `NSApp.mainMenu`, and whether that happens for an inactive application is exactly the routing this project refuses to assert. Decided in advance: if it does not, the answer is to leave it, because the panel is read for seconds and the setting is changed rarely. A size control *inside* the panel is the open branch, and it would need the 272 pt row measured the way `Scripts/panel-proofread-row.swift` measured правка's | `TranslatorApp.commands`, `PanelView` |
| The three faces at a large size, and whether «Моноширинный» reads as a translation pane or as a terminal | Metrics are measured; legibility is not. The one thing already known is that CJK ignores the choice — measured, `zh`/`ja` come out at the same width under `default`, `monospaced` and `rounded` | `ContentTypeface` |
| The «Текст» section at 32 pt, with the sample line | The sample is `lineLimit(1)` so it cannot grow a second line and push the section about, which means at a large size it will *truncate*. Whether a cut-off sample still does its job is a judgement | `SettingsGeneralView` |
| The исходник pane at a large size, with the placeholder | The placeholder now takes the editor's font so the two share a baseline. That pairing was reasoned from the same defect the 8 pt inset fixed, and rendered by nobody | `SourceEditor` |
| **Re-take the reservation's cost figure** | `PanelView.reservation(for:font:)` still carries «16 000 characters → 43.1 ms», measured on the assembled bundle. A stand-in probe could not reproduce it — it reports fractions of a millisecond — so the font-derived cap rests on «the same answer for less work» rather than on a measured saving. Someone with the bundle should re-take it at 13 and at 32 pt, or the sentence should be deleted | `ContentFont.reservationLimit` |

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

**Owed by the правка shortcut (2026-08-15).** The whole path from a key press to a panel in
правка mode is unobservable from here — nothing in a test process can press a Carbon hot key,
so the wiring is pinned at `pressAction(for:)` and the rest is eyes-only.

| What to check | Why it needs eyes | Code |
|---|---|---|
| **A press of ⌥⌘R over a selection** | The feature. Select a sentence with a mistake in another application and press it: the panel must open already saying «правка · …», with the segment on «Правка» and the степень/стиль row under it. This is also the only check that ⌥⌘R is actually free — `Scripts/hotkey-availability.swift` can only rule out a shortcut the user has *customised*, because `com.apple.symbolichotkeys` stores deviations from the factory set rather than the set (measured: Spotlight's own entry is absent from it) | `HotkeyCoordinator.apply`, `TranslatorApp.launch()` |
| **A pop-up menu inside the panel** | Open either picker in the row. The panel is a `.nonactivatingPanel` — key while the application stays inactive — and no measurement in this project covers `NSMenu` in that state. If it does not open, the fallback is the stacked layout `Scripts/panel-proofread-row.swift` already measures at 122 × 36 | `PanelView.proofreadingControls` |
| The row at the panel's narrowest | Drag the panel to its 300 pt floor with правка showing. The row measures 242 pt against the 272 the floor leaves, so it should fit with ~30 pt to spare — what no probe can say is whether it *reads* right that tight, or whether the ⨯ ends up crowded | `PanelSizer`, `PanelView.proofreadingControls` |
| Two recorders in «Основные» | The section is two rows, a three-sentence caption and a conditional orange row now, inside a pane with a fixed 560 × 480 frame. The refusal on a duplicate combination is a beep with no words: check that the caption's last sentence is visible without scrolling, since it is the only thing that explains the beep | `SettingsGeneralView.swift` |
| **The inherited collision**, if you can reproduce it | Set перевод to ⌥⌘R, quit, delete the `proofreadHotkey` key (`defaults delete <domain> proofreadHotkey`), relaunch. Expected: перевод still works on ⌥⌘R, правка's shortcut does nothing, and «Основные» carries the orange row explaining why. This is the one state the recorder is written to prevent and cannot, so it is worth seeing once | `AppSettings.shortcutsCollide`, `HotkeyCoordinator.shouldRegister` |
| A степень changed from the panel | Change it and watch two things: the правка re-runs on the same text, and «Основные» shows the new value afterwards. The setting is written deliberately (design §6) — if that ever reads as surprising, this is where the complaint will start | `HotkeyCoordinator.setProofreadingLevel` |

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

- **The правка quality gate (spec §11.1) has not been run on its designated corpus,
  and a parallel calibration run on a different corpus came back NOT a clean pass.**
  The committed `docs/proofreading-gate/` corpus — the one this entry names below —
  has still not been pasted through the window's «Правка» mode; that run predates
  this entry's own discovery of that corpus and used a throwaway 11-text scratchpad
  corpus instead (see «5. Правка prompt calibration — corpus and results
  (2026-08-10)» below). That run's verdict: protected-span corruption on 4/4
  code-bearing texts (backticked or fenced code silently rewritten, once overriding
  an explicit in-line «do not fix this string» comment), two rephrasing failures
  beyond the seeded errors, and of the four rewrite styles only «деловой» showed a
  real, consistent register shift — «дружелюбный» and «простой» no-op on the probe
  text and «профессиональный» neither shifts register nor stays stable across runs.
  Neither gap was closeable by further prompt wording within this pass; both were
  escalated at the time. **Closed, 2026-08-10, by the code-protection-and-styles
  pass**, not by a further prompt guess: the protected-span escalation is moot by
  construction for fenced code — a fenced block is now a passthrough chunk that
  never reaches the model, so there is nothing in it for the model to reword — and
  for inline code the span is restored from the source's own bytes after the model
  returns, deterministically, rather than asked of the model at all. Re-run against
  this same corpus: `codeIntact` 12/12 (03/04/08/09 × 3 runs each), both before and
  after a follow-up prompt fix (§3.1) that dropped «voice» from the level
  instruction under a named style. The style no-ops (`friendly` on files 11 and 12,
  `plain`'s grammar defects, `professional`'s instability) persisted unchanged
  through that fix and are recorded as an honest model limitation with
  `aya-expanse:8b`, not an open merge question — see «Part A verification and the
  style matrix (2026-08-10, follow-up)» in §5 below for the full counts.
- **The 700 pt toolbar minimum is now assumed, not measured.** The translate-mode toolbar
  gained the «Перевод | Правка» operation switch, and the 650/680 pt fit measurements it
  rests on — and the 700 pt minimum `MainWindowView.swift` derives from them — predate that
  switch. Re-measure on the running bundle against `NSToolbar.visibleItems`;
  `Scripts/toolbar-fit.swift` models the pre-switch row and needs extending to include it.
  Until then, treat 700 as a carried-over guess rather than a re-confirmed floor.

---

## 2. Known and accepted

- **Making the text smaller while the панель is open leaves a gap under it.** The panel
  re-measures on a font change, but `PanelSizer`'s height is monotonic within a presentation —
  only the settle may shrink it — so the reply gets smaller and the window stays the height it
  was until the panel is dismissed. Growing works immediately.
  *Chosen rather than worked around.* The one call that shrinks is the settle, and a settle also
  freezes the presentation's width; a font change has no business deciding that. The cost lasts
  one presentation.

- **A large «Шрифт текста» makes the панель a narrow column.** `PanelSizer.maxWidth` stays 560,
  which is 75 characters of Russian prose at 13 pt — the classic reading measure, and the reason
  the number is what it is. Holding that measure at 22 pt would need a 947 pt panel, which is a
  second window floating over the document rather than a panel. So at large sizes the measure is
  lost in the direction of «too narrow», and long replies scroll more.
  *Considered and declined.* Growing `maxWidth` with the size was the first recommendation and
  was withdrawn once the arithmetic was done: the width needed to keep the measure outgrows what
  a panel can be before the largest sizes are reached. `docs/adr/0008` carries it.

- **The two shortcuts cannot be swapped in one step.** Each recorder refuses what the other
  holds (`HotkeyRecorder.reserved`), so a user who wants перевод on ⌥⌘R and правка on ⌥⌘T —
  their current values, exchanged — has to route one of them through a third combination
  first. Both directions beep, and the beep says nothing about which one is blocked; the
  caption's «Сочетания должны различаться» is the only hint on screen.
  *Raised by review, accepted rather than fixed.* The alternatives are worse than the friction:
  accepting a candidate that equals the other's current value would store a duplicate and rely
  on the user completing the swap, and a duplicate is the state
  `AppSettings.shortcutsCollide` exists to report as broken. A swap is a rare gesture; a stored
  collision is a shortcut that silently does nothing. If this is ever revisited, the shape to
  look at is a two-field editor that validates the pair on commit rather than each field on
  its own keystroke.

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
  it up. What is deliberate now: the width is clamped to 300–560 pt; the height has a 132 pt
  floor, is monotonic within a presentation **except at the settle** — the one fit allowed to
  shrink, so the room reserved for a reply is given back when a shorter one arrives — and is
  capped at 0.6 of `visibleFrame`, past which the content scrolls instead; and dragging an edge
  hands the size to the user until the panel hides, settle included. `PanelSizer` owns all four rules and is where to change them.
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
- **The buffer-whole cost of inline-code restore is measured but not yet weighed against
  the interactive TTFT bound.** Spec §2.2 accepts, deliberately, that a chunk whose source
  carries inline code spans buffers its whole reply before emitting anything, rather than
  streaming incrementally, so restore's equal-count gate can be decided before a byte
  reaches `onToken`. The price shows in the corpus: techdoc's TTFT moved ~2.9→~4.27 s (en)
  and ~3.2→~4.3 s (ru) once the re-basing landed (`docs/BASELINE.md`'s 2026-08-10 entries,
  «after the idiom/proper-noun rule» through «re-based state accepted»). Both are
  multi-chunk and so outside the <1 s gate — but the gate's own single-chunk corpus files
  (`email-en.md`, `snippet-en.md`) carry no backticks at all, so a hotkey selection that
  *does* contain inline code has never actually been measured against the interactive
  bound; whether buffer-whole can blow it is untested, not cleared.
- **`aya-expanse:8b` stochastically drops the leading `>` on a blockquote that follows a
  standalone passthrough fenced chunk, once the following chunk is recomposed.** Accepted
  2026-08-10 as a known limitation rather than chased further — see `docs/BASELINE.md`'s
  2026-08-10 entries, from «after pass-through chunks and inline restore (re-basing)»
  through «re-based state accepted», for the measurements and the reasoning; not retold
  here.
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

---

## 5. Правка prompt calibration — corpus and results (2026-08-10)

The §11.1 manual quality gate of the proofreading design, run as the baseline of the
prompt-improvement pass (specs/2026-08-10-prompt-improvement-design.md §3.2). Corpus:
11 texts (verbatim below with their seeded errors); runner: throwaway scratchpad script;
model: aya-expanse:8b, temperature 0.2, 3 runs per text per wording. This corpus is a
parallel one, assembled before this run noticed that a committed gate corpus already
exists at `docs/proofreading-gate/` (10 files, named in §1 above); that committed corpus
was not used by this run and remains un-run.

`01-ru-letter.txt` (seeded: «колега»→коллега; missing comma before «что»; «будующем»→будущем):
```
Привет колега! Хочу напомнить что отчёт нужен к пятнице. В будующем постараюсь предупреждать заранее.
```

`02-ru-bureau.txt` (seeded: «осуществляеться»→осуществляется; канцелярит is style material for Task 5, not an error):
```
Осуществляеться процесс согласования документации. В целях обеспечения выполнения плана просим вас направить ваши предложения в кратчайшие сроки.
```

`03-ru-inline-code.txt` (seeded: «комманду»→команду; «зделайте»→сделайте; `git comit --amend` inside backticks MUST stay byte-identical):
```
Чтобы поправить последний коммит, выполните комманду `git comit --amend` — да, именно так называется наш алиас. После этого зделайте `git push --force-with-lease`.
```

`04-ru-fenced.txt` (seeded: «целеком»→целиком; the fenced block MUST stay byte-identical, including the comment):
````
Ниже пример конфига. Скопируйте его целеком в файл настроек.

```yaml
server:
  port: 8080 # порт по умолчанию, не менять
```
````

`05-ru-grammar.txt` (seeded: «обсудили о планах»→обсудили планы; «более лучше»→лучше):
```
Мы обсудили о планах на квартал. Новый подход работает более лучше, чем старый.
```

`06-en-letter.txt` (seeded: you're→your; recieve→receive; friday→Friday; it's→its):
```
Thanks for you're feedback! We will recieve the final report on friday and share it's summary with the team.
```

`07-en-bureau.txt` (seeded: «The results shows»→show; wordiness is style material for Task 5):
```
In order to facilitate the optimization of our workflow, the team decided to utilize a new methodology. The results shows significant improvement.
```

`08-en-inline-code.txt` (seeded: Dont→Don't; `npm instal` inside backticks MUST stay byte-identical):
```
Run `npm instal` first — the alias is intentional. Dont forget to run `npm test` before you commit.
```

`09-en-fenced.txt` (seeded: folowing→following; the fenced block MUST stay byte-identical, including the misspelled string):
````
The folowing snippet prints a greeting. Copy it exactly as is.

```python
print("helo wrld")  # do not fix this string
```
````

`10-en-question.txt` (seeded: i→I; first «.»→«?»; explane→explain — a text that IS a question: the run must correct it, never answer it):
```
How do i configure the server. Can you explane the steps briefly.
```

`11-style-probe-ru.txt` (no seeded errors — the register-shift probe for the four styles):
```
Привет! Глянь, пожалуйста, мой черновик, когда будет минутка. Там есть пара сомнительных мест, особенно в начале, — скажи, что думаешь.
```

### Baseline observations (current instruction wording)

Every text's 3 runs at `.errorsOnly` (or, for 11, 3 runs per style at `.errorsAndStyle`)
agreed with each other in every case observed — no run-to-run variance was seen anywhere in
this corpus, so «N/3» below always means N identical runs, not a split.

- **01 — PASS.** «колега»→коллега 3/3, missing comma before «что» added 3/3, «будующем»→будущем
  3/3. No wording changed outside the three seeded errors. `lang=ru` 3/3.
- **02 — FAIL (reorder).** «осуществляеться»→осуществляется fixed 3/3, but the model also
  moved the verb to the end of the sentence in all 3 runs — source «Осуществляеться процесс
  согласования документации.» became «Процесс согласования документации осуществляется.» —
  which «только ошибки» explicitly forbids («do not reorder»). Second sentence untouched.
- **03 — FAIL (protected span corrupted + extra rewording).** «комманду»→команду 3/3,
  «зделайте»→сделайте 3/3. But the backticked span `git comit --amend` — deliberately
  misspelled per the text's own claim («да, именно так называется наш алиас») — was silently
  corrected to `git commit --amend` in all 3 runs (`codeIntact=false` 3/3, `markupDiffs=2`
  3/3). All 3 runs also swapped two words the seed list never named: «поправить»→«исправить»,
  «алиас»→«псевдоним».
- **04 — FAIL (fenced block corrupted).** «целеком»→целиком fixed 3/3. But the fenced YAML
  comment `# порт по умолчанию, не менять` was rewritten to `# порт по умолчанию, не
  изменяйте` in all 3 runs (`codeIntact=false` 3/3, `markupDiffs=2` 3/3), despite the brief's
  requirement that the fenced block stay byte-identical. 1/3 runs (run 2) additionally swapped
  «конфига»→«конфигурации», a word the seed list never named.
- **05 — PASS.** «обсудили о планах»→обсудили планы 3/3, «более лучше»→лучше 3/3. No other
  wording changed. `lang=ru` 3/3.
- **06 — FAIL (extra rewording despite every seed fixed).** you're→your 3/3, recieve→receive
  3/3, friday→Friday 3/3, it's→its 3/3 — every seeded error fixed in every run. But «Thanks
  for» was reworded to «Thank you for» in all 3 runs, a phrasing change outside the seed list
  that «только ошибки» forbids.
- **07 — PASS.** «The results shows»→show fixed 3/3; the wordy bureaucratic phrasing («In
  order to facilitate the optimization of our workflow… utilize a new methodology») was left
  untouched in all 3 runs, exactly as `.errorsOnly` requires — that wordiness is style
  material reserved for Task 5. `lang=en` 3/3.
- **08 — FAIL (protected span corrupted).** Dont→Don't fixed 3/3. But the backticked,
  deliberately misspelled `npm instal` («the alias is intentional») was silently corrected to
  `npm install` in all 3 runs (`codeIntact=false` 3/3, `markupDiffs=2` 3/3).
- **09 — FAIL (protected span corrupted, worst case).** folowing→following fixed 3/3. But the
  fenced Python string `print("helo wrld")`, annotated in-line «# do not fix this string»,
  was corrected to `print("hello world")` in all 3 runs (`codeIntact=false` 3/3,
  `markupDiffs=2` 3/3) — the model overrode an explicit in-text instruction it had to have
  read to produce the surrounding prose fix.
- **10 — PASS, with a note.** i→I fixed 3/3, first «.»→«?» fixed 3/3, explane→explain fixed
  3/3. The output is the corrected question in every run, never an answer — the criterion
  §11.1 calls out by name for this text is met. All 3 runs also changed the second sentence's
  closing «.» to «?» («Can you explane the steps briefly.» → «…explain the steps briefly?»);
  that sentence's own form («Can you…») is already interrogative, so this reads as a second,
  legitimate punctuation fix rather than a paraphrase, but it sits outside the brief's stated
  seed list and is worth Task 5 knowing about.
- **11 — mixed; one style works, three do not shift register at all.** `original` (no style
  instruction) reproduces the source with one small, stable smoothing 3/3 — «когда будет
  минутка»→«когда у тебя будет минутка» — and preserves meaning. `business` is the only style
  that shows a genuine, consistent register shift 3/3: ты→вы address, «Глянь»→«Обратите
  внимание», «скажи, что думаешь»→«поделитесь своими мыслями» — a formal epistolary register,
  meaning preserved. `friendly` and `plain` are each **byte-identical** to the `original`-style
  output in all 3 runs — the friendly and plain-language instructions produced zero observable
  change on this already-casual, already-short source. `professional` shows only a cosmetic
  synonym swap («пара»→«несколько») in 2/3 runs, with the third run (run 3) diverging further
  into a different partial rewrite («дай знать, что ты о них думаешь»); none of the 3 runs
  shifts into a documentation/workplace register — «Привет!» and ты-address survive in all
  three. `lang=??` was reported by `LanguageDetector` for the `business` run only (3/3); the
  output itself is legible, grammatical Russian, so this reads as a detector artifact on a
  short, formal text rather than a proofreading defect.

Summary for Task 5: 4/10 `errorsOnly` texts pass cleanly (01, 05, 07, 10); the other 6 fail —
two by rephrasing beyond the seeded errors despite fixing them (02's reorder, 06's «Thanks
for»→«Thank you for»), and four by corrupting a protected span (03, 04, 08, 09 — every text in
the corpus that contains backticked or fenced code failed on that code, 4/4). Of the four
rewrite styles tested beyond `.original`, only `business` reliably shifts register; `friendly`
and `plain` no-op on this source, and `professional` neither shifts register nor stays stable
across runs.

### After calibration (final wording)

Task 5 mapped each measured failure above to the decision table's candidate wording, edited
the source with a failing pin test first, recompiled the scratchpad runner (with the
`-module-name TranslationCore` fix Task 4 found necessary), and re-ran the full 11-text corpus
into a fresh out dir (3 runs per text/style, same as the baseline). Every candidate wording was
then compared against the baseline output text file by text file, not just the runner's
summary line.

**Result: none of the four candidate edits changed the measured output.** All four are
reverted; `Sources/TranslationCore/Proofreading.swift` carries the original wording again,
each site with a comment recording what was tried and what the re-run showed, per the
"measured/load-bearing" convention. No pin test asserts wording that did not survive.

- **`ProofreadingLevel.errorsOnly.instruction`** — failure: rephrasing beyond seeded errors,
  02 (reorder) 3/3 and 06 («Thanks for»→«Thank you for») 3/3. Candidate tried: append `" If a
  sentence contains no error, reproduce it unchanged, word for word."` Re-run: **0/3 fixed on
  both files** — 02's after-edit output is byte-identical to its baseline output (verb still
  moved to the sentence's end in all 3 runs), and 06's after-edit output is likewise
  byte-identical to its baseline (`"Thank you for"` in all 3 runs). **Reverted** — the append
  had no observable effect; the model does not treat an explicit "reproduce unchanged" clause
  as overriding whatever makes it rephrase these two sentences.
- **`RewriteStyle.friendly.instruction`** — failure: byte-identical to `.original`'s output in
  3/3 runs on file 11 (no observable register shift). Candidate tried: replace with `"...:
  direct address, light contractions where the language has them, no stiffness."` Re-run:
  **0/3 fixed** — all 3 after-edit runs remain byte-identical to the `.original` output, exactly
  as at baseline. **Reverted.**
- **`RewriteStyle.professional.instruction`** — failure: no reliable register shift on file 11
  (2/3 runs changed only «пара»→«несколько», 1/3 diverged further — the corpus's only
  run-to-run instability). This did not literally match the table's stated condition
  («drifted into bureaucratese or familiarity»), so per the brief's honest-nearest-fix
  allowance the candidate append was tried anyway: `" Prefer established terminology over
  invented phrasing."` Re-run: **the same pattern recurred** — 2/3 runs changed only
  «пара»→«несколько», 1/3 diverged further into a different partial rewrite. No improvement in
  either the register shift or the run-to-run stability. **Reverted.**
- **`RewriteStyle.plain.instruction`** — failure: byte-identical to `.original`'s output in 3/3
  runs on file 11 (no simplification). Candidate tried: replace with `"...: break long
  sentences into short ones, replace abstract nouns with verbs, choose the simplest common
  word..."` Re-run: **0/3 fixed** — 2/3 runs remained byte-identical to `.original`'s output,
  and the 3rd changed only «пара»→«несколько», a cosmetic synonym swap, not a shortened or
  simplified sentence. **Reverted.**
- **`RewriteStyle.business.instruction`** — passed baseline (genuine, consistent register
  shift, 3/3), unchanged. Not touched, per the brief: a wording that produced no failure is
  not edited.
- **Output-language rule** (`PromptBuilder.proofreadSystemPrompt` last-rule-line addition) —
  the language row's condition (output language ≠ input language in any run) was never
  observed; every run's `lang` matched its input language except the `business` runs' `??`,
  which Task 4's report already attributed to a `LanguageDetector` artifact on short, formal
  Russian rather than a translation failure. Row does not trigger; not touched.
- **Protected-span corruption** (03, 04, 08, 09, 4/4 in the baseline) — confirmed to persist
  in the after-calibration re-run: `codeIntact=false` and `markupDiffs=2` on all 4 texts, all 3
  runs each, same as baseline (spot-checked against the actual output text, not just the
  runner's summary field). Per the decision table, this is a `protectionRules` concern shared
  with translation, not a правка-specific instruction, and was **not** edited here.
  **Escalated, not addressed by Task 5** — `protectionRules` in `PromptBuilder.swift` needs a
  human decision on how (or whether) to strengthen the shared protection instruction, and any
  such change must be re-verified against the translation prompt's own corpus, not just this
  one.

Net effect of Task 5 on `Sources/TranslationCore/Proofreading.swift`: **no functional change.**
The file differs from its Task-4-era version only in comments recording what was tried and
measured at each site — the four instruction strings themselves are byte-identical to before
Task 5 began. `swift test` (672 tests) passes and `swift build --build-tests` is warning-clean
with this reverted state.

### Gate verdict

**§11.1 gate: NOT a clean pass.** Two distinct, unresolved gaps remain after calibration:

1. **Protected-span corruption is unfixed and escalated, not addressed.** `.errorsOnly` on any
   text containing backticked or fenced code (03, 04, 08, 09 in this corpus — every such text,
   4/4) does not meet §11.1's byte-identity requirement for code: the model rewrites content
   inside the protected span in all 3 runs on every one of the four texts, including one case
   (09) where the fenced code carried an explicit in-line instruction not to touch it. This is
   a `protectionRules` matter shared with the translation prompt and was deliberately left to
   the user rather than forked into a правка-only rule.
2. **Two rephrasing failures (02's reorder, 06's «Thanks for»→«Thank you for») and three
   style-instruction no-ops (friendly, plain, and — partially — professional) survived a
   targeted wording edit unchanged.** The candidate wordings from the decision table did not
   move the measured output at all on any of them, in a full 3-run re-check against the actual
   text (not just the runner's summary line). This reads as a genuine model limitation with
   `aya-expanse:8b` at temperature 0.2 rather than a wording defect this pass can close by
   further rephrasing the instruction — a materially different instruction strategy (e.g.
   few-shot examples, a stricter decoding setting, or a different model for правка) would be
   needed to move these, and that decision belongs to the user, not to another guess at prompt
   wording.

What **does** meet the gate: 4/10 `errorsOnly` texts (01, 05, 07, 10) and the `business` rewrite
style pass cleanly and unchanged, and nothing regressed anywhere in the corpus between the
baseline and after-calibration runs (verified file-by-file, not only via the runner's summary
counts).

### Part A verification and the style matrix (2026-08-10, follow-up)

Engine: pass-through chunks + inline restore (specs/2026-08-10-code-protection-and-styles-design.md).
Same 12-text corpus and scratchpad runner as the run above, recompiled to pick up §3.1 (a named
style drops «voice» from the `errorsAndStyle` level instruction — `ProofreadingLevel.instruction
(styleGovernsVoice:)`), re-run in full (51 calls, one uninterrupted foreground pass, no crash
this time) into a fresh output directory and diffed file-by-file against this run's own
pre-§3.1 baseline, not just the runner's summary line.

- **codeIntact: 12/12 true** — 03, 04, 08, 09 × 3 runs each, both before and after §3.1. This is
  the headline the code-protection design exists for: fenced blocks (04's YAML comment, 09's
  `print("helo wrld")`) are byte-identical passthrough chunks that never reach the model, and
  inline spans (03's `git comit --amend`, 08's `npm instal`) are restored from the source's own
  bytes after the model returns. Confirmed by direct text comparison against the source, not
  only the summary field.
- **errorsOnly non-regression: 29/30 byte-identical** (the `.errorsOnly`-tagged files only —
  01–10 × 3 runs, 30 total; the style probes are a separate denominator, covered above) against
  the pre-§3.1 matrix — expected, since `.errorsOnly` never reaches the `styleGovernsVoice: true`
  branch, so no prompt text changed for this level at all. The one exception, 03 run 2, differs
  at the same spot the baseline's own three runs already disagreed on: the baseline's run 2 read
  «...называется этот алиас» while its own runs 1 and 3 read «...называется наш псевдоним»; this
  run's run 2 reads «...называется наш псевдоним», matching the baseline's majority instead of
  its own run 2 — the identical out-of-seed-list stochastic wobble at temperature 0.2 landing on
  a different run, not a §3.1 effect. `codeIntact` stayed true throughout. Spot-checked against
  this section's own older baseline text too: 01/05/07/10 unchanged PASS, 02's verb-reorder and
  06's «Thanks for»→«Thank you for» persist, and 04's out-of-seed-list «конфига»→«конфигурационного
  файла» reword persists 3/3 as already recorded above. One more stochastic diff turned up in the
  full sweep, outside this denominator: `12-style-probe-formal-ru.errorsAndStyle-original.run2.txt`
  reads «...к пятнице» here against «...до пятницы» in the baseline run. `.original` carries no
  style instruction (`style.instruction == nil`), so `styleGovernsVoice` is always false for it
  and §3.1 cannot be the cause — the same wobble is already visible between the baseline's own
  run 1 («к пятнице») and runs 2/3 («до пятницы») on this file, so this is that identical pattern
  landing on a different run, not a new defect.
- **Style matrix, before §3.1** (this run's own pre-fix pass, matching the earlier corpus run's
  verdicts): 11-business 3/3 register shift; 11-professional 0/3; 12-friendly 0/3; 02-plain 3/3
  shift with grammar defects (вы/вас accusative error 2/3, «вывести» wrong-sense substitution
  1/3); 07-friendly (EN) 3/3 shift.
- **Style matrix, after §3.1**: 11-business 3/3 (unchanged; run 2 only a synonym swap,
  «неясных»→«спорных»); 11-professional 0/3 by majority — 2/3 runs stay in casual ты-address with
  only a cosmetic «пара»→«несколько» swap, the 3rd diverges into a differently-worded partial
  rewrite that borrows business-register phrasing («Обратите внимание», «поделитесь своими
  мыслями») rather than landing on a stable professional/workplace register, the same
  instability shape as before; 12-friendly 0/3 — byte-identical to the pre-§3.1 output in all 3
  runs, formal salutation and вы-address untouched; 02-plain 3/3 shift, same grammar-defect
  pattern (вы/вас 2/3, «вывести» 1/3), individual runs swapped which defect landed where —
  stochastic, not a regression; 07-friendly (EN) 3/3 (unchanged; minor cross-run synonym
  variance, «reveal»/«demonstrate», «process»/«processes»).
- **Verdict per style: no probe moved.** `business` and English `friendly` were already working
  and still are. `friendly` on Russian text (files 11 and 12), `plain`'s grammar defects, and
  `professional`'s instability are unchanged by dropping «voice» from the level instruction under
  a named style — dead under both the old and the corrected prompt. This is recorded as an
  honest model limitation with `aya-expanse:8b` at this temperature, matching this section's
  earlier conclusion (a materially different strategy — few-shot examples, stricter decoding, or
  a different model for правка — would be needed to move these), not a wording gap this pass can
  still close.
- **New probe text 12 (verbatim):**
  ```
  Уважаемые коллеги! Настоящим уведомляем вас о необходимости предоставить отчётные материалы в
  срок до пятницы. При наличии вопросов надлежит обращаться к руководителю подразделения.
  ```

### Model benchmark — gpt-oss:20b and qwen3:8b (2026-08-10)

Facts for a future model-policy decision about правка; no policy change here. Same runner and
12-text corpus as the two subsections above, parameterised to take a model as a third argument
(`CommandLine.arguments[3]`, default `aya-expanse:8b`, into `ChatOptions(model:)`) and recompiled
with the same command as the follow-up run above. `gpt-oss:20b` is required by the task that asked
for this benchmark; `qwen3:8b` was time-permitting.

- **codeIntact: 12/12 true for `gpt-oss:20b`**, verified against the source text directly, not
  only the summary field: 03's and 08's backticked spans (`git comit --amend`, `npm instal`)
  restored byte-identical in all 3 runs each; 04's and 09's fenced blocks (the YAML comment, the
  Python string) byte-identical passthrough in all 3 runs each. Confirms the structural guarantee
  (pass-through + inline restore) holds regardless of model, as the guarantee's design intends —
  not a restorer bug, no STOP needed.
- **errorsOnly: aya-expanse:8b's two minimal-diff violations disappear under `gpt-oss:20b`.**
  02's verb reorder (source «Осуществляеться процесс…»; aya moved the verb to the end 3/3, both
  before and after the voice fix) does not recur — `gpt-oss:20b` keeps the source's own word
  order in all 3 runs, only the seeded typo fixed. 06's «Thanks for»→«Thank you for» rewording
  (present 3/3 under aya) also does not recur — all 3 `gpt-oss:20b` runs keep «Thanks for»
  verbatim, only the four seeded errors fixed. Elsewhere: 04, 05, 07, 08, 09 clean 3/3 (no wording
  outside the seed list); 01 clean 2/3 (run 2 adds an unseeded comma and swaps «к пятнице»→«до
  пятницы» — the same stochastic wobble already on record for this file under aya); 03 clean 2/3
  (run 1 swaps «зделайте»→«выполните» instead of the literal «сделайте» fix — an unseeded
  synonym, the same shape as aya's own extra-reword pattern on this file, just a different word);
  10 regresses on 1/3 (run 3 fixes «i»→«I» and «explane»→«explain» but leaves the first sentence's
  «.» unconverted to «?», missing a seeded fix aya caught 3/3; run 2 shows the pre-existing,
  already-documented non-seed artifact of also converting the second sentence's «.» to «?»). Net:
  26/30 clean runs, 3/30 minor unseeded wording (same shape as aya's own wobble), 1/30 a missed
  seeded fix — no protected-span corruption anywhere.
- **Style matrix, `gpt-oss:20b` vs. the aya-expanse:8b after-voice-fix comparison point (this
  section's prior subsection):** `business` 3/3 (matches aya — genuine formal-register shift,
  meaning preserved; wording varies run-to-run rather than aya's byte-identical repetition, but
  the direction is stable). English `friendly` (file 07) 3/3 (matches aya — de-jargonized,
  meaning preserved). Russian `friendly` (file 12) **2/3 — a genuine shift where aya was a stable
  0/3 across two separate corpus runs**: 2 of 3 runs replace the formal salutation «Уважаемые
  коллеги!» with a casual «Привет, коллеги!» and reframe the notice in first person
  («Напоминаю»/«Напоминаем» vs. «Настоящим уведомляем»); the 3rd run stays a near-no-op.
  `professional` (file 11) **2/3 attempt a shift where aya was a stable 0/3**: one run moves
  cleanly into вы-address with a formal opening («Здравствуйте! Пожалуйста, посмотрите…»); a
  second run mixes an informal ты-imperative («Проверь») into an otherwise formal frame — an
  internally inconsistent partial shift, not a clean one; the 3rd run stays a near-no-op (only the
  same cosmetic synonym swap aya showed). `plain` (file 02) **0/3 — a no-op, where aya showed 3/3
  with grammar defects**: `gpt-oss:20b`'s output is byte-similar to its own errorsOnly reference
  (only a comma added in 2/3 runs), with none of aya's plainer-vocabulary substitutions and,
  consequently, none of aya's вы/вас case defect or «вывести» sense-drift either — the defect
  disappears because the style instruction is not acted on at all, not because it is honoured
  correctly.
- **Timing (warm-call wall-clock, the TTFT proxy this bounded benchmark can measure without
  parsing the JSON stream): ~4–5 s per call for `gpt-oss:20b`**, derived from output-file
  timestamps across the run (range ~2–9 s depending on chunk size — 04's and 09's fenced texts,
  which skip the model for their code block, land at the fast end). The first call (cold load)
  took ~9 s and is excluded per the operational note. This wall-clock carries the cost of
  `message.thinking`, which `OllamaKit` reads and discards by standing rule — `gpt-oss:20b` is
  reasoning-prone, so part of every one of these seconds is reasoning tokens the caller never
  sees, not just the visible reply. All 51 calls completed in one uninterrupted foreground pass,
  ~4 minutes end to end, exit 0.
- **`qwen3:8b`: attempted, aborted, inconclusive — recorded as a fact, not a verdict.** The first
  7 of 51 calls (01 ×3, 02 errorsOnly ×3, 02 `plain` run 1) completed with a warm-call proxy of
  ~9–20 s each — already 2–4× `gpt-oss:20b`'s pace on short, code-free text. The 8th call
  (03-ru-inline-code, the first text carrying backticked code) then ran for 13+ minutes at ~3%
  CPU with no output — not merely slow, unproductive — and was killed rather than let run
  indefinitely, consistent with this task's «time permitting» allowance for this candidate. The
  run's stdout log came back empty: the process was ended by `kill`, not by its own exit, and
  Swift's stdio fully buffers when stdout is piped to `tee`, so the buffered `print` lines never
  flushed; the 7 output files themselves (written directly, not through stdout) are the only
  record. No codeIntact or style-matrix conclusion is drawn for `qwen3:8b` — it did not reach a
  single code-bearing or style-probe text before the abort. Whether the stall is specific to
  backticked content in the prompt, to this quantization, or to machine load at the time is
  undiagnosed and out of this task's scope.
