// Sources/TranslatorApp/EngineStatusModel.swift
import Foundation
import Observation

/// Whether the selected engine is answering, and whether the model this app is about to use is
/// already in its memory.
///
/// `modelResident` is a plain `Bool` and not an optional: both engines answer the question
/// (`/api/ps` on one, `loaded_instances` on the other), and the design closes the third engine
/// on the merits rather than deferring it, so a «running, and residency is not knowable» case
/// would have had no producer at all. This project states that rule on `ThinkRequest`: only what
/// is reachable should be representable.
enum EngineStatus: Equatable {
    case unknown
    case notAnswering
    case running(modelResident: Bool)

    var isHealthy: Bool {
        if case .running = self { return true }
        return false
    }

    /// Exhaustive with no `default:` on purpose: a fourth case should fail to compile here
    /// rather than silently keep the healthy glyph.
    ///
    /// **No polling timer drives this.** The status behind it refreshes at launch, when the main
    /// window or the settings window opens, after a translation attempt finishes (hotkey panel
    /// or main window), when a model is unloaded from the pane, and when the user presses
    /// «Проверить снова» — never on a clock. That last one is listed because it is the one a
    /// user reaches for *precisely* when they distrust this glyph. Between those moments the
    /// glyph can lag the truth, and that lag is a chosen trade rather than an oversight: a timer
    /// ticking in an app that spends nearly all its life idle in the menu bar was rejected (spec
    /// §6 / §9). Deliberately absent from the list is «when the menu opens» —
    /// `MenuBarExtra`'s content is not reliably re-instantiated on every opening across macOS
    /// versions, so a `.task` there would refresh on some systems and silently not on others.
    ///
    /// Two-valued whichever engine is selected, and that is not an oversight either: the glyph
    /// answers «can I translate», which has the same two answers on every server.
    var menuBarSymbol: String {
        switch self {
        case .unknown, .running: "character.bubble"
        case .notAnswering: "exclamationmark.bubble"
        }
    }
}

/// `@MainActor` because `refresh` assigns to `status` after awaiting the probe: without actor
/// isolation that assignment resumes on a cooperative-pool thread and SwiftUI's observation
/// would fire off the main thread. `status` is a genuine stored property, so `@Observable`'s
/// synthesized tracking applies — unlike `AppSettings`, this type needs no hand-written
/// `access`/`withMutation` hooks.
@Observable
@MainActor
final class EngineStatusModel {
    private let probe: EngineProbe
    var status: EngineStatus = .unknown

    init(probe: EngineProbe) { self.probe = probe }

    /// Any probe failure reads as «not answering». That is the actionable message for the
    /// overwhelmingly common cause, and the pane pairs it with «Открыть …»; distinguishing a
    /// crashed server from an unreachable one would give the user the same next step either way.
    func refresh(interactiveModel: String) async {
        do {
            _ = try await probe.installedModels()
            let resident = try await probe.residentModels()
            status = .running(modelResident: resident.contains(interactiveModel))
        } catch {
            status = .notAnswering
        }
    }
}
