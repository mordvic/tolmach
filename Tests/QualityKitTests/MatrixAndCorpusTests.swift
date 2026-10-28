import Testing
import Foundation
import TranslationCore
@testable import QualityKit

private func item(_ name: String, _ language: Language = .ru) -> CorpusItem {
    CorpusItem(name: name, language: language, text: "текст", meta: nil)
}

// MARK: matrix

@Test func aNamedStyleBringsItsControlEvenWhenNobodyAskedForIt() {
    // «Как в оригинале» is the control every named style is measured against, not a fifth
    // style under test: without it «the style was not applied» cannot be told from «the level
    // changed the text».
    let filter = MatrixFilter(models: ["m"], levels: [.rewrite], styles: [.friendly], runs: 1)
    let styles = Matrix.cells(items: [item("a")], filter: filter, temperature: 0.2).map(\.configuration.style)
    #expect(styles == ["original", "friendly"])
}

@Test func aLevelThatAllowsNoStyleRunsTheControlAloneAndOnce() {
    // `ProofreadingLevel.allowsRewriteStyle` is the one rule; «только ошибки» × four styles
    // would be four copies of the same request.
    let filter = MatrixFilter(models: ["m"], levels: [.errorsOnly], styles: [.friendly, .business], runs: 2)
    let cells = Matrix.cells(items: [item("a")], filter: filter, temperature: 0.2)
    #expect(cells.map(\.configuration.style) == ["original", "original"])
    #expect(cells.map(\.run) == [1, 2])
}

@Test func cellsAreOrderedModelFirstSoOneModelStaysResidentForItsWholeShare() {
    let filter = MatrixFilter(models: ["m1", "m2"], levels: [.rewrite], styles: [.original], runs: 1)
    let cells = Matrix.cells(items: [item("a"), item("b")], filter: filter, temperature: 0.2)
    #expect(cells.map { "\($0.configuration.model)/\($0.item.name)" } == ["m1/a", "m1/b", "m2/a", "m2/b"])
}

@Test func onlyKeepsTheNamedItemsAndTheFullMatrixIsItemsTimesLevelsTimesStylesTimesRuns() {
    let items = [item("a"), item("b"), item("c")]
    let all = MatrixFilter(models: ["m"], levels: [.errorsAndStyle, .rewrite],
                           styles: [.friendly, .business, .professional, .plain], runs: 3)
    #expect(Matrix.cells(items: items, filter: all, temperature: 0.2).count == 3 * 2 * 5 * 3)
    var narrowed = all
    narrowed.only = ["b"]
    #expect(Set(Matrix.cells(items: items, filter: narrowed, temperature: 0.2).map(\.item.name)) == ["b"])
}

@Test func aCellsFileNameIsStableAndSafeForAModelTagWithAColonAndASlash() {
    let filter = MatrixFilter(models: ["hf.co/org/model:12b"], levels: [.rewrite], styles: [.original], runs: 1)
    let cell = Matrix.cells(items: [item("ru-memo")], filter: filter, temperature: 0.5)[0]
    #expect(cell.fileName == "ru-memo__hf.co_org_model_12b__t0.50__rewrite__original__r1.json")
}

// MARK: corpus

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("quality-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func aTextWithoutASidecarTakesItsLanguageFromItsNamePrefix() throws {
    // `docs/proofreading-gate` has no sidecars and must load as it is — three scripts and
    // recorded measurements depend on its layout.
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "She don't know.".write(to: dir.appendingPathComponent("en-grammar.txt"), atomically: true, encoding: .utf8)
    try "Он незнает.".write(to: dir.appendingPathComponent("ru-spelling.txt"), atomically: true, encoding: .utf8)
    let items = try CorpusLoader.load(directory: dir)
    #expect(items.map(\.name) == ["en-grammar", "ru-spelling"])
    #expect(items.map(\.language) == [.en, .ru])
    #expect(items[0].meta == nil)
}

@Test func aSidecarIsReadAndItsFactsReachTheItem() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "Срок — 15 марта.".write(to: dir.appendingPathComponent("ru-memo.txt"), atomically: true, encoding: .utf8)
    let meta = ItemMeta(genre: "memo", language: "ru", register: "dry", mirror: "en-memo",
                        facts: [.init(id: "deadline", kind: .literal, note: "срок", anyOf: ["15 марта"])], traps: [])
    try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("ru-memo.meta.json"))
    let items = try CorpusLoader.load(directory: dir)
    #expect(items.count == 1)
    #expect(items[0].meta == meta)
}

@Test func aSidecarThatContradictsTheFileNameIsRefusedByName() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "Text.".write(to: dir.appendingPathComponent("ru-memo.txt"), atomically: true, encoding: .utf8)
    let meta = ItemMeta(genre: "memo", language: "en", register: "dry", mirror: nil, facts: [], traps: [])
    try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("ru-memo.meta.json"))
    #expect(throws: CorpusLoader.Failure.languageDisagrees(item: "ru-memo", name: "ru", sidecar: "en")) {
        try CorpusLoader.load(directory: dir)
    }
}

@Test func aTextWhoseLanguageNothingStatesIsRefusedRatherThanDetected() throws {
    // A detector's guess would put a run's language column on the same footing as the thing
    // being measured.
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "Text.".write(to: dir.appendingPathComponent("memo.txt"), atomically: true, encoding: .utf8)
    #expect(throws: CorpusLoader.Failure.languageUnknown(item: "memo")) {
        try CorpusLoader.load(directory: dir)
    }
}

@Test func theCorpusHashMovesWithOneByteOfOneTextAndNotWithTheDirectorysPath() throws {
    let a = try temporaryDirectory(), b = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    for dir in [a, b] {
        try "Он незнает.".write(to: dir.appendingPathComponent("ru-x.txt"), atomically: true, encoding: .utf8)
    }
    let same = try CorpusLoader.hash(of: CorpusLoader.load(directory: a))
    #expect(try CorpusLoader.hash(of: CorpusLoader.load(directory: b)) == same)
    try "Он не знает.".write(to: b.appendingPathComponent("ru-x.txt"), atomically: true, encoding: .utf8)
    #expect(try CorpusLoader.hash(of: CorpusLoader.load(directory: b)) != same)
}

// MARK: run directory

private func manifest(label: String = "night", temperature: Double = 0.2) -> RunManifest {
    RunManifest(label: label, createdAt: "2026-09-22T23:00:00Z", commit: "abc1234", dirty: false,
                engine: "ollama", engineVersion: "0.34.0", chunk: 4000, temperature: temperature,
                corpusPath: "quality-corpus/style", corpusHash: "00ff", external: false,
                filter: MatrixFilter(models: ["m"], levels: [.rewrite], styles: [.friendly], runs: 1))
}

private func record(for cell: Cell, reply: String = "ответ") -> CellRecord {
    CellRecord(item: cell.item.name, language: cell.item.language.rawValue, configuration: cell.configuration,
               run: cell.run, source: cell.item.text, reply: reply, facts: [],
               mechanics: MechanicalChecks.evaluate(source: cell.item.text, reply: reply, expectedLanguage: .ru,
                                                    sameLanguage: true, facts: []),
               ttftMS: 100, totalMS: 900, modelChunkCount: 1, markupDiffs: 0, markupNotCompared: false, error: nil)
}

@Test func aWrittenCellIsFoundAgainSoAnInterruptedNightIsResumedAndNotRepeated() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try RunDirectory.open(at: dir, manifest: manifest())
    let cells = Matrix.cells(items: [item("a")], filter: manifest().filter, temperature: 0.2)
    #expect(!run.has(cells[0]))
    try run.write(record(for: cells[0]))

    let reopened = try RunDirectory.open(at: dir, manifest: manifest())
    #expect(reopened.has(cells[0]))
    #expect(!reopened.has(cells[1]))
    #expect(try reopened.records().map(\.reply) == ["ответ"])
}

@Test func reopeningADirectoryUnderADifferentConfigurationIsRefused() throws {
    // Two temperatures in one directory would be one table describing two experiments.
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try RunDirectory.open(at: dir, manifest: manifest(temperature: 0.2))
    #expect(throws: RunDirectory.Failure.self) {
        try RunDirectory.open(at: dir, manifest: manifest(temperature: 0.5))
    }
}

@Test func reopeningLaterOnADifferentDayIsNotADifferentConfiguration() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try RunDirectory.open(at: dir, manifest: manifest())
    var later = manifest()
    later.createdAt = "2026-09-23T07:00:00Z"
    let reopened = try RunDirectory.open(at: dir, manifest: later)
    // The directory keeps the manifest it was created with.
    #expect(reopened.manifest.createdAt == "2026-09-22T23:00:00Z")
}

@Test func aFailedCellIsNotCountedAsDoneSoTheNextNightRetriesIt() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try RunDirectory.open(at: dir, manifest: manifest())
    let cell = Matrix.cells(items: [item("a")], filter: manifest().filter, temperature: 0.2)[0]
    var failed = record(for: cell, reply: "")
    failed.error = "connection refused"
    try run.write(failed)
    #expect(!run.has(cell))
}

// MARK: what the review of 2026-09-22 found

@Test func aRecordWrittenBeforeAFieldExistedStillReads() throws {
    // A run directory is a night of model time. A schema that refuses yesterday's file turns
    // «a corrected check corrects last night's table» into «a new field deletes it».
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try RunDirectory.open(at: dir, manifest: manifest())
    let cell = Matrix.cells(items: [item("a")], filter: manifest().filter, temperature: 0.2)[0]
    try run.write(record(for: cell))

    let file = dir.appendingPathComponent("cells").appendingPathComponent(cell.fileName)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    json["facts"] = nil
    json["addedBlocks"] = nil
    json["mechanics"] = ["flags": ["aFlagFromAnotherEra"]]
    try JSONSerialization.data(withJSONObject: json).write(to: file)

    let records = try run.records()
    #expect(records.count == 1)
    #expect(records[0].facts == [])
    #expect(records[0].mechanics == nil)
    #expect(run.has(cell))
}

@Test func aFileThatIsNotARecordIsCountedAndDoesNotCostTheOthers() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try RunDirectory.open(at: dir, manifest: manifest())
    let cell = Matrix.cells(items: [item("a")], filter: manifest().filter, temperature: 0.2)[0]
    try run.write(record(for: cell))
    try Data("{ half a file".utf8).write(to: dir.appendingPathComponent("cells/torn.json"))
    let read = try run.read()
    #expect(read.records.count == 1)
    #expect(read.unreadable == ["torn.json"])
}

@Test func aResumeUnderAnotherLabelOrATrailingSlashIsTheSameRun() throws {
    // The printed hint says «resume with --into <dir>» and nothing about repeating --label.
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try RunDirectory.open(at: dir, manifest: manifest(label: "t05"))
    var resumed = manifest(label: "run")
    resumed.corpusPath = "quality-corpus/style/"
    #expect(try RunDirectory.open(at: dir, manifest: resumed).manifest.label == "t05")
}

@Test func aRefusedResumeNamesWhatDiffers() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try RunDirectory.open(at: dir, manifest: manifest(temperature: 0.2))
    var other = manifest(temperature: 0.5)
    other.commit = "fffffff"
    do {
        _ = try RunDirectory.open(at: dir, manifest: other)
        Issue.record("a different temperature and commit were accepted")
    } catch let failure as RunDirectory.Failure {
        #expect(failure.description.contains("temperature (0.2 → 0.5)"))
        #expect(failure.description.contains("commit (abc1234 → fffffff)"))
        #expect(!failure.description.contains("chunk"))
    }
}
