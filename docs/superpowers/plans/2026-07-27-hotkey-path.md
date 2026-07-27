# Hotkey Path Implementation Plan (Plan 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pressing a global hotkey translates whatever text the user has selected in any app and shows it in a floating panel that never steals their focus.

**Architecture:** A new dependency-free `TextCapture` target owns every fragile macOS API — the Carbon hotkey registration, the Accessibility read, the clipboard fallback and the permission check — so none of it leaks into the engine or the SwiftUI layer. `TranslatorApp` gains an `NSPanel` host driven by a second `TranslationViewModel`, kept separate from the main window's so a hotkey translation never overwrites what is on screen there.

**Tech Stack:** Swift 5 language mode on Swift 6 tools, SwiftUI + AppKit, `Carbon.HIToolbox` for the hotkey, `ApplicationServices` for the Accessibility API, `CoreGraphics` for the synthetic keystroke. No external dependencies.

## Global Constraints

- Swift tools version 6.0, platform floor macOS 14, `.swiftLanguageMode(.v5)` on **every** target including the new one.
- No external dependencies. Foundation, NaturalLanguage, SwiftUI, AppKit, Observation, ApplicationServices, CoreGraphics, Carbon and Swift Testing only.
- All user-facing strings are Russian, correctly spelled, with guillemets «» and «ё» where they belong. Key-combination glyphs (⌥⌘T) and identifiers (`aya-expanse:8b`) stay as they are.
- **No backticks in any string rendered by `Text(String)`.** The plain-`String` initialiser never parses Markdown, so they show as literal grave accents. Use guillemets. This has already had to be fixed once, in Plan 2 Task 11.
- Baseline at the start of this plan: **192 tests passing**; `swift build` and `swift build --build-tests` both at zero warnings. Both must still hold at every commit.
- Views are checked by hand — GUI automation is unavailable in this environment. Every task that ships a view says so, states exactly what indirect evidence was gathered, and never describes UI that was not observed.
- The panel must never activate this app. `NSWorkspace.shared.frontmostApplication.bundleIdentifier` before and after showing it is the check, and it is available headlessly.

## Two facts that shape the whole plan

**1. The Accessibility grant is keyed to the code signature, and `make-app-bundle.sh` signs ad-hoc.** An ad-hoc signature's designated requirement is derived from the binary's cdhash, which changes on every build. macOS therefore treats each rebuild as a different program and the Accessibility grant does not carry over: the app reappears in the list unchecked, or duplicated. This is not a bug to fix in code, it is a property of ad-hoc signing, and every task that needs the permission must expect to re-grant it after a rebuild. Task 1 documents the one-time way out (a stable self-signed identity) and Task 12 verifies which behaviour this machine actually shows.

**2. The hotkey works without the Accessibility permission; the capture does not.** `RegisterEventHotKey` is a Carbon API that needs no TCC grant, so ⌥⌘T fires even on a fresh install. Spec 6.1 says «без разрешения хоткей не работает», and the user-visible outcome is the same — no translation appears — but the mechanism matters: because the hotkey fires, the app gets a chance to show the onboarding prompt *at the moment the user tried to use it*, which is worth far more than silence. That is what this plan builds.

---

## File Structure

**New target `TextCapture`** — every macOS-specific capture concern, no SwiftUI, no `TranslationCore`:

| File | Responsibility |
|---|---|
| `Sources/TextCapture/PermissionsGate.swift` | Is Accessibility granted; open the right System Settings pane |
| `Sources/TextCapture/HotkeyCombo.swift` | The value type: key code + modifiers, display string, `UserDefaults` round trip |
| `Sources/TextCapture/HotkeyManager.swift` | Carbon registration, re-registration on change, teardown |
| `Sources/TextCapture/PasteboardSnapshot.swift` | Save and restore the *whole* pasteboard, not just its string |
| `Sources/TextCapture/SelectionReader.swift` | Accessibility read, clipboard fallback, and the rule that orders them |

**`TranslatorApp` additions:**

| File | Responsibility |
|---|---|
| `Sources/TranslatorApp/PanelPlacement.swift` | Pure geometry: where the panel goes for a given cursor and screen |
| `Sources/TranslatorApp/TranslationPanel.swift` | The `NSPanel` subclass and its controller |
| `Sources/TranslatorApp/PanelView.swift` | The SwiftUI content of the panel |
| `Sources/TranslatorApp/HotkeyCoordinator.swift` | Hotkey → capture → panel → translate, and the settings-change re-registration |
| `Sources/TranslatorApp/HotkeyRecorder.swift` | The settings control that captures a new combination |

**Modified:** `Package.swift`, `Sources/TranslatorApp/AppSettings.swift` (the hotkey property), `Sources/TranslatorApp/SettingsGeneralView.swift` (the hotkey row), `Sources/TranslatorApp/TranslatorApp.swift` (owning the coordinator), `Sources/TranslatorApp/MainWindowView.swift` (the retry button), `Sources/TranslatorApp/RussianCopy.swift` (new copy), `Scripts/make-app-bundle.sh` (signing identity).

---

### Task 1: `TextCapture` target and `PermissionsGate`

**Files:**
- Create: `Sources/TextCapture/PermissionsGate.swift`
- Create: `Tests/TextCaptureTests/PermissionsGateTests.swift`
- Modify: `Package.swift`
- Modify: `Scripts/make-app-bundle.sh`

**Interfaces:**
- Produces: `public enum PermissionsGate { public static func isTrusted() -> Bool; public static func requestTrust() -> Bool; public static let settingsURL: URL; public static func openSettings() }`

`isTrusted()` must not prompt. `requestTrust()` must. Two functions rather than a flag, because the difference matters at every call site: the coordinator checks on every hotkey press and a prompt on every press would be intolerable, while the onboarding screen's button exists precisely to prompt.

- [ ] **Step 1: Add the target**

In `Package.swift`, before the `TranslatorApp` target:

```swift
        .target(name: "TextCapture", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TextCaptureTests", dependencies: ["TextCapture"], swiftSettings: [.swiftLanguageMode(.v5)]),
```

and add `"TextCapture"` to `TranslatorApp`'s and `TranslatorAppTests`' `dependencies` arrays.

- [ ] **Step 2: Write the failing test**

```swift
// Tests/TextCaptureTests/PermissionsGateTests.swift
import Testing
import Foundation
// `@testable import` does not re-export the module's own imports, so
// `kAXTrustedCheckOptionPrompt` is not in scope without naming the framework here.
import ApplicationServices
@testable import TextCapture

@Test func theSettingsURLPointsAtTheAccessibilityPane() {
    // The anchor is the part that rots: Apple has renamed these panes across releases, and
    // a wrong anchor opens Privacy & Security at the top with no hint what to click.
    #expect(PermissionsGate.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}

@Test func theTwoEntryPointsAskForOppositePromptBehaviour() {
    // `isTrusted()` runs on every hotkey press; if it ever passed the prompt option the
    // user would get a system dialog on every press. A test process cannot observe whether
    // a dialog appeared — `AXIsProcessTrustedWithOptions` returns immediately either way and
    // posts the dialog asynchronously — so timing the call would pass with the bug present.
    // What is pinned instead is the one thing that is observable: the option each entry
    // point builds. That is why the dictionary construction is a function of its own.
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    #expect(PermissionsGate.trustOptions(prompting: false)[key] == false)
    #expect(PermissionsGate.trustOptions(prompting: true)[key] == true)
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter PermissionsGateTests`
Expected: FAIL — `cannot find 'PermissionsGate' in scope`.

- [ ] **Step 4: Write the implementation**

```swift
// Sources/TextCapture/PermissionsGate.swift
import Foundation
import ApplicationServices
import AppKit

/// Whether this process may read other applications' UI and post synthetic events.
///
/// Both of `SelectionReader`'s paths need it: the Accessibility read obviously, and the
/// clipboard fallback too, because posting a synthetic ⌘C is itself a privileged action.
/// The hotkey does *not* need it — `RegisterEventHotKey` is a Carbon API with no TCC gate —
/// which is why the app can still react to the key press and explain itself.
public enum PermissionsGate {
    /// A function rather than two inline literals, because it is the only part of this
    /// type a test can actually look at: `AXIsProcessTrustedWithOptions` returns the same
    /// value whether or not it prompts, and posts its dialog asynchronously, so nothing
    /// downstream distinguishes the two calls from inside a test process.
    static func trustOptions(prompting: Bool) -> [String: Bool] {
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompting]
    }

    /// Never prompts. Safe to call on every hotkey press.
    public static func isTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(trustOptions(prompting: false) as CFDictionary)
    }

    /// Prompts, and returns the state *before* the user answers — the system dialog is
    /// asynchronous and the answer arrives by the app being restarted or re-checked, not
    /// by this call returning true.
    @discardableResult
    public static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(trustOptions(prompting: true) as CFDictionary)
    }

    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    public static func openSettings() { NSWorkspace.shared.open(settingsURL) }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PermissionsGateTests` — PASS (2 tests). Then `swift test` — 194 total, all green.

- [ ] **Step 6: Give the bundle a stable signing identity**

Ad-hoc signing re-keys the Accessibility grant on every build (see "Two facts" above). Change `Scripts/make-app-bundle.sh` to prefer a stable identity when one exists and fall back to ad-hoc:

```bash
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "LocalTranslator Dev"; then
  IDENTITY="LocalTranslator Dev"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "signed with $IDENTITY — the Accessibility grant survives rebuilds"
else
  codesign --force --sign - "$APP"
  echo "ad-hoc signed — macOS will ask for Accessibility again after each rebuild"
fi
```

Record in the report which branch this machine takes. Do **not** create a certificate yourself: it needs Keychain Access and the user's decision. Document the recipe instead — *Keychain Access → Certificate Assistant → Create a Certificate, name «LocalTranslator Dev», type «Code Signing», self-signed* — and note that `CODESIGN_IDENTITY=… ./Scripts/make-app-bundle.sh` overrides.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/TextCapture Tests/TextCaptureTests Scripts/make-app-bundle.sh
git commit -m "feat(capture): TextCapture target and the Accessibility permission gate"
```

---

### Task 2: `HotkeyCombo`

**Files:**
- Create: `Sources/TextCapture/HotkeyCombo.swift`
- Test: `Tests/TextCaptureTests/HotkeyComboTests.swift`

**Interfaces:**
- Produces: `public struct HotkeyCombo: Equatable, Sendable, Codable { public let keyCode: UInt16; public let modifiers: UInt; public var displayString: String; public var carbonModifiers: UInt32; public var isValid: Bool; public static let `default`: HotkeyCombo; public init(keyCode: UInt16, modifiers: UInt) }`

Everything here is a pure function of two integers, so this task carries the real test coverage for the hotkey feature. `AppSettings` (Task 7) stores it and `HotkeyManager` (Task 3) registers it.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TextCaptureTests/HotkeyComboTests.swift
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
    #expect(HotkeyCombo(keyCode: 0x11, modifiers: NSEvent.ModifierFlags.command.rawValue)
                .carbonModifiers == UInt32(cmdKey))
}

@Test func theComboSurvivesAUserDefaultsRoundTrip() {
    // It is stored as JSON in a single key rather than as two, so a half-written pair can
    // never register a combination the user did not choose.
    let combo = HotkeyCombo(keyCode: 0x23, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    let data = try! JSONEncoder().encode(combo)
    #expect(try! JSONDecoder().decode(HotkeyCombo.self, from: data) == combo)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HotkeyComboTests`
Expected: FAIL — `cannot find 'HotkeyCombo' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TextCapture/HotkeyCombo.swift
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

    /// Asks the current keyboard layout what this code types, so a user on a non-QWERTY
    /// layout sees the letter actually printed on their key.
    private static func printableName(_ code: UInt16) -> String? {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HotkeyComboTests` — PASS (6 tests). Then `swift test` — 200 total, all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TextCapture/HotkeyCombo.swift Tests/TextCaptureTests/HotkeyComboTests.swift
git commit -m "feat(capture): HotkeyCombo with macOS glyph ordering and validation"
```

---

### Task 3: `HotkeyManager`

**Files:**
- Create: `Sources/TextCapture/HotkeyManager.swift`
- Test: `Tests/TextCaptureTests/HotkeyManagerTests.swift`

**Interfaces:**
- Consumes: `HotkeyCombo`.
- Produces: `@MainActor public final class HotkeyManager { public init(); public private(set) var registered: HotkeyCombo?; @discardableResult public func register(_ combo: HotkeyCombo, onPress: @escaping @MainActor () -> Void) -> Bool; public func unregister() }`

`RegisterEventHotKey` is Carbon, and its event handler is a C function pointer that cannot capture context. The bridge is a file-private box reached through the handler's `userData`, which is the only way to get from a C callback back to a Swift closure without a global.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TextCaptureTests/HotkeyManagerTests.swift
import Testing
import AppKit
@testable import TextCapture

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HotkeyManagerTests`
Expected: FAIL — `cannot find 'HotkeyManager' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TextCapture/HotkeyManager.swift
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
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?
    public private(set) var registered: HotkeyCombo?

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
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // The Carbon handler runs on the main thread already, but the compiler cannot
            // know that from a C callback, so the hop is made explicit.
            MainActor.assumeIsolated { manager.onPress?() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        guard installed == noErr else { self.onPress = nil; return false }

        // Any four-character code will do as long as it is stable; 'TLMH' is Толмач Hotkey.
        let id = EventHotKeyID(signature: OSType(0x544C4D48), id: 1)
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
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HotkeyManagerTests` — PASS (4 tests). Then `swift test` — 204 total, all green.

- [ ] **Step 5: Prove the tests are real**

Delete the `unregister()` call at the top of `register(_:onPress:)` and confirm `registeringAgainReplacesRatherThanStacks` fails. Remove the `guard combo.isValid` and confirm `anInvalidCombinationIsRefusedBeforeItReachesCarbon` fails. Restore both and report the exact messages.

Note what these tests do **not** cover: that pressing the key actually calls `onPress`. Carbon delivers hot-key events through the main run loop, and a `swift test` process has no such loop running. That path is verified by hand in Task 10.

- [ ] **Step 6: Commit**

```bash
git add Sources/TextCapture/HotkeyManager.swift Tests/TextCaptureTests/HotkeyManagerTests.swift
git commit -m "feat(capture): Carbon hotkey registration with replace-on-change"
```

---

### Task 4: `PasteboardSnapshot`

**Files:**
- Create: `Sources/TextCapture/PasteboardSnapshot.swift`
- Test: `Tests/TextCaptureTests/PasteboardSnapshotTests.swift`

**Interfaces:**
- Produces: `public struct PasteboardSnapshot: Equatable { public let items: [[String: Data]]; public let changeCount: Int; public static func take(from: NSPasteboard) -> PasteboardSnapshot; public func restore(to: NSPasteboard) }`

Spec 6 makes this non-negotiable: «обязательно сохранить прежнее содержимое буфера обмена до эмуляции и восстановить после, иначе приложение молча затирает пользователю буфер». Saving `pasteboard.string(forType: .string)` and putting it back is the tempting shortcut and it is wrong — it destroys rich text, images, files and every private type, and it turns a multi-item pasteboard into one item. This type is separate and tested because it is the piece that silently destroys the user's data when it is subtly wrong.

Every test uses `NSPasteboard(name:)` — a private named pasteboard — never `.general`. A test that clobbers the developer's real clipboard while proving it does not clobber the user's would be its own kind of joke.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TextCaptureTests/PasteboardSnapshotTests.swift
import Testing
import AppKit
@testable import TextCapture

private func scratchPasteboard() -> NSPasteboard {
    // Never `.general`: these tests overwrite whatever they are given.
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.\(UUID().uuidString)"))
}

@Test func aPlainStringRoundTrips() {
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    pb.setString("привет", forType: .string)

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    pb.setString("затёрто", forType: .string)
    snapshot.restore(to: pb)

    #expect(pb.string(forType: .string) == "привет")
}

@Test func everyTypeOfAnItemSurvivesNotJustTheString() {
    // The whole reason this type exists. A user who copied rich text out of Pages has an
    // RTF flavour alongside the plain string; restoring only the string silently downgrades
    // their clipboard to plain text and they find out when they paste.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData(Data("простой".utf8), forType: .string)
    item.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
    pb.writeObjects([item])

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    pb.setString("затёрто", forType: .string)
    snapshot.restore(to: pb)

    #expect(pb.string(forType: .string) == "простой")
    #expect(pb.data(forType: .rtf) == Data("{\\rtf1 rich}".utf8))
}

@Test func multipleItemsStayMultipleItems() {
    // A multi-file copy in Finder is several items. Collapsing them to one loses all but
    // the first, and the loss is invisible until the user pastes.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    let first = NSPasteboardItem(); first.setData(Data("один".utf8), forType: .string)
    let second = NSPasteboardItem(); second.setData(Data("два".utf8), forType: .string)
    pb.writeObjects([first, second])

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    snapshot.restore(to: pb)

    #expect(pb.pasteboardItems?.count == 2)
    #expect(pb.pasteboardItems?.compactMap { $0.string(forType: .string) } == ["один", "два"])
}

@Test func anEmptyPasteboardRestoresAsEmptyRatherThanUnchanged() {
    // If the user's clipboard was empty before the hotkey, it must be empty after. Skipping
    // the restore when there is nothing to write leaves the copied selection sitting in the
    // clipboard — exactly the leak this type exists to prevent.
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()

    let snapshot = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    pb.setString("выделенный текст", forType: .string)
    snapshot.restore(to: pb)

    #expect(pb.pasteboardItems?.isEmpty ?? true)
    #expect(pb.string(forType: .string) == nil)
}

@Test func theChangeCountIsCapturedSoTheCopyCanBeDetected() {
    let pb = scratchPasteboard()
    defer { pb.releaseGlobally() }
    pb.clearContents()
    let before = PasteboardSnapshot.take(from: pb)
    pb.clearContents()
    pb.setString("новое", forType: .string)
    #expect(pb.changeCount > before.changeCount)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PasteboardSnapshotTests`
Expected: FAIL — `cannot find 'PasteboardSnapshot' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TextCapture/PasteboardSnapshot.swift
import Foundation
import AppKit

/// Everything on a pasteboard, so the clipboard fallback can put it all back.
///
/// Stored as one dictionary per item, keyed by the type's raw string. `NSPasteboardItem` is
/// deliberately not held on to: an item read out of a pasteboard is only valid until that
/// pasteboard changes, so keeping the objects would give back empty data at restore time —
/// the exact moment it must not.
public struct PasteboardSnapshot: Equatable {
    public let items: [[String: Data]]
    public let changeCount: Int

    public static func take(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let captured = (pasteboard.pasteboardItems ?? []).map { item -> [String: Data] in
            var flavours: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { flavours[type.rawValue] = data }
            }
            return flavours
        }
        return PasteboardSnapshot(items: captured, changeCount: pasteboard.changeCount)
    }

    public func restore(to pasteboard: NSPasteboard) {
        // Cleared unconditionally, including when there is nothing to write back. An empty
        // snapshot means the user's clipboard was empty, and leaving the text this app
        // copied behind would be the very leak the restore exists to prevent.
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { flavours in
            let item = NSPasteboardItem()
            for (raw, data) in flavours {
                item.setData(data, forType: NSPasteboard.PasteboardType(raw))
            }
            return item
        })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PasteboardSnapshotTests` — PASS (5 tests). Then `swift test` — 209 total, all green.

- [ ] **Step 5: Prove the tests are real**

Three mutations, each reverted:
1. Replace the body of `take` with a string-only capture — `everyTypeOfAnItemSurvivesNotJustTheString` must fail.
2. Make `restore` write a single merged item — `multipleItemsStayMultipleItems` must fail.
3. Add `guard !items.isEmpty else { return }` **before** `clearContents()` — `anEmptyPasteboardRestoresAsEmptyRatherThanUnchanged` must fail.

Report each exact message. Mutation 3 is the important one: it is the plausible-looking version of this code, and only that one test separates it from the correct one.

- [ ] **Step 6: Commit**

```bash
git add Sources/TextCapture/PasteboardSnapshot.swift Tests/TextCaptureTests/PasteboardSnapshotTests.swift
git commit -m "feat(capture): whole-pasteboard snapshot and restore"
```

---

### Task 5: `SelectionReader`

**Files:**
- Create: `Sources/TextCapture/SelectionReader.swift`
- Test: `Tests/TextCaptureTests/SelectionReaderTests.swift`

**Interfaces:**
- Consumes: `PermissionsGate`, `PasteboardSnapshot`.
- Produces: `public enum SelectionResult: Equatable { case text(String), empty, notPermitted }`
- Produces: `public struct SelectionReader { public typealias Reader = @Sendable () -> String?; public init(accessibility: @escaping Reader = SelectionReader.accessibilityText, clipboard: @escaping Reader = SelectionReader.clipboardText, isTrusted: @escaping @Sendable () -> Bool = PermissionsGate.isTrusted); public func read() -> SelectionResult; public static func accessibilityText() -> String?; public static func clipboardText() -> String? }`

Spec 6's order — Accessibility first, clipboard emulation only when it comes back empty — is the whole point, and it is a pure decision over two closures. Injecting them is what makes that decision testable without a second application on screen.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TextCaptureTests/SelectionReaderTests.swift
import Testing
@testable import TextCapture

@Test func theAccessibilityPathIsPreferredAndTheClipboardIsNotTouched() {
    // Spec 6: the Accessibility read does not disturb the clipboard, so when it works the
    // fallback must not run at all. A fallback that ran anyway would post a synthetic ⌘C
    // into the user's app on every single hotkey press.
    nonisolated(unsafe) var clipboardCalls = 0
    let reader = SelectionReader(accessibility: { "из Accessibility" },
                                 clipboard: { clipboardCalls += 1; return "из буфера" },
                                 isTrusted: { true })
    #expect(reader.read() == .text("из Accessibility"))
    #expect(clipboardCalls == 0)
}

@Test func anEmptyAccessibilityResultFallsThroughToTheClipboard() {
    // Some Electron apps and browsers answer the attribute with an empty string rather than
    // refusing it, so "empty" and "unsupported" have to be treated the same way.
    let reader = SelectionReader(accessibility: { "" }, clipboard: { "из буфера" }, isTrusted: { true })
    #expect(reader.read() == .text("из буфера"))

    let nilReader = SelectionReader(accessibility: { nil }, clipboard: { "из буфера" }, isTrusted: { true })
    #expect(nilReader.read() == .text("из буфера"))
}

@Test func whitespaceOnlySelectionsCountAsEmpty() {
    // Translating a run of spaces wastes a model call and shows the user an empty panel.
    let reader = SelectionReader(accessibility: { "   \n\t " }, clipboard: { "  " }, isTrusted: { true })
    #expect(reader.read() == .empty)
}

@Test func bothPathsComingBackEmptyIsDistinctFromHavingNoPermission() {
    // These need different words in the panel: «выделите текст» versus the onboarding
    // prompt. Collapsing them sends a user with no selection to System Settings.
    let empty = SelectionReader(accessibility: { nil }, clipboard: { nil }, isTrusted: { true })
    #expect(empty.read() == .empty)

    let untrusted = SelectionReader(accessibility: { "неважно" }, clipboard: { "неважно" }, isTrusted: { false })
    #expect(untrusted.read() == .notPermitted)
}

@Test func thePermissionIsCheckedBeforeEitherPathRuns() {
    // Without the grant the Accessibility read fails and the synthetic ⌘C is silently
    // dropped by the window server — so running them first would burn the round trip and
    // still end up here, having flickered the user's clipboard for nothing.
    nonisolated(unsafe) var attempts = 0
    let reader = SelectionReader(accessibility: { attempts += 1; return nil },
                                 clipboard: { attempts += 1; return nil },
                                 isTrusted: { false })
    #expect(reader.read() == .notPermitted)
    #expect(attempts == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SelectionReaderTests`
Expected: FAIL — `cannot find 'SelectionReader' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TextCapture/SelectionReader.swift
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
    public func read() -> SelectionResult {
        guard isTrusted() else { return .notPermitted }
        if let text = accessibility().flatMap(Self.meaningful) { return .text(text) }
        if let text = clipboard().flatMap(Self.meaningful) { return .text(text) }
        return .empty
    }

    /// Returns the text only if it contains something worth translating. Applications that
    /// do not really support the attribute often answer with an empty string rather than
    /// refusing, so emptiness has to be treated as absence at both call sites.
    private static func meaningful(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    // MARK: - The real readers

    /// The clean path: ask the focused element for its selected text. Touches nothing.
    public static func accessibilityText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }

        var selected: CFTypeRef?
        // swiftlint:disable:next force_cast — guarded by the CFGetTypeID check above.
        let target = element as! AXUIElement
        guard AXUIElementCopyAttributeValue(target, kAXSelectedTextAttribute as CFString,
                                            &selected) == .success
        else { return nil }
        return selected as? String
    }

    /// Serialises the whole snapshot → copy → poll → restore sequence against itself.
    ///
    /// Not optional. `NSPasteboard`'s per-name item cache is built without synchronisation,
    /// and two threads reading `pasteboardItems` for the same name abort the process with an
    /// uncaught `NSException` — measured 10 times out of 10, and 0 out of 10 for distinct
    /// names. `NSPasteboard.general` is a single shared name, so every caller of this function
    /// is on the same board. The race is intra-process, which is exactly why a lock closes it.
    ///
    /// A lock rather than `@MainActor`: the poll below busy-waits for up to half a second,
    /// and running that on the main actor would stall the run loop on every fallback press.
    private static let clipboardLock = NSLock()

    /// The fallback: post ⌘C and read what lands, then put the user's clipboard back.
    ///
    /// The wait is a poll rather than a fixed sleep. A sleep long enough to be safe on a slow
    /// app is a visible stall on every press, and one short enough to feel instant loses the
    /// text on a slow one — the poll is both.
    ///
    /// It polls for a **non-nil string**, not merely for `changeCount` to move. Measured:
    /// `clearContents()` bumps the counter *before* any data is written, and the subsequent
    /// write does not bump it again. Returning on the first observed change therefore samples
    /// the copying application's cleared-but-not-yet-written window and yields `nil` — an
    /// intermittent «выделите текст» on a perfectly good selection.
    public static func clipboardText() -> String? {
        clipboardLock.lock()
        defer { clipboardLock.unlock() }
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if pasteboard.changeCount != snapshot.changeCount,
               let copied = pasteboard.string(forType: .string) {
                return copied
            }
            usleep(10_000)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SelectionReaderTests` — PASS (5 tests). Then `swift test` — 214 total, all green.

- [ ] **Step 5: Prove the tests are real**

Move the `guard isTrusted()` to *after* both reads and confirm `thePermissionIsCheckedBeforeEitherPathRuns` fails on its `attempts == 0` assertion. Drop the `meaningful` filter from the Accessibility branch and confirm both `anEmptyAccessibilityResultFallsThroughToTheClipboard` and `whitespaceOnlySelectionsCountAsEmpty` fail. Restore, report the messages.

Say plainly in the report what is **not** covered: `accessibilityText()` and `clipboardText()` themselves. Neither can run meaningfully in a test process — there is no focused element belonging to another app, and a synthetic ⌘C posted from a unit test goes nowhere. Task 10's hand-check is where they are exercised.

- [ ] **Step 6: Commit**

```bash
git add Sources/TextCapture/SelectionReader.swift Tests/TextCaptureTests/SelectionReaderTests.swift
git commit -m "feat(capture): selection reader with Accessibility path and clipboard fallback"
```

---

### Task 6: `PanelPlacement`

**Files:**
- Create: `Sources/TranslatorApp/PanelPlacement.swift`
- Test: `Tests/TranslatorAppTests/PanelPlacementTests.swift`

**Interfaces:**
- Produces: `enum PanelPlacement { static func frame(cursor: CGPoint, size: CGSize, screen: CGRect, gap: CGFloat = 14) -> CGRect }`

Spec 7.2 says the panel «появляется рядом с курсором». Cursor-relative placement is the one part of the panel that is pure arithmetic, so it gets extracted and tested rather than being buried in the window controller where nobody could check the corner cases. All coordinates are AppKit's: origin bottom-left, y increasing upwards.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslatorAppTests/PanelPlacementTests.swift
import Testing
import CoreGraphics
@testable import TranslatorApp

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let size = CGSize(width: 360, height: 240)

@Test func thePanelSitsBelowAndRightOfTheCursorWhenThereIsRoom() {
    // Below-right is where a macOS pointer's own shadow falls, so the panel does not cover
    // the text the user just selected.
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 400, y: 600), size: size, screen: screen)
    #expect(frame.minX == 414)                 // cursor.x + gap
    #expect(frame.maxY == 586)                 // cursor.y - gap, panel hanging downwards
    #expect(frame.size == size)
}

@Test func itFlipsToTheLeftRatherThanHangingOffTheRightEdge() {
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 1400, y: 600), size: size, screen: screen)
    #expect(frame.maxX == 1386)                // cursor.x - gap
    #expect(frame.minX >= screen.minX)
}

@Test func itFlipsUpwardRatherThanHangingOffTheBottom() {
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 400, y: 100), size: size, screen: screen)
    #expect(frame.minY == 114)                 // cursor.y + gap, panel standing upwards
    #expect(frame.maxY <= screen.maxY)
}

@Test func aPanelTallerThanTheScreenIsClampedRatherThanPlacedOffIt() {
    // A long translation with warnings can outgrow a small display. Clamping keeps the
    // controls reachable; flipping alone would just move the overflow to the other edge.
    let tall = CGSize(width: 360, height: 1200)
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 400, y: 450), size: tall, screen: screen)
    #expect(frame.minY >= screen.minY)
    #expect(frame.minX >= screen.minX)
    #expect(frame.maxX <= screen.maxX)
}

@Test func aScreenWithANonZeroOriginIsRespected() {
    // A second display sits at an offset, and often a negative one. Assuming an origin of
    // zero puts the panel on the wrong monitor — or nowhere.
    let secondary = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
    let frame = PanelPlacement.frame(cursor: CGPoint(x: -1900, y: 1250), size: size, screen: secondary)
    #expect(frame.minX >= secondary.minX)
    #expect(frame.maxY <= secondary.maxY)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PanelPlacementTests`
Expected: FAIL — `cannot find 'PanelPlacement' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslatorApp/PanelPlacement.swift
import CoreGraphics

/// Where the floating panel goes, given where the pointer is.
///
/// Extracted from the panel controller because it is the only part of the panel that is
/// arithmetic rather than AppKit, and the corner cases — the pointer near an edge, a second
/// display at a negative origin, a panel taller than the screen — are exactly the ones
/// nobody exercises by hand.
///
/// AppKit screen coordinates: origin bottom-left, y increasing upwards.
enum PanelPlacement {
    static func frame(cursor: CGPoint, size: CGSize, screen: CGRect, gap: CGFloat = 14) -> CGRect {
        // Preferred: to the right of the pointer, hanging downwards from it.
        var x = cursor.x + gap
        var y = cursor.y - gap - size.height

        // Flip before clamping. Clamping alone would slide the panel along the edge and
        // park it on top of the selection the user is trying to read.
        if x + size.width > screen.maxX { x = cursor.x - gap - size.width }
        if y < screen.minY { y = cursor.y + gap }

        // Clamp last, for the cases flipping cannot solve: a panel wider or taller than the
        // screen, or a pointer close enough to a corner that both sides overflow.
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width))
        y = min(max(y, screen.minY), max(screen.minY, screen.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PanelPlacementTests` — PASS (5 tests). Then `swift test` — 219 total, all green.

- [ ] **Step 5: Prove the tests are real**

Swap the order so clamping runs before flipping, and confirm `itFlipsToTheLeftRatherThanHangingOffTheRightEdge` fails. Replace `screen.minX` with `0` throughout and confirm `aScreenWithANonZeroOriginIsRespected` fails. Restore, report the messages.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/PanelPlacement.swift Tests/TranslatorAppTests/PanelPlacementTests.swift
git commit -m "feat(app): cursor-relative panel placement with flip and clamp"
```

---

### Task 7: The hotkey setting and its recorder

**Files:**
- Create: `Sources/TranslatorApp/HotkeyRecorder.swift`
- Modify: `Sources/TranslatorApp/AppSettings.swift`
- Modify: `Sources/TranslatorApp/SettingsGeneralView.swift`
- Test: `Tests/TranslatorAppTests/AppSettingsTests.swift`

**Interfaces:**
- Consumes: `HotkeyCombo`.
- Produces: `AppSettings.hotkey: HotkeyCombo` (computed over `UserDefaults`, with the hand-written observation hooks every other property on that class uses).
- Produces: `struct HotkeyRecorder: NSViewRepresentable` with `@Binding var combo: HotkeyCombo`.

Spec 7.4 puts the hotkey field on the General tab. Plan 2 left it out deliberately, because a field configuring a shortcut that did not exist would be worse than none; it exists now.

**`AppSettings`'s properties are computed over `UserDefaults` and the `@Observable` macro synthesises nothing for them** — every getter calls `access(keyPath:)` and every setter wraps in `withMutation(keyPath:_:)` by hand. Plan 2 Task 2 shipped this class notifying nothing until that was fixed. Match the existing shape exactly.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/AppSettingsTests.swift`:

```swift
@Test func theHotkeyDefaultsToOptionCommandTAndSurvivesARelaunch() {
    let defaults = freshDefaults()
    #expect(AppSettings(defaults: defaults).hotkey == HotkeyCombo.default)

    let custom = HotkeyCombo(keyCode: 0x23, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    AppSettings(defaults: defaults).hotkey = custom
    // A second instance over the same suite is what a relaunch looks like from here.
    #expect(AppSettings(defaults: defaults).hotkey == custom)
}

@Test func aCorruptStoredHotkeyFallsBackToTheDefaultRatherThanLeavingNoHotkeyAtAll() {
    // The value is JSON in a single key and the file is user-writable. A half-written or
    // hand-mangled value must not leave the app with nothing registered and no way to fix
    // it, since the settings pane is reachable from the menu but the hotkey is not.
    let defaults = freshDefaults()
    defaults.set(Data("{ not json".utf8), forKey: "hotkey")
    #expect(AppSettings(defaults: defaults).hotkey == HotkeyCombo.default)
}
```

Add `import TextCapture` and `import AppKit` to that file if they are not already there.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppSettingsTests`
Expected: FAIL — `value of type 'AppSettings' has no member 'hotkey'`.

- [ ] **Step 3: Add the property**

In `AppSettings.swift`, add `import TextCapture` and, alongside the other properties:

```swift
    /// Stored as JSON under one key rather than as a key code and a modifier mask under
    /// two. Two keys can be observed half-written — a settings pane that crashed between
    /// them would leave the app registering a combination the user never chose — and a
    /// single value cannot.
    ///
    /// An unreadable value falls back to the default instead of to "no hotkey". The
    /// settings pane is reachable from the menu bar, but the hotkey is the only way in to
    /// the panel, so leaving it unset would be an unrecoverable state reached by a typo in
    /// a plist.
    var hotkey: HotkeyCombo {
        get {
            access(keyPath: \.hotkey)
            guard let data = defaults.data(forKey: "hotkey"),
                  let decoded = try? JSONDecoder().decode(HotkeyCombo.self, from: data)
            else { return .default }
            return decoded
        }
        set {
            withMutation(keyPath: \.hotkey) {
                defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotkey")
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppSettingsTests` — PASS. Then `swift test` — 221 total, all green.

- [ ] **Step 5: Write the recorder control**

```swift
// Sources/TranslatorApp/HotkeyRecorder.swift
import SwiftUI
import AppKit
import TextCapture

/// A button that, once clicked, turns the next key press into a `HotkeyCombo`.
///
/// `NSViewRepresentable` rather than SwiftUI, because SwiftUI has no way to read a raw key
/// code: `onKeyPress` reports characters, and a character is layout-dependent while
/// `RegisterEventHotKey` wants the physical code.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var combo: HotkeyCombo

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = { combo = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) { view.combo = combo }

    final class RecorderView: NSView {
        var combo: HotkeyCombo = .default { didSet { needsDisplay = true } }
        var onRecord: ((HotkeyCombo) -> Void)?
        private var isRecording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

        override func mouseDown(with event: NSEvent) {
            isRecording = true
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { return super.keyDown(with: event) }
            if event.keyCode == 53 { isRecording = false; return }   // Esc abandons
            let candidate = HotkeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue)
            // Refused here as well as in `HotkeyManager`, so the user sees the recorder
            // stay open rather than watching a combination be accepted and then not work.
            guard candidate.isValid else { NSSound.beep(); return }
            combo = candidate
            isRecording = false
            onRecord?(candidate)
        }

        override func resignFirstResponder() -> Bool { isRecording = false; return true }

        override func draw(_ dirtyRect: NSRect) {
            let title = isRecording ? "Нажмите сочетание…" : combo.displayString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style,
            ]
            NSColor.controlBackgroundColor.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = title as NSString
            let height = text.size(withAttributes: attributes).height
            text.draw(in: bounds.insetBy(dx: 4, dy: (bounds.height - height) / 2), withAttributes: attributes)
        }
    }
}
```

- [ ] **Step 6: Put it on the General tab**

In `SettingsGeneralView.swift`, above the language pickers, add:

```swift
            LabeledContent("Сочетание клавиш") {
                HotkeyRecorder(combo: $settings.hotkey)
            }
            Text("Нажмите на поле и наберите новое сочетание. Нужен хотя бы один из "
                 + "модификаторов ⌃, ⌥ или ⌘ — иначе сочетание отняло бы обычную клавишу "
                 + "у всех остальных программ.")
                .font(.caption)
                .foregroundStyle(.secondary)
```

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslatorApp/AppSettings.swift Sources/TranslatorApp/HotkeyRecorder.swift \
        Sources/TranslatorApp/SettingsGeneralView.swift Tests/TranslatorAppTests/AppSettingsTests.swift
git commit -m "feat(app): configurable hotkey with a recorder control"
```

---

### Task 8: The floating panel window

**Files:**
- Create: `Sources/TranslatorApp/TranslationPanel.swift`
- Test: `Tests/TranslatorAppTests/TranslationPanelTests.swift`

**Interfaces:**
- Consumes: `PanelPlacement`.
- Produces: `@MainActor final class TranslationPanel: NSPanel` and `@MainActor final class PanelController { init(content: () -> AnyView); func show(at cursor: CGPoint); func hide(); var isVisible: Bool; var onEscape: () -> Void; var onEnter: () -> Void }`

Spec 7.2's `.nonactivatingPanel` is the load-bearing part: without it the panel activates this app, the source application drops out of the foreground, its menu bar is replaced and the user's flow is broken. `.nonactivatingPanel` lets the panel take *key* status — so Esc and Enter reach it — while the owning application stays inactive. Those two things are different and the distinction is the whole design.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslatorAppTests/TranslationPanelTests.swift
import Testing
import AppKit
import SwiftUI
@testable import TranslatorApp

@MainActor
@Test func thePanelIsNonActivatingAndFloating() {
    // The three properties spec 7.2 rests on. A panel missing `.nonactivatingPanel`
    // activates the app; one that is not floating disappears behind the source window; one
    // that hides on deactivate vanishes the moment it is shown, since this app is never
    // active when it appears.
    let panel = TranslationPanel()
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.level == .floating)
    #expect(panel.hidesOnDeactivate == false)
    #expect(panel.canBecomeKey)
}

@MainActor
@Test func showingThePanelDoesNotChangeWhichApplicationIsFrontmost() {
    // The claim spec 7.2 actually makes, checked rather than asserted. `frontmostApplication`
    // is readable from a test process, so this does not need a human.
    let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let controller = PanelController { AnyView(Text("перевод")) }
    controller.show(at: CGPoint(x: 300, y: 300))
    defer { controller.hide() }
    #expect(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == before)
    #expect(controller.isVisible)
}

@MainActor
@Test func hidingIsIdempotent() {
    let controller = PanelController { AnyView(Text("перевод")) }
    controller.show(at: CGPoint(x: 300, y: 300))
    controller.hide()
    #expect(controller.isVisible == false)
    controller.hide()
    #expect(controller.isVisible == false)
}

@MainActor
@Test func thePanelLandsOnTheScreenThatHoldsTheCursor() {
    guard let screen = NSScreen.main else { return }
    let controller = PanelController { AnyView(Text("перевод")) }
    let cursor = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
    controller.show(at: cursor)
    defer { controller.hide() }
    #expect(screen.visibleFrame.contains(controller.frameForTesting.origin))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TranslationPanelTests`
Expected: FAIL — `cannot find 'TranslationPanel' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslatorApp/TranslationPanel.swift
import AppKit
import SwiftUI

/// The floating result panel.
///
/// `.nonactivatingPanel` is not decoration. Without it, ordering this window in activates
/// the application: the source app leaves the foreground, the menu bar changes under the
/// user and whatever they were doing is interrupted — which is precisely the failure spec
/// 7.2 names. With it, the panel can still become *key* and so receive Esc and Enter, while
/// the owning application stays inactive. Key and active are different things, and this
/// window needs the first without the second.
@MainActor
final class TranslationPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // The app is never active when this appears, so a panel that hid on deactivation
        // would be dismissed by the very state it is shown in.
        hidesOnDeactivate = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        // Follows the user across desktops and sits over full-screen apps, because the
        // selection it is translating came from one.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// `NSPanel` returns false unless the style mask says otherwise, and without this the
    /// panel never receives a key event — so Esc and Enter would do nothing.
    override var canBecomeKey: Bool { true }
    /// Deliberately false. Main status belongs to the document window; a panel taking it
    /// would make the app behave as though it had been activated.
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    private let panel = TranslationPanel()
    private let hosting: NSHostingView<AnyView>

    var onEscape: () -> Void = {}
    var onEnter: () -> Void = {}

    var isVisible: Bool { panel.isVisible }
    /// The panel's frame, for the placement test. Not used by the app itself.
    var frameForTesting: CGRect { panel.frame }

    init(content: () -> AnyView) {
        hosting = NSHostingView(rootView: content())
        panel.contentView = hosting
        panel.delegate = nil
    }

    func setContent(_ view: AnyView) { hosting.rootView = view }

    func show(at cursor: CGPoint) {
        // The screen the pointer is on, not `NSScreen.main` — which is the screen with the
        // key window, i.e. usually the wrong one when the user is working in another app on
        // a second display.
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrame(PanelPlacement.frame(cursor: cursor, size: size, screen: visible), display: false)
        // `makeKeyAndOrderFront` on a `.nonactivatingPanel` gives the panel key status
        // without activating the app — checked by
        // `showingThePanelDoesNotChangeWhichApplicationIsFrontmost`.
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel.orderOut(nil) }

    func resize(to size: CGSize) {
        guard panel.isVisible else { return }
        var frame = panel.frame
        // Grows downwards from the top edge, so the panel does not appear to jump while
        // text streams into it.
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }
}
```

- [ ] **Step 4: Handle Esc and Enter**

Add to `TranslationPanel`:

```swift
    var onEscape: () -> Void = {}
    var onEnter: () -> Void = {}

    /// Spec 7.2: Esc closes and cancels, Enter copies and closes. Handled on the panel
    /// rather than in SwiftUI because the content has no focused control to receive them —
    /// the panel is a readout, not a form.
    override func cancelOperation(_ sender: Any?) { onEscape() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {   // Return, Enter
            onEnter()
            return
        }
        super.keyDown(with: event)
    }
```

and forward them in `PanelController.init`: `panel.onEscape = { [weak self] in self?.onEscape() }`, likewise for Enter.

- [ ] **Step 5: Run tests**

Run: `swift test --filter TranslationPanelTests` — PASS (4 tests). Then `swift test` — 223 total, all green.

If the suite is running headless and `NSScreen.screens` is empty, `thePanelLandsOnTheScreenThatHoldsTheCursor` returns early by design. Report whether it actually exercised anything on this machine rather than counting a skipped test as a pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/TranslationPanel.swift Tests/TranslatorAppTests/TranslationPanelTests.swift
git commit -m "feat(app): non-activating floating panel"
```

---

### Task 9: `PanelView`

**Files:**
- Create: `Sources/TranslatorApp/PanelView.swift`
- Modify: `Sources/TranslatorApp/RussianCopy.swift`
- Test: `Tests/TranslatorAppTests/RussianCopyTests.swift`

**Interfaces:**
- Consumes: `TranslationViewModel`, `WarningsView`, `SelectionResult`, `RussianCopy`.
- Produces: `struct PanelView: View` with `let model: TranslationViewModel`, `let selection: SelectionResult`, `var onCopy: () -> Void`, `var onOpenInWindow: () -> Void`, `var onRetry: () -> Void`, `var onGrantPermission: () -> Void`.
- Produces: `RussianCopy.direction(from:to:) -> String`.

Spec 7.2's contents: the detected direction, the streaming text, the glossary and markup warnings, and the two buttons. Plus the two states that are not a translation at all — nothing selected, and no permission.

The view itself is hand-checked. `RussianCopy.direction` is not, and it gets the test.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/RussianCopyTests.swift`:

```swift
@Test func theDirectionLineNamesBothLanguagesInRussian() {
    #expect(RussianCopy.direction(from: .en, to: .ru) == "английский → русский")
    #expect(RussianCopy.direction(from: nil, to: .ru) == "язык не определён → русский")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RussianCopyTests`
Expected: FAIL — `type 'RussianCopy' has no member 'direction'`.

- [ ] **Step 3: Add the copy**

In `RussianCopy.swift`:

```swift
    /// The panel's header line. An undetected source is stated rather than hidden — the
    /// direction rule sends undetected text to the primary language, and a user who sees a
    /// surprising target deserves to know the detector is why.
    static func direction(from source: Language?, to target: Language) -> String {
        let left = source.map(\.russianName) ?? "язык не определён"
        return "\(left) → \(target.russianName)"
    }
```

- [ ] **Step 4: Write the view**

```swift
// Sources/TranslatorApp/PanelView.swift
import SwiftUI
import TranslationCore
import TextCapture

struct PanelView: View {
    let model: TranslationViewModel
    let selection: SelectionResult
    var onCopy: () -> Void = {}
    var onOpenInWindow: () -> Void = {}
    var onRetry: () -> Void = {}
    var onGrantPermission: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch selection {
            case .notPermitted: permissionPrompt
            case .empty: emptyHint
            case .text: translation
            }
        }
        .padding(14)
        .frame(minWidth: 340, maxWidth: 520, alignment: .leading)
    }

    /// Spec 8's «нет разрешения Accessibility» row, shown at the moment the user pressed
    /// the key rather than at launch — which is when they are actually asking for it.
    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Нет доступа к тексту в других программах", systemImage: "lock")
                .font(.headline)
            Text("Чтобы переводить выделенное по сочетанию клавиш, приложению нужен доступ "
                 + "в разделе «Универсальный доступ». Главное окно работает и без него.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Открыть настройки системы", action: onGrantPermission)
        }
    }

    private var emptyHint: some View {
        Label("Выделите текст и нажмите сочетание ещё раз", systemImage: "text.cursor")
            .font(.callout).foregroundStyle(.secondary)
    }

    private var translation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let target = model.resolvedTarget {
                Text(RussianCopy.direction(from: model.outcome?.detectedSource, to: target))
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                Text(model.translatedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            statusLine

            if let outcome = model.outcome, model.state == .finished {
                ViewThatFits(in: .vertical) {
                    WarningsView(outcome: outcome, target: model.resolvedTarget)
                    ScrollView { WarningsView(outcome: outcome, target: model.resolvedTarget) }
                }
                .frame(maxHeight: 120)
            }

            HStack {
                Button("Скопировать", action: onCopy)
                    .disabled(model.translatedText.isEmpty)
                Button("Открыть в окне", action: onOpenInWindow)
                Spacer()
                if model.state == .running {
                    Button("Отмена") { model.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                }
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch model.state {
        case .idle: EmptyView()
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Перевожу…").font(.caption) }
        case .finished: EmptyView()
        case .interrupted:
            Text("Перевод прерван — показана та часть, что успела прийти")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            // Spec 8: a failure offers a retry rather than only an explanation.
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Повторить", action: onRetry).font(.caption)
            }
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test` — 224 total, all green. `swift build` — zero warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/PanelView.swift Sources/TranslatorApp/RussianCopy.swift \
        Tests/TranslatorAppTests/RussianCopyTests.swift
git commit -m "feat(app): panel content with direction, warnings and the permission prompt"
```

---

### Task 10: Wiring the hotkey path end to end

**Files:**
- Create: `Sources/TranslatorApp/HotkeyCoordinator.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift`
- Test: `Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift`

**Interfaces:**
- Consumes: `HotkeyManager`, `SelectionReader`, `PanelController`, `TranslationViewModel`, `AppSettings`, `PasteboardSnapshot`.
- Produces: `@Observable @MainActor final class HotkeyCoordinator { init(settings:glossary:translator:selectionReader:manager:); var selection: SelectionResult; var panelModel: TranslationViewModel; func start(); func handOffToWindow() -> (String, String); func handlePress() async }`

**The panel gets its own `TranslationViewModel`**, not the window's. A hotkey translation must not overwrite what the user has on screen in the main window, and the re-entrancy guard added in Plan 2 is per-instance — sharing one would make a hotkey press during a window translation silently do nothing.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift
import Testing
import Foundation
@testable import TranslatorApp
@testable import TranslationCore
@testable import TextCapture

@MainActor
private func makeCoordinator(_ selection: SelectionResult,
                             reply: String = "перевод") -> HotkeyCoordinator {
    let defaults = InMemoryDefaults()
    let glossary = GlossaryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("hk-\(UUID().uuidString).json"))
    try? glossary.load()
    return HotkeyCoordinator(
        settings: AppSettings(defaults: defaults),
        glossary: glossary,
        translator: Translator(client: ScriptedClient(responses: [reply])),
        selectionReader: SelectionReader(accessibility: {
            if case .text(let value) = selection { return value }
            return nil
        }, clipboard: { nil }, isTrusted: {
            if case .notPermitted = selection { return false }
            return true
        }))
}

@MainActor
@Test func aCapturedSelectionBecomesTheSourceAndIsTranslated() async {
    let coordinator = makeCoordinator(.text("Hello, world."), reply: "Привет, мир.")
    await coordinator.handlePress()
    #expect(coordinator.selection == .text("Hello, world."))
    #expect(coordinator.panelModel.sourceText == "Hello, world.")
    #expect(coordinator.panelModel.translatedText == "Привет, мир.")
    #expect(coordinator.panelModel.state == .finished)
}

@MainActor
@Test func anEmptySelectionShowsTheHintAndDoesNotCallTheModel() async {
    // A model call on an empty selection costs the user a two-second pause to be told
    // nothing was selected — which the panel can say instantly.
    let coordinator = makeCoordinator(.empty)
    await coordinator.handlePress()
    #expect(coordinator.selection == .empty)
    #expect(coordinator.panelModel.state == .idle)
    #expect(coordinator.panelModel.translatedText.isEmpty)
}

@MainActor
@Test func aMissingPermissionShowsTheOnboardingPromptAndDoesNotCallTheModel() async {
    let coordinator = makeCoordinator(.notPermitted)
    await coordinator.handlePress()
    #expect(coordinator.selection == .notPermitted)
    #expect(coordinator.panelModel.state == .idle)
}

@MainActor
@Test func aSecondPressWhileTranslatingIsIgnoredRatherThanInterleaved() async {
    // `TranslationViewModel.translate()` already guards this, but the coordinator also
    // reassigns `sourceText` — which would swap the source out from under a running
    // translation and leave the panel showing one text's translation above another's.
    let coordinator = makeCoordinator(.text("Первый"), reply: "Один")
    await coordinator.handlePress()
    let first = coordinator.panelModel.translatedText
    await coordinator.handlePress()
    #expect(coordinator.panelModel.translatedText == first)
}

@MainActor
@Test func handingOffToTheWindowCarriesBothTexts() async {
    let coordinator = makeCoordinator(.text("Hello."), reply: "Привет.")
    await coordinator.handlePress()
    let (source, translated) = coordinator.handOffToWindow()
    #expect(source == "Hello.")
    #expect(translated == "Привет.")
}
```

Reuse `ScriptedClient` and `InMemoryDefaults` from the existing test files by making them non-private where they currently are.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HotkeyCoordinatorTests`
Expected: FAIL — `cannot find 'HotkeyCoordinator' in scope`.

- [ ] **Step 3: Write the coordinator**

```swift
// Sources/TranslatorApp/HotkeyCoordinator.swift
import Foundation
import Observation
import AppKit
import TranslationCore
import TextCapture

@Observable
@MainActor
final class HotkeyCoordinator {
    private let settings: AppSettings
    private let selectionReader: SelectionReader
    private let manager: HotkeyManager

    /// The panel's own view model, deliberately not the window's. A hotkey translation must
    /// not overwrite what the user has on screen in the window — and Plan 2's re-entrancy
    /// guard is per-instance, so sharing one would make a hotkey press during a window
    /// translation silently do nothing at all.
    let panelModel: TranslationViewModel
    private(set) var selection: SelectionResult = .empty

    init(settings: AppSettings,
         glossary: GlossaryStore,
         translator: Translator,
         selectionReader: SelectionReader = SelectionReader(),
         manager: HotkeyManager = HotkeyManager()) {
        self.settings = settings
        self.selectionReader = selectionReader
        self.manager = manager
        self.panelModel = TranslationViewModel(translator: translator,
                                               settings: settings, glossary: glossary)
    }

    /// Registers, and re-registers whenever the setting changes. Returns false when the
    /// stored combination is refused, which the caller surfaces rather than swallows.
    @discardableResult
    func start(onPress: @escaping @MainActor () -> Void) -> Bool {
        manager.register(settings.hotkey, onPress: onPress)
    }

    func stop() { manager.unregister() }

    /// Read the selection, then translate it. Everything the panel shows is decided here so
    /// the view stays a readout.
    func handlePress() async {
        // A press arriving mid-translation is dropped rather than queued. Reassigning
        // `sourceText` under a running translation would leave the panel showing one text's
        // output above another text's source.
        guard panelModel.state != .running else { return }
        selection = selectionReader.read()
        guard case .text(let captured) = selection else { return }
        panelModel.sourceText = captured
        await panelModel.translate()
        if settings.autoCopy, panelModel.state == .finished { copyResult() }
    }

    func retry() async {
        guard case .text = selection else { return }
        await panelModel.translate()
    }

    func copyResult() {
        guard !panelModel.translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(panelModel.translatedText, forType: .string)
    }

    func handOffToWindow() -> (source: String, translated: String) {
        (panelModel.sourceText, panelModel.translatedText)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HotkeyCoordinatorTests` — PASS (5 tests). Then `swift test` — 229 total, all green.

- [ ] **Step 5: Wire it into the app**

In `TranslatorApp.swift`: build the coordinator in `init()` with its own `Translator(client: client)`, hold a `PanelController` as `@State`, and on the `MenuBarExtra` label's existing `.task` — after `warmUp()` — call `coordinator.start`, whose `onPress` closure shows the panel at `NSEvent.mouseLocation`, then awaits `handlePress()`. Wire `onEscape` to `panelModel.cancel()` plus `hide()`, and `onEnter` to `copyResult()` plus `hide()`. «Открыть в окне» calls `handOffToWindow()`, writes both strings into the window's model, calls `openWindow(id:)` and `NSApp.activate`.

Re-register when the setting changes: the coordinator reads `settings.hotkey` inside `start`, so an `onChange`-equivalent is needed — call `start` again from the same `.task` using an `Observations`-style loop or a simple comparison on each panel show. State which you chose and why.

- [ ] **Step 6: Check by hand — this is the first end-to-end run**

Build and launch: `./Scripts/make-app-bundle.sh && open build/LocalTranslator.app`. Grant Accessibility when asked. Then, in order:

1. Select text in TextEdit, press ⌥⌘T. Record whether the panel appeared, whether TextEdit stayed frontmost, and how long until the first character.
2. Repeat in a browser and in an Electron app — this is where the Accessibility attribute is expected to fail and the clipboard fallback to take over.
3. **Copy something distinctive first, then use the hotkey, then paste.** The clipboard must contain what you copied, not the selection. This is the check spec 6 demands and the one that silently destroys user data when it is wrong.
4. Press Esc mid-translation, then Enter on a finished one.
5. Press the hotkey with nothing selected.

Report exactly what you observed, and mark anything you could not reach. **Do not describe UI you did not see.**

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslatorApp/HotkeyCoordinator.swift Sources/TranslatorApp/TranslatorApp.swift \
        Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift
git commit -m "feat(app): hotkey to panel to translation, end to end"
```

---

### Task 11: Retry in the main window

**Files:**
- Modify: `Sources/TranslatorApp/MainWindowView.swift`

Spec 8 gives «Повторить» to two rows — a timed-out request and an empty model reply. Plan 2 built the states but not the button; Task 9 added it to the panel, and this closes the same gap in the window. Nothing else in this plan touches the window, so it is its own task and its own commit.

- [ ] **Step 1: Add the button**

In `MainWindowView.swift`'s `statusLine`, replace the `.failed` case with:

```swift
        case .failed(let message):
            // Spec 8 pairs both failure rows with a retry. The state carries the reason;
            // the source text is still in the editor, so retrying costs the user nothing.
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Повторить") { Task { await model.translate() } }
                    .font(.caption)
            }
```

- [ ] **Step 2: Confirm the retry is actually reachable**

`translate()` opens with `guard state != .running`, and `.failed` is not `.running`, so the guard passes. Confirm that by reading `TranslationViewModel.translate()` rather than assuming, and say so in the report — the same guard would silently make this button inert if it had been written against a different state.

- [ ] **Step 3: Run tests**

Run: `swift test` — 229 total, all green. `swift build` — zero warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/TranslatorApp/MainWindowView.swift
git commit -m "feat(app): retry button on a failed window translation"
```

---

### Task 12: Onboarding at first launch, and the full manual pass

**Files:**
- Modify: `Sources/TranslatorApp/TranslatorApp.swift`
- Modify: `Sources/TranslatorApp/SettingsGeneralView.swift`
- Modify: `docs/superpowers/specs/2026-07-24-local-translator-design.md`

Spec 6.1 asks for an onboarding screen at first launch when the permission is missing. Task 9 already shows the prompt at the moment of use, which is the more useful half; this adds the standing indicator so a user who has not pressed the key yet is not left to discover it.

- [ ] **Step 1: Add a standing permission indicator to the General tab**

Above the hotkey row:

```swift
            if !PermissionsGate.isTrusted() {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Сочетание клавиш не сможет прочитать выделенный текст",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("Приложению нужен доступ в разделе «Универсальный доступ». "
                         + "Главное окно работает и без него.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Открыть настройки системы") { PermissionsGate.openSettings() }
                }
            }
```

Note in a comment that `isTrusted()` is read during `body` evaluation and is not observable, so the row updates when the pane is reopened rather than the instant the grant changes. That is honest and adequate — say so rather than pretending otherwise.

- [ ] **Step 2: Prompt once at first launch**

In the `MenuBarExtra` label's `.task`, before `warmUp()`:

```swift
        // Prompted once, at first launch only. `requestTrust()` shows the system dialog;
        // asking again on every launch would be nagging, and the standing indicator in
        // Settings plus the panel's own prompt already cover the user who declined.
        if !settings.hasRequestedAccessibility {
            settings.hasRequestedAccessibility = true
            PermissionsGate.requestTrust()
        }
```

Add `hasRequestedAccessibility: Bool` to `AppSettings` in the same computed-property shape as every other property there, defaulting to `false`.

- [ ] **Step 3: Correct the spec**

Section 6.1 says «Без разрешения хоткей не работает». That is the user-visible outcome but not the mechanism, and the difference is what the panel's prompt is built on. Replace that sentence with:

```
Без разрешения перевод по сочетанию клавиш не выполняется: само сочетание регистрируется
через Carbon и срабатывает даже без доступа, но оба пути захвата текста без него молчат.
Приложение пользуется этим — вместо тишины оно показывает во всплывающей панели объяснение
и кнопку в системные настройки ровно в тот момент, когда пользователь попытался
воспользоваться хоткеем. Главное окно при этом остаётся полностью функциональным.
```

- [ ] **Step 4: Full manual pass**

`./Scripts/make-app-bundle.sh && open build/LocalTranslator.app`, then:

1. **Revoke** the Accessibility grant, relaunch, press the hotkey. The panel must show the permission prompt, and the button must open the right pane.
2. Grant it, relaunch, press the hotkey on a selection. It must translate.
3. Change the hotkey in Settings, press the new one, then press the old one. Only the new one may work.
4. Try to record a bare key with no modifier. It must be refused.
5. Rebuild the bundle and press the hotkey again — record whether the grant survived. This is the ad-hoc-signing question from the top of the plan, and the answer belongs in the report.
6. Walk every settings tab once more and confirm nothing from Plan 2 regressed.

Report exactly what you observed and what you could not reach.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp docs/superpowers/specs/2026-07-24-local-translator-design.md
git commit -m "feat(app): first-launch permission prompt and standing indicator"
```

---

## Self-Review

**Spec coverage** (section → task):

- **6 capture, both mechanisms and their order** → Tasks 4, 5. The clipboard save/restore spec calls «обязательно» is Task 4's whole subject, with the empty-clipboard case pinned separately because that is where the plausible-looking implementation leaks the selection. ✅
- **6.1 permissions** → Tasks 1, 9, 12. Prompted once at first launch, shown standing in Settings, and shown again at the moment of use — the last being the one the user actually reads. ✅
- **6.2 hotkey and direction** → Tasks 2, 3, 7. The direction rule itself already ships in `AppSettings.targetLanguage(forDetected:)` from Plan 2 and is reused unchanged. ✅
- **7.1 menu bar** → unchanged from Plan 2. The `MenuBarExtra` label's `.task` gains the hotkey registration alongside the warm-up it already carries. ✅
- **7.2 floating panel** → Tasks 6, 8, 9. `.nonactivatingPanel`, cursor-relative placement, streaming text, warnings, both buttons, Esc and Enter, autoCopy. ✅
- **7.4 settings, the hotkey field** → Task 7. This is the field Plan 2 deliberately left out. ✅
- **8 error handling** → «нет разрешения» Tasks 9 and 12; «пустое выделение» Tasks 5 and 9; «повторить» Tasks 9 and 11, which also closes the gap Plan 2 left. The other four rows already ship. ✅
- **9 storage** → the hotkey joins the `UserDefaults` scalars. No new file, no history. ✅

**Gaps found and resolved:** Plan 2's self-review claimed spec 8's timeout row was covered by `TranslationViewModel`'s `.failed` state, but the «Повторить» button spec 8 names was never built — Task 11 adds it to the window and Task 9 to the panel. The spec's own claim that the hotkey does not work without permission turned out to be true of the outcome and false of the mechanism; Task 12 corrects it, and the correction is what Task 9's prompt is built on.

**Placeholder scan:** no TBD or TODO. Every code step carries real code. Task 10 Step 5 describes wiring rather than pasting a full rewritten `TranslatorApp.swift`, deliberately: that file is 150 lines of load-bearing comments from Plan 2 that must not be clobbered, and naming the edits is safer than reprinting the file. Task 10 Step 6 and Task 12 Step 4 are hand-checks with no code by nature.

**Type consistency:** `HotkeyCombo` is produced in Task 2 and consumed by name in Tasks 3, 7 and 10. `SelectionResult`'s three cases are produced in Task 5 and switched over in Tasks 9 and 10 — exhaustively, no `default:`. `PermissionsGate.isTrusted` is injected into `SelectionReader` in Task 5 and called directly in Tasks 9 and 12. `PanelPlacement.frame` is produced in Task 6 and called once, in Task 8. `TranslationViewModel`'s existing surface — `sourceText`, `translatedText`, `state`, `outcome`, `resolvedTarget`, `translate()`, `cancel()` — is used as Plan 2 left it, with no changes. `WarningsView(outcome:target:)` is called in Task 9 with the two arguments it already has; `problem:` and `onMute:` are omitted because muting belongs to the window, where the user can see the glossary. ✅

**Compiled before shipping.** The three pieces of this plan that could plausibly not compile
or not run were built and executed standalone rather than reasoned about:

- `HotkeyCombo` in full, including the `UCKeyTranslate` layout lookup. It printed `⌥⌘T`,
  `carbonModifiers == 2304` (`cmdKey | optionKey`), `⌘Пробел`, `⌃⌥⇧⌘T`, and refused a bare
  key — the exact values Task 2's tests assert. **This is where a real defect was found and
  fixed:** the first draft used `case kVK_F1...kVK_F12`, which traps at run time because
  those codes descend rather than ascend. The plan now lists them.
- `HotkeyManager`'s C-callback bridge, which is the syntactically riskiest thing here —
  `InstallEventHandler` with a non-capturing closure, `Unmanaged` round trip and
  `MainActor.assumeIsolated`. It registered, replaced, unregistered twice without trapping,
  and refused an invalid combination. It also **registered successfully from a plain CLI
  binary with no Accessibility grant**, which is the independent confirmation of the claim
  at the top of this plan that the hotkey needs no permission.
- Two syntax risks in the test code: a trailing closure followed by `== false` inside a
  `#expect(...)` argument, and `nonisolated(unsafe)` on a *local* variable captured by a
  `@Sendable` closure. Both compile.

`PanelPlacement`'s five asserted frames were worked through by hand against the
implementation, including the second-display case at a negative origin and the panel taller
than its screen. They agree.

**Testability honesty:** the pure logic — `HotkeyCombo`, `PasteboardSnapshot`, `SelectionReader`'s ordering, `PanelPlacement`, `HotkeyCoordinator` — carries real tests, roughly 37 of them. Four things cannot be tested here and every one is named in the task that ships it: that pressing the key calls `onPress` (no run loop in a test process), that `accessibilityText()` reads a real selection (no other app's focused element), that `clipboardText()`'s synthetic ⌘C lands anywhere (no window server), and every pixel of every view. Task 8 does check the one claim about the panel that *is* machine-checkable — that showing it leaves `frontmostApplication` unchanged — because that is spec 7.2's actual requirement rather than an appearance.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-27-hotkey-path.md`. Two execution options:

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration. This is how Plans 1 and 2 were built, and on this project the reviews have consistently found defects that the per-task tests did not.

**2. Inline Execution** — executed in this session with checkpoints for review.

Which approach?
