import Testing
@testable import TranslatorApp
@testable import LMStudioKit

/// Non-private so `ModelsViewModelTests` can drive `ModelsViewModel` with the same stub:
/// both view models take the same `EngineProbe`, and a second copy of this would be a
/// second thing to keep in step with the protocol.
struct StubProbe: EngineProbe {
    var installed: [EngineModel] = []
    var resident: [String] = []
    var failure: Error? = nil
    func installedModels() async throws -> [EngineModel] { if let failure { throw failure }; return installed }
    func residentModels() async throws -> [String] { if let failure { throw failure }; return resident }
}

@MainActor
@Test func aTransportFailureFromEitherEngineReadsAsNotAnswering() async {
    // Whose error it is does not matter, and that is the point: the user's next step is the
    // same — open the engine — so the model does not distinguish a crashed server from an
    // unreachable one.
    let model = EngineStatusModel(probe: StubProbe(failure: LMStudioError.notRunning))
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .notAnswering)
    #expect(model.status.isHealthy == false)
}

@MainActor
@Test func aRunningServerWithoutTheModelLoadedIsHealthyButNotResident() async {
    let probe = StubProbe(installed: [EngineModel(name: "aya-expanse:8b", sizeBytes: 0)], resident: [])
    let model = EngineStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: false))
    #expect(model.status.isHealthy)
}

@MainActor
@Test func theModelBeingResidentIsReportedSeparately() async {
    let probe = StubProbe(installed: [EngineModel(name: "aya-expanse:8b", sizeBytes: 0)], resident: ["aya-expanse:8b"])
    let model = EngineStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: true))
}

@MainActor
@Test func residencyIsJudgedForTheConfiguredModelNotAnyModel() async {
    // Another model being warm says nothing about the one the hotkey will use.
    let probe = StubProbe(
        installed: [EngineModel(name: "aya-expanse:8b", sizeBytes: 0), EngineModel(name: "gpt-oss:20b", sizeBytes: 0)],
        resident: ["gpt-oss:20b"]
    )
    let model = EngineStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: false))
}

@Test func theMenuBarGlyphSaysWhetherTheSelectedEngineIsAnswering() {
    // The icon is the only thing this app renders when nothing is open, and until now it
    // said the same thing whether or not the app could translate at all.
    #expect(EngineStatus.running(modelResident: true).menuBarSymbol == "character.bubble")
    #expect(EngineStatus.running(modelResident: false).menuBarSymbol == "character.bubble")
    #expect(EngineStatus.notAnswering.menuBarSymbol == "exclamationmark.bubble")
    // Unknown is not a failure — it is the first second of the app's life, and a warning
    // glyph there would cry wolf on every launch.
    #expect(EngineStatus.unknown.menuBarSymbol == "character.bubble")
}
