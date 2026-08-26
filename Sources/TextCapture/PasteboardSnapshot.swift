import Foundation
import AppKit

/// Everything on a pasteboard, so the clipboard fallback can put it all back.
///
/// `NSPasteboardItem` is deliberately not held on to: an item read out of a pasteboard goes
/// empty the moment that pasteboard changes — measured, `types` comes back `[]` and every
/// `data(forType:)` returns nil — so keeping the objects would give back nothing at restore
/// time, which is the exact moment it must not.
///
/// Flavours are kept in an ordered array rather than a `[String: Data]` because
/// `NSPasteboard.types` is an ordered list and a dictionary hands it back in Swift's hash
/// order. Measured: a board whose first declared type was `public.utf8-plain-text` came back
/// declaring `public.html` first in two process runs out of three, and never in the original
/// order. AppKit's own readers are unaffected — `availableType(from:)` follows the caller's
/// preference list, not the board's — but toolkits that enumerate the types themselves take
/// the first one they recognise, so the order is part of what has to be put back.
///
/// **Not thread-safe, because `NSPasteboard` is not.** Two threads reading the same
/// pasteboard at once abort the process: `-[NSPasteboard pasteboardItems]` raises an
/// uncaught `NSException`. Measured at 10 aborts in 10 runs, on a shared object and on fresh
/// objects for the same name alike, and whether the data was written by this process or
/// another; the exception varies — «value not absent» and `NSRangeException` from the same
/// race — so do not match on its name. Distinct names never aborted, 0 in 10, which is what
/// identifies the corrupted state as a per-name item cache rather than anything global. The
/// app's pasteboard is `NSPasteboard.general`, a process-wide singleton, so `take` and
/// `restore` have to be serialised by their caller.
///
/// **Three things a snapshot provably cannot put back**, all properties of `NSPasteboard`
/// rather than choices made here. Each still leaves the user better off than the no-snapshot
/// baseline, which destroys the clipboard outright — but none of them should be discovered
/// later by surprise:
///
/// - **File promises are downgraded, and the board still looks intact.** An
///   `NSFilePromiseProvider`'s metadata flavours all round-trip byte-identically and a
///   receiver still reads them, but fulfilment calls back to the pasteboard's *owner*, which
///   after the restore is this app, with nothing to serve it.
/// - **Ownership is lost.** It can only be set through `declareTypes(_:owner:)`, and the
///   original owner is a different process. No implementation can preserve it.
/// - **`changeCount` cannot be restored.** It is monotonic and server-owned, and the restore
///   itself bumps it, so a clipboard manager sees one extra entry per hotkey press. «The
///   clipboard is untouched» is true of the contents, not of the counter.
public struct PasteboardSnapshot: Equatable {
    /// One flavour of one item: the pasteboard type's raw string and its exact bytes.
    public struct Flavour: Equatable {
        public let type: String
        public let data: Data
    }

    /// One entry per pasteboard item, each holding that item's flavours in declared order.
    public let items: [[Flavour]]
    public let changeCount: Int

    public static func take(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let captured = (pasteboard.pasteboardItems ?? []).map { item in
            // `compactMap` rather than a force-read: a flavour an app promised but can no
            // longer serve answers nil, and dropping that one flavour is right — dropping
            // the whole item, or trapping, is not.
            item.types.compactMap { type in
                item.data(forType: type).map { Flavour(type: type.rawValue, data: $0) }
            }
        }
        return PasteboardSnapshot(items: captured, changeCount: pasteboard.changeCount)
    }

    /// Restores this snapshot **only if the board is still the one the caller accepted**.
    ///
    /// `restore` clears and rewrites unconditionally, which is right when the only thing that
    /// touched the board is this app's own synthetic ⌘C — and wrong when something else wrote
    /// afterwards. The ⌘C poll waits up to half a second, fully exposed when the target app
    /// ignores the keystroke, and a Universal Clipboard delivery inside that window used to be
    /// both returned as «the selection» and then overwritten with the stale snapshot, so the
    /// user's next ⌘V pasted old content.
    ///
    /// - Parameter changeCount: what `NSPasteboard.changeCount` read when the caller took the
    ///   value it is about to return. Not this snapshot's own count — by the time a restore is
    ///   due, the ⌘C has already moved the board past that.
    /// - Returns: whether anything was written back. False means the board had moved on and was
    ///   left alone, which is a decision and not a failure.
    @discardableResult
    public func restoreIfUnchanged(to pasteboard: NSPasteboard, since changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        restore(to: pasteboard)
        return true
    }

    public func restore(to pasteboard: NSPasteboard) {
        // Cleared unconditionally, including when there is nothing to write back. An empty
        // snapshot means the user's clipboard was empty, and leaving the text this app
        // copied behind would be the very leak the restore exists to prevent.
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { flavours in
            let item = NSPasteboardItem()
            for flavour in flavours {
                item.setData(flavour.data, forType: NSPasteboard.PasteboardType(flavour.type))
            }
            return item
        })
    }
}
