# The panel is hidden before the capture and shown after it

A hotkey press does this, in this order: hide any panel left over from the previous press,
read the selection off the main actor, **then** show the panel, then translate.

Showing the panel first is what reads as the responsive choice, and it is what the
implementation plan specified. It breaks the capture outright.

## The measurement

`.nonactivatingPanel` leaves the application inactive — but the panel still becomes the **key
window**, and system-wide accessibility focus follows the key window, not the active
application. Key and active are different things, and this is the direction that catches people
out.

Measured with a standalone probe:

- With the panel on screen, `AXUIElementCreateSystemWide()` answers `kAXFocusedUIElement` with
  this app's own window, role `AXWindow`, and `kAXSelectedTextAttribute` returns `-25205`.
- With this application not running at all, the identical query returns the source app's
  `AXTextArea` and the selected sentence.

Against TextEdit holding a selection the app had just read successfully, showing the panel first
produced «выделите текст» on every attempt, with the user's clipboard untouched.

## Consequences

- **Nothing appears on screen until the read returns.** On the Accessibility path that is about
  22 ms, which is invisible; on the clipboard fallback it is up to half a second, which is not.
  That is the price of the panel not being the thing that eats the selection.
- The same defect exists from the other side: the panel from the *previous* press is still on
  screen and still key, so on the second press it would eat the selection just as surely. Hence
  the hide as well as the delayed show.
- The read runs on a detached task, not the main actor, so the half second does not stop the run
  loop. A bare `Task {}` would inherit the actor and reintroduce the stall.

## Not fully explained

The clipboard fallback *also* returned nothing in the show-first runs, and that was never
isolated. The obvious candidate is the synthetic ⌘C landing on the panel rather than the source
application. The code records this as a suspicion rather than a finding, and it should keep that
status until someone measures it. See `docs/reference/OPEN-ITEMS.md`.

## Where the code is

`Sources/TranslatorApp/HotkeyCoordinator.swift` — the `willCapture` / `afterCapture` hooks and
the comment carrying the measurement above.
