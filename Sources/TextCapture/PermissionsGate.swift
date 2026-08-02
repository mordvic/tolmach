import Foundation
// `@preconcurrency` because HIServices predates concurrency annotation and imports
// `kAXTrustedCheckOptionPrompt` as a mutable global (`var`). Reading a mutable global from a
// `nonisolated` function is «reference to var … is not concurrency-safe», an error in the
// Swift 6 language mode — measured as one of the four that stopped a `-swift-version 6`
// build of this target.
//
// This spelling rather than a hand-rolled escape, and the alternatives were measured rather
// than dismissed. `nonisolated(unsafe)` on a `static let` holding the value does **not**
// work: the annotation covers the storage, while the diagnostic is about the *read* in the
// initialiser, so the error simply moves there — and the compiler then also warns that the
// annotation is pointless on a `Sendable` `String`. The same is true of a
// `nonisolated(unsafe)` local inside the initialiser and of an `@concurrent` accessor: all
// three still fail, checked by typechecking each at `-swift-version 6 -target
// arm64-apple-macosx14.0`. What is left is either this or hardcoding
// `"AXTrustedCheckOptionPrompt"`, and a literal would drop the only compiler-checked link to
// the framework's own symbol.
//
// It is narrower than it looks: `@preconcurrency` downgrades `Sendable`-related diagnostics
// from this one module and nothing else. `AXIsProcessTrustedWithOptions` and the `kAX…`
// attribute constants keep working unchanged.
@preconcurrency import ApplicationServices
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
