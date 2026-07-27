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
