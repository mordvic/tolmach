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

    var primaryLanguage: Language {
        get { Language(rawValue: string("primaryLanguage", "ru")) ?? .ru }
        set { defaults.set(newValue.rawValue, forKey: "primaryLanguage") }
    }
    var workingLanguage: Language {
        get { Language(rawValue: string("workingLanguage", "en")) ?? .en }
        set { defaults.set(newValue.rawValue, forKey: "workingLanguage") }
    }
    var defaultTone: Tone {
        get { Tone(rawValue: string("defaultTone", "neutral")) ?? .neutral }
        set { defaults.set(newValue.rawValue, forKey: "defaultTone") }
    }
    var interactiveModel: String {
        get { string("interactiveModel", ModelPolicy.defaultModel(for: .interactive)) }
        set { defaults.set(newValue, forKey: "interactiveModel") }
    }
    var backgroundModel: String {
        get { string("backgroundModel", ModelPolicy.defaultModel(for: .background)) }
        set { defaults.set(newValue, forKey: "backgroundModel") }
    }
    var keepAlive: String {
        get { string("keepAlive", "30m") }
        set { defaults.set(newValue, forKey: "keepAlive") }
    }
    var chunkSize: Int {
        get { int("chunkSize", 900) }
        set { defaults.set(newValue, forKey: "chunkSize") }
    }
    var temperature: Double {
        get { double("temperature", 0.2) }
        set { defaults.set(newValue, forKey: "temperature") }
    }
    var autoCopy: Bool {
        get { bool("autoCopy", false) }
        set { defaults.set(newValue, forKey: "autoCopy") }
    }
    var warmUpOnLaunch: Bool {
        get { bool("warmUpOnLaunch", true) }
        set { defaults.set(newValue, forKey: "warmUpOnLaunch") }
    }

    /// Spec 6.2: if the detected source is the primary language, translate into the
    /// working one; otherwise into the primary one. An undetected source is not the
    /// primary language, so it also goes to the primary one — the common case of
    /// pasting foreign text.
    func targetLanguage(forDetected detected: Language?) -> Language {
        detected == primaryLanguage ? workingLanguage : primaryLanguage
    }
}
