import Testing
import Foundation
import TranslationCore
@testable import QualityKit

/// Answers every call from a closure and remembers what it was asked.
private final class ScriptedClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(messages: [ChatMessage], options: ChatOptions)] = []
    private let answer: @Sendable ([ChatMessage]) throws -> String

    init(answer: @escaping @Sendable ([ChatMessage]) throws -> String) { self.answer = answer }

    var calls: [(messages: [ChatMessage], options: ChatOptions)] { lock.withLock { seen } }

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.withLock { seen.append((messages, options)) }
        return AsyncThrowingStream { continuation in
            do {
                continuation.yield(.token(try answer(messages)))
                continuation.yield(.done(ChatStats(loadDurationMS: 0, promptEvalCount: 1, promptEvalDurationMS: 1,
                                                   evalCount: 1, evalDurationMS: 1)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private struct Refused: Error, CustomStringConvertible { var description: String { "connection refused" } }

private let memo = CorpusItem(
    name: "ru-memo", language: .ru,
    text: "Уважаемые коллеги, отчёт за 2026 год необходимо предоставить до 15 марта.",
    meta: ItemMeta(genre: "memo", language: "ru", register: "dry", mirror: nil,
                   facts: [.init(id: "deadline", kind: .literal, note: "срок", anyOf: ["15 марта"])], traps: []))

private func cell(_ style: RewriteStyle, model: String = "translategemma:12b", run: Int = 1,
                  temperature: Double = 0.5) -> Cell {
    Cell(item: memo, configuration: .proofread(model: model, temperature: temperature, level: .rewrite, style: style),
         run: run)
}

// MARK: runner

@Test func aCellIsRunThroughTheAppsOwnRouteWithItsModelTemperatureAndStyle() async throws {
    let client = ScriptedClient { _ in "Коллеги, пришлите, пожалуйста, отчёт за 2026 год до 15 марта!" }
    let record = try await Runner(translator: Translator(client: client), chunk: 4000).run(cell(.friendly))

    #expect(record.reply == "Коллеги, пришлите, пожалуйста, отчёт за 2026 год до 15 марта!")
    #expect(record.source == memo.text)
    #expect(record.error == nil)
    #expect(!record.mechanics.idle)
    #expect(record.mechanics.flags == [])

    let call = try #require(client.calls.first)
    #expect(call.options.model == "translategemma:12b")
    #expect(call.options.temperature == 0.5)
    // The style reached the prompt through `PromptBuilder`, not through a copy of it here.
    let instruction = try #require(RewriteStyle.friendly.instruction)
    #expect(call.messages.contains { $0.content.contains(instruction) })
}

@Test func reasoningIsRequestedByTheAppsPolicyAtItsDefaultsNotByAUsersSettings() async throws {
    let client = ScriptedClient { _ in "ответ" }
    let runner = Runner(translator: Translator(client: client), chunk: 4000)
    _ = try await runner.run(cell(.original, model: "gpt-oss:20b"))
    _ = try await runner.run(cell(.original, model: "translategemma:12b"))
    #expect(client.calls.map(\.options.think) == [.level(.low), .off])
}

@Test func aTransportFailureIsRecordedAndDoesNotEndTheNight() async throws {
    let client = ScriptedClient { _ in throw Refused() }
    let record = try await Runner(translator: Translator(client: client), chunk: 4000).run(cell(.friendly))
    #expect(record.error == "connection refused")
    #expect(record.reply.isEmpty)
}

@Test func aCancellationIsNotAFailedCellItEndsTheRun() async throws {
    let client = ScriptedClient { _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) {
        try await Runner(translator: Translator(client: client), chunk: 4000).run(cell(.friendly))
    }
}

// MARK: report

private func record(_ style: RewriteStyle, run: Int, reply: String, error: String? = nil,
                    totalMS: Double = 1000) -> CellRecord {
    let c = cell(style, run: run)
    return CellRecord(item: memo.name, language: "ru", configuration: c.configuration, run: run,
                      source: memo.text, reply: reply,
                      mechanics: MechanicalChecks.evaluate(source: memo.text, reply: reply, expectedLanguage: .ru,
                                                           sameLanguage: true, facts: memo.facts),
                      ttftMS: 200, totalMS: totalMS, modelChunkCount: 1, markupDiffs: 0,
                      markupNotCompared: false, error: error)
}

private let rewritten = "Коллеги, отчёт за 2026 год нужно прислать до 15 марта."
private let rewrittenAgain = "Коллеги, отчёт за 2026 год надо прислать до 15 марта."
private let friendly = "Привет! Пришлите, пожалуйста, отчёт за 2026 год до 15 марта — спасибо!"

@Test func aStyleWhoseReplyIsItsControlsReplyIsIdleAgainstTheControlThoughNotAgainstTheSource() throws {
    // The finding of 2026-08-10, as a column: «дружеский» came back byte-identical to «как в
    // оригинале». Against the *source* both changed the text, so that column cannot see it.
    let rows = Report.rows([
        record(.original, run: 1, reply: rewritten),
        record(.friendly, run: 1, reply: rewritten),
        record(.business, run: 1, reply: friendly),
    ])
    let byStyle = Dictionary(uniqueKeysWithValues: rows.map { ($0.style, $0) })
    let idleStyle = try #require(byStyle["friendly"]), movedStyle = try #require(byStyle["business"])
    #expect(idleStyle.idleSource == 0)
    #expect(idleStyle.idleControl == 1)
    #expect(idleStyle.shiftControl == 0)
    #expect(movedStyle.idleControl == 0)
    #expect(try #require(movedStyle.shiftControl) > 0.3)
    // The control is not compared with itself.
    #expect(try #require(byStyle["original"]).idleControl == nil)
}

@Test func theNoiseFloorIsTheShiftBetweenTwoRunsOfTheControl() throws {
    // One word of nine differs between the two control runs: 2 changed tokens over the
    // tokens of both replies. What a style's shift has to exceed before it means anything.
    let rows = Report.rows([
        record(.original, run: 1, reply: rewritten),
        record(.original, run: 2, reply: rewrittenAgain),
    ])
    let expected = try #require(MechanicalChecks.shift(between: rewritten, and: rewrittenAgain))
    #expect(expected > 0 && expected < 0.15)
    #expect(rows.first?.noiseFloor == expected)
}

@Test func aFailedCellIsCountedAsAnErrorAndStaysOutOfEveryRate() throws {
    let rows = Report.rows([
        record(.original, run: 1, reply: rewritten),
        record(.original, run: 2, reply: "", error: "connection refused"),
    ])
    let row = try #require(rows.first)
    #expect(row.cells == 1)
    #expect(row.errors == 1)
    #expect(row.flagCounts[.emptyReply] == nil)
}

@Test func aStyledRunIsComparedWithTheControlOfItsOwnRunIndexAndSkippedWhenThatOneFailed() throws {
    let rows = Report.rows([
        record(.original, run: 1, reply: rewritten),
        record(.original, run: 2, reply: "", error: "connection refused"),
        record(.friendly, run: 1, reply: rewritten),
        record(.friendly, run: 2, reply: friendly),
    ])
    let row = try #require(rows.first { $0.style == "friendly" })
    #expect(row.idleControl == 1)
    #expect(row.comparedWithControl == 1)
}

@Test func theMedianOfAnEvenCountIsTheMeanOfTheMiddleTwo() {
    #expect(Report.median([4, 1, 3, 2]) == 2.5)
    #expect(Report.median([3, 1, 2]) == 2)
    #expect(Report.median([]) == nil)
}

@Test func theFailureListNamesTheCellTheFlagAndWhatWasLost() {
    let lines = Report.failures([
        record(.friendly, run: 2, reply: "Привет! Пришлите, пожалуйста, отчёт до конца месяца — спасибо!"),
        record(.business, run: 1, reply: rewritten),
    ])
    #expect(lines.count == 1)
    let line = lines[0]
    #expect(line.contains("ru-memo") && line.contains("friendly") && line.contains("r2"))
    #expect(line.contains("missingNumber: 2026, 15"))
    #expect(line.contains("missingFact: deadline"))
}

@Test func theRenderedTableSaysTheJudgeHasNotLookedAndCarriesTheManifestsHeadline() {
    let manifest = RunManifest(label: "night", createdAt: "2026-09-22T23:00:00Z", commit: "abc1234", dirty: true,
                               engine: "ollama", engineVersion: "0.34.0", chunk: 4000, temperature: 0.5,
                               corpusPath: "quality-corpus/style", corpusHash: "00ff", external: false,
                               filter: MatrixFilter(models: ["translategemma:12b"], levels: [.rewrite],
                                                    styles: [.friendly], runs: 1))
    let text = Report.render(manifest: manifest, records: [record(.original, run: 1, reply: rewritten)])
    #expect(text.hasPrefix(manifest.headline + "\n"))
    #expect(manifest.headline.contains("abc1234+dirty"))
    #expect(text.contains("mechanics only"))
}
