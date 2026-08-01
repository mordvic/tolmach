import Testing
import Foundation
// `kAXTrustedCheckOptionPrompt` below is a C constant from HIServices. `@testable import`
// does not re-export a module's own imports, so the test needs this in its own right —
// and, for the same reason `PermissionsGate` itself carries it, with `@preconcurrency`:
// the constant is imported as a mutable global, which the Swift 6 language mode refuses to
// read. `@testable import` does not re-export that attribute either.
@preconcurrency import ApplicationServices
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
