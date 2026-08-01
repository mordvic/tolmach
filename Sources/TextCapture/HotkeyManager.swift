import Foundation
import Carbon.HIToolbox

/// A system-wide hotkey, via Carbon's `RegisterEventHotKey`.
///
/// Carbon because there is no replacement at the macOS 14 floor that does the job.
/// `NSEvent.addGlobalMonitorForEvents` needs the Accessibility grant and cannot consume the
/// event, so the keystroke would also reach whatever app the user is in; a `CGEvent` tap
/// consumes but needs the same grant and a run-loop source of its own. `RegisterEventHotKey`
/// needs no permission at all and swallows the key — which is what lets this app react on a
/// fresh install and explain that it needs Accessibility for the *capture*.
@MainActor
public final class HotkeyManager {
    /// `nonisolated(unsafe)` on both, and it is `deinit` below that needs it.
    ///
    /// A `deinit` on a `@MainActor` class is itself nonisolated, and these two are
    /// `OpaquePointer`s, which are not `Sendable` — so touching them there is «cannot access
    /// property … with a non-Sendable type … from nonisolated deinit», an error in the Swift
    /// 6 language mode. Measured: two of the four errors that stopped a `-swift-version 6`
    /// build of this target were these two lines.
    ///
    /// What the annotation asserts is true rather than convenient: `deinit` runs only once
    /// the last reference is gone, so nothing else can hold these at that moment, and every
    /// other access to either is on the main actor.
    ///
    /// `isolated deinit` would state that to the compiler instead of asserting it, and it is
    /// **not** ruled out by the platform floor — measured, against an earlier draft of this
    /// comment that claimed it was: `@MainActor final class C { var p: OpaquePointer?;
    /// isolated deinit { _ = p } }` typechecks cleanly at `-swift-version 6 -target
    /// arm64-apple-macosx14.0`. It is declined on behaviour instead. It moves teardown onto
    /// the main actor, so a manager whose last release lands off it no longer unregisters
    /// synchronously — and that is precisely the path `docs/OPEN-ITEMS.md` §3 already lists
    /// as an unresolved narrow race. Changing it belongs in a change about that race, not in
    /// one whose whole purpose is to reach Swift 6 without moving any behaviour.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?
    public private(set) var registered: HotkeyCombo?

    /// Any four-character code will do as long as it is stable; 'TLMH' is Толмач Hotkey.
    ///
    /// `nonisolated` because it is an immutable constant that callers outside the main actor
    /// read — the C event handler among them. Left main-actor isolated it compiles here but
    /// warns at every nonisolated use, and that warning is an error in Swift 6 mode.
    nonisolated static let signature = OSType(0x544C4D48)

    /// Distinguishes this registration from every other hot key live in the process. Bumped
    /// per registration, not per instance, so a press of the *previous* combination that is
    /// already queued when the user changes the shortcut no longer matches and is dropped.
    ///
    /// Stays main-actor isolated, unlike `signature`: it is mutable, and the isolation is what
    /// makes `&+= 1` safe without a lock.
    private static var nextHotKeyID: UInt32 = 1
    private(set) var hotKeyID: UInt32 = 0

    public init() {}

    deinit {
        // Not `unregister()`: this is nonisolated and the Carbon calls are thread-agnostic.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Returns false when the combination is refused. Callers must react — a settings pane
    /// that ignores this leaves the user staring at a combination that does nothing.
    @discardableResult
    public func register(_ combo: HotkeyCombo, onPress: @escaping @MainActor () -> Void) -> Bool {
        guard combo.isValid else { return false }
        // Always tear down first. Registering over a live registration leaves the old one
        // installed, and the app answers to a combination the user has already changed.
        unregister()
        self.onPress = onPress

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            // Which hot key fired has to be read off the event. Both the handler and the hot
            // key are attached to the process-wide dispatcher target, so a second
            // `HotkeyManager` — or any other component in the process that registers a hot
            // key — installs a second handler on the *same* target, and every handler there is
            // offered every hot-key event. Measured with a handler that skipped this check:
            // the most recently installed one ran its closure for another manager's
            // combination and for a foreign signature, and returning noErr ended the chain so
            // the event never reached the manager it belonged to.
            var pressed = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr
            else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // The Carbon handler runs on the main thread already, but the compiler cannot
            // know that from a C callback, so the hop is made explicit.
            return MainActor.assumeIsolated {
                // Spelled `HotkeyManager` and not `Self`: a C function pointer cannot be formed
                // from a closure that captures the dynamic Self type, and `Self` inside this
                // body is exactly that capture.
                guard pressed.signature == HotkeyManager.signature, pressed.id == manager.hotKeyID
                else { return OSStatus(eventNotHandledErr) }
                manager.onPress?()
                return noErr
            }
        }, 1, &spec, context, &handlerRef)
        guard installed == noErr else { self.onPress = nil; return false }

        hotKeyID = Self.nextHotKeyID
        Self.nextHotKeyID &+= 1
        let id = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id,
                                         GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr else { unregister(); return false }
        registered = combo
        return true
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        onPress = nil
        registered = nil
        // Reset alongside the rest, so the field means "the id currently registered" rather
        // than "the last id this instance used". Nothing reads it while no handler is
        // installed, but leaving it set makes the invariant unreadable.
        hotKeyID = 0
    }
}
