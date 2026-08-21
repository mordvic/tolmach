// Tests/LMStudioKitTests/LMStudioClientTests.swift
import Testing
import Foundation
@testable import LMStudioKit
@testable import TranslationCore

@Test func aConnectionRefusalReadsAsTheServerNotRunningAndATimeoutDoesNot() {
    // Same split as `OllamaClient.mapTransportError`, and for the same reason: «nothing is
    // listening» has a remedy the user can act on («Открыть LM Studio»), while «up but slow»
    // does not and must not borrow that message.
    #expect(LMStudioClient.mapTransportError(URLError(.cannotConnectToHost)) as? LMStudioError == .notRunning)
    #expect(LMStudioClient.mapTransportError(URLError(.timedOut)) as? LMStudioError == nil)
}

@Test func anErrorThatIsNotATransportErrorPassesThroughUnchanged() {
    let original = LMStudioError.server(code: "model_not_found", type: nil, message: "нет такой модели")
    #expect(LMStudioClient.mapTransportError(original) as? LMStudioError == original)
}

@Test func theTimeoutsAreTheValuesTheirReasoningWasWrittenFor() {
    // Pinned as literals, like `OllamaTimeoutTests` does: each number's reasoning is on
    // `LMStudioClient.Timeout`, and a change here should force a change there.
    #expect(LMStudioClient.Timeout.interactive == 30)
    #expect(LMStudioClient.Timeout.probe == 10)
    #expect(LMStudioClient.Timeout.load == 120)
    #expect(LMStudioClient.Timeout.downloadPoll == 10)
    // The relation, not just the values: `/api/v1/models/load` answers only when the model *is*
    // loaded — 5.603 s for 8.97 GB and 8.134 s for 12.10 GB, measured 2026-08-21, against a
    // largest local model of 22.81 GB. A ceiling sitting near the slowest measurement would
    // abort a load that was going to succeed.
    #expect(LMStudioClient.Timeout.load > 8.134 * 2)
}

/// **This pins the request builder, not the wiring.** No test in this file drives `chat`,
/// `models`, `load`, `unload` or `download` — a test process has no server to answer them, and
/// `OllamaKitTests` has never stubbed a `URLSession` either. So repointing a call site at
/// another path, or having one build its own `URLRequest` by hand again, would leave this green;
/// what it does catch is the builder itself changing under the six call sites that share it.
/// `docs/reference/TESTING.md`'s shape 5 asks for exactly this sentence rather than for a name
/// that implies coverage nobody has — and a test claiming to prove that `models(from:session:)`
/// *uses* the builder was written here and deleted, because a mutation showed it proved no such
/// thing.
@Test func theRequestBuilderTargetsTheLoopbackPortAndCarriesTheTimeoutAndMethodItWasGiven() {
    let client = LMStudioClient()
    let chat = client.request("api/v1/chat", timeout: LMStudioClient.Timeout.interactive, method: "POST")
    #expect(chat.url?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
    #expect(chat.httpMethod == "POST")
    #expect(chat.timeoutInterval == 30)
    #expect(chat.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let probe = client.request("api/v1/models", timeout: LMStudioClient.Timeout.probe)
    #expect(probe.url?.absoluteString == "http://127.0.0.1:1234/api/v1/models")
    #expect(probe.httpMethod == "GET")
    #expect(probe.timeoutInterval == 10)
    // A GET carries no body, so it must not claim one.
    #expect(probe.value(forHTTPHeaderField: "Content-Type") == nil)
}

@Test func aPortChangesTheAddressAndTheHostStaysOnLoopback() {
    // The host is not configurable anywhere in this module: a free-text address is the one
    // place «text never leaves the machine» would stop being a property of the code.
    #expect(LMStudioClient.baseURL(port: 4567).absoluteString == "http://127.0.0.1:4567")
    #expect(LMStudioClient(port: 4567).request("api/v1/models", timeout: 1).url?.host == "127.0.0.1")
}

@Test func aDownloadIsPolledRatherThanStreamedAndNotFasterThanItsBarCanUse() {
    // A choice rather than a measurement, recorded so that changing it is deliberate: this
    // endpoint has no stream, and a sub-second poll of a multi-gigabyte download buys nothing.
    #expect(LMStudioClient.downloadPollInterval == .seconds(1))
}

@Test func anUnreadCatalogueLeavesReasoningUnsentRatherThanGuessing() async {
    // The fail-safe, exercised through the actor that implements it: a lookup that throws must
    // answer «not known», and `ReasoningChoice` turns that into no key on the wire. Guessing
    // `off` here is what returns HTTP 400 on gpt-oss.
    let catalogue = ModelCatalogue { throw LMStudioError.notRunning }
    let allowed = await catalogue.reasoningOptions(for: "openai/gpt-oss-20b")
    #expect(allowed == nil)
    #expect(ReasoningChoice.value(for: .off, allowed: allowed) == nil)
}

@Test func theCatalogueIsReadOnceForAWholeDocumentAndAgainAfterItChanges() async {
    // A multi-chunk translation must not pay a round trip per chunk; a load, an unload or a
    // download must not leave the answer stale.
    let calls = Counter()
    let catalogue = ModelCatalogue {
        await calls.increment()
        return [LMStudioModel(key: "google/gemma-4-e4b", displayName: "Gemma", sizeBytes: 1,
                              format: "mlx", loadedInstanceIDs: [], reasoningOptions: ["off", "on"])]
    }
    for _ in 0..<5 { _ = await catalogue.reasoningOptions(for: "google/gemma-4-e4b") }
    #expect(await calls.value == 1)
    await catalogue.invalidate()
    #expect(await catalogue.reasoningOptions(for: "google/gemma-4-e4b") == ["off", "on"])
    #expect(await calls.value == 2)
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
