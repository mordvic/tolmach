// Sources/TranslatorApp/AppSettings.swift
import Foundation
import Observation
import TranslationCore

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
    var backgroundModel: String {
        get {
            access(keyPath: \.backgroundModel)
            return string("backgroundModel", ModelPolicy.defaultModel(for: .background))
        }
        set { withMutation(keyPath: \.backgroundModel) { defaults.set(newValue, forKey: "backgroundModel") } }
    }
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

    /// Spec 6.2: if the detected source is the primary language, translate into the
    /// working one; otherwise into the primary one. An undetected source is not the
    /// primary language, so it also goes to the primary one — the common case of
    /// pasting foreign text.
    func targetLanguage(forDetected detected: Language?) -> Language {
        detected == primaryLanguage ? workingLanguage : primaryLanguage
    }
}
