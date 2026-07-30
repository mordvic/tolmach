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
    ///
    /// `@Sendable` on the declaration because `SelectionReader.init` defaults a
    /// `@Sendable () -> Bool` parameter to this function *as a value*, and a reference to a
    /// plain `static func` is not a Sendable function value — the conversion warns in Swift 5
    /// mode and is an error in Swift 6. `requestTrust` is deliberately left alone: nothing
    /// passes it around as a value, and it is the one call here with a user-visible side
    /// effect. `AXIsProcessTrustedWithOptions` is thread-agnostic, so the attribute is true.
    @Sendable public static func isTrusted() -> Bool {
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
