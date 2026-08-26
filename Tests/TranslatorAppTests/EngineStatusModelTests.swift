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

// MARK: - A stale probe must not overwrite a fresher answer

/// A probe whose calls the test releases **one at a time**, so «slow» is a fact rather than a
/// sleep and the *order* in which two refreshes finish is chosen rather than raced.
///
/// Nominated calls **fail** once released, which is what lets the test tell whose answer ended
/// up on the model. Two earlier versions of this fixture could not: the first gave both refreshes
/// the same answer, and the second keyed the answer on a counter both had already advanced. Both
/// passed with the guard deleted — `docs/reference/TESTING.md`'s first rule, failing twice out
/// loud. Failure is also the direction that matters: a wrong «не отвечает» over a healthy engine,
/// with no timer to correct it.
private actor GatedProbe: EngineProbe {
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private let failing: Set<Int>
    private let resident: [String]
    private(set) var started = 0

    struct Failure: Error {}

    init(failing: Set<Int> = [], resident: [String] = []) {
        self.failing = failing
        self.resident = resident
    }

    func installedModels() async throws -> [EngineModel] {
        let index = started
        started += 1
        await withCheckedContinuation { gates[index] = $0 }
        if failing.contains(index) { throw Failure() }
        return []
    }
    func residentModels() async throws -> [String] { resident }

    /// Lets exactly one suspended call proceed, by its zero-based index.
    func release(call index: Int) {
        gates.removeValue(forKey: index)?.resume()
    }
    func waitUntilStarted(_ count: Int) async {
        while started < count { await Task.yield() }
    }
}

/// There is no polling timer and at least five overlapping triggers, and `refresh` awaits **two**
/// probes in turn on a 10 s timeout. So a slow refresh against a hung server could resume long
/// after a fresher one had answered, and overwrite it — and with nothing scheduled to correct it,
/// the wrong answer stays until a human triggers another by hand. The dangerous direction is a
/// green indicator over a dead engine: nothing prompts the user to re-check that.
@MainActor @Test func aSlowRefreshDoesNotOverwriteTheAnswerOfAFresherOne() async {
    // Call 0 — the stale one — fails; call 1 succeeds. Without the guard the late failure
    // overwrites the good answer with «не отвечает», which is the direction that matters:
    // nothing prompts a user to re-check an engine the app says is down.
    let probe = GatedProbe(failing: [0], resident: ["aya-expanse:8b"])
    let model = EngineStatusModel(probe: probe)

    let stale = Task { await model.refresh(interactiveModel: "aya-expanse:8b") }
    await probe.waitUntilStarted(1)

    // A second refresh starts and finishes while the first is still suspended.
    let fresh = Task { await model.refresh(interactiveModel: "aya-expanse:8b") }
    await probe.waitUntilStarted(2)
    await probe.release(call: 1)
    await fresh.value
    #expect(model.status == .running(modelResident: true))

    // Only now does the stale one resume, with its older, wrong answer.
    await probe.release(call: 0)
    await stale.value

    #expect(model.status == .running(modelResident: true),
            "a stale probe overwrote a fresher answer")
}

/// And the guard must not make the *current* refresh a no-op — the failure that would hide
/// itself, since the status simply never changes and nothing says why.
@MainActor @Test func asingleRefreshStillWritesItsAnswer() async {
    let probe = GatedProbe(resident: ["aya-expanse:8b"])
    let model = EngineStatusModel(probe: probe)
    #expect(model.status == .unknown)

    let run = Task { await model.refresh(interactiveModel: "aya-expanse:8b") }
    await probe.waitUntilStarted(1)
    await probe.release(call: 0)
    await run.value

    #expect(model.status == .running(modelResident: true))
}

/// The mirror of the test above, and the reason the guard is on **both** writes. Here the stale
/// refresh is the one that *succeeds*: without a guard on the success path it reports a running
/// engine over the fresh refusal — a green indicator on a dead server, which is the failure
/// nothing prompts the user to re-check.
@MainActor @Test func aStaleSuccessDoesNotOverwriteAFreshRefusal() async {
    let probe = GatedProbe(failing: [1], resident: [])
    let model = EngineStatusModel(probe: probe)

    let stale = Task { await model.refresh(interactiveModel: "aya-expanse:8b") }
    await probe.waitUntilStarted(1)
    let fresh = Task { await model.refresh(interactiveModel: "aya-expanse:8b") }
    await probe.waitUntilStarted(2)

    await probe.release(call: 1)
    await fresh.value
    #expect(model.status == .notAnswering)

    await probe.release(call: 0)
    await stale.value

    #expect(model.status == .notAnswering, "a stale success overwrote a fresher refusal")
}
