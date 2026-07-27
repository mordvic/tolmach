import Testing
import AppKit
import Carbon.HIToolbox
@testable import TranslatorApp
import TextCapture

/// The brief calls the recorder hand-check-only because it is an `NSViewRepresentable`.
/// That is true of what it *draws* — the rounded rect, the accent-coloured border, the
/// «Нажмите сочетание…» placeholder and the way SwiftUI sizes it inside a `Form` are all
/// still eyes-only. It is not true of what it *decides*. `RecorderView` is an `NSView`
/// whose whole job is turning an `NSEvent` into a `HotkeyCombo`, synthetic key events cost
/// nothing to build, and neither a window nor a running `NSApplication` is needed to hand
/// one to `keyDown(with:)` — measured, these run in the ordinary headless test process.
///
/// So the decisions are pinned here and the pixels are left to the hand-check. Nothing
/// below calls `displayString`: it goes to Text Input Sources for the current keyboard
/// layout, which makes any assertion about a rendered letter depend on which layout is
/// installed, and the type's own tests already cover it.
@MainActor
private func makeRecorder() -> HotkeyRecorder.RecorderView { HotkeyRecorder.RecorderView() }

@MainActor
private func click(_ view: HotkeyRecorder.RecorderView) {
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                   timestamp: 0, windowNumber: 0, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
    view.mouseDown(with: event)
}

private func keyEvent(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                     timestamp: 0, windowNumber: 0, context: nil,
                     characters: "x", charactersIgnoringModifiers: "x",
                     isARepeat: false, keyCode: keyCode)!
}

@MainActor
private func press(_ view: HotkeyRecorder.RecorderView,
                   _ keyCode: UInt16,
                   _ flags: NSEvent.ModifierFlags) {
    view.keyDown(with: keyEvent(keyCode, flags))
}

/// The recorder must write down the combination the user can *see*, not the bits the
/// hardware happened to send. A real `NSEvent` carries more than the four flags a shortcut
/// may hold: caps lock being on, the key living on the numeric pad, and fn — which every
/// arrow key and every function key sets unconditionally — all ride along, and none of them
/// survive into a `HotkeyCombo`.
///
/// The order is what this pins, and it is the part that is easy to get wrong: mask first,
/// then validate and store the masked value. Validating `event.modifierFlags` and storing
/// `candidate` would let a press of ⇧ plus a numeric-pad key through — `.numericPad` is not
/// a real modifier but it is a set bit — and then store a plain ⇧ combination the manager
/// will refuse.
/// Every value here differs from `HotkeyCombo.default` in *both* fields. That is not
/// fussiness: the first draft of this test recorded ⌥⌘T, which is the default, so
/// `view.combo` compared equal to the recorded combination whether or not the recorder had
/// ever assigned it — deleting `combo = candidate` from the source left this test green.
/// Mutation testing is what found that, and this is the shape that survives it.
@MainActor @Test func theRecordedCombinationIsTheMaskedOneNotTheRawEventFlags() {
    let view = makeRecorder()
    var recorded: HotkeyCombo?
    view.onRecord = { recorded = $0 }
    click(view)
    #expect(view.combo == HotkeyCombo.default)   // the premise the assertions below rest on
    press(view, 0x23, [.control, .option, .capsLock, .numericPad, .function])

    let expected = HotkeyCombo(keyCode: 0x23,
                               modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
    #expect(expected != HotkeyCombo.default)
    #expect(recorded == expected)
    // Stated separately from the equality above, which is weaker than it looks:
    // `HotkeyCombo.==` compares a `modifiers` that the type's own initialiser already
    // masked, so the equality would hold even if the recorder had handed the stray bits
    // straight through. Measured — swapping `event.modifierFlags` for the weaker
    // `deviceIndependentFlagsMask` here changes nothing observable, because `HotkeyCombo`
    // re-masks either way. So this line documents where the masking happens rather than
    // defending it; `HotkeyComboTests` is what defends it.
    #expect(recorded?.modifiers == NSEvent.ModifierFlags([.control, .option]).rawValue)
    // The view's own copy is updated too, so the control cannot show one combination while
    // the setting holds another.
    #expect(view.combo == expected)
}

/// A combination with no Control, Option or Command is refused, and — the half that matters
/// — the recorder stays armed afterwards. Disarming on a refusal would leave the user
/// looking at their old shortcut with no sign anything happened, having to click again for
/// every attempt.
@MainActor @Test func aCombinationWithNoRealModifierIsRefusedAndTheRecorderStaysArmed() {
    let view = makeRecorder()
    var recorded: HotkeyCombo?
    view.onRecord = { recorded = $0 }
    click(view)

    press(view, 0x11, [])               // bare «T»
    #expect(recorded == nil)
    press(view, 0x11, [.shift])         // ⇧T is how a capital T is typed
    #expect(recorded == nil)
    press(view, 0x11, [.capsLock])      // set bits, but not modifier bits
    #expect(recorded == nil)
    #expect(view.combo == HotkeyCombo.default)   // nothing was written down

    // Still listening: the next valid press is taken without another click.
    press(view, 0x11, [.control])
    #expect(recorded == HotkeyCombo(keyCode: 0x11,
                                    modifiers: NSEvent.ModifierFlags.control.rawValue))
}

@MainActor @Test func escapeAbandonsTheRecordingAndStopsListening() {
    let view = makeRecorder()
    var recorded: HotkeyCombo?
    view.onRecord = { recorded = $0 }
    click(view)

    press(view, UInt16(kVK_Escape), [])
    #expect(recorded == nil)
    #expect(view.combo == HotkeyCombo.default)

    // Disarmed, so a subsequent press is an ordinary key press and not a recording.
    press(view, 0x11, [.option, .command])
    #expect(recorded == nil)
}

/// Nothing is recorded before the control is clicked. Without this the view would swallow
/// key presses meant for the rest of the settings pane the moment it took focus.
@MainActor @Test func nothingIsRecordedUntilTheControlIsClicked() {
    let view = makeRecorder()
    var recorded: HotkeyCombo?
    view.onRecord = { recorded = $0 }
    press(view, 0x11, [.option, .command])
    #expect(recorded == nil)
}

/// Pressing and releasing modifiers alone must record nothing — there is no combination
/// yet, only the beginning of one.
///
/// What makes that true is an absence: AppKit delivers a bare modifier through
/// `flagsChanged(with:)` and never through `keyDown(with:)`, and `RecorderView` does not
/// override `flagsChanged`, so the inherited responder does nothing with it. An absence is
/// exactly what a later "improvement" removes — updating the display live as the user holds
/// ⌥⌘ is a reasonable thing to want, and routing that through the recording path would
/// commit ⌥ on its own the instant the user touched it. This is the test that would fail.
@MainActor @Test func pressingOnlyModifiersRecordsNothing() {
    let view = makeRecorder()
    var recorded: HotkeyCombo?
    view.onRecord = { recorded = $0 }
    click(view)

    let flagsOnly = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                     modifierFlags: [.option, .command], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "",
                                     charactersIgnoringModifiers: "", isARepeat: false,
                                     keyCode: UInt16(kVK_Option))!
    view.flagsChanged(with: flagsOnly)
    #expect(recorded == nil)
    #expect(view.combo == HotkeyCombo.default)

    // Still armed, so the real press that follows the modifiers is the one that counts.
    press(view, 0x11, [.option, .command])
    #expect(recorded == HotkeyCombo(keyCode: 0x11,
                                    modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue))
}

/// Beyond the brief, and the reason `performKeyEquivalent(with:)` exists on the view at all.
///
/// AppKit sends a key-down carrying Command through key-equivalent dispatch before it ever
/// reaches `keyDown` — the key window's view hierarchy first, then the main menu. A
/// recorder that only overrides `keyDown` therefore offers the app's own menu items first
/// refusal on exactly the combinations it exists to record, and the default shortcut this
/// app ships, ⌥⌘T, is one of them. Claiming the event while armed is what stops ⌘W closing
/// the settings window and ⌘Q quitting mid-recording.
///
/// The `while armed` half is not decoration: this method is offered every key equivalent in
/// the window regardless of focus, so an unguarded `return true` would eat the rest of the
/// pane's shortcuts.
@MainActor @Test func commandCombinationsAreClaimedBeforeTheMenuButOnlyWhileArmed() {
    let idle = makeRecorder()
    var recordedWhileIdle: HotkeyCombo?
    idle.onRecord = { recordedWhileIdle = $0 }
    // Not armed: the event is passed on, so ⌘W still closes the window as the user expects.
    #expect(idle.performKeyEquivalent(with: keyEvent(0x0D, [.command])) == false)
    #expect(recordedWhileIdle == nil)

    let armed = makeRecorder()
    var recorded: HotkeyCombo?
    armed.onRecord = { recorded = $0 }
    click(armed)
    // Armed: claimed and written down, rather than reaching the menu.
    #expect(armed.performKeyEquivalent(with: keyEvent(0x11, [.option, .command])) == true)
    #expect(recorded == HotkeyCombo(keyCode: 0x11,
                                    modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue))
}
