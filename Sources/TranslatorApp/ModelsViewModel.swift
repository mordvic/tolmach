// Sources/TranslatorApp/ModelsViewModel.swift
import Foundation
import Observation
import OllamaKit
import TranslationCore

/// Three states rather than a `Bool`, because «this model is not installed» and «I could
/// not ask» send the user to different places: the first to the download field below, the
/// second to starting Ollama. An unreachable server answers with an empty list, so a
/// two-state answer would report every model as missing the moment Ollama stops.
enum ModelAvailability: Equatable { case installed, notInstalled, unknown }

/// `@MainActor` for the same reason `OllamaStatusModel` is: every mutation here happens
/// after an `await` on the probe or the pull stream, and without actor isolation those
/// assignments would resume on a cooperative-pool thread with SwiftUI observing from the
/// main one.
@Observable
@MainActor
final class ModelsViewModel {
    typealias Puller = @Sendable (String) -> AsyncThrowingStream<PullProgress, Error>

    private let probe: OllamaProbe
    private let puller: Puller

    var installed: [OllamaModel] = []

    /// The names alone, for the picker and for `availability(of:)`. A computed property
    /// rather than a second stored one, so the two cannot fall out of step.
    var installedNames: [String] { installed.map(\.name) }

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

    init(probe: OllamaProbe = LiveOllamaProbe(),
         puller: @escaping Puller = { model in OllamaClient().pull(model: model) }) {
        self.probe = probe
        self.puller = puller
    }

    func reload() async {
        do {
            installed = try await probe.installedModels()
            listIsConfirmed = true
            error = nil
        } catch {
            listIsConfirmed = false
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
