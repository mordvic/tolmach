// Sources/TranslatorApp/OllamaStatusModel.swift
import Foundation
import Observation
import OllamaKit

enum OllamaStatus: Equatable {
    case unknown
    case notRunning
    case running(modelResident: Bool)

    var label: String {
        switch self {
        case .unknown: "Проверяю Ollama…"
        case .notRunning: "Ollama не запущена"
        case .running(true): "Ollama работает, модель в памяти"
        case .running(false): "Ollama работает, модель не загружена"
        }
    }

    var isHealthy: Bool {
        if case .running = self { return true }
        return false
    }

    /// Exhaustive with no `default:` on purpose: a fourth case should fail to compile here
    /// rather than silently keep the healthy glyph.
    ///
    /// **No polling timer drives this.** The status behind it refreshes at launch, when the
    /// main window or the settings window opens, after a translation attempt finishes (hotkey
    /// panel or main window), and when the user presses «Проверить снова» in the «Модели» pane
    /// — never on a clock. That last one is listed because it is the one a user reaches for
    /// *precisely* when they distrust this glyph, so a list that omitted it would read as
    /// though there were no way to force the question. Between those moments this glyph can
    /// lag the truth: Ollama can stop right after a refresh and the menu bar will keep saying
    /// `character.bubble` until the next one of those moments. Deliberately absent from that
    /// list is "when the menu opens" — `MenuBarExtra`'s content is not reliably re-instantiated
    /// on every opening across macOS versions, so a `.task` there would refresh on some
    /// systems and silently not on others. The lag this leaves is a chosen trade, not an
    /// oversight — a timer ticking in an app that spends nearly all its life idle in the menu
    /// bar was rejected (see spec §6 / §9), and this comment is where the trade is written
    /// down rather than left implicit.
    var menuBarSymbol: String {
        switch self {
        case .unknown, .running: "character.bubble"
        case .notRunning: "exclamationmark.bubble"
        }
    }
}

protocol OllamaProbe: Sendable {
    /// The whole model and not just its name: `sizeBytes` is what the settings pane shows,
    /// and flattening to `[String]` here is where it used to be lost.
    func installedModels() async throws -> [OllamaModel]
    func residentModels() async throws -> [String]
}

struct LiveOllamaProbe: OllamaProbe {
    let client: OllamaClient
    init(client: OllamaClient = OllamaClient()) { self.client = client }
    func installedModels() async throws -> [OllamaModel] { try await client.models() }
    func residentModels() async throws -> [String] { try await client.ps().map(\.name) }
}

/// `@MainActor` because `refresh` assigns to `status` after awaiting the probe: without
/// actor isolation that assignment resumes on a cooperative-pool thread and SwiftUI's
/// observation would fire off the main thread. `status` is a genuine stored property, so
/// `@Observable`'s synthesized tracking applies — unlike `AppSettings`, this type needs no
/// hand-written `access`/`withMutation` hooks.
@MainActor
@Observable
final class OllamaStatusModel {
    private let probe: OllamaProbe
    var status: OllamaStatus = .unknown

    init(probe: OllamaProbe = LiveOllamaProbe()) { self.probe = probe }

    /// Any probe failure reads as "not running". That is the actionable message for the
    /// overwhelmingly common cause, and spec 8 pairs it with a "Запустить Ollama" button;
    /// distinguishing a crashed server from an unreachable one would give the user the
    /// same next step either way.
    func refresh(interactiveModel: String) async {
        do {
            _ = try await probe.installedModels()
            let resident = try await probe.residentModels()
            status = .running(modelResident: resident.contains(interactiveModel))
        } catch {
            status = .notRunning
        }
    }
}
