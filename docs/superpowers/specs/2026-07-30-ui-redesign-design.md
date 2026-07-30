# UI redesign — design

Date: 2026-07-30
Status: approved for implementation

## Status of this document

This is the pre-implementation design. It records what the three surfaces — the floating panel,
the main window and the settings window — are to become, and the reasoning each decision rests
on. Once the code exists, **the code is the authority on behaviour and this document is the
authority on why**.

Two kinds of statement appear below and they must not be confused. A claim marked **measured**
restates an observation already recorded in the code or in `docs/`; the citation says where.
Everything else is intent, and intent has not been observed. In particular: this environment has
no GUI automation, so nothing in this document has been seen on a screen. Section 8 lists what a
human must check.

---

## 1. What is wrong today

Read from the code, not from a running app.

### 1.1 The panel

`TranslationPanel` is a fixed 380 × 260 for its whole life (`TranslationPanel.swift`). A one-line
result leaves the lower half empty; a long translation scrolls inside an unmoving rectangle. The
internal ceilings do not add up to the panel: 220 pt for the text, 120 pt for the warnings, plus
a status row and a button row, against 260 pt of content height — so whenever a run produces both
text and warnings, every part of the panel is compressed at once.

The panel is `.titled` with a transparent titlebar, so it carries an invisible title strip and a
visible close button, and it has no material, no corner radius and nothing else distinguishing it
from an ordinary window.

### 1.2 The main window

- The two `TextEditor`s sit flush against each other with no frames, headings or placeholders.
  The right one is bound to `.constant(model.translatedText)`: it takes a caret and silently
  discards typing. A control that accepts input and does nothing with it is the largest single
  defect in the window.
- Language pickers render `Language.shortCode` (`ru`, `en`) while the settings render
  `Language.russianName` («русский»). One vocabulary under two names, which `CONTEXT.md` exists
  to prevent.
- There is no «Скопировать», no «Очистить» and no way to swap the languages. The panel has a
  copy button; the window does not.
- One caption carries four unrelated meanings in turn: Ollama status, «Перевожу…», elapsed time,
  and the failure message.
- `WarningsView` is capped at 140 pt taken out of the window's 460 pt minimum
  (`MainWindowView.swift:36`). The arithmetic in that comment is sound; it is needed only because
  the window is a single vertical stack with no toolbar and no collapsible region.

### 1.3 The settings

- Each pane fixes its own size — 420, 420, 520 × 440, 420 — so the window resizes on every tab
  switch.
- «Основные» is one flat `Form` with no `Section`: a permission warning, the hotkey, two
  languages, a tone, two toggles and three explanatory paragraphs interleaved.
- «Глоссарий» is a flat list of `HStack` rows with no search, no sorting, no count and no empty
  state.
- «Модели» does not say what is installed, only what is selected.
- Ollama's state is visible only in the main window, in a caption — not in the pane where a
  broken Ollama is repaired.

---

## 2. Direction

Exemplary native macOS. System controls, system materials, system accent; a real window toolbar,
`Form(.grouped)` with sections, `.regularMaterial` on the panel. No custom chrome, no custom
palette, no bespoke controls. Every string stays Russian with «guillemets» and «ё», and none of
the copy rendered by `Text(String)` gains a backtick.

Three surfaces, worked in this order: **panel, window, settings**. The panel is first because it
holds the only genuine technical risk.

---

## 3. The panel

### 3.1 Form

`styleMask` becomes `[.nonactivatingPanel, .resizable, .fullSizeContentView, .utilityWindow]` —
`.titled` is dropped. The panel gets a 12 pt corner radius and a `.regularMaterial` background,
so it reads as a floating layer rather than as a window.

A rounded corner needs the window itself to stop painting: `isOpaque = false` and
`backgroundColor = .clear` on the panel, with the material and the `clipShape` drawn by the
SwiftUI content. Without both, the square window background stays visible behind the rounded
content and the radius reads as a grey notch in each corner.

`.nonactivatingPanel` stays, and it stays for the reason already recorded: it is what lets the
panel become *key* without activating the application. `canBecomeKey` is permission and the style
mask is the grant, and the current comment (`TranslationPanel.swift:57`) is explicit that the
measurement behind it was taken on a `.titled` panel. **Dropping `.titled` invalidates that
measurement.** Section 8 owns the re-check; if an untitled panel turns out not to take key status,
`.titled` comes back with `titleVisibility = .hidden` and the corner radius is applied to the
content view instead.

Closing is unchanged: Esc closes and cancels, Enter copies and closes, and the next hotkey press
hides the panel before it captures. There is no click-outside dismissal today and none is added —
`hidesOnDeactivate` stays false, because the application is never active while the panel is up and
a panel that hid on deactivation would be dismissed by the very state it appears in. What is lost
is the titlebar's close button, so the panel's own header carries a small borderless ⨯ at its
trailing edge and a mouse still has a target.

### 3.2 Content

Top to bottom:

1. **Header** — the direction line («английский → русский») produced by `PanelView.direction`,
   with the ⨯ at the trailing edge. Withheld exactly when `direction` returns nil today; that
   rule and its reasoning are unchanged.
2. **Translation** — `Text` with `textSelection(.enabled)`.
3. **Status** — spinner and «Перевожу…», or the orange interruption row, or the red failure row
   with «Повторить». `PanelView.status(for:)` is unchanged, including its exhaustive switch.
4. **Warnings** — `WarningsView`, still gated on `hasContent`. The gate stays for the reason it
   was added: an empty slot cost 86 of 260 points (`WarningsView.swift:23`). It matters less now
   that the panel sizes itself, and it is still right — an empty stack should not claim height.
5. **Actions** — «Скопировать», «Открыть в окне», and «Отмена» while running. The enablement
   rules are unchanged, `adoptionRefusal` included, and so is the «Окно занято своим переводом»
   line under them.

The content view contains **no `ScrollView`** in its ordinary form. That is what makes it
measurable. A second, scrolling variant of the same layout exists and is installed only when the
measured height exceeds the ceiling.

`PanelView`'s own `.frame(minWidth: 340, maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)`
goes away. Its `maxHeight` and `.topLeading` existed to stop short content floating in the middle
of a fixed rectangle, which is the problem this whole section removes; its width clamp would now
fight the sizer for the same decision, and two clamps disagreeing about width is how a measured
ideal width silently stops being the width used.

### 3.3 Sizing

`hosting.sizingOptions` stays `[]`. This is not a leftover: it is what stops Auto Layout deriving
the window's size from the hosting view's compressed measurement, which was measured on the
running bundle at 380 × 120 (`TranslationPanel.swift:119`). The panel's size stays the
controller's decision; what changes is that the controller now computes it instead of hard-coding
it.

**Measurement.** Two passes on `NSHostingView.sizeThatFits(in:)`:

1. Unbounded width and height → the ideal width of the content laid out without wrapping.
2. The chosen width, unbounded height → the height at that width.

**`PanelSizer`** is a new type with no AppKit in it. It takes the ideal size, the previous frame
size, the screen's `visibleFrame`, whether a run is in progress, and whether the user has resized
by hand, and returns the next size. Its rules:

- **Width** is clamped to 300…560 pt and is computed **once per presentation** — on the first
  content update after `show(at:)` — then frozen until the panel hides. A width that moved while
  tokens arrived would re-wrap every line on every token.
- **Height** is clamped to 120 pt … 60 % of `visibleFrame.height`.
- **Height is monotonic within one run**: it never decreases between the first token and
  `.finished`. Text arriving cannot make the panel shrink.
- Reaching the height ceiling switches the controller to the scrolling content variant, which is
  then pinned at the ceiling.
- If the user has resized by hand, the sizer returns the current size unchanged.

**Throttling.** At most one measure-and-resize per 100 ms while a run streams, plus one
unconditional pass when the state leaves `.running`. Every frame goes through the sizer, so the
throttle can only delay growth, never skip it.

### 3.4 Anchoring

`PanelPlacement.frame(cursor:size:screen:)` starts returning a placement — the frame **and** the
corner it is anchored by. The anchor is the corner nearest the cursor, which the existing
flip-then-clamp arithmetic already determines: preferred is top-left (the panel hangs down and to
the right of the pointer), flipped horizontally gives top-right, flipped vertically gives
bottom-left, both give bottom-right.

A new `PanelPlacement.reframe(current:newSize:anchor:screen:)` grows the frame from that corner
and re-clamps the result inside `visibleFrame`. Re-clamping is not optional: a panel that grows
past the bottom of the screen has no other way back, and `constrainFrameRect` is overridden to
return the frame untouched — deliberately, because Stage Manager was measured moving a frame 202
pt sideways (`TranslationPanel.swift:67`).

### 3.5 Manual resize

The panel is `.resizable`. On `windowDidEndLiveResize` the controller sets a `userSized` flag,
which suppresses automatic sizing for the rest of the presentation. `hide()` clears it, so the
next hotkey press starts from automatic sizing again. Nothing is persisted; the panel stays
ephemeral, which is what it is for.

### 3.6 Motion

No animation while a run streams — the steps are a line at a time and animating each one produces
jitter. One 0.15 s ease-out animation on the settle that follows `.finished`, which is where the
shape genuinely changes (warnings appear, the scrolling variant is swapped out). No animation at
all when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true.

---

## 4. The main window

### 4.1 Toolbar

A real `.toolbar`, replacing the `HStack` of controls in the content:

- source language `Picker` — «Определить» plus every `Language`,
- a ⇄ button,
- target language `Picker` — «По правилу» plus every `Language`,
- tone `Picker`,
- a spacer,
- «Перевести» as `.borderedProminent` with ⌘↩, replaced by «Отмена» with ⌘. while running.

Pickers render `russianName`, not `shortCode`. The ⌘. shortcut on «Отмена» keeps its existing
justification: ⌘↩ belongs to a button that is not on screen during a run.

### 4.2 Panes

`HSplitView` with a draggable divider. Each pane has a one-line header: a caption on the leading
edge and one action on the trailing edge.

**Исходник.** `TextEditor` with a border and a placeholder («Вставьте или наберите текст») drawn
over it while empty. Trailing header action: «Очистить», disabled when the field is empty. A
footer in the bottom-trailing corner carries the character count and the chunk hint.

That footer stays a **separate view value holding only the model reference**, exactly as
`ChunkHint` is today. The reason is measured: as a computed property of `MainWindowView.body` the
hint re-ran `Chunker.chunk` twice per streamed token (`MainWindowView.swift:156`). The character
count joins it in the same type and inherits the same protection.

**Перевод.** Not a `TextEditor`. A selectable `Text` inside a `ScrollView`, honestly read-only.
Trailing header action: «Скопировать», enabled as soon as the first token lands — the same rule
the panel's copy button uses, and for the same reason: an interrupted run leaves output worth
keeping. When there is no translation and nothing running, the pane shows an empty state: a muted
glyph and «Здесь появится перевод».

### 4.3 Swapping languages

⇄ swaps the effective languages and moves the translation into the source field, clearing the
result.

It lives on `TranslationViewModel` as `swapLanguages()` with a companion `canSwapLanguages`, not
in the view, so it is testable. It is available only when both effective languages are known —
the source either overridden or already determined by a finished run, the target likewise.
Swapping «определить» with «по правилу» exchanges two absences and is refused.

`swapLanguages()` sets `sourceOverride` to the effective target and `targetOverride` to the
effective source, moves `translatedText` into `sourceText` when it is non-empty, and clears
`translatedText` and `outcome` together — the two are cleared as a pair everywhere else in the
view model, and a translation's outcome must never outlive the text it describes.

It is refused while a run is in progress.

### 4.4 The bottom bar

One row, replacing the status caption:

- idle → `status.label`,
- running → spinner and «Перевожу…»,
- interrupted → the orange row,
- failed → the red message and «Повторить»,
- finished → «Готово за N мс», and when `WarningsView.hasContent` is true, a one-phrase summary
  and a disclosure triangle.

Expanding shows `WarningsView` inside `ViewThatFits(in: .vertical)` with a `ScrollView` fallback —
the same construction and the same reason as today: a bare `ScrollView` is greedy in its scroll
axis and would sit at its ceiling under a two-line warning. The ceiling rises from 140 pt to 200
pt, because the region no longer competes with the editors for the window's minimum height: while
collapsed it costs one row. The disclosure state is view state and lasts until the window closes.

The «не показывать» action and `mute(_:)`'s three-way error handling move with `WarningsView`
unchanged. Muting is still offered only in the window, never in the panel.

### 4.5 Size

Minimum 700 × 480, up from 640 × 460. The toolbar and the two pane headers take roughly 20 pt
that the old layout spent on content, and two 280 pt panes plus a divider need slightly more than
640 pt of width.

### 4.6 Decomposition

`MainWindowView` splits into `MainWindowView` (layout and toolbar), `SourcePane`,
`TranslationPane` and `RunStatusBar`. The file is 181 lines today and would roughly double.

---

## 5. The settings

### 5.1 Shape

Three tabs, one size for all of them: 560 × 480, applied by a single `SettingsPane` wrapper that
also applies `.formStyle(.grouped)`. The window stops resizing when the tab changes. Every pane
uses `Section` with headings.

### 5.2 «Основные»

- **Доступ** — a row that is **always** visible, not one that appears on failure: «Доступ к
  тексту в других программах» with either «предоставлен» or an orange «нет доступа» and «Открыть
  настройки системы». A block that appears and disappears makes the form jump, and a user whose
  permission is granted never learns the permission exists. The cached `isTrusted` and its refresh
  on `didBecomeActiveNotification` are unchanged; the reasoning on that property still holds, TCC
  lag included.
- **Сочетание клавиш** — `HotkeyRecorder` and its caption.
- **Языки** — primary, working, the collision warning, and the caption about how direction is
  chosen.
- **Перевод** — default tone.
- **Поведение** — «Копировать результат по хоткею автоматически» and «Прогревать модель при
  запуске». The first label keeps the words «по хоткею» verbatim: `autoCopy` is read only by
  `HotkeyCoordinator`, so it governs the panel and not the window, and the label used to promise
  the whole app.

### 5.3 «Модели»

- **Ollama** — running or not, the address, and «Проверить снова».
- **Модель для перевода** — the picker and both notes (not installed, blacklisted), unchanged.
  Blacklisted models stay selectable.
- **Установленные модели** — name, on-disk size, and a «в памяти» mark. Read-only; no deletion.
- **Загрузка** — the field, the button, the progress bar, the status line and the error,
  unchanged.
- **Дополнительно** — `keepAlive`, chunk size and temperature, each with its existing caption.

The «Дополнительно» tab is removed and `SettingsAdvancedView.swift` is deleted.

### 5.4 «Глоссарий»

Header: a search field, a term count, the «Показывать перевод на» picker, and **+** / **−**
buttons. The list supports multiple selection and **−** removes everything selected. An empty
glossary shows an empty state inviting the first term. The footer keeps the file path, «Показать
файл в Finder» (disabled when the file does not exist), «Перечитать файл», and the unconditional
`lastProblem` banner. «Скрытые предупреждения» is unchanged.

**Ordering is not recomputed per keystroke, and this is the load-bearing part of the pane.**

Rows are identified by their index into `glossary.file.entries`, and that is deliberate: a term is
not unique, the file is hand-edited, and «Добавить термин» appends a blank one, so keying by term
collapses two real rows into one (`SettingsGlossaryView.swift:81`). Sorting and filtering on top
of index identity means the visible order must be stable while a row is being edited — otherwise
the row a user is typing into moves out from under the caret the moment its term stops sorting
where it did, or stops matching the search.

So the order is a pure function, `GlossaryOrder.visibleOrder(entries:query:) -> [Int]`, and it is
recomputed only on: adding a term, removing terms, changing the search text, and re-reading the
file. Editing the text inside a row does not reorder anything. A newly added blank term sorts
first, which is where the user needs it.

All existing bindings stay bounds-checked in both directions. SwiftUI can evaluate the body of a
row that no longer exists during the update that follows a removal, and an unchecked subscript
traps there. `persist()` keeps its three-way error handling and its guard against clearing
`lastProblem` on every keystroke.

---

## 6. The menu bar

The `MenuBarExtra` label becomes `character.bubble` when Ollama answers and `exclamationmark.bubble`
when it does not. The menu gains a first row stating the same thing in words.

**No polling.** The status refreshes at launch, when the menu opens, when the settings window
opens, and after every translation attempt. Between those moments the glyph can lag reality. A
timer firing every N seconds in an app that spends most of its life idle in the menu bar is a bad
trade for a glyph, and the lag is written down here rather than papered over.

The `.task { await launch() }` hanging off the label stays where it is. Scene order stays
`MenuBarExtra` → `Window` → `Settings`; it is load-bearing, and reordering it opens the main
window at every login.

---

## 7. Components and testing

### 7.1 New pure types

| Type | Responsibility |
|---|---|
| `PanelSizer` | Next panel size from ideal size, previous size, screen, run state, `userSized`. Owns the ceilings, the frozen width and the monotonic height. |
| `PanelPlacement` (extended) | `frame(cursor:size:screen:)` returns frame + anchor corner; new `reframe(current:newSize:anchor:screen:)` grows from the anchor and re-clamps. |
| `GlossaryOrder` | `visibleOrder(entries:query:) -> [Int]`. |
| `TranslationViewModel.swapLanguages()` / `canSwapLanguages` | The swap as behaviour, not as a gesture. |

All four are testable with Swift Testing and no UI, in the style the project already uses.

### 7.2 The one change outside `TranslatorApp`

`OllamaProbe.installedModels()` returns `[OllamaModel]` instead of `[String]`. The size is already
there — `OllamaKit.OllamaModel.sizeBytes` — and is currently discarded at the protocol boundary.
`OllamaStatusModel` and `ModelsViewModel` map to names where they need names. The change is
mechanical but it touches every existing test that supplies a fake probe, and the implementation
plan must account for that.

`TranslationCore` is not touched. `glossary.json` is not touched — no new fields, byte-for-byte
the same format.

### 7.3 Files

Rewritten: `PanelView`, `TranslationPanel`, `MainWindowView`, `SettingsGeneralView`,
`SettingsModelsView`, `SettingsGlossaryView`.
New: `PanelSizer`, `SourcePane`, `TranslationPane`, `RunStatusBar`, `SettingsPane`, `GlossaryList`,
`GlossaryOrder`.
Deleted: `SettingsAdvancedView`.
Extended: `PanelPlacement`, `PanelController`, `TranslationViewModel`, `ModelsViewModel`,
`OllamaStatusModel`, `RussianCopy`.

### 7.4 Standing rules that apply

- `swift build --build-tests` stays at zero warnings.
- Swift 6 tools, `.swiftLanguageMode(.v5)`, macOS 14 floor, no new targets and no dependencies.
- Tests are Swift Testing with sentence names; `UserDefaults` tests use `InMemoryDefaults`.
- Comments carry *why* and the measurement behind it. Where this redesign removes code a comment
  justifies, the comment moves with the behaviour or records why the measurement no longer applies.
  Deleting the code and keeping the comment is the failure mode this project has already paid for
  twice.

---

## 8. What only a human can check

To be appended to `docs/OPEN-ITEMS.md` as part of the work, not afterwards.

| Check | Why it cannot be automated |
|---|---|
| An untitled `.nonactivatingPanel` still becomes key and receives Esc and Enter | The existing measurement was taken with `.titled` in the mask; §3.1 invalidates it |
| `NSHostingView.sizeThatFits` returns a usable size on the assembled bundle | The test process and the bundle have already disagreed once about hosting-view sizing — the 380 × 120 collapse reproduced only in the bundle |
| Growth does not move text the reader has already read | The anchor arithmetic is testable; the perception is not |
| A one-line result, a long result and the permission prompt each get a panel that fits | The three states are the whole point of the change |
| Manual resize sticks until the panel hides, and the next press sizes automatically again | Live resize cannot be driven from a test process |
| The settings window no longer resizes between tabs | No GUI automation |
| The menu bar glyph changes when Ollama stops | No GUI automation |
| The translation pane refuses the caret | The defect being fixed is precisely that it accepted one |

## 9. Deliberately not in scope

- Deleting models from the «Модели» pane.
- Persisting the panel's manual size across presentations.
- A polling timer for Ollama's state.
- Batch file translation, which is v2, and the background model role, which stays policy-only.
- Any change to `glossary.json`, to `TranslationCore`, or to the translation pipeline.
