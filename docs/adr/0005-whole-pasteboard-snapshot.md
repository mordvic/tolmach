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
  app goes through `GeneralPasteboard.withExclusiveAccess`. See `docs/reference/PLATFORM-TRAPS.md`.
- A copy that lands after the poll deadline overwrites the restored clipboard. Unavoidable
  without waiting longer on every press; recorded rather than fixed.

## Where the code is

`Sources/TextCapture/PasteboardSnapshot.swift`, `Sources/TextCapture/GeneralPasteboard.swift`,
and `SelectionReader.clipboardText()`.

---

## What the fallback costs, written down (2026-08-26)

Two things the ⌘C fallback does that no snapshot can undo. Neither is a defect in this
implementation; both were unrecorded, which is the defect this section fixes.

### The selection is placed on the general pasteboard

Posting ⌘C is what puts the user's selection there, so for the length of the poll it is visible
to every clipboard-history manager on the machine and to Universal Clipboard. «Текст не покидает
машину» is a statement about what this app sends over the network; it has this caveat, and the
caveat had been written down nowhere.

The Accessibility read is tried first precisely because it costs nothing of the sort — this is
the price of the path taken when that read comes back empty, which is the path a user with a
non-cooperating application is always on.

`org.nspasteboard.ConcealedType` would opt a well-behaved history manager out. It is not
adopted here: it is a convention rather than an API, honoured by some managers and not others,
and adopting it would make this section read as though the exposure had been solved. It is a
reasonable thing to add later, with a measurement of which managers actually honour it.

### A concurrent write is mistaken for the selection

The poll accepts *any* change to `changeCount` inside its half-second window, because
`NSPasteboard` has no owner and nothing in this app can ask who wrote. So a third-party write
landing in that window is returned as «the selection», sent to the model and shown in the panel.
The window is fully exposed when the target application ignores ⌘C, which is exactly the case
the fallback exists for.

Two halves of this are fixed and one is not:

- **The restore no longer destroys the newer content.** `PasteboardSnapshot.restoreIfUnchanged`
  puts the snapshot back only if the board is still the one the poll accepted. Before this, a
  copy arriving from the user's iPhone was both read as their selection *and* then overwritten
  with this app's stale snapshot, so their next ⌘V pasted old content.
- **Universal Clipboard is recognised and refused.** Content handed over from another device
  carries `com.apple.is-remote-clipboard`; it is the one third-party write that identifies
  itself, so it is the one that can be excluded by name.
- **The general case remains.** Any other process writing inside the window is still mistaken
  for the selection. There is no API that would distinguish it, and inventing a heuristic —
  «text that does not look like a selection» — would fail in the direction that loses the user's
  actual selection. Accepted, and recorded here rather than left to be rediscovered.

---

## What else the fallback reads, and what that does not change (2026-08-31)

Rich capture (the formatting design's §10) made the fallback read **two more flavours off the
same board**: once the poll's `string(forType: .string)` lands, `public.html` and `public.rtf`
are read in the same pass, under the same held `GeneralPasteboard` lock, and travel as raw
`Data` on `CapturedSelection`. `MarkupKit` converts them; `TextCapture` converts nothing.

Every cost this ADR records is unchanged by that, and deliberately:

- **The same one ⌘C.** No second keystroke, no second poll, no second snapshot. The copy has
  already happened; these are two reads off a board this app is already holding, between the
  poll accepting a value and the `defer` that puts the user's clipboard back.
- **The same exposure.** The selection is on the general pasteboard for the length of the poll
  either way — that is the price recorded above, not a new one.
- **The same restore.** `restoreIfUnchanged` still puts back every flavour of every item in
  declared order, which is what this whole ADR is about; reading a flavour does not consume it.
- **The capture order is unchanged.** Accessibility first, and it stays plain: the attribute it
  asks for is a string. So rich capture improves only the applications where that read *fails*
  and this fallback runs — Safari, Xcode and Telegram among them, per `SelectionReader`'s own
  measurements. Lifting it onto the Accessibility path is the design's tier 1
  (`kAXAttributedStringForRangeParameterizedAttribute`), and it is **not built**: it is gated on
  a measurement of what real applications answer it with (design §11.1, `OPEN-ITEMS` §1).
