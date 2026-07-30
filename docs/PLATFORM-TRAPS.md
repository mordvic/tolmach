# macOS traps

Eleven platform behaviours that each cost this project a real defect. They are collected here
so that someone about to write a *new* call site finds them — an agent adding its first
`NSPasteboard` line will not think to open `PasteboardSnapshot.swift`.

**This file is an index, not the authority.** Each entry gives the fact, the measurement, and
the file that owns it. The owning file has the full reasoning and is kept true by sitting next
to the code it constrains; this list is a finding aid and can only be as fresh as its last
edit. When they disagree, the code comment is right.

---

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
`sizingOptions = []` leaves the frame to the caller. Note that neither `fittingSize` nor
`intrinsicContentSize` is usable for measuring the content — both report the same number
whatever is in the view. → `Sources/TranslatorApp/TranslationPanel.swift`

**`constrainFrameRect(_:to:)` rewrites the frame on order-in** for `.titled` windows. Measured:
a frame at x = 19 came back at x = 221, AppKit reserving the Stage Manager strip — silently
overruling the placement arithmetic. → `Sources/TranslatorApp/TranslationPanel.swift`

**`NSApp.activate(ignoringOtherApps:)` does not activate on macOS 14.** The window comes front
and answers `AXMain`, but the app is not frontmost and keystrokes still go elsewhere; the same
failure makes a settings window swallow its first click. macOS 14 replaced unilateral
activation with the cooperative `NSRunningApplication.activate(from:options:)`.
→ `activateThisApp()` in `Sources/TranslatorApp/TranslatorApp.swift`

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
