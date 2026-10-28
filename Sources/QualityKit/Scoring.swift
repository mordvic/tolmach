import Foundation

/// Turns verdicts on packets into outcomes for pairs — with the key, which is the only place
/// «X» becomes a configuration again.
public enum Scoring {
    public enum Axis: String, Sendable, CaseIterable { case meaning, style, naturalness }
    public enum Winner: String, Sendable, Equatable { case a, b, tie }

    public struct Outcome: Sendable, Equatable {
        public let pair: PacketKey.Pair
        public let meaning: Winner
        public let style: Winner
        public let naturalness: Winner
        /// Axes on which the two orderings disagreed. Each is a tie above — the judge was
        /// voting for a position, not for a text.
        public let flipped: Set<Axis>
        /// Стиль or естественность won by the side that lost a fact the other kept. Смысл is a
        /// veto: such a win is reported apart and counted for nobody.
        public let vetoed: Set<Axis>
        public let lostByA: Set<String>
        public let lostByB: Set<String>

        public func winner(_ axis: Axis) -> Winner {
            switch axis { case .meaning: meaning; case .style: style; case .naturalness: naturalness }
        }
    }

    public struct Count: Sendable, Equatable {
        public var a = 0, b = 0, tie = 0, vetoed = 0
        public init(a: Int = 0, b: Int = 0, tie: Int = 0, vetoed: Int = 0) {
            self.a = a; self.b = b; self.tie = tie; self.vetoed = vetoed
        }
    }

    public struct Agreement: Sendable, Equatable {
        public let agreed: Int
        /// Pairs neither judge called a tie — the denominator the calibration bar is stated on.
        public let decided: Int
        public init(agreed: Int, decided: Int) { self.agreed = agreed; self.decided = decided }
    }

    /// One outcome per pair that has **both** of its orderings judged by `judge`. A pair with
    /// one verdict is not scored at all: half a swap test is not a weaker result, it is none.
    public static func outcomes(key: PacketKey, verdicts: [Verdict], judge: String) -> [Outcome] {
        let byPacket = Dictionary(verdicts.filter { $0.judge == judge && $0.rubric == Rubric.version }
            .map { ($0.packet, $0) }, uniquingKeysWith: { first, _ in first })

        return key.pairs.compactMap { pair in
            guard pair.packets.count == 2,
                  let first = byPacket[pair.packets[0].id], let second = byPacket[pair.packets[1].id] else { return nil }
            let orderings = [(first, pair.packets[0].xIs), (second, pair.packets[1].xIs)]

            func side(_ choice: Verdict.Choice, xIs: String) -> Winner {
                switch choice {
                case .tie: .tie
                case .x: xIs == "a" ? .a : .b
                case .y: xIs == "a" ? .b : .a
                }
            }
            var flipped = Set<Axis>()
            func settle(_ axis: Axis, _ pick: (Verdict) -> Verdict.Choice) -> Winner {
                let votes = orderings.map { side(pick($0.0), xIs: $0.1) }
                if votes[0] == votes[1] { return votes[0] }
                flipped.insert(axis)
                return .tie
            }
            let meaning = settle(.meaning) { $0.meaning }
            let style = settle(.style) { $0.style }
            let naturalness = settle(.naturalness) { $0.naturalness }

            // Lost means lost under **both** orderings — the same rule a win is held to.
            func lost(by who: String) -> Set<String> {
                orderings.map { verdict, xIs in Set(xIs == who ? verdict.lostFacts.x : verdict.lostFacts.y) }
                    .reduce(nil) { $0?.intersection($1) ?? $1 } ?? []
            }
            let lostByA = lost(by: "a"), lostByB = lost(by: "b")

            var vetoed = Set<Axis>()
            for (axis, winner) in [(Axis.style, style), (.naturalness, naturalness)] {
                if winner == .a, !lostByA.subtracting(lostByB).isEmpty { vetoed.insert(axis) }
                if winner == .b, !lostByB.subtracting(lostByA).isEmpty { vetoed.insert(axis) }
            }
            return Outcome(pair: pair, meaning: meaning, style: style, naturalness: naturalness,
                           flipped: flipped, vetoed: vetoed, lostByA: lostByA, lostByB: lostByB)
        }
    }

    public static func tally(_ outcomes: [Outcome]) -> [Axis: Count] {
        var tally: [Axis: Count] = [:]
        for axis in Axis.allCases {
            var count = Count()
            for outcome in outcomes {
                if outcome.vetoed.contains(axis) { count.vetoed += 1; continue }
                switch outcome.winner(axis) {
                case .a: count.a += 1
                case .b: count.b += 1
                case .tie: count.tie += 1
                }
            }
            tally[axis] = count
        }
        return tally
    }

    /// How often two judges named the same side, over pairs **neither** called a tie — the
    /// figure the calibration bar (≥ 80 %) is stated on, reported as «N of M».
    public static func agreement(_ one: [Outcome], _ other: [Outcome]) -> [Axis: Agreement] {
        func id(_ o: Outcome) -> String { "\(o.pair.item)/\(o.pair.level)/\(o.pair.style)/\(o.pair.run)" }
        let others = Dictionary(other.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Axis: Agreement] = [:]
        for axis in Axis.allCases {
            var agreed = 0, decided = 0
            for outcome in one {
                guard let match = others[id(outcome)] else { continue }
                let mine = outcome.winner(axis), theirs = match.winner(axis)
                guard mine != .tie, theirs != .tie else { continue }
                decided += 1
                if mine == theirs { agreed += 1 }
            }
            result[axis] = Agreement(agreed: agreed, decided: decided)
        }
        return result
    }

    /// Failure categories per side, from every verdict whose quotation holds.
    public static func failureCounts(key: PacketKey, packets: [Packet], verdicts: [Verdict], judge: String)
        -> (a: [Verdict.Category: Int], b: [Verdict.Category: Int]) {
        let packetByID = Dictionary(packets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let xIs = Dictionary(key.pairs.flatMap(\.packets).map { ($0.id, $0.xIs) }, uniquingKeysWith: { first, _ in first })
        var a: [Verdict.Category: Int] = [:], b: [Verdict.Category: Int] = [:]
        for verdict in verdicts where verdict.judge == judge && verdict.rubric == Rubric.version {
            guard let packet = packetByID[verdict.packet], let x = xIs[verdict.packet] else { continue }
            for failure in verdict.failures where Verdict.holds(failure, in: packet) {
                let isA = (failure.side == .x) == (x == "a")
                if isA { a[failure.category, default: 0] += 1 } else { b[failure.category, default: 0] += 1 }
            }
        }
        return (a, b)
    }
}
