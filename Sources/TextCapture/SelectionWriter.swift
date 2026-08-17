import Foundation
import AppKit
import Carbon.HIToolbox

/// The write side of the panel's round trip: puts `text` where the selection `SelectionReader`
/// captured used to be, by snapshotting the pasteboard, placing `text` on it, synthesizing ⌘V,
/// and restoring the snapshot — the mirror image of `SelectionReader.clipboardText()`'s
/// snapshot → ⌘C → restore.
///
/// No Accessibility write (`AXUIElementSetAttributeValue`) anywhere in this type, deliberately:
/// unlike the read side, where Accessibility is tried first and the clipboard is the fallback,
/// write support through that attribute is inconsistent enough across applications — issue #27
/// — that this type does not attempt it at all. The clipboard + synthetic ⌘V path is the only
/// mechanism, because it is the same path a user's own ⌘V takes and so behaves the same
/// everywhere that does.
public struct SelectionWriter: Sendable {
    public typealias Trigger = @Sendable () -> Void

    private let triggerPaste: Trigger

    public init(triggerPaste: @escaping Trigger = SelectionWriter.pasteKeystroke) {
        self.triggerPaste = triggerPaste
    }

    /// Replaces whatever is on `pasteboard` with `text`, synthesizes ⌘V, then restores the
    /// pasteboard to what it held before this call — under one held lock, not two.
    ///
    /// **The whole sequence runs inside a single `GeneralPasteboard.withExclusiveAccess` call,
    /// mirroring `SelectionReader.clipboardText()`'s own single held lock — not a call to
    /// `GeneralPasteboard.write(_:to:)`.** `write(_:to:)` takes that same lock itself, and
    /// `NSLock` is not reentrant: calling it from inside an already-held lock would deadlock.
    /// So this writes the pasteboard directly (`clearContents()`/`setString(_:forType:)`), the
    /// same two calls `write(_:to:)` makes, just without taking a second lock to do it.
    ///
    /// No verification that the frontmost application, its window, or its selection are still
    /// the ones a caller captured earlier — issue #27 is explicit that this is deliberate, not
    /// an oversight. The synthetic ⌘V goes wherever focus currently is.
    ///
    /// `async`, and detached internally to a background priority task before the lock is
    /// taken — the same shape `GeneralPasteboard.write(_:to:)` uses, and for the same two
    /// reasons: holding this lock can block for as long as a concurrent
    /// `SelectionReader.clipboardText()` poll is still running (up to half a second), and
    /// `NSPasteboard` is not `Sendable`, so the board is boxed the way `write(_:to:)`'s own
    /// comment explains before it can cross into the detached task.
    ///
    /// `@MainActor` on the entry point only, for the same reason `write(_:to:)` carries it: the
    /// lock is still taken inside the detached task, so the main actor is suspended here and
    /// never blocked — what this buys is a caller that is itself `@MainActor`
    /// (`HotkeyCoordinator`, holding a non-`Sendable` `NSPasteboard`) being able to hand this
    /// method its board without «sending risks causing data races».
    @MainActor
    public func replace(_ text: String, on pasteboard: NSPasteboard = .general) async {
        guard !text.isEmpty else { return }
        struct BoxedBoard: @unchecked Sendable { let board: NSPasteboard }
        let boxed = BoxedBoard(board: pasteboard)
        let trigger = triggerPaste
        await Task.detached(priority: .userInitiated) {
            GeneralPasteboard.withExclusiveAccess {
                let snapshot = PasteboardSnapshot.take(from: boxed.board)
                defer { snapshot.restore(to: boxed.board) }
                boxed.board.clearContents()
                boxed.board.setString(text, forType: .string)
                trigger()
            }
        }.value
    }

    // MARK: - The real trigger

    /// Synthesizes ⌘V. `@Sendable` for the same reason `SelectionReader`'s real readers are —
    /// referencing this as a value, which `init`'s default argument does, needs it.
    ///
    /// The flags on both events are forced to exactly `.maskCommand`, the same load-bearing
    /// override `SelectionReader.clipboardText()` applies to its ⌘C events and for the same
    /// reason: `CGEvent(keyboardEventSource:)` pre-loads whatever modifiers are physically held
    /// at construction time, and the panel's dedicated shortcut for this action is ⌘⇧↩ — so
    /// Shift is still down when this runs. An unpatched event would carry it into the paste,
    /// which in many applications means "paste and match style" rather than a plain paste.
    @Sendable public static func pasteKeystroke() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
