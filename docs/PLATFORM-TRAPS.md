# macOS traps

The platform behaviours that each cost this project a real defect. They are collected here
so that someone about to write a *new* call site finds them — an agent adding its first
`NSPasteboard` line will not think to open `PasteboardSnapshot.swift`.

**This file is an index, not the authority.** Each entry gives the fact, the measurement, and
the file that owns it. The owning file has the full reasoning and is kept true by sitting next
to the code it constrains; this list is a finding aid and can only be as fresh as its last
edit. When they disagree, the code comment is right.

---

## Suspending on a human

**A checked continuation nobody resumes is a hang with no symptom.** `Translator.translate`
takes an optional review hook and suspends there while a person answers a sheet. The answer
arrives from the main actor; cancellation arrives from somewhere else entirely — ⌘., the
toolbar's «Отмена», the queue being cleared, the window closing. If none of them resumes the
continuation, the run is suspended *forever*: it is not a crash, not an error, and
`Task.checkCancellation()` cannot reach it because it is not running. Resumed twice, it traps
the process instead.

This is the same shape as the `AsyncThrowingStream` trap below — cancellation *finishes*
instead of throwing, so «not resumed» looks like nothing happening — and that one already cost
this project a truncated document reported as a success.

Owned by `TranslatorApp/DocumentTermsRequest.swift`, whose entire job is «exactly once»,
driven through all four orders by `DocumentTermsRequestTests`. Both `cancel()` implementations
that can reach it — `TranslationViewModel`'s and `FileQueueModel`'s — cancel the request
*before* the task, because a run waiting on a human has no network call to interrupt.

**The probe that was deliberately not run.** The ⌥⌘T path escalates to the main window rather
than putting editable text fields inside the `.nonactivatingPanel`. How focus, the focus ring,
⌘V through the menu and Cyrillic input behave in a panel that is key while its app is *not*
active is unverified — and unverified is where it stays, because the escalation removes the
need. If that decision is ever revisited, this probe comes first.

## A static function on a `View`, called from a test

`View` is `@MainActor @preconcurrency`, so a closure written inside any of its members —
including a `static func` — inherits main-actor isolation, and under
`.swiftLanguageMode(.v6)` that isolation is checked at **run time** with a trap rather than
at compile time with a diagnostic. A test that calls such a function off the main actor
builds cleanly and dies with signal 5.

Measured twice: `WarningsViewTests` records the original investigation and the four fixes
that were tried and rejected; `DocumentTermsViewTests` hit it again the day it was written,
on `rows(for:)`'s `filter` and `map`. The fix both times is `@MainActor` on the tests.

## Concurrency that aborts the process

Two Apple frameworks respond to concurrent use by killing the process with an uncaught
exception. Neither returns an error, so neither can be recovered from — they can only be
prevented.

**Text Input Sources / Text Services Manager.** Two threads in TIS at once abort with
«Text Input Sources or Text Services Manager API is being called in two threads concurrently».
Measured: 8 threads × 400 calls, SIGABRT 3 runs out of 3 without a lock, survives 3 of 3 with
one. The lock only serialises *our* callers — AppKit makes its own unlocked TIS calls on the
main thread, and a background call under the lock overlapping one of those still aborts, also
3 of 3. → `Sources/TextCapture/HotkeyCombo.swift`

**`NSPasteboard`.** Two threads reading `pasteboardItems` for the same pasteboard *name* abort.
Measured: 10 out of 10 for one name, both on a shared object and on freshly constructed ones;
0 out of 10 for distinct names — which is what identifies the corrupted state as a per-name
item cache. The exception varies («value not absent», `NSRangeException`), so nothing may match
on its name. `NSPasteboard.general` is a single shared name, so every clipboard caller in the
app is on the same board. → `Sources/TextCapture/PasteboardSnapshot.swift`,
`Sources/TextCapture/GeneralPasteboard.swift`

---

## Accessibility

**Focus follows the *key* window, not the active application.** A `.nonactivatingPanel` leaves
the app inactive but still becomes key — and system-wide `kAXFocusedUIElement` follows key.
Measured: with the panel on screen the focused element is this app's own `AXWindow` and
`kAXSelectedTextAttribute` answers `-25205`; with the app not running, the identical query
returns the source app's `AXTextArea` and the selected sentence. This is why the panel is
hidden *before* the capture and shown after it, which reads like the wrong order until you
know. → `Sources/TranslatorApp/HotkeyCoordinator.swift`

**`AXUIElementCreateSystemWide` needs an `NSApplication`.** It lists `AXFocusedUIElement` among
its attributes in any process but answers `kAXErrorCannotComplete` until the process has a
window-server connection — measured in a trusted command-line tool, and measured to start
answering the moment `NSApplication.shared` is touched, `.accessory` policy included. A
headless helper would therefore fail silently forever. → `Sources/TextCapture/SelectionReader.swift`

**The default messaging timeout is 1.5 seconds.** Spent synchronously on every call whenever
the frontmost app is not answering: measured at 1.503 s on 10 consecutive probes against a
wedged app, against 22 ms healthy. → `Sources/TextCapture/SelectionReader.swift`

**A forced cast to a CoreFoundation type does not trap.** `CFString as! AXUIElement` succeeds
silently and hands the API a bogus element, which then answers `-25202`. The compiler refuses
`as?` here and points at comparing type IDs, so `CFGetTypeID` is the only real guard.
→ `Sources/TextCapture/SelectionReader.swift`

---

## Synthetic events

**`CGEvent` pre-loads the live hardware modifier state at construction.** Because the hotkey
fires on key *down*, the user is still holding its modifiers when the synthetic ⌘C is built —
so the event comes out carrying them. Measured: built while ⌥⌘ was held it carried CMD+OPT;
while ⇧ was held, SHIFT. Assigning `flags` explicitly overwrites it; the posting tap is not the
variable, since `.cghidEventTap`, `.cgSessionEventTap`, `.privateState` and
`.combinedSessionState` all behave identically. → `Sources/TextCapture/SelectionReader.swift`

**`clearContents()` bumps `changeCount` before any data is written**, and the subsequent write
does not bump it again. A poll that returns on the first observed change therefore samples the
copying application's cleared-but-empty window and gets nil.
→ `Sources/TextCapture/SelectionReader.swift`

---

## Keyboard

**Function-key virtual codes descend.** `kVK_F1` is 122 and `kVK_F12` is 111, with F5 at 96 —
they are neither contiguous nor ordered. `case kVK_F1...kVK_F12` compiles and traps at run
time with «Range requires lowerBound <= upperBound».
→ `Sources/TextCapture/HotkeyCombo.swift`

**⌘-bearing key-downs go through `performKeyEquivalent` first.** AppKit routes them through
key-equivalent dispatch before `keyDown` sees them, so a view recording a shortcut gives the
app's own menu items first refusal on exactly what it is trying to record — ⌘W would close the
window and ⌘Q quit the app mid-recording. → `Sources/TranslatorApp/HotkeyRecorder.swift`

**A Carbon hotkey needs no Accessibility grant.** Verified by registering one from a plain CLI
binary with no grant at all. That is what lets this app react to the shortcut on a fresh
install and explain that the *capture* is what needs permission — see `docs/adr/0002`.
→ `Sources/TextCapture/HotkeyManager.swift`

**Carbon hotkey handlers are process-wide.** Every handler installed on
`GetEventDispatcherTarget()` is offered every hot-key event in the process, newest first, and
returning `noErr` ends the chain. Two managers without an ID check means the newer one eats the
older one's presses — measured, and a foreign signature ran the closure too.
→ `Sources/TextCapture/HotkeyManager.swift`

---

## Windows and views

**`NSHostingView` as a window's `contentView` publishes compressed constraints.** AppKit then
shrinks the window to satisfy them: measured, the panel opened 380 × 120 regardless of content
because a `ScrollView` compresses to nothing, truncating the permission prompt to one line.
`sizingOptions = []` leaves the frame to the caller. Those two numbers were taken on a `.titled`
panel against a fixed size and neither condition exists any more — the mechanism stands, the
figures are quarantined. → `Sources/TranslatorApp/TranslationPanel.swift`

**An installed hosting view measures what it is *showing*, not what its content wants.** Which
is why the entry above concludes that nothing on the installed view is usable for measurement:
a `ScrollView` in the content compresses to nothing and the view reports that compressed height
as the truth. The fix is a **second, detached host** that is never installed in a window and
always holds the *non-scrolling* variant of the same content — measure that, then decide from
the answer whether the installed one gets a `ScrollView`. → `PanelController.measuring` in
`Sources/TranslatorApp/TranslationPanel.swift`

**`sizeThatFits(in:)` exists on `NSHostingController` and not on `NSHostingView`.** Checked in
the SDK's `SwiftUI.swiftinterface`: the `NSHostingView` class body has no `sizeThatFits` of any
signature, so the call does not compile. It matters because `fittingSize` is the obvious
substitute and it is **not a proposal-taking API** — measured, a long paragraph answered
6929 × 44 both with no frame and with the frame preset to 560 × 120, so there is no way to ask
an `NSHostingView` for a height *at a width*. That is exactly what a second measuring pass
needs, so the measuring host is an `NSHostingController`.
→ `Sources/TranslatorApp/TranslationPanel.swift`

**A greedy SwiftUI view answers your proposal back at you, and `greatestFiniteMagnitude`
survives an `isFinite` check.** Measured on the real `PanelView`: `sizeThatFits(in: unbounded)`
answered `greatestFiniteMagnitude` on both axes for a one-word translation *and* for a
forty-sentence one, because the view carries `frame(maxWidth: .infinity, maxHeight: .infinity)`
and contains three `Spacer`s. A sizer that tests `isFinite && > 0` takes that for a real
measurement: every panel came out at the width ceiling and the height ceiling, always scrolling,
and never resized again. `fittingSize` asks for the **ideal** size instead, where a `Spacer` is
0 — the same two views answered 274 and 6929. So the two passes deliberately use two different
APIs: `fittingSize` for the ideal width, `sizeThatFits(in:)` for the height *at that width*.
→ `PanelController.measure` in `Sources/TranslatorApp/TranslationPanel.swift`

**A detached measuring host does not see content that changed through `@Observable`
observation until `layoutSubtreeIfNeeded()` runs.** Reassigning `rootView` is enough only when
the rebuilt view genuinely differs — a builder that captured a `String` does, and that is the
shape in which this was first (correctly, but narrowly) measured. A builder that reads a model
*inside* `body` does not: the rebuilt view's stored properties are identical, the same object
reference, so nothing looks changed and the pending invalidation is never flushed. Measured on
one reused host: after the text changed and `rootView` was reassigned, `fittingSize` still
answered the previous 274 and `sizeThatFits(560)` still answered 94 tall; the layout call moved
them to 6929 and 302.

Re-measured end to end against the real `PanelHost`, driven through the real
`HotkeyCoordinator.handlePress` with an injected `SelectionReader`, reading the panel's frame
at `show(at:)`. Five presses — short text, long text, `.empty`, `.notPermitted`, short text —
**with** the layout call: 300 × 120, 300 × 120, 326 × 120, 560 × 131, 560 × 305. **Without** it:
300 × 120, 300 × 120, **560 × 305, 326 × 120, 560 × 131**. Deterministic over repeated runs and
identical whether or not the panel is hidden between presses. Two things follow. The stale size
**changes press to press** rather than freezing — presses 4 and 5 are each exactly the previous
press's size — which is why the source comment's «sizes every press against the previous one» is
the accurate description. And a change of selection *kind* is stale too: `.empty` and
`.notPermitted` come out at the wrong size, and neither runs a translation, so neither ever gets
a second chance to correct itself. (Presses 1 and 2 are equal in both columns for a reason that
is not staleness: `handlePress` assigns `sourceText` *after* the panel is shown, so a text press
legitimately opens on the previous run's content either way — which is a trap of its own, and is
why `show(at:)` no longer freezes the panel's width there. The frames above are the size at
`show(at:)`, which for a `.text` press is now **provisional**: the panel corrects itself as the
reply arrives. For an `.empty` or a `.notPermitted` press it is still the final size, because
neither runs a translation.)
→ `PanelController.measure` in `Sources/TranslatorApp/TranslationPanel.swift`

**`constrainFrameRect(_:to:)` rewrites the frame on order-in**, and **not only for `.titled`
windows** — this project's panel has carried no `.titled` bit since the UI redesign and the
override is still load-bearing. What reproduces on the current mask, re-measured against a stock
`NSPanel`: a frame whose top crosses the menu-bar band comes back pulled down by the height of
the band, exactly as the titled one did. What did **not** reproduce on that re-measurement is
the original evidence — a frame at x = 19 coming back at x = 221, AppKit reserving the Stage
Manager strip — which is consistent with the original note saying it was taken on a development
machine with Stage Manager on. Both figures are kept: the first is why the override exists now,
the second is why it was written. See `docs/MEASUREMENTS.md` for where each observation lives.
→ `Sources/TranslatorApp/TranslationPanel.swift`

**`NSApp.activate(ignoringOtherApps:)` does not activate on macOS 14.** The window comes front
and answers `AXMain`, but the app is not frontmost and keystrokes still go elsewhere; the same
failure makes a settings window swallow its first click. macOS 14 replaced unilateral
activation with the cooperative `NSRunningApplication.activate(from:options:)`.
→ `activateThisApp()` in `Sources/TranslatorApp/TranslatorApp.swift`

**A `Picker`'s title is not drawn inside a `.toolbar`.** SwiftUI keeps it as the control's
accessibility label and renders nothing, so `Picker("Из", …)` in a toolbar ships as a bare
pop-up. Nothing in the source says so — the title is right there in the call — and no test in
this project can see it; it was found by putting a screenshot of the running app next to the
drawing. Draw the label as its own `Text` and add `.labelsHidden()` to keep the accessibility
label from being read twice. → the toolbar in `Sources/TranslatorApp/MainWindowView.swift`

**Hiding a window's title is `titleVisibility`, not `.navigationTitle("")`.** Measured with
`Scripts/window-title.swift`: both remove the drawn title, but `navigationTitle("")` leaves
`NSWindow.title` empty while `titleVisibility = .hidden` keeps it. The title string is what the
«Окно» menu lists the window under — a menu this app deliberately adds «Открыть окно перевода»
to — as well as what Mission Control and VoiceOver announce.

**And setting it once does not hold.** On the running bundle the assignment lands and is undone
before the next 400 ms sample: `1` at `viewDidMoveToWindow`, `0` at all six samples after,
with `_NSToolbarTitleField` visible again at 60 × 19. Re-asserted from `viewDidMoveToWindow`,
`updateNSView` and `NSWindow.didUpdateNotification` together, the same instrumentation reads
`1` and zero visible title fields at all five samples over 3 s. **What performs the reset is
not established** — saved-state restoration, `.defaultSize` and view-level churn were each
tested and cleared, and the probe does not reproduce the failure at all: `MODE=once` passes
there and fails on the app. So instrument the bundle, not the probe, before trimming any of
the three. → `WindowTitleHidden` in `Sources/TranslatorApp/MainWindowView.swift`

**A `ToolbarItemGroup`'s children are separate toolbar items.** Measured through
`NSToolbar.items`: a group holding three labels, three pickers and a button reports 7 items, not
1. macOS spaces them apart and overflows them one at a time, so a label written beside the
control it names sits a toolbar gap away from it and can be left on the bar when that control is
pushed into the ». Put the pair in a single `ToolbarItem` containing an `HStack`. Worth 60 pt of
width here as well. → the toolbar in `Sources/TranslatorApp/MainWindowView.swift`

**An `NSPopUpButton` is as wide as its widest menu item, not as its selection.** So one long
option sets the width of every picker that lists the same values, whether or not it is ever
chosen: «китайский (упрощённый)» was seven characters longer than any other language name and
cost 70 pt in five pickers at once. A mock-up cannot show this — it draws the string that is
showing. → `Language.russianName` in `Sources/TranslatorApp/RussianCopy.swift`

**Where SwiftUI puts the window title, relative to your toolbar items.** It lays the title out
*after* the `.navigation` group, so a full navigation group leaves the title sitting between
the last control and the trailing button, reading as a control itself.
→ `Sources/TranslatorApp/MainWindowView.swift`

**`.nonactivatingPanel` grants key status; `canBecomeKey` only permits it.** A `.titled`
`NSPanel` answers `canBecomeKey` true with *and* without the style bit — the bit is what lets
the panel take key without activating the app. → `Sources/TranslatorApp/TranslationPanel.swift`

---

## Preferences

**`removePersistentDomain(forName:)` does not remove the plist.** `cfprefsd` owns the file and
writes it back from its own cache roughly ten seconds after the process exits, so deleting the
file in-process is never late enough either. Four variants were tried — removal plus
synchronise, explicit per-key removal, `CFPreferencesSetMultiple`, dropping the suite from the
search list — and all four left a file behind. The only thing that leaks nothing is never
letting a write reach the daemon. → `Tests/TranslatorAppTests/InMemoryDefaults.swift`

---

## Ollama

Not macOS, but the same category — behaviour established by experiment rather than by reading:

**`"think": false` does not disable reasoning.** It moves it out of `message.thinking` and into
`message.content`, i.e. straight into the translation. Verified on `qwen3:30b`. The parameter is
therefore never sent, and `message.thinking` is read and discarded.
→ `Sources/OllamaKit/OllamaClient.swift`, and §3.1 of the design spec

**Durations are nanoseconds.** Converted at the client boundary.
→ `Sources/OllamaKit/OllamaClient.swift`
