# Carbon `RegisterEventHotKey` for the global shortcut

The hotkey is registered through Carbon's `RegisterEventHotKey`, a deprecated-in-spirit API
from a framework Apple has been retiring for twenty years. Two modern-looking alternatives were
rejected.

## Why not the alternatives

**`NSEvent.addGlobalMonitorForEvents`** requires the Accessibility grant and **cannot consume
the event**. The keystroke would reach whatever application the user is in as well as this one —
so ⌥⌘T would also do whatever ⌥⌘T does in their editor.

**A `CGEvent` tap** consumes correctly but needs the same grant, plus a run-loop source of its
own and the handling for the system disabling it under load.

## The property that decides it

**A Carbon hotkey needs no Accessibility grant at all.** Verified by registering one from a
plain command-line binary with no grant of any kind — it registered and fired.

That is not a minor convenience. It is what makes the app's onboarding possible. Reading the
user's selection *does* need the grant — both the Accessibility read and the synthetic ⌘C
fallback are privileged — so on a fresh install the capture cannot work. Because the hotkey
itself fires anyway, the app gets to react at the moment the user tries to use it, and show the
panel with an explanation and a button into System Settings.

With a global monitor or an event tap, a user without the grant would press the shortcut and
get **nothing at all** — no panel, no explanation, no way to discover what was missing short of
reading documentation they have no reason to open.

## Consequences

- The design spec's §6.1 says «without permission the hotkey does not work». That is true of
  the *outcome* and false of the *mechanism*, and the difference is this decision. The spec now
  says so.
- Carbon's handler model is process-wide: every handler installed on `GetEventDispatcherTarget()`
  is offered every hot-key event in the process, newest first, and returning `noErr` ends the
  chain. `HotkeyManager` therefore assigns a unique id per registration and returns
  `eventNotHandledErr` on a mismatch. Without that, two instances eat each other's presses —
  measured, along with a foreign signature running the closure.
- The C callback cannot capture context, so the bridge back to Swift goes through `userData` as
  an `Unmanaged` pointer. That leaves a narrow off-main teardown window, recorded in
  `docs/reference/OPEN-ITEMS.md`.
- If Apple removes Carbon, this must be rewritten, and the onboarding story goes with it. There
  is no replacement at the macOS 14 floor with the no-permission property.

## Where the code is

`Sources/TextCapture/HotkeyManager.swift`, and `Sources/TextCapture/HotkeyCombo.swift` for the
modifier translation Carbon needs.
