// Sources/TranslatorApp/ModelEngine.swift
import Foundation
import TranslationCore

/// Which local server the app talks to.
///
/// Lives here rather than in `TranslationCore` on purpose: it names *transports*, and the domain
/// layer's one hard rule is that it knows nothing about them. `ModelRole` and `ModelPolicy` are
/// the domain's vocabulary for «which model»; this is the app's for «whose server».
enum ModelEngine: String, CaseIterable, Sendable {
    case ollama
    case lmStudio

    /// The port each server listens on out of the box. **Only the port is configurable, never
    /// the host** — a free-text address is the one place «text never leaves the machine» would
    /// stop being a property of this code and become a matter of what someone typed.
    var defaultPort: Int {
        switch self {
        case .ollama: 11434
        case .lmStudio: 1234
        }
    }

    /// What a fresh install answers for «модель для перевода», or `nil` where there is no
    /// honest answer.
    ///
    /// `ModelPolicy.defaultModel(for:)` names Ollama tags — `aya-expanse:8b` exists nowhere in
    /// LM Studio — so the second engine starts empty and the app says so, rather than
    /// pre-filling a name that would come back «model not found» from a server that never had
    /// it. Nothing is auto-selected either: flipping a radio button may not silently choose a
    /// 22.81 GB model and then load it at the next warm-up.
    var defaultTranslationModel: String? {
        switch self {
        case .ollama: ModelPolicy.defaultModel(for: .interactive)
        case .lmStudio: nil
        }
    }

    /// The suffix that keeps one engine's stored choices out of the other's.
    ///
    /// Empty for Ollama, and that is what makes this change require no migration: every key an
    /// existing install already wrote — `"interactiveModel"`, `"backgroundModel"`,
    /// `"proofreadModel"` — stays exactly where it is and becomes the Ollama scope. The
    /// precedent for a key that does not match its property is `batchModel`, stored under
    /// `"backgroundModel"` since the observability wave.
    var settingsKeySuffix: String {
        switch self {
        case .ollama: ""
        case .lmStudio: ".lmStudio"
        }
    }
}
