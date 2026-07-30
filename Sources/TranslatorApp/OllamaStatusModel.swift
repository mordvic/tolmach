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
