import Testing
import Foundation
@testable import QualityKit

private let facts = [
    ItemMeta.Fact(id: "deadline", kind: .literal, note: "срок — 15 марта", anyOf: ["15 марта"]),
    ItemMeta.Fact(id: "cause", kind: .semantic, note: "задержка по вине поставщика", anyOf: []),
]
private let packet = Packet(id: "p0001", item: "ru-memo", language: "ru", operation: "proofread", level: "rewrite",
                            requestedStyle: "friendly", source: "Отчёт необходимо предоставить до 15 марта.",
                            facts: facts, x: "Привет! Жду отчёт до 15 марта.", y: "Отчёт нужно сдать вовремя.")

private func verdict(_ id: String = "p0001", judge: String = "claude", meaning: Verdict.Choice = .x,
                     style: Verdict.Choice = .x, naturalness: Verdict.Choice = .tie,
                     lostX: [String] = [], lostY: [String] = [], failures: [Verdict.Failure] = []) -> Verdict {
    Verdict(packet: id, rubric: Rubric.version, judge: judge, meaning: meaning, style: style,
            naturalness: naturalness, lostFacts: .init(x: lostX, y: lostY), failures: failures, note: nil)
}

// MARK: validation

@Test func aWellFormedVerdictHasNoProblems() {
    let v = verdict(lostY: ["deadline"],
                    failures: [.init(side: .y, category: .factLost, quote: "сдать вовремя")])
    #expect(v.problems(against: packet) == [])
}

@Test func aFailureWhoseQuotationIsNotInTheTextItBlamesDoesNotCount() {
    // «A verdict without a quotation does not count» — and a quotation is only one if the
    // text contains it. Checked against the side the failure names, not against either.
    let v = verdict(failures: [.init(side: .y, category: .llmCliche, quote: "Жду отчёт")])
    #expect(v.problems(against: packet) == [.quoteNotInText(side: .y, quote: "Жду отчёт")])
    #expect(verdict(failures: [.init(side: .x, category: .llmCliche, quote: " ")]).problems(against: packet)
            == [.quoteNotInText(side: .x, quote: " ")])
}

@Test func aLostFactTheSidecarNeverListedIsAProblem() {
    #expect(verdict(lostX: ["budget"]).problems(against: packet) == [.unknownFact("budget")])
}

@Test func aVerdictUnderAnotherRubricOrForAnotherPacketIsAProblem() {
    var old = verdict()
    old.rubric = "0"
    #expect(old.problems(against: packet) == [.rubricMismatch(found: "0", expected: Rubric.version)])
    #expect(verdict("p0002").problems(against: packet) == [.wrongPacket(found: "p0002", expected: "p0001")])
}

@Test func aVerdictDecodesFromWhatAJudgeIsAskedToWrite() throws {
    let json = """
    {"packet":"p0001","rubric":"\(Rubric.version)","judge":"claude","meaning":"x","style":"y","naturalness":"tie",
     "lostFacts":{"x":[],"y":["deadline"]},
     "failures":[{"side":"y","category":"factLost","quote":"сдать вовремя"}]}
    """
    let v = try JSONDecoder().decode(Verdict.self, from: Data(json.utf8))
    #expect(v.style == .y)
    #expect(v.failures.first?.category == .factLost)
    #expect(v.note == nil)
}

// MARK: scoring

private func key(_ pairs: [(String, String, String)]) -> PacketKey {
    // (first packet id, second packet id, which side X is in the first)
    PacketKey(a: .init(headline: "A", model: nil), b: .init(headline: "B", model: nil), seed: 1,
              pairs: pairs.enumerated().map { index, p in
                  .init(item: "ru-\(index)", language: "ru", level: "rewrite", style: "friendly", run: 1,
                        packets: [.init(id: p.0, xIs: p.2), .init(id: p.1, xIs: p.2 == "a" ? "b" : "a")])
              },
              identicalPairs: 0)
}

@Test func aWinIsAWinOnlyWhenItSurvivesTheSwappedOrder() {
    let k = key([("p1", "p2", "a"), ("p3", "p4", "a")])
    let outcomes = Scoring.outcomes(key: k, verdicts: [
        // Pair 0: X in p1 is A, X in p2 is B — «x» then «y» both mean A. It holds.
        verdict("p1", style: .x), verdict("p2", style: .y),
        // Pair 1: the judge says «x» both times — it is voting for a position. A tie.
        verdict("p3", style: .x), verdict("p4", style: .x),
    ], judge: "claude")
    #expect(outcomes.map(\.style) == [.a, .tie])
    #expect(outcomes[1].flipped.contains(.style))
}

@Test func aPairWithOnlyOneOfItsTwoVerdictsIsNotScored() {
    let outcomes = Scoring.outcomes(key: key([("p1", "p2", "a")]), verdicts: [verdict("p1")], judge: "claude")
    #expect(outcomes.isEmpty)
}

@Test func aStyleWinByTheSideThatLostAFactTheOtherKeptIsVetoed() {
    // Смысл is a veto: a friendlier text that lost the deadline is not the better text.
    let k = key([("p1", "p2", "a")])
    let outcomes = Scoring.outcomes(key: k, verdicts: [
        verdict("p1", meaning: .y, style: .x, lostX: ["deadline"]),
        verdict("p2", meaning: .x, style: .y, lostY: ["deadline"]),
    ], judge: "claude")
    #expect(outcomes[0].meaning == .b)
    #expect(outcomes[0].style == .a)
    #expect(outcomes[0].vetoed == [.style])
    let tally = Scoring.tally(outcomes)
    #expect(tally[.style] == Scoring.Count(a: 0, b: 0, tie: 0, vetoed: 1))
    #expect(tally[.meaning] == Scoring.Count(a: 0, b: 1, tie: 0, vetoed: 0))
}

@Test func aFactBothSidesLostVetoesNeither() {
    let k = key([("p1", "p2", "a")])
    let outcomes = Scoring.outcomes(key: k, verdicts: [
        verdict("p1", style: .x, lostX: ["cause"], lostY: ["cause"]),
        verdict("p2", style: .y, lostX: ["cause"], lostY: ["cause"]),
    ], judge: "claude")
    #expect(outcomes[0].vetoed == [])
}

@Test func agreementIsCountedOverPairsNeitherJudgeCalledATie() {
    let k = key([("p1", "p2", "a"), ("p3", "p4", "a"), ("p5", "p6", "a")])
    let claude = Scoring.outcomes(key: k, verdicts: [
        verdict("p1", style: .x), verdict("p2", style: .y),      // A
        verdict("p3", style: .y), verdict("p4", style: .x),      // B
        verdict("p5", style: .tie), verdict("p6", style: .tie),  // tie
    ], judge: "claude")
    let human = Scoring.outcomes(key: k, verdicts: [
        verdict("p1", judge: "human", style: .x), verdict("p2", judge: "human", style: .y),  // A — agrees
        verdict("p3", judge: "human", style: .x), verdict("p4", judge: "human", style: .y),  // A — disagrees
        verdict("p5", judge: "human", style: .x), verdict("p6", judge: "human", style: .y),  // A — claude tied
    ], judge: "human")
    let agreement = Scoring.agreement(claude, human)
    #expect(agreement[.style] == Scoring.Agreement(agreed: 1, decided: 2))
}

@Test func failuresAreTalliedByCategoryPerSideAndOnlyWhenTheirQuotationHolds() {
    let k = key([("p1", "p2", "a")])
    let packets = [
        Packet(id: "p1", item: "i", language: "ru", operation: "proofread", level: "rewrite", requestedStyle: "friendly",
               source: "s", facts: [], x: "текст стороны А", y: "текст стороны Б"),
        Packet(id: "p2", item: "i", language: "ru", operation: "proofread", level: "rewrite", requestedStyle: "friendly",
               source: "s", facts: [], x: "текст стороны Б", y: "текст стороны А"),
    ]
    let counts = Scoring.failureCounts(key: k, packets: packets, verdicts: [
        verdict("p1", failures: [.init(side: .x, category: .llmCliche, quote: "стороны А"),
                                 .init(side: .y, category: .registerMissed, quote: "нет такой цитаты")]),
        verdict("p2", failures: [.init(side: .y, category: .llmCliche, quote: "стороны А")]),
    ], judge: "claude")
    #expect(counts.a == [.llmCliche: 2])
    #expect(counts.b == [:])
}

@Test func theRubricDocumentStatesTheVersionTheCodeTalliesUnder() throws {
    let text = try String(contentsOfFile: "docs/reference/QUALITY-RUBRIC.md", encoding: .utf8)
    #expect(text.contains("**Rubric version: \(Rubric.version)**"))
    // And names every category the decoder accepts — a judge can only use what it was shown.
    for category in Verdict.Category.allCases {
        #expect(text.contains("`\(category.rawValue)`"), "the rubric does not list \(category.rawValue)")
    }
}

@Test func aQuotationHoldsAcrossTheSpacesAndHyphensAModelWrites() {
    // `gpt-oss:20b` writes «on 24\u{202F}Mira Avenue» and «58‑4417» with U+2011; a judge
    // copies what it sees, which is a plain space and a hyphen — 5 verdicts of 24 were
    // discarded for that before this existed.
    let p = Packet(id: "p1", item: "i", language: "en", operation: "proofread", level: "rewrite", requestedStyle: "friendly",
                   source: "s", facts: [], x: "keys received on\u{202F}1\u{202F}October, order 58\u{2011}4417", y: "y")
    let v = verdict("p1", failures: [.init(side: .x, category: .grammar, quote: "on 1 October, order 58-4417")])
    #expect(v.problems(against: p) == [])
}
