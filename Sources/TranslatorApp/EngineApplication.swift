// Sources/TranslatorApp/EngineApplication.swift
import AppKit
import Foundation

/// Finding and revealing the application behind an engine, so the pane can offer «Открыть …»
/// when the server is silent.
///
/// **Revealing, never starting a server, and never stopping one.** Neither engine can be stopped
/// over HTTP, and the only alternative would be running another program — `lms server stop`, or
/// killing `ollama serve`. This app has never started a process and does not begin here, for
/// three reasons recorded in the design (§3.3): measured on the machine this was written on, a
/// server holding no model is 63 MB against a 17.4 GB model, so the memory worth freeing is
/// freed by «Выгрузить»; the server is shared — LM Studio's own documentation names Zed, Cline
/// and Continue as its clients — so stopping it breaks work this app knows nothing about; and it
/// is the one operation that does not undo itself, since an unloaded model returns on the next
/// request while a stopped server does not.
///
/// This also closes design spec §8's «Ollama not running → a «Запустить Ollama» button», which
/// has never existed in the code: the user starts and stops the server where they started it.
enum EngineApplication {
    /// Bundle identifiers to try, in order. A list rather than one string because an engine may
    /// ship under more than one identifier over its life, and because this is the part a test
    /// can read — whether any of them is *installed* is a fact about the machine.
    ///
    /// `ai.elementlabs.lmstudio` is read off the installed bundle rather than guessed. Ollama's
    /// is listed for the packaged app; a Homebrew install has no bundle at all, which is why
    /// `url(for:)` may answer nil and the button is offered only when it does not.
    static func bundleIdentifiers(for engine: ModelEngine) -> [String] {
        switch engine {
        case .ollama: ["com.electron.ollama", "com.ollama.ollama"]
        case .lmStudio: ["ai.elementlabs.lmstudio"]
        }
    }

    /// Where that application is, or nil when it is not installed — the ordinary case for
    /// Ollama, which is commonly a Homebrew binary with no `.app` anywhere.
    static func url(for engine: ModelEngine, workspace: NSWorkspace = .shared) -> URL? {
        bundleIdentifiers(for: engine)
            .lazy
            .compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// Brings it forward. The same mechanism `PermissionsGate.openSettings()` uses for the
    /// System Settings pane, and the same intent: hand the user the place where the thing they
    /// need to change actually lives.
    @discardableResult
    static func reveal(_ engine: ModelEngine, workspace: NSWorkspace = .shared) -> Bool {
        guard let url = url(for: engine, workspace: workspace) else { return false }
        workspace.open(url)
        return true
    }
}
