import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

private func scratchDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("writer-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func aTranslationIsWrittenAsUTF8BesideItsSourceAndSaysWhere() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("doc.md")
    try Data("source".utf8).write(to: source)

    guard case let .saved(written) = TranslatedFileWriter.write("Привет, мир.", beside: source, target: .ru)
    else { Issue.record("expected the write to succeed"); return }

    #expect(written.lastPathComponent == "doc.ru.md")
    #expect(try String(contentsOf: written, encoding: .utf8) == "Привет, мир.")
}

@Test func theReturnedURLIsWhereTheBytesWentEvenWhenTheFirstNameWasTaken() throws {
    // The whole reason naming and writing are one call. Asking OutputNaming again after
    // the write finds the name taken by that very write and answers with the next number
    // — a «показать в Finder» link pointing at a file that does not exist.
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("doc.md")
    try Data("source".utf8).write(to: source)
    try Data("занято".utf8).write(to: directory.appendingPathComponent("doc.ru.md"))

    guard case let .saved(written) = TranslatedFileWriter.write("новый перевод", beside: source, target: .ru)
    else { Issue.record("expected the write to succeed"); return }

    #expect(written.lastPathComponent == "doc.ru 2.md")
    #expect(try String(contentsOf: written, encoding: .utf8) == "новый перевод")
    // And the file that was already there is untouched.
    #expect(try String(contentsOf: directory.appendingPathComponent("doc.ru.md"),
                       encoding: .utf8) == "занято")
}

@Test func aRefusedWriteComesBackAsARussianSentenceAndNotAnNSErrorDump() {
    let denied = URL(fileURLWithPath: "/System/definitely-not-writable/doc.md")
    guard case let .refused(message) = TranslatedFileWriter.write("текст", beside: denied, target: .ru)
    else { Issue.record("expected the write to be refused"); return }
    // The user reads this. An NSCocoaErrorDomain description is English and names a
    // domain nobody outside this process has heard of.
    #expect(message.contains("Не удалось сохранить"))
    #expect(!message.contains("NSCocoaErrorDomain"))
}

@Test func aMoveIntoPlaceRefusesToClobberAnExistingFile() throws {
    // The guarantee the whole naming rule rests on, pinned against Foundation rather than
    // assumed. `.withoutOverwriting` cannot be combined with `.atomic` — measured: Foundation
    // does not return an error for that pair, it traps with «withoutOverwriting is not
    // supported with atomic» — so the write goes to a temporary sibling atomically and then
    // moves, and it is `moveItem` that has to refuse.
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let taken = directory.appendingPathComponent("taken.md")
    try Data("не трогать".utf8).write(to: taken)
    let temporary = directory.appendingPathComponent("temp")
    try Data("новое".utf8).write(to: temporary, options: .atomic)

    #expect(throws: (any Error).self) {
        try FileManager.default.moveItem(at: temporary, to: taken)
    }
    #expect(try String(contentsOf: taken, encoding: .utf8) == "не трогать")
}

@Test func aTornWriteLeavesNoHalfDocumentBesideTheSource() throws {
    // The destination only ever appears complete: the bytes land in a temporary sibling
    // first, so a process killed or a disk filled partway through leaves that behind rather
    // than a truncated file that OutputNaming would thereafter treat as «taken».
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("doc.md")
    try Data("source".utf8).write(to: source)

    guard case let .saved(written) = TranslatedFileWriter.write("перевод", beside: source, target: .ru)
    else { Issue.record("expected the write to succeed"); return }

    #expect(try String(contentsOf: written, encoding: .utf8) == "перевод")
    // Nothing left over.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(leftovers.sorted() == ["doc.md", "doc.ru.md"])
}

@Test func aNameTakenBetweenTheCheckAndTheMoveCostsANumberAndNotTheDocument() throws {
    // The whole point of the naming scheme, and it was not happening: `moveItem` threw on
    // the occupied name and the user was told «воспользуйтесь "Сохранить как…"» — a
    // permission answer to a collision.
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("doc.md")
    try Data("source".utf8).write(to: source)
    // Occupied *after* a caller would have chosen it, which is what the race produces.
    try Data("занято".utf8).write(to: directory.appendingPathComponent("doc.ru.md"))

    guard case let .saved(written) = TranslatedFileWriter.write("перевод", beside: source, target: .ru)
    else { Issue.record("expected the write to succeed"); return }

    #expect(written.lastPathComponent == "doc.ru 2.md")
    #expect(try String(contentsOf: written, encoding: .utf8) == "перевод")
    #expect(try String(contentsOf: directory.appendingPathComponent("doc.ru.md"),
                       encoding: .utf8) == "занято")
}

@Test func aTemporaryAbandonedByAKilledProcessIsSweptUpByTheNextWrite() throws {
    // The temporary is removed on every failure path inside the write, but not by a process
    // that dies between `Data.write` and `moveItem`. Nothing else cleans them up, so each
    // interrupted save left another hidden file beside the user's document for ever.
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("doc.md")
    try Data("source".utf8).write(to: source)

    let abandoned = directory.appendingPathComponent(".tolmach-\(UUID().uuidString).partial")
    try Data("half a translation".utf8).write(to: abandoned)
    // Backdated past the hour: a temporary younger than that may belong to a save in flight
    // in another window, and sweeping it would break that save to tidy up after this one.
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: abandoned.path)

    guard case .saved = TranslatedFileWriter.write("перевод", beside: source, target: .ru)
    else { Issue.record("expected the write to succeed"); return }

    #expect(FileManager.default.fileExists(atPath: abandoned.path) == false)
}

@Test func aTemporaryThatCouldStillBelongToASaveInFlightIsLeftAlone() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("doc.md")
    try Data("source".utf8).write(to: source)

    // Just written, i.e. exactly the shape of another window's temporary mid-move.
    let inFlight = directory.appendingPathComponent(".tolmach-\(UUID().uuidString).partial")
    try Data("someone else's bytes".utf8).write(to: inFlight)
    // And an unrelated dotfile, which is none of this sweep's business whatever its age.
    let unrelated = directory.appendingPathComponent(".DS_Store")
    try Data("x".utf8).write(to: unrelated)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: unrelated.path)

    guard case .saved = TranslatedFileWriter.write("перевод", beside: source, target: .ru)
    else { Issue.record("expected the write to succeed"); return }

    #expect(FileManager.default.fileExists(atPath: inFlight.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}
