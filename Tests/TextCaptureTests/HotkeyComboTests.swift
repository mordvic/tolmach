import Testing
import AppKit
// Carbon explicitly: `@testable import` does not re-export the module's own imports, so
// `cmdKey` and friends are not in scope without it. Task 1 hit the same trap with
// `kAXTrustedCheckOptionPrompt`.
import Carbon.HIToolbox
@testable import TextCapture

// What virtual key code 0x11 renders as is a property of the keyboard layout that happens to
// be active when the suite runs, not of this code — enumerated on this machine, 0x11 is T on
// ABC, Е on Russian and RussianWin, Y on Dvorak, Ш on Bulgarian. Showing the letter printed on
// the user's own key is the point of `printableName`, so the implementation is right and stays
// as it is; it is the tests that must not assert a letter, or `swift test` turns red whenever
// the author has the Russian layout selected — which, for a Russian-language app, is most of
// the time. Assertions below therefore split the combination into the modifier prefix, which
// is computed from the flags alone, and a key portion taken from a named key: `keyName`
// returns those from its own table and never reaches the layout at all.
private let optionCommand = NSEvent.ModifierFlags([.option, .command]).rawValue

@Test func theDefaultIsOptionCommandT() {
    // Spec 6.2. 0x11 is kVK_ANSI_T. This is what Task 3 hands to RegisterEventHotKey, and it
    // is layout-independent: the code and the flags are fixed, only the rendering moves.
    #expect(HotkeyCombo.default == HotkeyCombo(keyCode: 0x11, modifiers: optionCommand))
    #expect(HotkeyCombo.default.keyCode == 0x11)
    #expect(HotkeyCombo.default.modifiers == optionCommand)

    // The glyphs the default renders with, asserted without asserting the letter after them.
    #expect(HotkeyCombo.default.displayString.hasPrefix("⌥⌘"))
    #expect(HotkeyCombo(keyCode: UInt16(kVK_Space), modifiers: optionCommand)
                .displayString == "⌥⌘Пробел")
}

@Test func modifierGlyphsAreOrderedTheWayMacOSOrdersThem() {
    // Control, Option, Shift, Command — the order every macOS menu uses. Rendering them in
    // the order the flags happen to be declared would produce a string no user recognises.
    let allFlags = NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue
    // kVK_Space rather than a letter key, so the assertion can be exact: "Пробел" comes from
    // the table in `keyName`, which returns before any layout lookup happens.
    #expect(HotkeyCombo(keyCode: UInt16(kVK_Space), modifiers: allFlags).displayString
            == "⌃⌥⇧⌘Пробел")
    // And the same prefix precedes a letter key, whatever letter this layout puts there.
    #expect(HotkeyCombo(keyCode: 0x11, modifiers: allFlags).displayString.hasPrefix("⌃⌥⇧⌘"))
}

@Test func namedKeysRenderAsNamesNotAsGarbage() {
    // 0x31 is space, 0x24 is return. Both have no printable glyph; falling through to a
    // character lookup renders them as an invisible run the user cannot read back.
    #expect(HotkeyCombo(keyCode: 0x31, modifiers: NSEvent.ModifierFlags.command.rawValue).displayString == "⌘Пробел")
    #expect(HotkeyCombo(keyCode: 0x24, modifiers: NSEvent.ModifierFlags.command.rawValue).displayString == "⌘↩")
    #expect(HotkeyCombo(keyCode: 0x30, modifiers: NSEvent.ModifierFlags.command.rawValue).displayString == "⌘⇥")
}

@Test func keysThatTypeAControlCharacterFallBackToTheirNumber() {
    // `UCKeyTranslate` returns success with length 1 for these, so a `length > 0` check
    // treats an invisible control character as a perfectly good name and the fallback never
    // fires. Measured over codes 0...127 on this machine, 17 of them do it.
    //
    // 71 is the keypad Clear key: it translated to U+001B, so ⌘Clear rendered as "⌘" followed
    // by an invisible byte. 114 is Help and gave U+0005.
    let clear = HotkeyCombo(keyCode: 71, modifiers: NSEvent.ModifierFlags.command.rawValue)
    #expect(clear.displayString == "⌘клавиша 71")
    #expect(HotkeyCombo(keyCode: 114, modifiers: NSEvent.ModifierFlags.command.rawValue)
                .displayString == "⌘клавиша 114")

    // Stated as an invariant rather than as three examples: no key code may ever render as
    // something the user cannot see. This is the assertion that would catch a seventeenth
    // control character appearing on a keyboard type nobody tested on.
    for code in UInt16(0)...UInt16(127) {
        let name = HotkeyCombo.keyName(code)
        let escaped = name.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined()
        #expect(!name.isEmpty, "key code \(code) has an empty name")
        #expect(!name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                "key code \(code) renders as control characters \(escaped)")
    }
}

@Test func theSecondRowOfFunctionKeysIsNamedToo() {
    // F13–F16 all translated to U+0010 and F17–F20 fell through to "клавиша 64/79/80/90".
    // Both rows exist on an Apple extended keyboard, so both are recordable. The F-number
    // comes from the position in `functionKeys`, and the virtual codes are not in order
    // (F13=105, F14=107, F15=113, F16=106), so a mis-ordered list renumbers them silently.
    #expect(HotkeyCombo.keyName(UInt16(kVK_F13)) == "F13")
    #expect(HotkeyCombo.keyName(UInt16(kVK_F14)) == "F14")
    #expect(HotkeyCombo.keyName(UInt16(kVK_F15)) == "F15")
    #expect(HotkeyCombo.keyName(UInt16(kVK_F16)) == "F16")
    #expect(HotkeyCombo.keyName(UInt16(kVK_F17)) == "F17")
    #expect(HotkeyCombo.keyName(UInt16(kVK_F20)) == "F20")
    // The first row must not have shifted while the second was appended.
    #expect(HotkeyCombo.keyName(UInt16(kVK_F1)) == "F1")
    #expect(HotkeyCombo.keyName(UInt16(kVK_F12)) == "F12")
    #expect(HotkeyCombo(keyCode: UInt16(kVK_F13),
                        modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)
                .displayString == "⌥⌘F13")
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
    //
    // Note this says nothing about the mask: `combo` was masked on the way in, so the bytes
    // encoded here are already clean and decoding them cannot expose an unmasked field.
    // `decodingAppliesTheSameMaskTheInitDoes` below covers that separately.
    let combo = HotkeyCombo(keyCode: 0x23, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    let data = try! JSONEncoder().encode(combo)
    #expect(try! JSONDecoder().decode(HotkeyCombo.self, from: data) == combo)
}

@Test func decodingAppliesTheSameMaskTheInitDoes() {
    // Literal JSON, not a re-encoded combo: what Task 7 reads back out of UserDefaults is not
    // necessarily what this build wrote. A hand-edited plist or a value from an older version
    // carries bits the init strips, and a synthesised `init(from:)` assigns the stored
    // properties directly, letting them straight through. An unmasked `modifiers` then fails
    // to compare equal to the same visible combination the user records fresh — the exact
    // failure the mask exists to prevent.
    //
    // 3211264 = 0x310000 = command | numericPad | capsLock.
    let json = Data(#"{"keyCode":17,"modifiers":3211264}"#.utf8)
    let decoded = try! JSONDecoder().decode(HotkeyCombo.self, from: json)
    #expect(decoded.modifiers == NSEvent.ModifierFlags.command.rawValue)
    #expect(decoded == HotkeyCombo(keyCode: 0x11, modifiers: NSEvent.ModifierFlags.command.rawValue))
    #expect(decoded.keyCode == 0x11)
}
