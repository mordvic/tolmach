// Sources/TranslatorApp/ModelsViewModel.swift
import Foundation
import Observation
import OllamaKit
import TranslationCore

/// Three states rather than a `Bool`, because «this model is not installed» and «I could
/// not ask» send the user to different places: the first to the download field below, the
/// second to starting the engine. An unreachable server answers with an empty list, so a
/// two-state answer would report every model as missing the moment the engine stops.
enum ModelAvailability: Equatable { case installed, notInstalled, unknown }

/// `@MainActor` for the same reason `EngineStatusModel` is: every mutation here happens
/// after an `await` on the probe or the pull stream, and without actor isolation those
/// assignments would resume on a cooperative-pool thread with SwiftUI observing from the
/// main one.
@Observable
@MainActor
final class ModelsViewModel {
    typealias Puller = @Sendable (String) -> AsyncThrowingStream<PullProgress, Error>
    /// Frees one model's memory. Injected like `puller`, so a test can drive «Выгрузить»
    /// without a server and so this layer never learns which engine it is talking to.
    typealias Unloader = @Sendable (EngineModel) async throws -> Void

    private let probe: EngineProbe
    private let puller: Puller
    private let unloader: Unloader?

    var installed: [EngineModel] = []

    /// The names alone, for the picker and for `availability(of:)`. A computed property
    /// rather than a second stored one, so the two cannot fall out of step.
    var installedNames: [String] { installed.map(\.name) }

    /// Which installed models the engine currently holds in memory. Read on the
    /// same reload as the installed list, so the two describe the same moment.
    var resident: [String] = []

    var pullProgress: Double?
    var pullStatus: String?
    var error: String?

    /// Whether `installed` is something the server actually confirmed. A failed reload
    /// leaves the last known list in place — emptying it would blank the pickers — but stops
    /// this layer vouching for it, so `availability(of:)` goes back to `.unknown`.
    private(set) var listIsConfirmed = false

    /// A second pull would write the same `pullProgress` and `pullStatus` as the first, so
    /// the bar would jump between two downloads and whichever finished first would clear it
    /// out from under the other.
    private(set) var isPulling = false

    init(probe: EngineProbe, puller: @escaping Puller, unloader: Unloader? = nil) {
        self.probe = probe
        self.puller = puller
        self.unloader = unloader
    }

    /// Whether a row may offer «Выгрузить»: only a model the engine says it is holding.
    ///
    /// There is deliberately no «выгрузить всё» anywhere above this: a loaded instance reports
    /// its id and its configuration and nothing about *who* loaded it (measured 2026-08-21), so
    /// a blanket command could only either reach another application's model or lie about its
    /// own scope.
    func isResident(_ model: EngineModel) -> Bool {
        resident.contains(model.name) || !model.loadedInstanceIDs.isEmpty
    }

    /// Frees one model's memory and re-reads the lists, so the row stops saying «в памяти» in
    /// the same breath.
    ///
    /// Refused while a download is running for `isPulling`'s reason turned around: both write
    /// `error`, and a failed unload would replace a download's failure with its own.
    /// **The re-read happens before the failure is recorded, and the order is load-bearing.**
    /// `reload()` clears `error` when it succeeds, so recording first and reloading afterwards
    /// wiped the message — a failed unload reported itself as a silent success, which a test
    /// caught before this comment was written. The lists are re-read either way: a refusal does
    /// not prove the model is still resident.
    func unload(_ model: EngineModel) async {
        guard let unloader, !isPulling else { return }
        do {
            try await unloader(model)
            await reload()
        } catch {
            let failure = TranslationViewModel.message(for: error)
            await reload()
            self.error = failure
        }
    }

    /// Whether «Длина рассуждения» is worth drawing for the current selection, which is a
    /// **per-engine** question and not a per-name one.
    ///
    /// On Ollama the app is blind, so the answer is `ModelPolicy`'s prefix table — the same rule
    /// `AppSettings.usesGptOss` has always applied. On LM Studio the server states each model's
    /// `allowed_options`, so the answer is «this model offers levels and cannot be silenced»,
    /// which is both more accurate and the only version that works there: no publisher-qualified
    /// name matches the prefix table, so the old rule would never draw the row at all.
    ///
    /// Drawn only when silence is *unavailable*, and that is what keeps the two controls from
    /// contradicting each other: a model that can be silenced obeys «Отключать рассуждение
    /// модели» outright, so offering a length beside it would be offering a value the app then
    /// ignores.
    func showsReasoningLength(for settings: AppSettings) -> Bool {
        switch settings.engine {
        case .ollama:
            return settings.usesGptOss
        case .lmStudio:
            let selected = [settings.interactiveModel, settings.resolvedBatchModel,
                            settings.resolvedProofreadModel]
            return installed.contains { model in
                guard selected.contains(model.name), let options = model.reasoningOptions else {
                    return false
                }
                return !options.contains("off")
                    && options.contains { ThinkRequest.Level(rawValue: $0) != nil }
            }
        }
    }

    func reload() async {
        do {
            installed = try await probe.installedModels()
            resident = try await probe.residentModels()
            listIsConfirmed = true
            error = nil
        } catch {
            listIsConfirmed = false
            resident = []
            self.error = "Не удалось получить список моделей. " + RussianCopy.failureDetail(error)
        }
    }

    func pull(_ model: String) async {
        guard !isPulling else { return }
        isPulling = true
        pullStatus = "Начинаю загрузку…"
        pullProgress = nil
        error = nil
        do {
            for try await progress in puller(model) { apply(progress) }
            // A finished pull is precisely when the installed list changed.
            await reload()
        } catch {
            self.error = "Загрузка не удалась. " + RussianCopy.failureDetail(error)
        }
        pullProgress = nil
        pullStatus = nil
        isPulling = false
    }

    /// Applying one line is separated from consuming the stream so the rule below is
    /// directly testable — the interesting behaviour happens *between* lines, and a test
    /// that can only look after the stream ends cannot see it: by then both fields have
    /// been cleared on purpose.
    func apply(_ progress: PullProgress) {
        pullStatus = RussianCopy.pullStatus(progress.status)
        // Only a line carrying byte counts moves the bar. Ollama interleaves bare status
        // lines ("verifying sha256 digest") with no counts at all, and `fraction` is nil
        // for those; treating nil as 0 would snap the bar back to empty mid-download.
        if let fraction = progress.fraction { pullProgress = fraction }
    }

    /// Blacklisted models stay selectable — the reason is measured evidence, not a ban.
    func warning(for model: String) -> String? { RussianCopy.blacklistReason(for: model) }

    func availability(of model: String) -> ModelAvailability {
        guard listIsConfirmed else { return .unknown }
        return installedNames.contains(model) ? .installed : .notInstalled
    }

    /// A `Picker` bound to a value absent from its options renders blank, and a blank
    /// picker is indistinguishable from «nothing selected». The configured model is
    /// therefore always an option — `optionLabel` is what says it is not installed.
    func options(selecting selected: String) -> [String] {
        installedNames.contains(selected) ? installedNames : installedNames + [selected]
    }

    func optionLabel(_ model: String) -> String {
        availability(of: model) == .notInstalled ? "\(model) — не установлена" : model
    }
}
