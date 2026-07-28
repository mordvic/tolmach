import Foundation
import AppKit

/// The one place in the process allowed to touch `NSPasteboard.general`.
///
/// `NSPasteboard`'s per-name item cache is built without synchronisation, and two threads
/// reading `pasteboardItems` for the same name abort the process with an uncaught
/// `NSException` — measured 10 times out of 10 for one name, and 0 out of 10 for distinct
/// names. The exception varies («value not absent», `NSRangeException`) so nothing may match
/// on it, and it is an abort rather than a thrown error, so nothing can recover from it.
/// `NSPasteboard.general` is a single shared name: every part of this application that
/// touches the clipboard is on the same board as every other.
///
/// This exists as a type rather than a private field on `SelectionReader` because a lock only
/// serialises the callers that take it. `SelectionReader.clipboardText()` held one and closed
/// the race *with itself*, while the application's own «скопировать» wrote to the same board
/// from the main actor without it — safe in practice only because the panel that offers the
/// button happens to be hidden while a capture runs. That is a property of the current UI, not
/// of the code, and it would be reintroduced by any future caller: a menu item, a second
/// shortcut, a URL handler. Routing every access through one function makes the guarantee
/// structural.
///
/// A lock and not `@MainActor`: `SelectionReader.clipboardText()` busy-waits up to half a
/// second waiting for the copy to land, and running that on the main actor would stall the run
/// loop on every fallback press.
public enum GeneralPasteboard {
    private static let lock = NSLock()

    /// Run `body` with exclusive access to the general pasteboard.
    ///
    /// Not reentrant — `NSLock` is not. Nothing inside a `withExclusiveAccess` block may call
    /// back into one.
    public static func withExclusiveAccess<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
