import Testing
@testable import TranslatorApp
@testable import OllamaKit

/// Non-private so `ModelsViewModelTests` can drive `ModelsViewModel` with the same stub:
/// both view models take the same `OllamaProbe`, and a second copy of this would be a
/// second thing to keep in step with the protocol.
struct StubProbe: OllamaProbe {
    var installed: [OllamaModel] = []
    var resident: [String] = []
    var failure: Error? = nil
    func installedModels() async throws -> [OllamaModel] { if let failure { throw failure }; return installed }
    func residentModels() async throws -> [String] { if let failure { throw failure }; return resident }
}

@MainActor
@Test func aTransportFailureReadsAsNotRunning() async {
    let model = OllamaStatusModel(probe: StubProbe(failure: OllamaError.notRunning))
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .notRunning)
    #expect(model.status.isHealthy == false)
}

@MainActor
@Test func aRunningServerWithoutTheModelLoadedIsHealthyButNotResident() async {
    let probe = StubProbe(installed: [OllamaModel(name: "aya-expanse:8b", sizeBytes: 0)], resident: [])
    let model = OllamaStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: false))
    #expect(model.status.isHealthy)
}

@MainActor
@Test func theModelBeingResidentIsReportedSeparately() async {
    let probe = StubProbe(installed: [OllamaModel(name: "aya-expanse:8b", sizeBytes: 0)], resident: ["aya-expanse:8b"])
    let model = OllamaStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: true))
}

@MainActor
@Test func residencyIsJudgedForTheConfiguredModelNotAnyModel() async {
    // Another model being warm says nothing about the one the hotkey will use.
    let probe = StubProbe(
        installed: [OllamaModel(name: "aya-expanse:8b", sizeBytes: 0), OllamaModel(name: "gpt-oss:20b", sizeBytes: 0)],
        resident: ["gpt-oss:20b"]
    )
    let model = OllamaStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: false))
}

@Test func theMenuBarGlyphSaysWhetherOllamaIsAnswering() {
    // The icon is the only thing this app renders when nothing is open, and until now it
    // said the same thing whether or not the app could translate at all.
    #expect(OllamaStatus.running(modelResident: true).menuBarSymbol == "character.bubble")
    #expect(OllamaStatus.running(modelResident: false).menuBarSymbol == "character.bubble")
    #expect(OllamaStatus.notRunning.menuBarSymbol == "exclamationmark.bubble")
    // Unknown is not a failure — it is the first second of the app's life, and a warning
    // glyph there would cry wolf on every launch.
    #expect(OllamaStatus.unknown.menuBarSymbol == "character.bubble")
}
