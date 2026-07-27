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
/// uncaught `NSException` («value not absent»). Measured at 10 aborts in 10 runs, on a
/// shared object and on fresh objects for the same name alike, and whether the data was
/// written by this process or another. The app's pasteboard is `NSPasteboard.general`, a
/// process-wide singleton, so `take` and `restore` have to stay on one thread — in practice
/// the main actor, where the hotkey handler runs.
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
