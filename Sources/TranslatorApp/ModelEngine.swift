// Sources/TranslatorApp/ModelEngine.swift
import Foundation
import LMStudioKit
import OllamaKit
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
    ///
    /// Taken from each client rather than restated here: the address is written once per
    /// transport module, and a second copy of the number in the app layer is a second thing to
    /// keep in step.
    var defaultPort: Int {
        switch self {
        case .ollama: OllamaClient.defaultPort
        case .lmStudio: LMStudioClient.defaultPort
        }
    }

    /// What a TCP port can actually be. Everything outside it is not a slow server or a wrong
    /// one — it is a string no URL can be built from.
    static let validPorts = 1...65535

    /// The stored port, or this engine's default when the stored value is not a port at all.
    ///
    /// **Applied on the way out as well as on the way in**, for the same reason
    /// `ContentFont.clamped` is (`AppSettings.contentFontSize`): the setter is not the only
    /// writer. `defaults write … enginePort -int -1` is one, and so is the «Порт» field, whose
    /// `.number` format parses a negative happily. `URL(string: "http://127.0.0.1:-1")` answers
    /// nil, and both call sites force-unwrapped it — so a value nothing rejected became a trap
    /// inside `warmUpOnLaunch`, which is on by default and runs at every start. The stored value
    /// survived each crash, which made it a loop only a hand-edited plist could break.
    ///
    /// The default rather than the nearest bound, because the nearest bound is a lie: port 1 is
    /// not a quieter version of −1, it is a different machine's answer. The default is the one
    /// value that is true about this engine.
    func portOrDefault(_ port: Int) -> Int {
        Self.validPorts.contains(port) ? port : defaultPort
    }

    /// The address this engine will actually be dialled on.
    ///
    /// Asked of the client rather than assembled here, so that what «Модели» *shows* and what
    /// the router *calls* cannot come apart. The pane already shared the port; it wrote the host
    /// itself, which made three places in the tree that spelled the loopback address where
    /// ADR 0009 claims two — and a display that can disagree with the target is exactly what
    /// that ADR exists to rule out.
    func baseURL(port: Int) -> URL {
        switch self {
        case .ollama: OllamaClient.baseURL(port: port)
        case .lmStudio: LMStudioClient.baseURL(port: port)
        }
    }

    /// «host:port», for the one label that shows it.
    func address(port: Int) -> String {
        let url = baseURL(port: port)
        return "\(url.host ?? OllamaClient.loopbackHost):\(url.port ?? port)"
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
