# The clipboard fallback snapshots the whole pasteboard, not its string

When the Accessibility read comes back empty, the app posts a synthetic ⌘C to get the
selection. Spec §6 makes restoring the user's clipboard afterwards mandatory: «otherwise the
application silently destroys the user's clipboard».

The tempting implementation — save `string(forType: .string)`, post ⌘C, put the string back —
is wrong in four ways at once, and each of them is silent.

## What the shortcut loses

- **Every flavour but plain text.** A user who copied rich text out of Pages has an RTF
  representation alongside the string; restoring only the string downgrades their clipboard to
  plain text, and they find out when they paste.
- **Multiple items.** A multi-file copy in Finder is several items. Restoring one collapses it.
- **Declared type order.** `NSPasteboard.types` is an ordered list and consumers take the first
  type they recognise. A `[String: Data]` dictionary hands it back in hash order — measured,
  three process runs gave three different scrambles, and a board whose first declared type was
  `public.utf8-plain-text` came back declaring `public.html` first in two runs of three. Hence
  an ordered `[[Flavour]]`, not a dictionary. (A dictionary also makes the bug *untestable*: its
  synthesised `==` is order-insensitive.)
- **Emptiness.** If the clipboard was empty before, it must be empty after. Skipping the restore
  when there is nothing to write leaves the copied selection sitting there — the exact leak the
  restore exists to prevent.

## What no implementation can preserve

Recorded because these should not be discovered later by surprise:

- **File promises are downgraded, and the board still looks intact.** The metadata flavours
  round-trip byte-identically and a receiver still reads them, but fulfilment calls back to the
  pasteboard's *owner*, which after the restore is this app, with nothing to serve it.
- **Ownership is lost.** It can only be set through `declareTypes(_:owner:)`, and the original
  owner is a different process.
- **`changeCount` cannot be restored.** It is monotonic and server-owned, and the restore itself
  bumps it — so a clipboard manager sees one extra entry per hotkey press. «The clipboard is
  untouched» is true of the contents, not of the counter.

Each still leaves the user better off than the no-snapshot baseline, which destroys the
clipboard outright.

## Consequences

- `NSPasteboardItem`s are never held — an item read out of a pasteboard goes empty the moment
  that pasteboard changes, and feeding held items back to `writeObjects` aborts the process.
  The bytes are copied eagerly instead.
- Concurrent access to one pasteboard *name* aborts the process, so every clipboard touch in the
  app goes through `GeneralPasteboard.withExclusiveAccess`. See `docs/PLATFORM-TRAPS.md`.
- A copy that lands after the poll deadline overwrites the restored clipboard. Unavoidable
  without waiting longer on every press; recorded rather than fixed.

## Where the code is

`Sources/TextCapture/PasteboardSnapshot.swift`, `Sources/TextCapture/GeneralPasteboard.swift`,
and `SelectionReader.clipboardText()`.
