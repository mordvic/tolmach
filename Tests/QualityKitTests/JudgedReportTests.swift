import Testing
import Foundation
@testable import QualityKit

private func pair(_ n: Int) -> PacketKey.Pair {
    .init(item: "ru-\(n)", language: "ru", level: "rewrite", style: "friendly", run: 1,
          packets: [.init(id: "p\(n)a", xIs: "a"), .init(id: "p\(n)b", xIs: "b")])
}

private func packets(_ n: Int) -> [Packet] {
    [Packet(id: "p\(n)a", item: "ru-\(n)", language: "ru", operation: "proofread", level: "rewrite",
            requestedStyle: "friendly", source: "s", facts: [], x: "текст А", y: "текст Б"),
     Packet(id: "p\(n)b", item: "ru-\(n)", language: "ru", operation: "proofread", level: "rewrite",
            requestedStyle: "friendly", source: "s", facts: [], x: "текст Б", y: "текст А")]
}

/// Both orderings of pair `n`, voting for the same side on every axis.
private func votes(_ n: Int, judge: String, for side: Scoring.Winner) -> [Verdict] {
    func choice(xIs: String) -> Verdict.Choice { side == .tie ? .tie : ((side == .a) == (xIs == "a") ? .x : .y) }
    return [("p\(n)a", "a"), ("p\(n)b", "b")].map { id, xIs in
        Verdict(packet: id, rubric: Rubric.version, judge: judge, meaning: .tie, style: choice(xIs: xIs),
                naturalness: .tie, lostFacts: .init(x: [], y: []), failures: [], note: nil)
    }
}

private func key(_ count: Int) -> PacketKey {
    PacketKey(a: .init(headline: "quality: cold", model: nil), b: .init(headline: "quality: warm", model: nil),
              seed: 1, pairs: (1...count).map(pair), identicalPairs: 2)
}

@Test func aReportWithoutAHumansVerdictsSaysTheJudgeIsUncalibratedOnItsFirstLine() {
    let text = JudgedReport.render(key: key(1), packets: packets(1), verdicts: votes(1, judge: "claude", for: .b))
    #expect(text.hasPrefix("JUDGE UNCALIBRATED"))
    #expect(text.contains("A  quality: cold"))
    #expect(text.contains("identical replies, not judged: 2"))
}

@Test func calibrationPassesAtEightyPercentOverEnoughDecidedPairsAndSaysNOfM() {
    // 20 pairs, the human agrees on 16: 16 of 20 is the bar exactly.
    var verdicts: [Verdict] = []
    for n in 1...20 {
        verdicts += votes(n, judge: "claude", for: .a)
        verdicts += votes(n, judge: "human", for: n <= 16 ? .a : .b)
    }
    let all = (1...20).flatMap(packets)
    let text = JudgedReport.render(key: key(20), packets: all, verdicts: verdicts)
    #expect(text.hasPrefix("judge calibrated on стиль"))
    #expect(text.contains("стиль 16 of 20"))

    // One fewer agreement and the first line goes back.
    var worse = verdicts.filter { !($0.judge == "human" && $0.packet.hasPrefix("p16")) }
    worse += votes(16, judge: "human", for: .b)
    #expect(JudgedReport.render(key: key(20), packets: all, verdicts: worse).hasPrefix("JUDGE UNCALIBRATED"))
}

@Test func agreementOverAHandfulOfPairsIsNotACalibration() {
    // 3 of 3 is 100 % and means nothing; the bar is stated on enough decided pairs.
    var verdicts: [Verdict] = []
    for n in 1...3 { verdicts += votes(n, judge: "claude", for: .a) + votes(n, judge: "human", for: .a) }
    let text = JudgedReport.render(key: key(3), packets: (1...3).flatMap(packets), verdicts: verdicts)
    #expect(text.hasPrefix("JUDGE UNCALIBRATED"))
    #expect(text.contains("стиль 3 of 3"))
}

@Test func aVerdictWithAProblemIsListedAndItsBrokenQuotationCountsForNothing() {
    var bad = votes(1, judge: "claude", for: .a)
    bad[0].failures = [.init(side: .x, category: .llmCliche, quote: "этого в тексте нет")]
    let text = JudgedReport.render(key: key(1), packets: packets(1), verdicts: bad)
    #expect(text.contains("p1a: quotes «этого в тексте нет»"))
    #expect(!text.contains("llmCliche"))
}

@Test func aHumansAnswerIsThreeLettersInTheAxesOrder() {
    #expect(HumanAnswer.parse("x y =") == .init(meaning: .x, style: .y, naturalness: .tie))
    #expect(HumanAnswer.parse("XY=") == .init(meaning: .x, style: .y, naturalness: .tie))
    #expect(HumanAnswer.parse("x y") == nil)
    #expect(HumanAnswer.parse("x y z") == nil)
}
