import Foundation
import TranslationCore

/// What a judge is handed — «пакет»: a source, two replies called X and Y, the style that was
/// asked for and the facts that had to survive. **Nothing in it says which configuration is
/// which**: no model, no temperature, no run label, no commit. That is `PacketKey`'s, and the
/// key is a file the judge is never given.
public struct Packet: Codable, Sendable, Equatable {
    /// Opaque: a sequence number after the shuffle, so neither a pair's two orderings nor a
    /// configuration can be read off it.
    public let id: String
    public let item: String
    public let language: String
    public let operation: String
    public let level: String?
    /// The register the reply was *asked* to be in — what the «стиль» axis is judged against.
    public let requestedStyle: String?
    public let source: String
    public let facts: [ItemMeta.Fact]
    public let x: String
    public let y: String
}

/// Which side each packet's X was, and what the two sides were. Read by `Scoring` and by a
/// person afterwards; never by a judge.
public struct PacketKey: Codable, Sendable, Equatable {
    public struct SideDescription: Codable, Sendable, Equatable {
        public let headline: String
        public let model: String?
    }
    public struct Ordering: Codable, Sendable, Equatable {
        public let id: String
        /// `a` or `b`.
        public let xIs: String
    }
    public struct Pair: Codable, Sendable, Equatable {
        public let item: String
        public let language: String
        public let level: String
        public let style: String
        public let run: Int
        /// Two: the same pair with the order swapped. A verdict that does not survive the swap
        /// is recorded as «равны» — the cheap defence against position bias.
        public let packets: [Ordering]
    }
    public let a: SideDescription
    public let b: SideDescription
    public let seed: UInt64
    public let pairs: [Pair]
    /// Pairs whose two replies are token-identical. No judge is asked; they are ties.
    public let identicalPairs: Int
}

public enum Packets {
    /// One side of a comparison: a run, optionally narrowed to one of its models — which is
    /// how two models of a single run are compared.
    public struct Side: Sendable {
        public let manifest: RunManifest
        public let records: [CellRecord]
        public let model: String?
        public init(manifest: RunManifest, records: [CellRecord], model: String?) {
            self.manifest = manifest; self.records = records; self.model = model
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case externalCorpus(label: String)
        case nothingToCompare
        public var description: String {
            switch self {
            case let .externalCorpus(label):
                "run «\(label)» was taken over a corpus that is not committed to this repository. Its texts " +
                "are not public, so no packet is built from it: judge it by mechanics and by your own reading " +
                "(docs/design/specs/2026-09-22-quality-harness-design.md §3)."
            case .nothingToCompare:
                "the two sides share no answered cell with the same text, level, style and run index"
            }
        }
    }

    public struct Built: Sendable, Equatable {
        public let packets: [Packet]
        public let key: PacketKey
    }

    /// - Parameter sample: how many pairs to keep, taken round-robin across language × level ×
    ///   style so a small sample still covers every style; nil keeps them all.
    public static func build(a: Side, b: Side, sample: Int?, seed: UInt64) throws -> Built {
        // Before anything else exists: a refusal that ran after the pairing would already
        // have the texts in memory in the shape they are handed over in.
        for side in [a, b] where side.manifest.external {
            throw Failure.externalCorpus(label: side.manifest.label)
        }

        struct Slot: Hashable { let item, level, style: String; let run: Int }
        func answered(_ side: Side) -> [Slot: CellRecord] {
            Dictionary(side.records
                .filter { $0.error == nil && (side.model == nil || $0.configuration.model == side.model) }
                .map { (Slot(item: $0.item, level: $0.configuration.level ?? "-",
                             style: $0.configuration.style ?? "-", run: $0.run), $0) },
                       uniquingKeysWith: { first, _ in first })
        }
        let left = answered(a), right = answered(b)
        let shared = left.keys.filter { right[$0] != nil }
            .sorted { ($0.item, $0.level, $0.style, $0.run) < ($1.item, $1.level, $1.style, $1.run) }
        guard !shared.isEmpty else { throw Failure.nothingToCompare }

        func tokens(_ text: String) -> [String] { TextTokenizer.tokens(of: text).map(\.text) }
        let differing = shared.filter { tokens(left[$0]!.reply) != tokens(right[$0]!.reply) }

        var generator = SplitMix64(state: seed)
        var chosen = differing
        if let sample, sample < differing.count {
            let strata = Dictionary(grouping: differing) { "\(left[$0]!.language)/\($0.level)/\($0.style)" }
            var queues = strata.keys.sorted().map { strata[$0]!.shuffled(using: &generator) }
            chosen = []
            while chosen.count < sample {
                for index in queues.indices where chosen.count < sample && !queues[index].isEmpty {
                    chosen.append(queues[index].removeFirst())
                }
            }
        }

        // Two orderings per pair, then one shuffle over all of them, then the ids — so a
        // pair's twin is not the next packet and an id says nothing.
        struct Draft { let slot: Slot; let xIs: String }
        var drafts: [Draft] = []
        for slot in chosen {
            let first = Bool.random(using: &generator) ? "a" : "b"
            drafts.append(Draft(slot: slot, xIs: first))
            drafts.append(Draft(slot: slot, xIs: first == "a" ? "b" : "a"))
        }
        drafts.shuffle(using: &generator)

        var packets: [Packet] = []
        var orderings: [Slot: [PacketKey.Ordering]] = [:]
        for (index, draft) in drafts.enumerated() {
            let id = String(format: "p%04d", index + 1)
            let sideA = left[draft.slot]!, sideB = right[draft.slot]!
            let (x, y) = draft.xIs == "a" ? (sideA, sideB) : (sideB, sideA)
            packets.append(Packet(id: id, item: sideA.item, language: sideA.language,
                                  operation: sideA.configuration.operation, level: sideA.configuration.level,
                                  requestedStyle: sideA.configuration.style, source: sideA.source,
                                  facts: sideA.facts, x: x.reply, y: y.reply))
            orderings[draft.slot, default: []].append(.init(id: id, xIs: draft.xIs))
        }

        let pairs = chosen.map { slot in
            PacketKey.Pair(item: slot.item, language: left[slot]!.language, level: slot.level, style: slot.style,
                           run: slot.run, packets: orderings[slot] ?? [])
        }
        return Built(packets: packets,
                     key: PacketKey(a: .init(headline: a.manifest.headline, model: a.model),
                                    b: .init(headline: b.manifest.headline, model: b.model),
                                    seed: seed, pairs: pairs,
                                    identicalPairs: shared.count - differing.count))
    }
}

/// A seeded generator, because `SystemRandomNumberGenerator` cannot be seeded and a packet set
/// that cannot be rebuilt cannot be checked. SplitMix64 — public domain, a dozen lines, and
/// the dependency list is closed (`docs/adr/0007`).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
