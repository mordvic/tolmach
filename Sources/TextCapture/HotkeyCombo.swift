import Foundation
import AppKit
import Carbon.HIToolbox

/// A key combination, stored as the two integers macOS actually deals in.
///
/// `modifiers` holds an `NSEvent.ModifierFlags` raw value rather than the flags themselves so
/// the type stays `Codable` without a custom encoder, and it is masked on the way in to just
/// the four flags a shortcut may contain — ⌘⌥⌃⇧ — because a raw `NSEvent` flags value carries
/// more than that, and any of the extra bits would make two presses of the same visible
/// combination compare unequal.
///
/// The mask is deliberately that explicit four-flag set and **not**
/// `deviceIndependentFlagsMask`, which looks like the tidier spelling and is weaker. Measured:
/// the left/right variants do sit in the low bits that `deviceIndependentFlagsMask` clears,
/// but `numericPad` (0x200000), `capsLock` (0x10000), `function` (0x800000) and `help`
/// (0x400000) are all high bits that survive it. Press ⌘ together with a key on the numeric
/// keypad, or with caps lock on, and that mask leaves the difference in place. Intersecting
/// with the four flags strips every one of them.
public struct HotkeyCombo: Equatable, Sendable, Codable {
    public let keyCode: UInt16
    public let modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection([.command, .option, .control, .shift]).rawValue
    }

    /// Written out rather than synthesised, because a synthesised `init(from:)` assigns the
    /// stored properties directly and so never applies the mask above. That matters: Task 7
    /// persists this type as JSON in `UserDefaults`, where the bytes read back are not
    /// necessarily bytes this build wrote — a hand-edited plist or a value from an older
    /// version can carry the numeric-pad, caps-lock or left/right bits, and an unmasked
    /// `modifiers` compares unequal to the same visible combination recorded fresh.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                  modifiers: try container.decode(UInt.self, forKey: .modifiers))
    }

    /// Spec 6.2's default.
    public static let `default` = HotkeyCombo(
        keyCode: UInt16(kVK_ANSI_T),
        modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)

    private var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// At least one of Control, Option or Command. Shift alone does not count: ⇧T is how
    /// everyone types a capital T, and registering it would take the letter away from the
    /// whole system. A bare key with no modifier at all is worse still.
    public var isValid: Bool {
        !flags.intersection([.command, .option, .control]).isEmpty
    }

    /// Glyphs in the order macOS itself uses in menus — ⌃⌥⇧⌘ — not the order the flags
    /// happen to be declared in.
    public var displayString: String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    public var carbonModifiers: UInt32 {
        var out: Int = 0
        if flags.contains(.command) { out |= cmdKey }
        if flags.contains(.option) { out |= optionKey }
        if flags.contains(.control) { out |= controlKey }
        if flags.contains(.shift) { out |= shiftKey }
        return UInt32(out)
    }

    /// Listed rather than expressed as a range, because the virtual key codes for the
    /// function keys are neither contiguous nor ordered: `kVK_F1` is 122 and `kVK_F12` is
    /// 111, so `kVK_F1...kVK_F12` is an inverted range and traps at run time with
    /// "Range requires lowerBound <= upperBound". Verified on this machine — F1=122,
    /// F2=120, F5=96, F12=111, and the second row is scrambled too: F13=105, F14=107,
    /// F15=113, F16=106, F17=64, F18=79, F19=80, F20=90.
    ///
    /// The F-number comes from the array index, so the order of this list is the mapping.
    /// Runs to F20 because an Apple extended keyboard has those keys: left short, F13–F16
    /// rendered as an invisible U+0010 and F17–F20 as "клавиша 64/79/80/90".
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16,
        kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Keys with no printable glyph get a name. Without this branch they render as an
    /// invisible or nonsensical run and the user cannot read back what they just recorded.
    static func keyName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Space: return "Пробел"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let index = functionKeys.firstIndex(of: Int(code)) { return "F\(index + 1)" }
            return printableName(code) ?? "клавиша \(code)"
        }
    }

    /// Serialises *our own* Text Input Sources calls against each other. Read the limit before
    /// relying on it.
    ///
    /// HIToolbox detects concurrent TIS/TSM use and aborts the whole process rather than
    /// returning an error — "Text Input Sources or Text Services Manager API is being called in
    /// two threads concurrently". Two threads reaching `printableName` at once is reachable,
    /// not theoretical: it killed the test run the first time these tests were executed in
    /// parallel, and this lock is what makes a parallel suite deterministic again.
    ///
    /// What it does **not** do is make `displayString` safe to call from any thread. The lock
    /// can only exclude callers that take it; it cannot exclude AppKit, which makes its own
    /// unlocked TIS calls on the main thread. A background thread inside this locked lookup,
    /// concurrent with ordinary main-thread AppKit work, still aborts the process — measured,
    /// 3 runs out of 3. The lock removes one race; the framework's half of it remains.
    ///
    /// So: read `displayString` on the main actor. In this app every production reader already
    /// is one — the SwiftUI bodies that show the current shortcut, and the recorder view. Do
    /// not take this comment as licence to read it from a background task. Confining the
    /// lookup to the main actor outright was considered and rejected: `HotkeyCombo` is
    /// `Sendable` and the tests read it off-main, so main-actor isolation would spread through
    /// the type to close a hazard none of this app's paths actually reach.
    private static let inputSourceLock = NSLock()

    /// Asks the current keyboard layout what this code types, so a user on a non-QWERTY
    /// layout sees the letter actually printed on their key.
    private static func printableName(_ code: UInt16) -> String? {
        inputSourceLock.lock()
        defer { inputSourceLock.unlock() }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let name = String(utf16CodeUnits: chars, count: length)
        // A non-empty answer is not the same as a readable one. `UCKeyTranslate` reports
        // success for keys that "type" a control character — keypad Enter gives U+0003, Clear
        // U+001B, Help U+0005, and every key the layout does not really map gives U+0010 — so
        // `length > 0` alone lets an invisible glyph through and the caller's `?? "клавиша N"`
        // never fires. The user then sees «⌥⌘» with nothing after it and cannot tell which key
        // they just recorded. Rejecting here is what routes those codes to the fallback.
        guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return name.uppercased()
    }
}
