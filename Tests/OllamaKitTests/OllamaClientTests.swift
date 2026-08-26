// Tests/OllamaKitTests/OllamaClientTests.swift
import Foundation
import Testing
@testable import OllamaKit
@testable import TranslationCore

@Test func connectionRefusedBecomesNotRunning() {
    let mapped = OllamaClient.mapTransportError(URLError(.cannotConnectToHost))
    #expect(mapped as? OllamaError != nil)
    if case .notRunning = mapped as? OllamaError { } else { Issue.record("expected .notRunning") }
}

@Test func aTimeoutIsNotMistakenForNotRunning() {
    // Ollama is running but slow — a different problem with a different remedy.
    let mapped = OllamaClient.mapTransportError(URLError(.timedOut))
    #expect((mapped as? OllamaError) == nil)
}

@Test func anUnrelatedErrorPassesThroughUnchanged() {
    let original = OllamaError.decoding("bad shape")
    let mapped = OllamaClient.mapTransportError(original)
    #expect(mapped is OllamaError)
}

// MARK: - The loopback address is written once, and building it cannot trap

/// `defaultBaseURL` is the literal; `baseURL(port:)` is the same address parameterised. They
/// have to agree, or a caller that varies the port silently talks somewhere else.
@Test func theDefaultAddressAndTheBuilderAgreeOnTheDefaultPort() {
    #expect(OllamaClient.baseURL(port: OllamaClient.defaultPort) == OllamaClient.defaultBaseURL)
    #expect(OllamaClient.baseURL() == OllamaClient.defaultBaseURL)
    #expect(OllamaClient.baseURL(port: 11435).absoluteString == "http://127.0.0.1:11435")
}

/// The trap this replaced: `URL(string: "http://127.0.0.1:-1")` answers nil, and the app
/// force-unwrapped it — so a stored `-1` crashed the process at every launch. The app clamps
/// the setting, which is the real guarantee; this is what stops the next caller from needing to
/// know that. Degrading to the default address is right here because the alternative is a trap,
/// and because the host — the part that carries the privacy promise — is identical either way.
@Test func aPortThatCannotFormAURLFallsBackInsteadOfTrapping() {
    for impossible in [-1, -65535] {
        #expect(OllamaClient.baseURL(port: impossible) == OllamaClient.defaultBaseURL)
    }
    // Whatever it answers, it is on loopback. That is the property the fallback must not lose.
    #expect(OllamaClient.baseURL(port: -1).host == "127.0.0.1")
}
