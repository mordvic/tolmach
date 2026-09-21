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

        let shift: Double?
        if sameLanguage {
            shift = Self.shift(of: TextDiff.changes(source: source, result: reply))
        } else {
            shift = nil
        }
        let idle = sameTokens(source, reply)

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

    /// «Холостой ход»: the two texts are the same tokens in the same order — whitespace is a
    /// boundary, so a collapsed double space is not a change (`TextTokenizer`'s rule).
    ///
    /// **Not `TextDiff.changes(…).count == 0`**, which is what this was first: `TextDiff` never
    /// compares code, so a reply that appended a whole fenced block — the answered-instruction
    /// shape — had «no changes» and was reported as the model doing nothing.
    public static func sameTokens(_ a: String, _ b: String) -> Bool {
        TextTokenizer.tokens(of: a).map(\.text) == TextTokenizer.tokens(of: b).map(\.text)
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
    ///
    /// Three allowances, each from the first live run (2026-09-22, `translategemma:12b`, the
    /// style corpus, 48 cells) where the strict reading flagged replies that had lost nothing:
    /// a number up to twelve **spelled out** («1 month» → «one month», 20 of 20 replies to one
    /// text); an **afternoon hour on the twelve-hour clock** («19:00» → «7 p.m.», 18 of 18),
    /// allowed only where the source writes it as an hour, so «19 заявок» → «7 заявок» is still
    /// a loss; and the `:00` such a rewrite drops. And one from review: a grouped reading whose
    /// parts all survive separately («101,102,103» → «101, 102 и 103») is a list, not a loss.
    public static func missingNumbers(source: String, reply: String) -> [String] {
        let replyNumbers = numbers(in: reply)
        let grouped = Set(replyNumbers.map(\.value))
        let raw = Set(replyNumbers.flatMap(\.parts))
        let words = Set(TextTokenizer.tokens(of: reply).filter { $0.kind == .word }.map { $0.text.lowercased() })

        var seen = Set<String>()
        return numbers(in: source).filter { number in
            if grouped.contains(number.value) || raw.contains(number.value) { return false }
            if number.parts.count > 1, number.parts.allSatisfy(raw.contains) { return false }
            if let small = Int(number.value), let spellings = numberWords[small], !words.isDisjoint(with: spellings) {
                return false
            }
            if number.isHour, let hour = Int(number.value), (13...23).contains(hour) || hour == 0,
               raw.contains(String(hour == 0 ? 12 : hour - 12)) { return false }
            if number.isMinutes, Int(number.value) == 0 { return false }
            return true
        }.map(\.value).filter { seen.insert($0).inserted }
    }

    /// Sidecar `literal` facts absent from the reply in every one of their spellings.
    ///
    /// A spelling that is **only a number** («64», «7 500») is looked for as a whole number,
    /// for the reason `missingNumbers` is: «64» is not present in «1964». Any other spelling is
    /// a case-insensitive substring, deliberately — «Лесн» is how a sidecar says «Лесная, Лесной,
    /// Лесную» without listing a declension.
    public static func missingFacts(_ facts: [ItemMeta.Fact], in reply: String) -> [String] {
        let haystack = normalised(reply)
        let replyNumbers = numbers(in: reply)
        let present = Set(replyNumbers.map(\.value)).union(replyNumbers.flatMap(\.parts))
        func survives(_ spelling: String) -> Bool {
            let numeric = spelling.unicodeScalars.allSatisfy {
                ("0"..."9").contains($0) || [" ", "\u{00A0}", "\u{202F}", ",", "."].contains($0)
            }
            let wanted = numbers(in: spelling)
            if numeric, !wanted.isEmpty { return wanted.allSatisfy { present.contains($0.value) } }
            return haystack.contains(normalised(spelling))
        }
        return facts.filter { $0.kind == .literal && !$0.anyOf.contains(where: survives) }.map(\.id)
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

    struct Number {
        /// Grouping removed and leading zeros dropped: «10 000» is `10000`, «03» is `3`.
        let value: String
        /// The digit runs it was read from — more than one only for a grouped reading.
        let parts: [String]
        /// Written as the hour of a clock time: a run directly followed by «:» and a digit.
        let isHour: Bool
        /// Written as the minutes of one: a run directly preceded by «:» after an hour.
        let isMinutes: Bool
    }

    /// Digit runs, with a run of three-digit groups read as one number: «10 000», «10,000»
    /// and «10.000» are all `10000`. A decimal («3.5») is two runs, which is as strict as this
    /// needs to be — both halves still have to survive.
    static func numbers(in text: String) -> [Number] {
        var found: [Number] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func isDigit(_ s: Unicode.Scalar) -> Bool { ("0"..."9").contains(s) }
        func canonical(_ digits: String) -> String {
            let trimmed = String(digits.drop { $0 == "0" })
            return trimmed.isEmpty ? "0" : trimmed
        }
        let groupSeparators: Set<Unicode.Scalar> = [" ", "\u{00A0}", "\u{202F}", ",", "."]
        var previousWasHour = false
        while i < scalars.count {
            guard isDigit(scalars[i]) else { i += 1; continue }
            let start = i
            var run = ""
            while i < scalars.count, isDigit(scalars[i]) { run.unicodeScalars.append(scalars[i]); i += 1 }
            var parts = [canonical(run)]
            // A leading group is 1–3 digits; every following one exactly three.
            if run.count <= 3 {
                while i + 3 < scalars.count, groupSeparators.contains(scalars[i]) {
                    let group = scalars[(i + 1)...(i + 3)]
                    guard group.allSatisfy(isDigit) else { break }
                    let after = i + 4
                    if after < scalars.count, isDigit(scalars[after]) { break }
                    var piece = ""
                    for s in group { run.unicodeScalars.append(s); piece.unicodeScalars.append(s) }
                    parts.append(canonical(piece))
                    i = after
                }
            }
            let isHour = parts.count == 1 && i + 1 < scalars.count && scalars[i] == ":" && isDigit(scalars[i + 1])
            let isMinutes = previousWasHour && start > 0 && scalars[start - 1] == ":"
            found.append(Number(value: canonical(run), parts: parts, isHour: isHour, isMinutes: isMinutes))
            previousWasHour = isHour
        }
        return found
    }

    /// Zero to twelve, in the forms a rewrite actually produces. Whole words, never prefixes:
    /// «два» as a prefix would accept «двадцать» for a lost «2».
    private static let numberWords: [Int: Set<String>] = [
        0: ["zero", "ноль", "нуля"],
        1: ["one", "один", "одна", "одно", "одного", "одной", "одну", "одним", "одном"],
        2: ["two", "два", "две", "двух", "двум", "двумя", "двое"],
        3: ["three", "три", "трёх", "трех", "трём", "трем", "тремя", "трое"],
        4: ["four", "четыре", "четырёх", "четырех", "четырём", "четырем", "четырьмя", "четверо"],
        5: ["five", "пять", "пяти", "пятью", "пятеро"],
        6: ["six", "шесть", "шести", "шестью"],
        7: ["seven", "семь", "семи", "семью"],
        8: ["eight", "восемь", "восьми", "восемью"],
        9: ["nine", "девять", "девяти", "девятью"],
        10: ["ten", "десять", "десяти", "десятью"],
        11: ["eleven", "одиннадцать", "одиннадцати"],
        12: ["twelve", "двенадцать", "двенадцати"],
    ]
}
