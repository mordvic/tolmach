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

@Test func savingBeforeLoadingRefusesAndLeavesNoFileBehind() throws {
    // The clobber this gate exists to prevent: a store that has never read the user's
    // file holds an empty `GlossaryFile`, so a save would write emptiness over a
    // hand-authored glossary. Throwing is only half the requirement — a save that threw
    // *after* writing would have destroyed the data just the same, so the absence of the
    // file is the assertion that matters.
    let url = tempURL()
    let store = GlossaryStore(url: url)
    #expect(!store.isLoaded)
    #expect(throws: GlossaryStoreError.saveBeforeLoad) { try store.save() }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func loadingFirstUnlocksSavingAndTheFileRoundTrips() throws {
    let url = tempURL()
    let store = GlossaryStore(url: url)
    try store.load()
    #expect(store.isLoaded)
    store.mute("FHIR")
    try store.save()
    #expect(FileManager.default.fileExists(atPath: url.path))

    let reloaded = GlossaryStore(url: url)
    try reloaded.load()
    #expect(reloaded.file == store.file)
    #expect(reloaded.mutedSet.contains("fhir"))
}

@Test func aFileEditedBehindTheAppsBackIsNotOverwritten() throws {
    // The long-running-app clobber. `load()` succeeded at launch, the app sat in the menu
    // bar for days, the user hand-edited glossary.json — the workflow the file is designed
    // for — and then clicked «не показывать». Writing the launch-time snapshot here would
    // take the whole file with it, `entries` included. As with the load gate, throwing is
    // only half of it: what matters is that the user's bytes are still on disk afterwards.
    let url = tempURL()
    let atLaunch = #"{"entries":[{"doNotTranslate":true,"term":"FHIR","translations":{}}],"mutedTerms":["alpha"]}"#
    try atLaunch.write(to: url, atomically: true, encoding: .utf8)
    let store = GlossaryStore(url: url)
    try store.load()

    // Deliberately the same byte length as `atLaunch`: the store also compares file size,
    // and an edit that changed the length would let the test pass on size alone without
    // ever exercising the modification date the check is built on.
    let handEdited = #"{"entries":[{"doNotTranslate":true,"term":"FHIR","translations":{}}],"mutedTerms":["omega"]}"#
    #expect(handEdited.utf8.count == atLaunch.utf8.count)
    try handEdited.write(to: url, atomically: true, encoding: .utf8)

    store.mute("profile server")
    #expect(throws: GlossaryStoreError.fileChangedOnDisk) { try store.save() }
    #expect(try String(contentsOf: url, encoding: .utf8) == handEdited)
}

@Test func aFileCreatedByHandAfterAnEmptyFirstLaunchIsNotOverwritten() throws {
    // `load()` found no file, so there was no modification date to capture. That absence
    // is itself the stamp: a file existing now means someone created it between launch and
    // this save, and it is no more overwritable than one that was edited.
    let url = tempURL()
    let store = GlossaryStore(url: url)
    try store.load()

    let handWritten = #"{"entries":[{"doNotTranslate":true,"term":"FHIR","translations":{}}],"mutedTerms":[]}"#
    try handWritten.write(to: url, atomically: true, encoding: .utf8)

    store.mute("profile server")
    #expect(throws: GlossaryStoreError.fileChangedOnDisk) { try store.save() }
    #expect(try String(contentsOf: url, encoding: .utf8) == handWritten)
}

@Test func aSecondSaveInTheSameSessionSucceeds() throws {
    // The app's own write moves the modification date, so the stamp has to be re-taken
    // after it. Otherwise the check fires on the store's own previous save and the second
    // «не показывать» of a session fails for no reason.
    let url = tempURL()
    let store = GlossaryStore(url: url)
    try store.load()
    store.mute("FHIR")
    try store.save()
    store.mute("profile server")
    try store.save()

    let reloaded = GlossaryStore(url: url)
    try reloaded.load()
    #expect(reloaded.mutedSet == ["fhir", "profile server"])
}

@Test func aFailedLoadLeavesTheStoreLockedSoTheBadFileSurvives() throws {
    // C2.2's promise in test form: a malformed file is recorded, not swallowed, and
    // because the gate never opened nothing downstream can overwrite it.
    let url = tempURL()
    try "{ not json".write(to: url, atomically: true, encoding: .utf8)
    let store = GlossaryStore(url: url)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(!store.isLoaded)
    #expect(throws: GlossaryStoreError.saveBeforeLoad) { try store.save() }
    #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
}
