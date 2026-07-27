import Testing
import AppKit
// Carbon explicitly: `@testable import` does not re-export the module's own imports, so
// `cmdKey` and friends are not in scope without it. Task 1 hit the same trap with
// `kAXTrustedCheckOptionPrompt`.
import Carbon.HIToolbox
@testable import TextCapture

@Test func theDefaultIsOptionCommandT() {
    // Spec 6.2. 0x11 is kVK_ANSI_T.
    #expect(HotkeyCombo.default == HotkeyCombo(keyCode: 0x11,
                                               modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue))
    #expect(HotkeyCombo.default.displayString == "⌥⌘T")
}

@Test func modifierGlyphsAreOrderedTheWayMacOSOrdersThem() {
    // Control, Option, Shift, Command — the order every macOS menu uses. Rendering them in
    // the order the flags happen to be declared would produce a string no user recognises.
    let all = HotkeyCombo(keyCode: 0x11,
                          modifiers: NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue)
    #expect(all.displayString == "⌃⌥⇧⌘T")
}

@Test func namedKeysRenderAsNamesNotAsGarbage() {
    // 0x31 is space, 0x24 is return. Both have no printable glyph; falling through to a
    // character lookup renders them as an invisible run the user cannot read back.
    #expect(HotkeyCombo(keyCode: 0x31, modifiers: NSEvent.ModifierFlags.command.rawValue).displayString == "⌘Пробел")
    #expect(HotkeyCombo(keyCode: 0x24, modifiers: NSEvent.ModifierFlags.command.rawValue).displayString == "⌘↩")
    #expect(HotkeyCombo(keyCode: 0x30, modifiers: NSEvent.ModifierFlags.command.rawValue).displayString == "⌘⇥")
}

@Test func aCombinationWithNoModifierIsRejected() {
    // Registering a bare key steals it from every app on the system: the user could not
    // type the letter T anywhere. Shift alone is no better — ⇧T is just a capital T.
    #expect(HotkeyCombo(keyCode: 0x11, modifiers: 0).isValid == false)
    #expect(HotkeyCombo(keyCode: 0x11, modifiers: NSEvent.ModifierFlags.shift.rawValue).isValid == false)
    #expect(HotkeyCombo(keyCode: 0x11, modifiers: NSEvent.ModifierFlags.command.rawValue).isValid)
    #expect(HotkeyCombo.default.isValid)
}

@Test func carbonModifiersTranslateEachFlagSeparately() {
    // Carbon uses its own constants, and getting one wrong registers a different
    // combination than the one shown in settings — a mismatch nothing else would catch.
    let combo = HotkeyCombo(keyCode: 0x11,
                            modifiers: NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue)
    #expect(combo.carbonModifiers == UInt32(cmdKey | optionKey | controlKey | shiftKey))

    // One flag at a time, which is the only thing that pins each translation down. Asserting
    // only the all-four case above would pass with any two constants swapped, because
    // `optionKey | controlKey` and `controlKey | optionKey` are the same number.
    func carbon(_ flag: NSEvent.ModifierFlags) -> UInt32 {
        HotkeyCombo(keyCode: 0x11, modifiers: flag.rawValue).carbonModifiers
    }
    #expect(carbon(.command) == UInt32(cmdKey))
    #expect(carbon(.option) == UInt32(optionKey))
    #expect(carbon(.control) == UInt32(controlKey))
    #expect(carbon(.shift) == UInt32(shiftKey))

    // The value HotkeyManager will actually hand to RegisterEventHotKey for the default.
    #expect(HotkeyCombo.default.carbonModifiers == 2304)
}

@Test func theComboSurvivesAUserDefaultsRoundTrip() {
    // It is stored as JSON in a single key rather than as two, so a half-written pair can
    // never register a combination the user did not choose.
    let combo = HotkeyCombo(keyCode: 0x23, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    let data = try! JSONEncoder().encode(combo)
    #expect(try! JSONDecoder().decode(HotkeyCombo.self, from: data) == combo)
}
