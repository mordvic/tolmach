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

@Test func reloadingAfterAnOutsideEditLetsSavingWorkAgain() throws {
    // The dead end Task 9 left behind, and the contract the «Перечитать файл» button rests
    // on. Once `save()` starts throwing `fileChangedOnDisk` nothing else in the app can
    // clear the condition, so saving stays broken for the rest of the session — the app is
    // `LSUIElement` and that session can be days long. `load()` is the only way out, and it
    // only is one because it re-stamps: without that, the second save would compare against
    // the launch-time stamp again and refuse just the same.
    let url = tempURL()
    let atLaunch = #"{"entries":[],"mutedTerms":["alpha"]}"#
    try atLaunch.write(to: url, atomically: true, encoding: .utf8)
    let store = GlossaryStore(url: url)
    try store.load()

    let handEdited = #"{"entries":[],"mutedTerms":["omega"]}"#
    try handEdited.write(to: url, atomically: true, encoding: .utf8)
    store.mute("beta")
    #expect(throws: GlossaryStoreError.fileChangedOnDisk) { try store.save() }

    // The button: re-read, then carry on. The user's hand-edit is now what the store holds,
    // and the refused change is gone with it — which is the honest outcome, since the store
    // never wrote it.
    try store.load()
    #expect(store.mutedSet == ["omega"])
    store.mute("beta")
    try store.save()

    let reloaded = GlossaryStore(url: url)
    try reloaded.load()
    #expect(reloaded.mutedSet == ["omega", "beta"])
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

@Test func aGlossaryEntryEncodesTheSameJSONNowThatItIsMutable() throws {
    // `GlossaryEntry`'s stored properties became `var` so the glossary tab can bind editable
    // fields to a row. That is a change to a `Codable` type whose encoded form is a
    // hand-edited, git-tracked file (spec 9), so the shape has to be pinned rather than
    // assumed: a renamed property or an accidental `CodingKeys` would silently orphan every
    // glossary already on disk. `.sortedKeys` matches what `GlossaryStore.save()` writes.
    let entry = GlossaryEntry(term: "FHIR", doNotTranslate: true, translations: ["ru": "ФХИР"])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(data: try encoder.encode(entry), encoding: .utf8)
    #expect(json == #"{"doNotTranslate":true,"term":"FHIR","translations":{"ru":"ФХИР"}}"#)
    #expect(try JSONDecoder().decode(GlossaryEntry.self, from: Data(json!.utf8)) == entry)
}

@Test func anEntryEditedInPlaceRoundTripsThroughTheFile() throws {
    // What the glossary tab actually does. Its rows bind to elements of `file.entries`, so
    // an edit lands on an existing element rather than replacing the array — only
    // expressible because the three stored properties are `var`. All three are exercised
    // here, since each one is a separate binding in the tab.
    let url = tempURL()
    let store = GlossaryStore(url: url)
    try store.load()
    store.file.entries = [GlossaryEntry(term: "profile server", doNotTranslate: true)]
    store.file.entries[0].term = "Profile Server"
    store.file.entries[0].doNotTranslate = false
    store.file.entries[0].translations["ru"] = "сервер профилей"
    try store.save()

    let reloaded = GlossaryStore(url: url)
    try reloaded.load()
    #expect(reloaded.file.entries == [GlossaryEntry(term: "Profile Server",
                                                    translations: ["ru": "сервер профилей"])])
}

@Test func duplicateTermsSurviveAsTwoSeparateEntries() throws {
    // Why the tab lists rows by index rather than by term. Nothing on the path into
    // `file.entries` uniques them — the file is hand-edited and the «+» button appends —
    // so two rows can carry the same term, and a `Table` or a `ForEach` keyed by `term`
    // would render one of them and silently drop the other's translation.
    let url = tempURL()
    let store = GlossaryStore(url: url)
    try store.load()
    store.file.entries = [
        GlossaryEntry(term: "server", translations: ["ru": "сервер"]),
        GlossaryEntry(term: "server", translations: ["de": "Server"]),
    ]
    try store.save()

    let reloaded = GlossaryStore(url: url)
    try reloaded.load()
    #expect(reloaded.file.entries.count == 2)
    #expect(reloaded.file.entries.map(\.translations) == [["ru": "сервер"], ["de": "Server"]])
}

@Test func aFailedReloadLocksTheStoreInsteadOfArmingAClobber() throws {
    // The reload button's failure path. `load()` stamps the file before it reads it, so a
    // decode that throws leaves the stamp already moved to the file it could not read. If
    // `isLoaded` also survived from the successful launch load, the next save would pass
    // both of `save()`'s guards and write this session's copy straight over the user's
    // broken file — Task 9's clobber, reached backwards through the button meant to help.
    let url = tempURL()
    try #"{"entries":[],"mutedTerms":["alpha"]}"#.write(to: url, atomically: true, encoding: .utf8)
    let store = GlossaryStore(url: url)
    try store.load()
    #expect(store.isLoaded)

    let broken = "{ not json"
    try broken.write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(store.isLoaded == false)

    // The store still holds the launch-time entries, and must not be able to write them.
    #expect(store.mutedSet == ["alpha"])
    #expect(throws: GlossaryStoreError.saveBeforeLoad) { try store.save() }
    #expect(try String(contentsOf: url, encoding: .utf8) == broken)

    // And the way out still works once the user fixes the file.
    try #"{"entries":[],"mutedTerms":["beta"]}"#.write(to: url, atomically: true, encoding: .utf8)
    try store.load()
    #expect(store.mutedSet == ["beta"])
    store.mute("gamma")
    try store.save()
}

// MARK: - The file the user actually keeps

/// `write(to:options:.atomic)` writes a temporary file and renames it into place, which replaces
/// a symlinked `glossary.json` with a regular file. This file is *designed* to be hand-edited and
/// git-tracked (spec 9), so linking it into a dotfiles repository is the documented workflow —
/// and the first save silently broke the link, after which every edit went to a copy the
/// repository no longer saw. The stamp had the same blindness: it described the link.
@MainActor @Test func savingThroughASymlinkKeepsTheSymlink() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("glossary-symlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let real = directory.appendingPathComponent("real.json")
    try Data(#"{"entries":[],"mutedTerms":[]}"#.utf8).write(to: real)
    let link = directory.appendingPathComponent("glossary.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let store = GlossaryStore(url: link)
    try store.load()
    store.replaceEntries([GlossaryEntry(term: "resource", translations: ["ru": "ресурс"])])
    try store.save()

    // The link survives…
    let kind = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
    #expect(kind == .typeSymbolicLink, "the atomic write replaced the symlink with a regular file")
    // …and the bytes landed in the file the user actually keeps.
    let written = try String(contentsOf: real, encoding: .utf8)
    #expect(written.contains("resource"))
}

/// A second save in the same session must still work — the stamp is taken of the resolved file,
/// so it has to be compared against the resolved file too, or the store accuses itself.
@MainActor @Test func asecondSaveThroughASymlinkIsNotMistakenForAnEditBehindOurBack() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("glossary-symlink-twice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let real = directory.appendingPathComponent("real.json")
    try Data(#"{"entries":[],"mutedTerms":[]}"#.utf8).write(to: real)
    let link = directory.appendingPathComponent("glossary.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let store = GlossaryStore(url: link)
    try store.load()
    store.replaceEntries([GlossaryEntry(term: "a", translations: ["ru": "а"])])
    try store.save()
    store.replaceEntries([GlossaryEntry(term: "b", translations: ["ru": "б"])])
    try store.save()

    #expect(try String(contentsOf: real, encoding: .utf8).contains("\"b\""))
}
