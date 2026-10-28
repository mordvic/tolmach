import Foundation

/// The table for a judged comparison. Its **first line is the calibration status**, the way
/// `acceptance` opens with what its gates apply to: a judged number from a judge nobody has
/// checked against a person is an unverified number, and the reader is told before the number.
public enum JudgedReport {
    /// The bar the design session set: agreement with a person over pairs neither called a tie.
    public static let agreementBar = 0.8
    /// Below this many decided pairs an agreement rate is an anecdote — 3 of 3 is 100 %. The
    /// calibration is 24 pairs; 20 leaves room for ties without letting a handful pass.
    /// **Not measured** — a first value.
    public static let minimumDecidedPairs = 20

    static let names: [Scoring.Axis: String] = [.meaning: "смысл", .style: "стиль", .naturalness: "естественность"]

    public static func render(key: PacketKey, packets: [Packet], verdicts: [Verdict]) -> String {
        let claude = Scoring.outcomes(key: key, verdicts: verdicts, judge: "claude")
        let human = Scoring.outcomes(key: key, verdicts: verdicts, judge: "human")
        let agreement = Scoring.agreement(claude, human)

        let calibrated = Scoring.Axis.allCases.filter { axis in
            guard let a = agreement[axis], a.decided >= minimumDecidedPairs else { return false }
            return Double(a.agreed) >= agreementBar * Double(a.decided)
        }
        var out = calibrated.isEmpty
            ? "JUDGE UNCALIBRATED — no axis has ≥ \(Int(agreementBar * 100)) % agreement with a person over " +
              "≥ \(minimumDecidedPairs) decided pairs; read every figure below as unverified\n"
            : "judge calibrated on \(calibrated.map { names[$0]! }.joined(separator: ", ")) · rubric \(Rubric.version)\n"
        out += "agreement with a person (pairs neither called a tie): " + Scoring.Axis.allCases.map { axis in
            let a = agreement[axis] ?? .init(agreed: 0, decided: 0)
            return "\(names[axis]!) \(a.agreed) of \(a.decided)"
        }.joined(separator: " · ") + "\n\n"

        out += "A  \(key.a.headline)\(key.a.model.map { " · model \($0)" } ?? "")\n"
        out += "B  \(key.b.headline)\(key.b.model.map { " · model \($0)" } ?? "")\n"
        out += "pairs: \(key.pairs.count) · judged both ways by claude: \(claude.count) · by a person: \(human.count) · " +
               "identical replies, not judged: \(key.identicalPairs)\n\n"

        for (label, outcomes) in [("claude", claude), ("human", human)] where !outcomes.isEmpty {
            let tally = Scoring.tally(outcomes)
            out += "\(label):\n"
            for axis in Scoring.Axis.allCases {
                let c = tally[axis] ?? .init()
                let flips = outcomes.filter { $0.flipped.contains(axis) }.count
                out += "  \(names[axis]!.padding(toLength: 15, withPad: " ", startingAt: 0)) A \(c.a) · B \(c.b) · равны \(c.tie)" +
                       " (из них перевернулись при смене порядка: \(flips)) · вето \(c.vetoed)\n"
            }
            let lostA = outcomes.filter { !$0.lostByA.isEmpty }.count, lostB = outcomes.filter { !$0.lostByB.isEmpty }.count
            out += "  pairs with a lost fact: A \(lostA) · B \(lostB)\n"
            let failures = Scoring.failureCounts(key: key, packets: packets, verdicts: verdicts, judge: label)
            for (side, counts) in [("A", failures.a), ("B", failures.b)] where !counts.isEmpty {
                out += "  failures \(side): " + counts.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: " · ") + "\n"
            }
            out += "\n"
        }

        let byID = Dictionary(packets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let problems = verdicts.flatMap { verdict -> [String] in
            guard let packet = byID[verdict.packet] else { return ["\(verdict.packet): no such packet"] }
            return verdict.problems(against: packet).map { "\(verdict.packet): \($0)" }
        }
        if !problems.isEmpty {
            out += "verdicts with a problem (\(problems.count)) — a broken quotation counts for nothing:\n"
            for line in problems { out += "  \(line)\n" }
        }
        return out
    }
}

/// What a person types in `quality judge --human`: three letters, in the axes' order —
/// смысл, стиль, естественность — each `x`, `y` or `=`.
public struct HumanAnswer: Equatable, Sendable {
    public let meaning: Verdict.Choice
    public let style: Verdict.Choice
    public let naturalness: Verdict.Choice

    public static func parse(_ line: String) -> HumanAnswer? {
        let choices = line.lowercased().filter { !$0.isWhitespace }.map { character -> Verdict.Choice? in
            switch character { case "x", "х": .x; case "y", "у": .y; case "=": .tie; default: nil }
        }
        guard choices.count == 3, let meaning = choices[0], let style = choices[1], let naturalness = choices[2] else {
            return nil
        }
        return HumanAnswer(meaning: meaning, style: style, naturalness: naturalness)
    }
}
