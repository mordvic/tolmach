import Testing
@testable import TranslatorApp
@testable import OllamaKit

/// Non-private so `ModelsViewModelTests` can drive `ModelsViewModel` with the same stub:
/// both view models take the same `OllamaProbe`, and a second copy of this would be a
/// second thing to keep in step with the protocol.
struct StubProbe: OllamaProbe {
    var installed: [String] = []
    var resident: [String] = []
    var failure: Error? = nil
    func installedModels() async throws -> [String] { if let failure { throw failure }; return installed }
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
    let probe = StubProbe(installed: ["aya-expanse:8b"], resident: [])
    let model = OllamaStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: false))
    #expect(model.status.isHealthy)
}

@MainActor
@Test func theModelBeingResidentIsReportedSeparately() async {
    let probe = StubProbe(installed: ["aya-expanse:8b"], resident: ["aya-expanse:8b"])
    let model = OllamaStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: true))
}

@MainActor
@Test func residencyIsJudgedForTheConfiguredModelNotAnyModel() async {
    // Another model being warm says nothing about the one the hotkey will use.
    let probe = StubProbe(installed: ["aya-expanse:8b", "gpt-oss:20b"], resident: ["gpt-oss:20b"])
    let model = OllamaStatusModel(probe: probe)
    await model.refresh(interactiveModel: "aya-expanse:8b")
    #expect(model.status == .running(modelResident: false))
}
