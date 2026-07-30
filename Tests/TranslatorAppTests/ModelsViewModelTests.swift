import Testing
import Foundation
@testable import TranslatorApp
@testable import TranslationCore
@testable import OllamaKit

/// `PullProgress`'s memberwise initialiser is internal (the struct is public, its `init` is
/// not), so the stream stubs below need `@testable import OllamaKit` rather than a plain one.
private func silentPuller() -> ModelsViewModel.Puller {
    { _ in AsyncThrowingStream { $0.finish() } }
}

@MainActor
private func makeModel(installed: [String] = [],
                       failure: Error? = nil,
                       puller: @escaping ModelsViewModel.Puller = silentPuller()) -> ModelsViewModel {
    // Callers only ever care about names here; the size-carrying tests build `StubProbe`
    // directly instead of going through this helper.
    let models = installed.map { OllamaModel(name: $0, sizeBytes: 0) }
    return ModelsViewModel(probe: StubProbe(installed: models, failure: failure), puller: puller)
}

// MARK: - Blacklist warnings

@MainActor
@Test func blacklistedModelsCarryTheirMeasuredReason() {
    let model = makeModel()
    #expect(model.warning(for: "gemma3n:e4b") != nil)
    #expect(model.warning(for: "qwen3:30b") != nil)
    #expect(model.warning(for: "aya-expanse:8b") == nil)
}

/// The reason is shown in a Russian settings pane, and `ModelPolicy`'s own copy is English
/// («Port: corrupts identifiers character-by-character…»). Returning the engine's string
/// verbatim is the bug this pins.
@MainActor
@Test func theWarningIsRussianAndNotTheEnginesEnglish() {
    let model = makeModel()
    for name in ["gemma3n:e4b", "qwen3:30b"] {
        let warning = model.warning(for: name)
        #expect(warning != ModelPolicy.blacklistReason(for: name),
                "«\(name)» still shows ModelPolicy's English reason")
        #expect(warning?.rangeOfCharacter(from: CharacterSet(charactersIn: "а"..."я")) != nil,
                "«\(name)» warning has no Cyrillic at all: \(warning ?? "nil")")
    }
}

/// `ModelPolicy.blacklistReason` matches by prefix so every tag of a bad model is covered;
/// the app's Russian lookup must key the same way rather than on the exact name.
@MainActor
@Test func theWarningMatchesAnyTagOfABlacklistedModel() {
    let model = makeModel()
    #expect(model.warning(for: "gemma3n:e2b") != nil)
    #expect(model.warning(for: "gemma3n") != nil)
    // A different qwen3 size is not the blacklisted one.
    #expect(model.warning(for: "qwen3:8b") == nil)
}

// MARK: - reload

@MainActor
@Test func reloadPublishesTheInstalledList() async {
    let model = makeModel(installed: ["aya-expanse:8b", "gpt-oss:20b"])
    await model.reload()
    #expect(model.installedNames == ["aya-expanse:8b", "gpt-oss:20b"])
    #expect(model.error == nil)
}

@MainActor
@Test func aProbeFailureIsReportedInRussianAndLeavesTheListAlone() async {
    let model = makeModel(installed: ["aya-expanse:8b"])
    await model.reload()
    let broken = makeModel(failure: OllamaError.notRunning)
    await broken.reload()
    #expect(broken.installed.isEmpty)
    guard let message = broken.error else {
        Issue.record("a failed reload must set `error`"); return
    }
    #expect(message.contains("Ollama не запущена"),
            "the transport failure's Russian text is missing: \(message)")
}

// MARK: - C1: applying one progress line

/// The rule lives *between* lines: a bare status line carries no byte counts, and treating
/// its missing fraction as zero snaps a half-finished bar back to empty. A test that can
/// only look after the stream has ended cannot see that — by then both fields are cleared
/// deliberately — so `apply` is called directly here.
@MainActor
@Test func aStatusLineWithoutByteCountsLeavesTheBarWhereItWas() {
    let model = makeModel()
    model.apply(PullProgress(status: "pulling 65f986688a01", completed: 50, total: 100))
    #expect(model.pullProgress == 0.5)

    model.apply(PullProgress(status: "verifying sha256 digest", completed: 0, total: 0))
    #expect(model.pullProgress == 0.5)                     // still, not reset to 0 or nil
    #expect(model.pullStatus == "Проверяю контрольную сумму…")  // but the caption moved on
}

@MainActor
@Test func applyTranslatesTheStatusAndAdvancesTheBar() {
    let model = makeModel()
    model.apply(PullProgress(status: "pulling manifest", completed: 0, total: 0))
    #expect(model.pullStatus == "Получаю манифест…")
    #expect(model.pullProgress == nil)
    model.apply(PullProgress(status: "pulling 65f986688a01", completed: 25, total: 100))
    #expect(model.pullProgress == 0.25)
    model.apply(PullProgress(status: "pulling 65f986688a01", completed: 90, total: 100))
    #expect(model.pullProgress == 0.9)
}

// MARK: - pull

@MainActor
@Test func pullClearsTheBarAndRefreshesTheListWhenItFinishes() async {
    let model = makeModel(installed: ["aya-expanse:8b"], puller: { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(PullProgress(status: "pulling 65f986688a01", completed: 50, total: 100))
            continuation.yield(PullProgress(status: "verifying sha256 digest", completed: 0, total: 0))
            continuation.finish()
        }
    })
    await model.pull("aya-expanse:8b")
    #expect(model.pullProgress == nil)
    #expect(model.pullStatus == nil)
    #expect(model.error == nil)
    // A finished pull is exactly when the installed list changed, so it is refetched.
    #expect(model.installedNames == ["aya-expanse:8b"])
}

@MainActor
@Test func aFailedPullReportsRussianAndStillClearsTheBar() async {
    let model = makeModel(installed: [], puller: { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(PullProgress(status: "pulling 65f986688a01", completed: 50, total: 100))
            continuation.finish(throwing: OllamaError.httpStatus(500, "boom"))
        }
    })
    await model.pull("aya-expanse:8b")
    #expect(model.pullProgress == nil)
    #expect(model.pullStatus == nil)
    guard let message = model.error else {
        Issue.record("a failed pull must set `error`"); return
    }
    #expect(message.contains("500"), "the HTTP status is missing from: \(message)")
    #expect(message.contains("Загрузка"), "the failure is not described in Russian: \(message)")
    // The throwing path must release the flag too. A wedged `isPulling` would disable the
    // download button for the rest of the session, and only the success path pinned it.
    #expect(!model.isPulling)
}

/// Two pulls at once write the same `pullProgress` and `pullStatus`, so the bar would jump
/// between two downloads and whichever finished first would clear it out from under the
/// other. The button is disabled while a pull runs, but that is derived state in a view;
/// the invariant belongs here.
@MainActor
@Test func aSecondPullWhileOneIsRunningIsIgnored() async {
    let model = makeModel(installed: ["aya-expanse:8b"], puller: { _ in
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(PullProgress(status: "pulling 65f986688a01", completed: 1, total: 100))
                try? await Task.sleep(nanoseconds: 200_000_000)
                continuation.finish()
            }
        }
    })
    let first = Task { await model.pull("aya-expanse:8b") }
    while model.pullStatus == nil { await Task.yield() }

    await model.pull("gpt-oss:20b")
    // Returned at once, having touched nothing: the running pull's caption is still up.
    #expect(model.pullStatus != nil)
    #expect(model.isPulling)

    await first.value
    #expect(model.pullProgress == nil)
    #expect(model.pullStatus == nil)
    #expect(!model.isPulling)
}

// MARK: - C4: a configured model that is not installed

@MainActor
@Test func aConfiguredModelStaysInThePickerEvenWhenItIsNotInstalled() async {
    let model = makeModel(installed: ["gpt-oss:20b"])
    await model.reload()
    // A `Picker` whose selection is absent from its options renders blank, so the
    // configured value has to be an option whether or not the server has it.
    #expect(model.options(selecting: "aya-expanse:8b") == ["gpt-oss:20b", "aya-expanse:8b"])
    #expect(model.options(selecting: "gpt-oss:20b") == ["gpt-oss:20b"])   // no duplicate
    #expect(model.availability(of: "aya-expanse:8b") == .notInstalled)
    #expect(model.availability(of: "gpt-oss:20b") == .installed)
    #expect(model.optionLabel("aya-expanse:8b").contains("не установлена"))
    #expect(model.optionLabel("gpt-oss:20b") == "gpt-oss:20b")
}

/// «Not installed» and «I could not ask» are different facts and lead to different actions.
/// Before the first successful reload — and after a failed one — the app knows nothing, and
/// claiming the model is missing would send the user to download something they may have.
@MainActor
@Test func nothingIsClaimedAboutInstallationUntilTheServerHasAnswered() async {
    let model = makeModel(installed: ["gpt-oss:20b"])
    #expect(model.availability(of: "aya-expanse:8b") == .unknown)   // no reload yet
    #expect(model.optionLabel("aya-expanse:8b") == "aya-expanse:8b")

    let broken = makeModel(failure: OllamaError.notRunning)
    await broken.reload()
    #expect(broken.availability(of: "aya-expanse:8b") == .unknown)
    #expect(broken.options(selecting: "aya-expanse:8b") == ["aya-expanse:8b"])

    await model.reload()
    #expect(model.availability(of: "aya-expanse:8b") == .notInstalled)
}

/// A reload that fails after a successful one must stop vouching for the list it is no
/// longer able to confirm.
@MainActor
@Test func aFailedReloadAfterAGoodOneGoesBackToUnknown() async {
    let probe = FlakyProbe()
    let model = ModelsViewModel(probe: probe, puller: silentPuller())
    await model.reload()
    #expect(model.availability(of: "gpt-oss:20b") == .installed)
    probe.fail = true
    await model.reload()
    #expect(model.availability(of: "gpt-oss:20b") == .unknown)
}

/// `OllamaProbe` is `Sendable` and `installedModels()` is `async`, so the switchable flag
/// cannot be a plain `var` on a struct. Access is confined to the main actor by the tests
/// that use it, which is what `@unchecked` is asserting here.
private final class FlakyProbe: OllamaProbe, @unchecked Sendable {
    var fail = false
    func installedModels() async throws -> [OllamaModel] {
        if fail { throw OllamaError.notRunning }
        return [OllamaModel(name: "gpt-oss:20b", sizeBytes: 0)]
    }
    func residentModels() async throws -> [String] { [] }
}

@MainActor
@Test func theInstalledListKeepsTheSizeTheServerReported() async {
    // The size is what makes the list worth showing: a user deciding whether to pull a
    // second model is deciding about disk space. It exists in `OllamaModel` already and
    // used to be discarded at the protocol boundary.
    let probe = StubProbe(installed: [OllamaModel(name: "aya-expanse:8b", sizeBytes: 5_100_273_664)])
    let model = ModelsViewModel(probe: probe, puller: { _ in .init { $0.finish() } })
    await model.reload()
    #expect(model.installed.first?.sizeBytes == 5_100_273_664)
    #expect(model.installedNames == ["aya-expanse:8b"])
    #expect(model.availability(of: "aya-expanse:8b") == .installed)
}

@MainActor
@Test func aFailedReloadStopsClaimingAnythingIsInMemory() async {
    // The installed list survives a failure on purpose — emptying it would blank the picker
    // — but «в памяти» is a claim about right now, and right now the server did not answer.
    var probe = StubProbe(installed: [OllamaModel(name: "aya-expanse:8b", sizeBytes: 1)],
                          resident: ["aya-expanse:8b"])
    let models = ModelsViewModel(probe: probe, puller: { _ in .init { $0.finish() } })
    await models.reload()
    #expect(models.resident == ["aya-expanse:8b"])
    probe.failure = URLError(.cannotConnectToHost)
    let broken = ModelsViewModel(probe: probe, puller: { _ in .init { $0.finish() } })
    await broken.reload()
    #expect(broken.resident.isEmpty)
}

