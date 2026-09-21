import Foundation

/// The rubric a verdict was given under. The document is `docs/reference/QUALITY-RUBRIC.md`;
/// a test holds its version line to this constant, and verdicts under two versions are never
/// tallied together — a changed rubric is a changed instrument.
public enum Rubric {
    public static let version = "1"
}

/// One judge's decision on one пакет — «вердикт».
public struct Verdict: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable { case x, y, tie }
    public enum Side: String, Codable, Sendable { case x, y }

    /// A **closed** list. A judge that cannot name what is wrong from it has not found a
    /// failure this harness knows how to count, and says so in `note`.
    public enum Category: String, Codable, Sendable, CaseIterable {
        // смысл
        case factLost, factInvented, meaningDistorted, answeredInstead
        // стиль
        case styleNotApplied, registerMissed
        // естественность
        case calque, llmCliche, grammar
        // правка-specific: the level was overstepped or understepped
        case needlessEdit, errorLeft
        // перевод-specific
        case untranslated
    }

    public struct Failure: Codable, Sendable, Equatable {
        public let side: Side
        public let category: Category
        /// Verbatim from the side's text. **A failure whose quotation is not in that text does
        /// not count** (`problems(against:)`, `Scoring.failureCounts`): it is how a judge's
        /// claim stays checkable by someone who did not read the pair.
        public let quote: String
        public init(side: Side, category: Category, quote: String) {
            self.side = side; self.category = category; self.quote = quote
        }
    }

    public struct LostFacts: Codable, Sendable, Equatable {
        public let x: [String]
        public let y: [String]
        public init(x: [String], y: [String]) { self.x = x; self.y = y }
    }

    public var packet: String
    public var rubric: String
    /// `claude` or `human` — the directory the verdict is kept under.
    public var judge: String
    public var meaning: Choice
    public var style: Choice
    public var naturalness: Choice
    /// The checklist: ids of sidecar facts each side lost. What makes смысл a count.
    public var lostFacts: LostFacts
    public var failures: [Failure]
    public var note: String?

    public init(packet: String, rubric: String, judge: String, meaning: Choice, style: Choice,
                naturalness: Choice, lostFacts: LostFacts, failures: [Failure], note: String?) {
        self.packet = packet; self.rubric = rubric; self.judge = judge; self.meaning = meaning
        self.style = style; self.naturalness = naturalness; self.lostFacts = lostFacts
        self.failures = failures; self.note = note
    }

    public enum Problem: Equatable, CustomStringConvertible {
        case wrongPacket(found: String, expected: String)
        case rubricMismatch(found: String, expected: String)
        case unknownFact(String)
        case quoteNotInText(side: Side, quote: String)

        public var description: String {
            switch self {
            case let .wrongPacket(found, expected): "is for packet \(found), not \(expected)"
            case let .rubricMismatch(found, expected): "was given under rubric \(found); the current one is \(expected)"
            case let .unknownFact(id): "names a fact the packet does not list: \(id)"
            case let .quoteNotInText(side, quote): "quotes «\(quote)» which is not in \(side.rawValue.uppercased())'s text"
            }
        }
    }

    public func problems(against packet: Packet) -> [Problem] {
        var problems: [Problem] = []
        if self.packet != packet.id { problems.append(.wrongPacket(found: self.packet, expected: packet.id)) }
        if rubric != Rubric.version { problems.append(.rubricMismatch(found: rubric, expected: Rubric.version)) }
        let known = Set(packet.facts.map(\.id))
        for id in lostFacts.x + lostFacts.y where !known.contains(id) { problems.append(.unknownFact(id)) }
        for failure in failures where !Self.holds(failure, in: packet) {
            problems.append(.quoteNotInText(side: failure.side, quote: failure.quote))
        }
        return problems
    }

    static func holds(_ failure: Failure, in packet: Packet) -> Bool {
        let quote = failure.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return false }
        return (failure.side == .x ? packet.x : packet.y).contains(quote)
    }
}
