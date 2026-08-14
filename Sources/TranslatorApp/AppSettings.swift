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
    /// An empty string is treated as absent, so a value cleared through `defaults write`
    /// reads the same as one that was never set.
    private func optionalString(_ key: String) -> String? {
        guard let value = defaults.string(forKey: key), !value.isEmpty else { return nil }
        return value
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
    var defaultProofreadingLevel: ProofreadingLevel {
        get {
            access(keyPath: \.defaultProofreadingLevel)
            return ProofreadingLevel(rawValue: string("proofreadingLevel", "errorsOnly")) ?? .errorsOnly
        }
        set {
            withMutation(keyPath: \.defaultProofreadingLevel) {
                defaults.set(newValue.rawValue, forKey: "proofreadingLevel")
            }
        }
    }
    var defaultRewriteStyle: RewriteStyle {
        get {
            access(keyPath: \.defaultRewriteStyle)
            return RewriteStyle(rawValue: string("rewriteStyle", "original")) ?? .original
        }
        set {
            withMutation(keyPath: \.defaultRewriteStyle) {
                defaults.set(newValue.rawValue, forKey: "rewriteStyle")
            }
        }
    }
    var interactiveModel: String {
        get {
            access(keyPath: \.interactiveModel)
            return string("interactiveModel", ModelPolicy.defaultModel(for: .interactive))
        }
        set { withMutation(keyPath: \.interactiveModel) { defaults.set(newValue, forKey: "interactiveModel") } }
    }
    /// The model the file queue uses, or `nil` for «the same one the hotkey uses».
    ///
    /// **The only setting in this app with no fixed default, and that is deliberate.**
    /// Ollama holds one model in memory: cold load ~2000 ms against ~155 ms warm
    /// (measured, recorded in CLAUDE.md alongside `keep_alive`). If this defaulted to
    /// anything but the interactive model, then every ⌥⌘T pressed during a queue run
    /// would cost two cold loads — one to serve the panel, one to get back to the queue
    /// — and a thirteen-file queue makes that the normal case rather than the edge. A
    /// different default would build that thrash into the box for a user who never
    /// opened the settings.
    ///
    /// `ModelPolicy.defaultModel(for: .background)` is still not consulted. It is a
    /// recommendation to a user who opens the picker, not a default that changes what
    /// the app does before anyone asks for it. `ModelRole.background` stays as policy.
    ///
    /// Stored under `"backgroundModel"` — the key the property removed with the
    /// observability wave wrote to. Its removal comment promised exactly this, and a
    /// value a user stored before that removal comes back here.
    var batchModel: String? {
        get {
            access(keyPath: \.batchModel)
            return optionalString("backgroundModel")
        }
        set {
            withMutation(keyPath: \.batchModel) {
                // `set(nil,)` and not `removeObject(forKey:)`, and the difference is not
                // stylistic. `InMemoryDefaults` — the only defaults these tests are
                // allowed to touch — overrides exactly three methods: `object`, `set` and
                // `string`. `removeObject` would fall through to the superclass and empty
                // the throwaway backing suite while the in-memory dictionary kept the
                // value, so clearing this setting would appear to do nothing under test
                // and work in production. Assigning `nil` through the overridden `set`
                // removes the key from that dictionary — the same effect through the door
                // that is open.
                let stored = (newValue?.isEmpty == false) ? newValue : nil
                defaults.set(stored, forKey: "backgroundModel")
            }
        }
    }

    /// What to actually put in `ChatOptions` for a queue run.
    ///
    /// A derived property rather than a `??` at the call site: there is more than one
    /// call site (the runner and the settings picker's «current» state), and the rule
    /// that `nil` means «follow the interactive model» is the whole point of the
    /// property above.
    var resolvedBatchModel: String { batchModel ?? interactiveModel }

    /// Whether the app asks a model not to reason.
    ///
    /// **On by default, which is a change in what the app does and is meant to be.** Ollama
    /// turns reasoning on by default for a capable model and `OllamaStreamParser` discards
    /// `message.thinking` by standing rule, so before this setting existed the app paid for a
    /// trace it threw away: measured 2026-08-11, `qwen3:8b` produced 2621 characters of it
    /// before the first character of translation. Which models may actually be told, and how,
    /// is `ModelPolicy.thinkRequest(for:quiet:level:)`.
    var quietThinking: Bool {
        get {
            access(keyPath: \.quietThinking)
            return bool("quietThinking", true)
        }
        set { withMutation(keyPath: \.quietThinking) { defaults.set(newValue, forKey: "quietThinking") } }
    }

    /// How much reasoning `gpt-oss` is allowed, for the one family that cannot be switched off.
    ///
    /// Defaults to `.low` rather than to the model's own default for the same reason
    /// `quietThinking` defaults to on: measured 15 characters of trace at 0.49 s to first token
    /// against 478 characters when nothing is sent.
    var gptOssThinkingLevel: ThinkRequest.Level {
        get {
            access(keyPath: \.gptOssThinkingLevel)
            return ThinkRequest.Level(rawValue: string("gptOssThinkingLevel", "low")) ?? .low
        }
        set {
            withMutation(keyPath: \.gptOssThinkingLevel) {
                defaults.set(newValue.rawValue, forKey: "gptOssThinkingLevel")
            }
        }
    }

    /// Whether either path would run a `gpt-oss` model — i.e. whether the depth control has
    /// anything to govern.
    ///
    /// A derived property rather than a comparison written in the pane, for
    /// `batchModelDiffersFromInteractive`'s stated reason: a view that restated the prefix rule
    /// would go on drawing the row after the rule changed.
    var usesGptOss: Bool {
        ModelPolicy.thinkingLevelsOnly.contains {
            interactiveModel.hasPrefix($0) || resolvedBatchModel.hasPrefix($0)
        }
    }

    /// Whether the queue and the hotkey would use two different models — i.e. whether a
    /// hotkey press during a queue run costs a model swap in Ollama's memory.
    ///
    /// A property rather than a comparison written in the settings pane, for
    /// `canSwapLanguages`' reason: the caption has to answer before it is drawn, and a
    /// view that restated the comparison would go on reassuring the user after the rule
    /// changed.
    var batchModelDiffersFromInteractive: Bool { resolvedBatchModel != interactiveModel }

    /// Whether a finished translation is written beside its source without being asked.
    ///
    /// On by default: a queue whose results have to be saved one at a time is a queue
    /// that has not finished the job. What it cannot assume is that the write will be
    /// allowed — see `TranslatedFileWriter` and its save-panel fallback.
    var saveNextToSource: Bool {
        get {
            access(keyPath: \.saveNextToSource)
            return bool("saveNextToSource", true)
        }
        set { withMutation(keyPath: \.saveNextToSource) { defaults.set(newValue, forKey: "saveNextToSource") } }
    }

    /// Whether the queue halts after a file that finished with warnings.
    ///
    /// Off by default: the warnings are kept per file and can be read afterwards, so the
    /// default is «the queue finishes» rather than «the queue waits for you».
    var stopOnWarnings: Bool {
        get {
            access(keyPath: \.stopOnWarnings)
            return bool("stopOnWarnings", false)
        }
        set { withMutation(keyPath: \.stopOnWarnings) { defaults.set(newValue, forKey: "stopOnWarnings") } }
    }

    /// Whether the документный глоссарий is shown for review before the translation that
    /// uses it.
    ///
    /// **Ships off, although the design document draws it on.** The drawing put this
    /// switch in the batch settings and reasoned about a file; the gate reaches every
    /// path that builds a документный глоссарий, ⌥⌘T included, and a default that
    /// changes the flagship interaction for every existing user is not one a mock can
    /// grant.
    ///
    /// Read by `TranslationViewModel.translate` and `FileQueueModel.translate` — which pass
    /// the engine a review hook only when it is on — and by the pane that draws it.
    var reviewDocumentTerms: Bool {
        get {
            access(keyPath: \.reviewDocumentTerms)
            return bool("reviewDocumentTerms", false)
        }
        set { withMutation(keyPath: \.reviewDocumentTerms) { defaults.set(newValue, forKey: "reviewDocumentTerms") } }
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
                // Encoding two integers cannot realistically fail, and if it ever did the
                // `try?` would store `nil` — which removes the key, so the getter above falls
                // back to `.default` and the app keeps a working shortcut. That is the right
                // behaviour and it stays. What it must not do is be silent: the user would
                // have set a combination, watched it not take, and had nothing to look at.
                guard let encoded = try? JSONEncoder().encode(newValue) else {
                    Log.settings.error("""
                        could not encode the hotkey combination; it was not stored and the \
                        default remains in force \
                        (combination: \(newValue.displayString, privacy: .public))
                        """)
                    defaults.removeObject(forKey: "hotkey")
                    return
                }
                defaults.set(encoded, forKey: "hotkey")
            }
        }
    }

    /// The правка shortcut, stored exactly as `hotkey` is: one JSON value under one key,
    /// `isValid` re-checked on the way out because a plist is user-writable and a value that
    /// decodes cleanly can still be unusable.
    ///
    /// **One piece of `hotkey`'s reasoning does not transfer, and the difference is worth
    /// stating.** That property falls back to its default rather than to «no hotkey» because
    /// the shortcut is the only way in to the panel, so an unset value would be an
    /// unrecoverable state reached by a typo. That door stays open here whatever this
    /// property holds — правка is still reachable from the panel's own switch. The fallback
    /// is kept anyway, for the weaker but sufficient reason: a setting whose stored state and
    /// behaviour disagree is a setting the user cannot reason about.
    var proofreadHotkey: HotkeyCombo {
        get {
            access(keyPath: \.proofreadHotkey)
            guard let data = defaults.data(forKey: "proofreadHotkey"),
                  let decoded = try? JSONDecoder().decode(HotkeyCombo.self, from: data),
                  decoded.isValid
            else { return .proofreadDefault }
            return decoded
        }
        set {
            withMutation(keyPath: \.proofreadHotkey) {
                guard let encoded = try? JSONEncoder().encode(newValue) else {
                    Log.settings.error("""
                        could not encode the правка combination; it was not stored and the \
                        default remains in force \
                        (combination: \(newValue.displayString, privacy: .public))
                        """)
                    defaults.removeObject(forKey: "proofreadHotkey")
                    return
                }
                defaults.set(encoded, forKey: "proofreadHotkey")
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

extension AppSettings {
    /// The only place in the app that builds `ChatOptions`.
    ///
    /// It was four places, all passing the identical triple of model, temperature and
    /// keep-alive. Collapsing them is not tidying: after it, an app-layer `ChatOptions` cannot
    /// be built without the think decision having been made, so a fifth call site added later
    /// cannot silently opt out of the setting.
    ///
    /// `acceptance` and `translate-cli` deliberately do **not** come through here — the first
    /// measures the engine against fixed thresholds and must not follow a user's setting, and
    /// the second states its own with `--think`.
    func chatOptions(model: String) -> ChatOptions {
        ChatOptions(model: model, temperature: temperature, keepAlive: keepAlive,
                    think: ModelPolicy.thinkRequest(for: model, quiet: quietThinking,
                                                    level: gptOssThinkingLevel))
    }
}
