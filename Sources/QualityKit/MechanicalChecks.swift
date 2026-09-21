import Foundation
import TranslationCore

/// What can be said about one reply without asking anybody — the first of the harness's three
/// layers (`docs/design/specs/2026-09-22-quality-harness-design.md` §5).
///
/// Every value here is a **flag for a reader, not a verdict**: a model may legitimately write
/// «пять» for «5», and a rewrite may legitimately fold a question into a statement. What the
/// layer is for is making the gross failures free to find — the wrong language, a lost date,
/// an answer where a correction was asked for — so the judge's attention goes to the rest.
public struct Mechanics: Codable, Sendable, Equatable {
    public enum Flag: String, Codable, Sendable, CaseIterable {
        case emptyReply, wrongLanguage, missingNumber, missingFact, lostQuestion, lengthOutOfRange
    }

    /// No token-level change from the source — «холостой ход». For a translation: the reply
    /// *is* the source, i.e. it came back untranslated.
    public let idle: Bool
    /// Changed tokens over all tokens, 0…1. nil for a translation (two languages have no
    /// word diff) and when `TextDiff` declined to compare.
    public let shift: Double?
    /// `Language.rawValue` of what the reply reads as, nil when the detector cannot say.
    public let replyLanguage: String?
    public let languageOK: Bool
    public let missingNumbers: [String]
    /// Sidecar fact ids.
    public let missingFacts: [String]
    public let sourceQuestions: Int
    public let replyQuestions: Int
    /// Reply word tokens over source word tokens.
    public let lengthRatio: Double
    public let flags: [Flag]
}

public enum MechanicalChecks {
    /// Outside this band a reply is flagged. Wide on purpose: Russian → English runs about
    /// 1.2 words to one and «простой и ясный» legitimately shortens, so the band is for a reply
    /// that lost half the text or doubled it, not for a tight one. **Not measured** — a first
    /// value, to be revisited against the first campaign's distribution.
    public static let lengthBand: ClosedRange<Double> = 0.5...2.0

    public static func evaluate(source: String, reply: String, expectedLanguage: Language,
                                sameLanguage: Bool, facts: [ItemMeta.Fact]) -> Mechanics {
        let sourceWords = wordCount(source)
        let replyWords = wordCount(reply)
        let ratio = sourceWords > 0 ? Double(replyWords) / Double(sourceWords) : 0
        let sourceQuestions = questionMarks(in: source)
        let replyQuestions = questionMarks(in: reply)

        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // An absent reply is one failure, not five: reporting its language as wrong and
            // every fact as missing would bury the only thing that happened.
            return Mechanics(idle: false, shift: nil, replyLanguage: nil, languageOK: false,
                             missingNumbers: [], missingFacts: [],
                             sourceQuestions: sourceQuestions, replyQuestions: 0,
                             lengthRatio: 0, flags: [.emptyReply])
        }

        let idle: Bool
        let shift: Double?
        if sameLanguage {
            let changes = TextDiff.changes(source: source, result: reply)
            idle = changes.notCompared == nil && changes.count == 0
            shift = Self.shift(of: changes)
        } else {
            idle = TextTokenizer.tokens(of: source).map(\.text) == TextTokenizer.tokens(of: reply).map(\.text)
            shift = nil
        }

        let detected = LanguageDetector.detect(reply)
        let languageOK = detected == expectedLanguage
        let numbers = missingNumbers(source: source, reply: reply)
        let lostFacts = missingFacts(facts, in: reply)

        var flags: [Mechanics.Flag] = []
        if !languageOK { flags.append(.wrongLanguage) }
        if !numbers.isEmpty { flags.append(.missingNumber) }
        if !lostFacts.isEmpty { flags.append(.missingFact) }
        if replyQuestions < sourceQuestions { flags.append(.lostQuestion) }
        if !lengthBand.contains(ratio) { flags.append(.lengthOutOfRange) }

        return Mechanics(idle: idle, shift: shift, replyLanguage: detected?.rawValue,
                         languageOK: languageOK, missingNumbers: numbers, missingFacts: lostFacts,
                         sourceQuestions: sourceQuestions, replyQuestions: replyQuestions,
                         lengthRatio: ratio, flags: flags)
    }

    /// Changed tokens over all tokens across every compared block — the post-check ratio
    /// `Scripts/change-density.sh` reads per block, summed so one number describes a reply.
    /// `changedTokens` is counted before `mergeGap` (PR #83), so this does not move with it.
    public static func shift(of changes: ChangeSet) -> Double? {
        guard changes.notCompared == nil else { return nil }
        let all = changes.blocks.reduce(0) { $0 + $1.sourceTokens + $1.resultTokens }
        guard all > 0 else { return 0 }
        return Double(changes.blocks.reduce(0) { $0 + $1.changedTokens }) / Double(all)
    }

    /// The shift between two replies to the same text — a named style against its control, or
    /// one control run against another for the noise floor.
    public static func shift(between a: String, and b: String) -> Double? {
        shift(of: TextDiff.changes(source: a, result: b))
    }

    /// Numbers the source states and the reply does not, each once, in source order.
    ///
    /// Compared as **whole numbers, never as substrings** — «15» is not present in «2015» —
    /// and with digit grouping removed, because «10 000» → «10,000» is what a translation
    /// into English does and is not a loss.
    public static func missingNumbers(source: String, reply: String) -> [String] {
        let present = Set(numbers(in: reply))
        var seen = Set<String>()
        return numbers(in: source).filter { !present.contains($0) && seen.insert($0).inserted }
    }

    /// Sidecar `literal` facts absent from the reply in every one of their spellings.
    public static func missingFacts(_ facts: [ItemMeta.Fact], in reply: String) -> [String] {
        let haystack = normalised(reply)
        return facts.filter { fact in
            fact.kind == .literal && !fact.anyOf.contains { haystack.contains(normalised($0)) }
        }.map(\.id)
    }

    public static func questionMarks(in text: String) -> Int {
        text.reduce(0) { $0 + ($1 == "?" ? 1 : 0) }
    }

    private static func wordCount(_ text: String) -> Int {
        TextTokenizer.tokens(of: text).reduce(0) { $0 + ($1.kind == .word ? 1 : 0) }
    }

    private static func normalised(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .lowercased()
    }

    /// Digit runs, with a run of three-digit groups read as one number: «10 000», «10,000»
    /// and «10.000» are all `10000`. A decimal («3.5») is two runs, which is as strict as this
    /// needs to be — both halves still have to survive.
    private static func numbers(in text: String) -> [String] {
        var found: [String] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func isDigit(_ s: Unicode.Scalar) -> Bool { ("0"..."9").contains(s) }
        let groupSeparators: Set<Unicode.Scalar> = [" ", "\u{00A0}", "\u{202F}", ",", "."]
        while i < scalars.count {
            guard isDigit(scalars[i]) else { i += 1; continue }
            var run = ""
            while i < scalars.count, isDigit(scalars[i]) { run.unicodeScalars.append(scalars[i]); i += 1 }
            // A leading group is 1–3 digits; every following one exactly three.
            if run.count <= 3 {
                while i + 3 < scalars.count, groupSeparators.contains(scalars[i]) {
                    let group = scalars[(i + 1)...(i + 3)]
                    guard group.allSatisfy(isDigit) else { break }
                    let after = i + 4
                    if after < scalars.count, isDigit(scalars[after]) { break }
                    for s in group { run.unicodeScalars.append(s) }
                    i = after
                }
            }
            found.append(run)
        }
        return found
    }
}
