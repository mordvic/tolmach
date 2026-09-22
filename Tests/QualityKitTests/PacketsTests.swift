import Testing
import Foundation
import TranslationCore
@testable import QualityKit

private let source = "Уважаемые коллеги, отчёт за 2026 год необходимо предоставить до 15 марта."
private let facts = [ItemMeta.Fact(id: "deadline", kind: .literal, note: "срок — 15 марта", anyOf: ["15 марта"])]

private func manifest(_ label: String, temperature: Double, external: Bool = false) -> RunManifest {
    RunManifest(label: label, createdAt: "2026-09-22T23:00:00Z", commit: "abc1234", dirty: false,
                engine: "ollama", engineVersion: "0.34.0", chunk: 4000, temperature: temperature,
                corpusPath: "quality-corpus/style", corpusHash: "00ff", external: external,
                filter: MatrixFilter(models: ["m"], levels: [.rewrite], styles: [.friendly], runs: 2))
}

private func record(_ item: String, _ style: RewriteStyle, run: Int, temperature: Double, reply: String,
                    model: String = "m", error: String? = nil) -> CellRecord {
    CellRecord(item: item, language: "ru",
               configuration: .proofread(model: model, temperature: temperature, level: .rewrite, style: style),
               run: run, source: source, reply: reply, facts: facts,
               mechanics: MechanicalChecks.evaluate(source: source, reply: reply, expectedLanguage: .ru,
                                                    sameLanguage: true, facts: facts),
               ttftMS: 1, totalMS: 1, modelChunkCount: 1, markupDiffs: 0, markupNotCompared: false, error: error)
}

private func sides(externalB: Bool = false) -> (Packets.Side, Packets.Side) {
    let a = Packets.Side(manifest: manifest("cold", temperature: 0.2), records: [
        record("ru-memo", .friendly, run: 1, temperature: 0.2, reply: "Коллеги, пришлите отчёт за 2026 год до 15 марта."),
        record("ru-memo", .friendly, run: 2, temperature: 0.2, reply: "Одинаковый ответ за 2026 год до 15 марта."),
        record("ru-note", .friendly, run: 1, temperature: 0.2, reply: "Есть только на одной стороне."),
    ], model: nil)
    let b = Packets.Side(manifest: manifest("warm", temperature: 0.5, external: externalB), records: [
        record("ru-memo", .friendly, run: 1, temperature: 0.5, reply: "Привет! Жду отчёт за 2026 год до 15 марта, спасибо!"),
        record("ru-memo", .friendly, run: 2, temperature: 0.5, reply: "Одинаковый ответ за 2026 год до 15 марта."),
        record("ru-note", .friendly, run: 1, temperature: 0.5, reply: "", error: "connection refused"),
    ], model: nil)
    return (a, b)
}

@Test func aPairIsTheSameTextLevelStyleAndRunIndexAnsweredOnBothSides() throws {
    let (a, b) = sides()
    let built = try Packets.build(a: a, b: b, sample: nil, seed: 1)
    // ru-note failed on one side; run 2 is token-identical and needs no judge.
    #expect(built.key.pairs.count == 1)
    #expect(built.key.identicalPairs == 1)
    #expect(built.key.pairs[0].item == "ru-memo")
    #expect(built.key.pairs[0].run == 1)
}

@Test func everyPairIsTwoPacketsWithTheOrderSwapped() throws {
    let (a, b) = sides()
    let built = try Packets.build(a: a, b: b, sample: nil, seed: 1)
    #expect(built.packets.count == 2)
    let pair = built.key.pairs[0]
    let first = try #require(built.packets.first { $0.id == pair.packets[0].id })
    let second = try #require(built.packets.first { $0.id == pair.packets[1].id })
    #expect(pair.packets[0].xIs != pair.packets[1].xIs)
    #expect(first.x == second.y && first.y == second.x)
    #expect(Set([first.x, first.y]) == Set([a.records[0].reply, b.records[0].reply]))
}

@Test func aPacketCarriesWhatAJudgeNeedsAndNothingThatSaysWhichSideIsWhich() throws {
    let (a, b) = sides()
    let packet = try #require(try Packets.build(a: a, b: b, sample: nil, seed: 1).packets.first)
    #expect(packet.source == source)
    #expect(packet.requestedStyle == "friendly")
    #expect(packet.level == "rewrite")
    #expect(packet.facts == facts)

    let json = String(decoding: try JSONEncoder().encode(packet), as: UTF8.self)
    for leak in ["cold", "warm", "0.2", "0.5", "abc1234", "temperature", "\"m\""] {
        #expect(!json.contains(leak), "the packet leaks «\(leak)»")
    }
}

@Test func aRunOverAnExternalCorpusIsRefusedBeforeAnyPacketExists() {
    // The boundary that is code and not agreement: committed text is already public, a user's
    // working texts are not, and a packet is what a cloud judge is handed.
    let (a, b) = sides(externalB: true)
    #expect(throws: Packets.Failure.externalCorpus(label: "warm")) {
        try Packets.build(a: a, b: b, sample: nil, seed: 1)
    }
}

@Test func theSameSeedBuildsTheSamePacketsAndADifferentSeedADifferentOrder() throws {
    var aRecords: [CellRecord] = [], bRecords: [CellRecord] = []
    for index in 1...12 {
        aRecords.append(record("ru-\(index)", .friendly, run: 1, temperature: 0.2, reply: "Вариант А номер \(index) за 2026 год до 15 марта."))
        bRecords.append(record("ru-\(index)", .friendly, run: 1, temperature: 0.5, reply: "Вариант Б номер \(index) за 2026 год до 15 марта."))
    }
    let a = Packets.Side(manifest: manifest("cold", temperature: 0.2), records: aRecords, model: nil)
    let b = Packets.Side(manifest: manifest("warm", temperature: 0.5), records: bRecords, model: nil)
    let one = try Packets.build(a: a, b: b, sample: nil, seed: 7)
    #expect(try Packets.build(a: a, b: b, sample: nil, seed: 7) == one)
    #expect(try Packets.build(a: a, b: b, sample: nil, seed: 8).packets.map(\.x) != one.packets.map(\.x))
    // Which side is X must not be constant, or «X» is a label for a configuration.
    #expect(Set(one.key.pairs.map { $0.packets[0].xIs }).count == 2)
}

@Test func aSampleTakesFromEveryStyleBeforeItTakesTwiceFromOne() throws {
    var aRecords: [CellRecord] = [], bRecords: [CellRecord] = []
    for style in [RewriteStyle.friendly, .business, .plain] {
        for index in 1...5 {
            aRecords.append(record("ru-\(index)", style, run: 1, temperature: 0.2, reply: "А \(style.rawValue) \(index), 2026, 15 марта"))
            bRecords.append(record("ru-\(index)", style, run: 1, temperature: 0.5, reply: "Б \(style.rawValue) \(index), 2026, 15 марта"))
        }
    }
    let a = Packets.Side(manifest: manifest("cold", temperature: 0.2), records: aRecords, model: nil)
    let b = Packets.Side(manifest: manifest("warm", temperature: 0.5), records: bRecords, model: nil)
    let built = try Packets.build(a: a, b: b, sample: 6, seed: 3)
    #expect(built.key.pairs.count == 6)
    let perStyle = Dictionary(grouping: built.key.pairs, by: \.style).mapValues(\.count)
    #expect(perStyle == ["friendly": 2, "business": 2, "plain": 2])
}

@Test func twoModelsOfOneRunAreTwoSides() throws {
    let run = manifest("models", temperature: 0.2)
    let records = [
        record("ru-memo", .friendly, run: 1, temperature: 0.2, reply: "Ответ первой модели, 2026, 15 марта.", model: "m1"),
        record("ru-memo", .friendly, run: 1, temperature: 0.2, reply: "Ответ второй модели, 2026, 15 марта.", model: "m2"),
    ]
    let built = try Packets.build(a: .init(manifest: run, records: records, model: "m1"),
                                  b: .init(manifest: run, records: records, model: "m2"), sample: nil, seed: 1)
    #expect(built.key.pairs.count == 1)
    #expect(built.key.a.model == "m1" && built.key.b.model == "m2")
}
