// Sources/TranslatorApp/AppSettings.swift
import Foundation
import Observation
import TranslationCore
import TextCapture

@Observable
final class AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func string(_ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }
    private func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }
    private func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? fallback
    }
    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    // Every property below reads and writes `UserDefaults` directly rather than
    // caching into a stored property, so a value changed outside the app (another
    // process, `defaults write`) is picked up on the next read without a reload.
    // Because none of these are stored properties, `@Observable`'s synthesized
    // change tracking doesn't wire itself up automatically — each getter/setter
    // calls `access(keyPath:)` / `withMutation(keyPath:_:)` by hand so SwiftUI still
    // notices a change.

    var primaryLanguage: Language {
        get {
            access(keyPath: \.primaryLanguage)
            return Language(rawValue: string("primaryLanguage", "ru")) ?? .ru
        }
        set { withMutation(keyPath: \.primaryLanguage) { defaults.set(newValue.rawValue, forKey: "primaryLanguage") } }
    }
    var workingLanguage: Language {
        get {
            access(keyPath: \.workingLanguage)
            return Language(rawValue: string("workingLanguage", "en")) ?? .en
        }
        set { withMutation(keyPath: \.workingLanguage) { defaults.set(newValue.rawValue, forKey: "workingLanguage") } }
    }
    var defaultTone: Tone {
        get {
            access(keyPath: \.defaultTone)
            return Tone(rawValue: string("defaultTone", "neutral")) ?? .neutral
        }
        set { withMutation(keyPath: \.defaultTone) { defaults.set(newValue.rawValue, forKey: "defaultTone") } }
    }
    var interactiveModel: String {
        get {
            access(keyPath: \.interactiveModel)
            return string("interactiveModel", ModelPolicy.defaultModel(for: .interactive))
        }
        set { withMutation(keyPath: \.interactiveModel) { defaults.set(newValue, forKey: "interactiveModel") } }
    }
    // `backgroundModel` used to live here. It was written by a settings picker and read by
    // nothing — both surfaces build `ChatOptions` from `interactiveModel` — so it was removed
    // along with its control rather than left as a setting that does nothing.
    //
    // `ModelRole.background` and `ModelPolicy.defaultModel(for: .background)` are deliberately
    // kept: the two-path model policy is a design decision recorded in §5 of the spec, and the
    // background path is batch translation in v2. This property comes back when something
    // reads it.
    //
    // Any value a user already stored stays in `UserDefaults` under `"backgroundModel"`,
    // untouched. Nothing reads it, and v2 would find it again.
    var keepAlive: String {
        get {
            access(keyPath: \.keepAlive)
            return string("keepAlive", "30m")
        }
        set { withMutation(keyPath: \.keepAlive) { defaults.set(newValue, forKey: "keepAlive") } }
    }
    var chunkSize: Int {
        get {
            access(keyPath: \.chunkSize)
            return int("chunkSize", 900)
        }
        set { withMutation(keyPath: \.chunkSize) { defaults.set(newValue, forKey: "chunkSize") } }
    }
    var temperature: Double {
        get {
            access(keyPath: \.temperature)
            return double("temperature", 0.2)
        }
        set { withMutation(keyPath: \.temperature) { defaults.set(newValue, forKey: "temperature") } }
    }
    var autoCopy: Bool {
        get {
            access(keyPath: \.autoCopy)
            return bool("autoCopy", false)
        }
        set { withMutation(keyPath: \.autoCopy) { defaults.set(newValue, forKey: "autoCopy") } }
    }
    var warmUpOnLaunch: Bool {
        get {
            access(keyPath: \.warmUpOnLaunch)
            return bool("warmUpOnLaunch", true)
        }
        set { withMutation(keyPath: \.warmUpOnLaunch) { defaults.set(newValue, forKey: "warmUpOnLaunch") } }
    }

    /// Whether the system's Accessibility dialog has ever been raised by this app.
    ///
    /// Not «whether the permission is granted» — that is `PermissionsGate.isTrusted()` and it
    /// is the system's answer, not a preference. This records only that the app has asked
    /// once, so a user who declined is not asked again on every launch. It is deliberately
    /// not exposed in any settings pane: it is a latch, not a choice, and the two visible
    /// ways back to the permission (the panel's prompt and the General tab's indicator) are
    /// what a user who changes their mind uses.
    var hasRequestedAccessibility: Bool {
        get {
            access(keyPath: \.hasRequestedAccessibility)
            return bool("hasRequestedAccessibility", false)
        }
        set {
            withMutation(keyPath: \.hasRequestedAccessibility) {
                defaults.set(newValue, forKey: "hasRequestedAccessibility")
            }
        }
    }

    /// Stored as JSON under one key rather than as a key code and a modifier mask under
    /// two. Two keys can be observed half-written — a settings pane that crashed between
    /// them would leave the app registering a combination the user never chose — and a
    /// single value cannot.
    ///
    /// An unreadable value falls back to the default instead of to "no hotkey". The
    /// settings pane is reachable from the menu bar, but the hotkey is the only way in to
    /// the panel, so leaving it unset would be an unrecoverable state reached by a typo in
    /// a plist.
    ///
    /// `isValid` is checked on the way out for the same reason and not only on the way in.
    /// Undecodable bytes are the obvious corruption; a value that decodes cleanly and is
    /// still unusable is the quieter one. `{"keyCode":17,"modifiers":0}` is well-formed
    /// JSON and a well-formed `HotkeyCombo`, and it is a bare «T». The recorder refuses
    /// those, but the recorder is not the only writer — the reasoning above is about a
    /// user-writable plist, and a plist can hold this just as easily as it can hold
    /// garbage. `HotkeyManager.register` would refuse it and the app would end up with no
    /// hotkey at all: the same unrecoverable state, reached through the door left open
    /// next to the one that was closed.
    var hotkey: HotkeyCombo {
        get {
            access(keyPath: \.hotkey)
            guard let data = defaults.data(forKey: "hotkey"),
                  let decoded = try? JSONDecoder().decode(HotkeyCombo.self, from: data),
                  decoded.isValid
            else { return .default }
            return decoded
        }
        set {
            withMutation(keyPath: \.hotkey) {
                defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotkey")
            }
        }
    }

    /// Spec 6.2: if the detected source is the primary language, translate into the
    /// working one; otherwise into the primary one. An undetected source is not the
    /// primary language, so it also goes to the primary one — the common case of
    /// pasting foreign text.
    func targetLanguage(forDetected detected: Language?) -> Language {
        detected == primaryLanguage ? workingLanguage : primaryLanguage
    }
}
