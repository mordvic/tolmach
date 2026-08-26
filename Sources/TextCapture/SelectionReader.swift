import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

public enum SelectionResult: Equatable, Sendable {
    case text(String)
    /// Both paths ran and found nothing. The panel says «выделите текст».
    case empty
    /// Neither path can work. The panel shows the onboarding prompt instead.
    case notPermitted
}

public struct SelectionReader: Sendable {
    public typealias Reader = @Sendable () -> String?

    private let accessibility: Reader
    private let clipboard: Reader
    private let isTrusted: @Sendable () -> Bool

    public init(accessibility: @escaping Reader = SelectionReader.accessibilityText,
                clipboard: @escaping Reader = SelectionReader.clipboardText,
                isTrusted: @escaping @Sendable () -> Bool = PermissionsGate.isTrusted) {
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.isTrusted = isTrusted
    }

    /// Spec 6's order: Accessibility, then the clipboard, then a hint.
    ///
    /// Each of the three is called at most once. That is not tidiness: a second call to
    /// `clipboard` is a second synthetic ⌘C into the user's application, a second
    /// whole-pasteboard destroy-and-rebuild, and another half-second of polling.
    public func read() -> SelectionResult {
        guard isTrusted() else { return .notPermitted }
        if let text = accessibility().flatMap(Self.meaningful) { return .text(text) }
        if let text = clipboard().flatMap(Self.meaningful) { return .text(text) }
        return .empty
    }

    /// Returns the text only if it contains something worth translating. Applications that
    /// do not really support the attribute often answer with an empty string rather than
    /// refusing, so emptiness has to be treated as absence at both call sites. Measured:
    /// Activity Monitor's focused search field answers `kAXSelectedTextAttribute` with
    /// `.success` and a zero-length string.
    ///
    /// Returns `raw`, not the trimmed form. Whitespace decides *whether* there is a
    /// selection; it is not stripped from one that exists, because a double-click in most
    /// applications includes the trailing space and trimming would change the text handed to
    /// the model — and, on a round trip, what comes back to the user.
    private static func meaningful(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    // MARK: - The real readers

    /// The clean path: ask the focused element for its selected text. Touches nothing.
    ///
    /// **Needs a process that has an `NSApplication`.** `AXUIElementCreateSystemWide()` lists
    /// `AXFocusedUIElement` among its attributes in any process, but answers it with
    /// `kAXErrorCannotComplete` until the process has a window-server connection — measured,
    /// stable across repeated tries in a plain command-line tool that *was* Accessibility-
    /// trusted, and measured to start answering `.success` the moment `NSApplication.shared`
    /// is touched, `.accessory` activation policy included. So this works from the menu-bar
    /// app and returns nil from anything that has not brought AppKit up. It is also why no
    /// test here calls it.
    ///
    /// Every failure is a nil, never a trap, and nil means "try the clipboard". Measured
    /// shapes of failure in the wild, all reached by the guards below: Safari's focused
    /// element is an `AXGroup` answering `kAXErrorNoValue`; Xcode's and Telegram's answer
    /// `kAXErrorAttributeUnsupported`.
    ///
    /// `@Sendable` on the declaration, not just on the parameter that defaults to it. Without
    /// it, referencing this function *as a value* — which is exactly what the default argument
    /// in `init` does — yields a non-Sendable function value, and converting that to the
    /// `Reader` type warns «converting non-Sendable function value to '@Sendable () -> String?'
    /// may introduce data races» in Swift 5 mode and fails outright in Swift 6. It is also
    /// true: the AX calls below are thread-agnostic synchronous IPC.
    @Sendable public static func accessibilityText() -> String? {
        let system = AXUIElementCreateSystemWide()
        // Without this the default AX messaging timeout is 1.5 seconds, and it is spent
        // synchronously on every press whenever the frontmost application is not answering.
        // Measured against an app whose main thread was wedged: `kAXFocusedUIElement` blocked
        // 1.503 s on 10 consecutive probes and then returned `kAXErrorCannotComplete`, after
        // which `read()` falls through to the clipboard path and spends its full half second
        // too — two seconds before the user is told «выделите текст». A quarter second is
        // still an eternity for an app that is answering at all: the healthy measurement was
        // 22 ms.
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }

        // The `CFGetTypeID` check above is the *only* thing guarding this cast. Measured: a
        // forced downcast to a CoreFoundation type does not trap on the wrong type — casting
        // a `CFString` to `AXUIElement` succeeds silently and hands the AX API a bogus
        // element, which then answers `kAXErrorInvalidUIElement` (-25202). The compiler
        // refuses `as?` here outright ("conditional downcast to CoreFoundation type
        // 'AXUIElement' will always succeed") and points at comparing the type IDs instead,
        // so this pairing is the sanctioned spelling, not a shortcut around one.
        let target = element as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXSelectedTextAttribute as CFString,
                                            &selected) == .success
        else { return nil }
        // `as?` and not a force cast: the attribute is documented as a `CFString` but nothing
        // stops an application answering with something else. Anything that is not a string
        // — an `NSAttributedString` among them, measured to cast to nil rather than to its
        // characters — degrades to the clipboard fallback instead of returning nonsense.
        return selected as? String
    }


    /// The fallback: post ⌘C and read what lands, then put the user's clipboard back.
    ///
    /// The wait is a poll rather than a fixed sleep. A sleep long enough to be safe on a slow
    /// app is a visible stall on every press, and one short enough to feel instant loses the
    /// text on a slow one — the poll is both.
    ///
    /// It polls for a **non-nil string**, not merely for `changeCount` to move. Measured:
    /// `clearContents()` bumps the counter *before* any data is written, and the subsequent
    /// write does not bump it again — a board went 1 → 2 on the clear and stayed at 2 through
    /// the write, reading back nil in between. Returning on the first observed change
    /// therefore samples the copying application's cleared-but-not-yet-written window and
    /// yields `nil` — an intermittent «выделите текст» on a perfectly good selection.
    ///
    /// The `changeCount` half of the condition is load-bearing too, in the other direction:
    /// without it an application that ignores ⌘C entirely would make this hand back whatever
    /// the user already had in their clipboard, as if it were their selection.
    ///
    /// A selection that is not text spins the full half second and returns nil. Measured: a
    /// board carrying file URLs — a Finder copy — or a TIFF from a screenshot answers
    /// `string(forType: .string)` with nil and derives no plain-text flavour, so the poll
    /// never satisfies and the user gets «выделите текст». Right answer, slowest path.
    ///
    /// A copy that arrives *after* the deadline is the one failure this cannot contain: the
    /// poll gives up, the restore below puts the user's clipboard back, and the slow
    /// application's ⌘C then lands on top of it. The user loses their clipboard and is told
    /// «выделите текст» anyway. Waiting longer trades that against a stall on every press.
    ///
    /// `@Sendable` for the same reason as `accessibilityText`, and with the same
    /// justification: `GeneralPasteboard.withExclusiveAccess` is what makes calling it from
    /// any thread safe. See that type for why the serialisation cannot live here.
    @Sendable public static func clipboardText() -> String? {
        GeneralPasteboard.withExclusiveAccess { clipboardTextLocked() }
    }

    /// Whether this board was written by Universal Clipboard rather than by the ⌘C just posted.
    ///
    /// `com.apple.is-remote-clipboard` is the flavour the system attaches to content handed over
    /// from another device. It is the only third-party write on this path that identifies
    /// itself, which is why it is the only one that can be excluded by name.
    static let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    static func isRemoteClipboard(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(remoteClipboardType) ?? false
    }

    /// The body of `clipboardText()`, split out so the lock is taken in exactly one place.
    private static func clipboardTextLocked() -> String? {

        // Built before the snapshot is taken, so that failing to build them costs nothing.
        // `PasteboardSnapshot.restore` is not free even when it puts back exactly what it
        // found: it clears and rewrites, which transfers pasteboard ownership to this app and
        // downgrades any file promise on the board to metadata nothing will serve. Doing that
        // on a path where the ⌘C was never posted is pure loss. Constructing the events does
        // not touch the pasteboard, so the snapshot still predates the copy.
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else { return nil }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        // Registered after the unlock, so it runs before it: the restore has to happen inside
        // the lock. And `defer` runs after the return value has been read — measured, a
        // function returning a string it read from a board it clears in a `defer` still
        // returns the string — so the `return copied` below is not racing this.
        //
        // **Conditional on the board still being the one we read.** The restore clears and
        // rewrites, so an unconditional one destroys anything that landed after the poll
        // accepted its value — Universal Clipboard delivering a copy from the user's iPhone
        // inside the ≤0.5 s window is the concrete case, and the user's next ⌘V then pastes
        // this app's stale snapshot. Putting back a clipboard is worth doing; overwriting a
        // newer one to do it is not.
        var acceptedChangeCount = snapshot.changeCount
        defer { snapshot.restoreIfUnchanged(to: pasteboard, since: acceptedChangeCount) }

        // These two assignments are load-bearing, not tidiness. Do not delete them.
        //
        // The hotkey fires on key *down*, so the user is still physically holding its
        // modifiers when this runs, and `CGEvent(keyboardEventSource:)` pre-loads the live
        // hardware modifier state into the new event at construction time. Measured with a
        // passive tap and with a real AppKit application in front: built while ⌥⌘ was held,
        // the event came out already carrying CMD+OPT; built while ⇧ was held, SHIFT. With
        // these assignments the target application receives exactly CMD in every
        // configuration; with them removed it receives ⌥⌘C — a different command in real
        // applications, and one that would work for whoever chose a harmless hotkey and fail
        // mysteriously for everyone else.
        //
        // The merge happens at construction, not at post: `.cgSessionEventTap`,
        // `.privateState` and `.combinedSessionState` all behave identically, and clearing
        // the modifiers beforehand changes nothing. The assignment is the whole fix.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if pasteboard.changeCount != snapshot.changeCount,
               let copied = pasteboard.string(forType: .string) {
                // **A board delivered from another device is not this selection.** The poll
                // accepts any change it sees, because `NSPasteboard` has no owner and nothing
                // here can ask who wrote — so the one write that *can* be told apart is told
                // apart. Universal Clipboard marks its own, and without this check that content
                // was sent to the model and shown in the panel as the user's selection.
                //
                // The general case remains: any third party writing inside this window is still
                // mistaken for the selection. That is inherent to the fallback and is recorded
                // in ADR 0005 rather than papered over here.
                guard !isRemoteClipboard(pasteboard) else { return nil }
                acceptedChangeCount = pasteboard.changeCount
                return copied
            }
            usleep(10_000)
        }
        return nil
    }
}
