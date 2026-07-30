import Testing
import AppKit
// Carbon explicitly: `@testable import` does not re-export the module's own imports, so
// `kEventHotKeyPressed` and `eventNotHandledErr` are not in scope without it.
import Carbon.HIToolbox
@testable import TextCapture

/// Dispatches a hot-key-pressed event through Carbon's handler chain, without a key press.
///
/// This is the same call the application's run loop makes once it has pulled a real hot-key
/// event off the main event queue, so it exercises the installed handler, the `userData`
/// bridge and the closure. What it does **not** exercise is everything before that: that the
/// OS notices the key combination and posts an event to this process at all. That half needs a
/// real press and is verified by hand in Task 10.
@discardableResult
private func dispatchHotKey(signature: OSType = HotkeyManager.signature, id: UInt32) -> OSStatus {
    var event: EventRef?
    CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                0, UInt32(kEventAttributeNone), &event)
    guard let event else { return OSStatus(-1) }
    defer { ReleaseEvent(event) }
    var pressed = EventHotKeyID(signature: signature, id: id)
    SetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &pressed)
    return SendEventToEventTarget(event, GetEventDispatcherTarget())
}

@MainActor
@Test func registeringSucceedsAndRecordsTheCombination() {
    let manager = HotkeyManager()
    defer { manager.unregister() }
    // An obscure combination, so a hotkey the developer actually uses is not stolen for
    // the duration of the test run.
    let combo = HotkeyCombo(keyCode: 0x2B, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
    #expect(manager.register(combo) {})
    #expect(manager.registered == combo)
}

@MainActor
@Test func registeringAgainReplacesRatherThanStacks() {
    // Settings can change the combination at any time. Without the unregister on the way
    // in, the old combination stays live forever and the app answers to both.
    let manager = HotkeyManager()
    defer { manager.unregister() }
    let first = HotkeyCombo(keyCode: 0x2B, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
    let second = HotkeyCombo(keyCode: 0x2C, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
    #expect(manager.register(first) {})
    #expect(manager.register(second) {})
    #expect(manager.registered == second)
}

@MainActor
@Test func unregisteringIsIdempotentAndClearsTheRecord() {
    let manager = HotkeyManager()
    #expect(manager.register(HotkeyCombo(keyCode: 0x2B,
                                         modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)) {})
    manager.unregister()
    #expect(manager.registered == nil)
    manager.unregister()          // must not trap on a second call
    #expect(manager.registered == nil)
}

@MainActor
@Test func anInvalidCombinationIsRefusedBeforeItReachesCarbon() {
    // A bare key would be registered happily by Carbon and would take that key away from
    // every application on the system. The refusal belongs here, not in the settings view,
    // so no call site can bypass it.
    let manager = HotkeyManager()
    defer { manager.unregister() }
    #expect(manager.register(HotkeyCombo(keyCode: 0x11, modifiers: 0)) {} == false)
    #expect(manager.registered == nil)
}

@MainActor
@Test func aDispatchedPressReachesTheClosure() {
    // The `userData` bridge from the C handler back to a Swift closure, end to end. Nothing
    // else in this file proves the closure is reachable at all: `register` returning true
    // only says Carbon accepted the registration.
    let manager = HotkeyManager()
    defer { manager.unregister() }
    var fired = 0
    #expect(manager.register(HotkeyCombo(keyCode: 0x2B,
                                         modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)) {
        fired += 1
    })
    #expect(dispatchHotKey(id: manager.hotKeyID) == noErr)
    #expect(fired == 1)
}

@MainActor
@Test func nothingReachesTheClosureAfterUnregister() {
    // `Unmanaged.passUnretained` does not keep the manager alive, so a handler that outlived
    // `unregister` would be reading freed memory. This asserts the observable half — nothing
    // reaches the closure afterwards — and deliberately does not claim to prove
    // `RemoveEventHandler` ran: `unregister` also nils `onPress`, so a surviving handler
    // would no-op and this test would still pass. The assertion that actually depends on the
    // handler being gone is `registeringTwiceOnOneInstanceSucceedsBothTimes` below, which
    // fails with -9866 if a stale handler is left installed.
    let manager = HotkeyManager()
    var fired = 0
    let combo = HotkeyCombo(keyCode: 0x2B, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
    #expect(manager.register(combo) { fired += 1 })
    let id = manager.hotKeyID
    manager.unregister()
    dispatchHotKey(id: id)
    #expect(fired == 0)
}

@MainActor
@Test func twoManagersDoNotAnswerToEachOthersHotkey() {
    // Both instances install a handler on the *same* shared dispatcher target, so every
    // handler is offered every hot-key event in the process — not just its own. Measured: with
    // a handler that does not check which hot key fired, the most recently installed one takes
    // every press and returns noErr, and the other manager's closure is never called even for
    // its own combination.
    let first = HotkeyManager()
    let second = HotkeyManager()
    defer { first.unregister(); second.unregister() }
    var firstFired = 0, secondFired = 0
    #expect(first.register(HotkeyCombo(keyCode: 0x2B,
                                       modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)) {
        firstFired += 1
    })
    #expect(second.register(HotkeyCombo(keyCode: 0x2C,
                                        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)) {
        secondFired += 1
    })
    #expect(first.hotKeyID != second.hotKeyID)

    dispatchHotKey(id: first.hotKeyID)
    #expect(firstFired == 1)
    #expect(secondFired == 0)

    dispatchHotKey(id: second.hotKeyID)
    #expect(firstFired == 1)
    #expect(secondFired == 1)
}

@MainActor
@Test func aHotkeyBelongingToSomebodyElseIsPassedOn() {
    // Any other component in the process may have its own hot key; the event still arrives at
    // every handler on the dispatcher target. Answering noErr to it would both run this app's
    // action on a stranger's keystroke and stop the event reaching its real owner, because
    // noErr ends the chain.
    let manager = HotkeyManager()
    defer { manager.unregister() }
    var fired = 0
    #expect(manager.register(HotkeyCombo(keyCode: 0x2B,
                                         modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)) {
        fired += 1
    })
    // Same signature, a registration this manager does not own.
    dispatchHotKey(id: manager.hotKeyID &+ 1000)
    // A different signature entirely.
    dispatchHotKey(signature: OSType(0x5A5A5A5A), id: manager.hotKeyID)
    #expect(fired == 0)
    #expect(dispatchHotKey(signature: OSType(0x5A5A5A5A), id: 1) == OSStatus(eventNotHandledErr))
}

@MainActor
@Test func registeringTwiceOnOneInstanceSucceedsBothTimes() {
    // This is the assertion that depends on `RemoveEventHandler` actually running. Carbon
    // refuses a duplicate handler proc with the same `userData` — `eventHandlerAlreadyInstalled`,
    // -9866 — so a stale handler left installed by `unregister` makes the second `register`
    // return false. Nothing else in this file notices a leaked handler.
    let manager = HotkeyManager()
    defer { manager.unregister() }
    let combo = HotkeyCombo(keyCode: 0x2B,
                            modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
    #expect(manager.register(combo) {})
    manager.unregister()
    #expect(manager.register(combo) {})
}

@MainActor
@Test func aQueuedPressOfThePreviousShortcutIsDroppedAfterAChange() {
    // Why the counter is bumped per registration rather than per instance. The user changes
    // the shortcut while a press of the old one is already in flight; if both registrations
    // shared an id, that stale press would still match and translate whatever happened to be
    // selected. Assigning the id once per instance passes every other test in this file.
    let manager = HotkeyManager()
    defer { manager.unregister() }
    var fired = 0
    let first = HotkeyCombo(keyCode: 0x2B,
                            modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
    let second = HotkeyCombo(keyCode: 0x2C,
                             modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
    #expect(manager.register(first) { fired += 1 })
    let staleID = manager.hotKeyID
    #expect(manager.register(second) { fired += 1 })
    #expect(manager.hotKeyID != staleID)

    _ = dispatchHotKey(id: staleID)
    #expect(fired == 0, "a press of the shortcut the user just replaced must not translate")
    _ = dispatchHotKey(id: manager.hotKeyID)
    #expect(fired == 1)
}
