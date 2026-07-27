import Testing
import Foundation
@testable import TranslatorApp
@testable import TranslationCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("glossary-\(UUID().uuidString).json")
}

@Test func aMissingFileLoadsAsEmptyRatherThanThrowing() throws {
    // First launch has no file; that is normal, not an error.
    let store = GlossaryStore(url: tempURL())
    try store.load()
    #expect(store.file.entries.isEmpty)
    #expect(store.file.mutedTerms.isEmpty)
}

@Test func entriesAndMutedTermsRoundTrip() throws {
    let url = tempURL()
    let store = GlossaryStore(url: url)
    try store.load()
    store.file.entries = [
        GlossaryEntry(term: "FHIR", doNotTranslate: true),
        GlossaryEntry(term: "profile server", translations: ["ru": "сервер профилей"]),
    ]
    store.mute("profile server")
    try store.save()

    let reloaded = GlossaryStore(url: url)
    try reloaded.load()
    #expect(reloaded.file == store.file)
    #expect(reloaded.mutedSet.contains("profile server"))
    #expect(reloaded.glossary.entries.count == 2)
}

@Test func mutingIsIdempotentAndCaseInsensitive() throws {
    let store = GlossaryStore(url: tempURL())
    try store.load()
    store.mute("Profile Server")
    store.mute("profile server")
    #expect(store.file.mutedTerms.count == 1)
    // GlossaryVerifier lowercases both sides, so the stored form only has to be stable.
    #expect(store.mutedSet.contains("profile server"))
}

@Test func aCorruptFileFailsLoudlyRatherThanSilentlyDiscardingTheUsersGlossary() throws {
    let url = tempURL()
    try "{ not json".write(to: url, atomically: true, encoding: .utf8)
    let store = GlossaryStore(url: url)
    #expect(throws: (any Error).self) { try store.load() }
    // And nothing was overwritten: the bad file is still on disk for the user to fix.
    #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
}
