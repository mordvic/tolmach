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
