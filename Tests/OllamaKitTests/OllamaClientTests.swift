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
