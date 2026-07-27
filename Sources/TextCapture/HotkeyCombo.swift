import Foundation
import AppKit
import Carbon.HIToolbox

/// A key combination, stored as the two integers macOS actually deals in.
///
/// `modifiers` holds an `NSEvent.ModifierFlags` raw value rather than the flags themselves
/// so the type stays `Codable` without a custom encoder, and it is masked to the device
/// -independent set on the way in: a raw `NSEvent` flags value carries left/right variants
/// and a numeric-pad bit that would make two presses of the same visible combination
/// compare unequal.
public struct HotkeyCombo: Equatable, Sendable, Codable {
    public let keyCode: UInt16
    public let modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection([.command, .option, .control, .shift]).rawValue
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
    /// F2=120, F5=96, F12=111.
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
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

    /// Serialises the Text Input Sources calls below. HIToolbox detects concurrent TIS/TSM
    /// use and aborts the whole process rather than returning an error — "Text Input Sources
    /// or Text Services Manager API is being called in two threads concurrently". Since this
    /// type is `Sendable` and `displayString` is public, two threads reaching `printableName`
    /// at once is reachable, not theoretical: it killed the test run the first time these
    /// tests were executed in parallel.
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
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
