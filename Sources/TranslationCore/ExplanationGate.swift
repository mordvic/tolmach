// Sources/TranslationCore/ExplanationGate.swift
import Foundation

/// What `Translator.explain` returns: the model was never asked (`.skipped`), it answered and
/// the answer failed the gate (`.rejected`), or it answered and every line held (`.accepted`).
///
/// **Never a partial dictionary.** A правка's marks already carry the true diff without any
/// model in the loop (`docs/adr/0012`); an explanation is commentary *about* that diff, and a
/// wrong sentence sitting beside a right one is worse than no sentence at all — a reader has no
/// way to tell which is which, and every one of them would be read as endorsed by the app. So a
/// reply that fails the gate on any single line loses the whole set, the same "all or nothing"
/// shape `FormattingGate` gives a reconstructed document.
public enum ExplanationOutcome: Sendable, Equatable {
    /// One sentence per change, keyed by the change's 1-based position in `ChangeSet.changes`
    /// (the same numbering the prompt handed out and the reply was asked to echo).
    case accepted([Int: String])
    case rejected(ExplanationGate.RejectReason)
    case skipped(ExplanationGate.SkipReason)
}

/// The whole of the trust placed in an explanation reply — the `FormattingGate` pattern applied
/// to a much smaller, much more structured reply. Two jobs, matching the two moments a run can
/// end without a real answer: **before** any call is made (`skipReason`, for a change set this
/// route should not even ask about), and **after** one comes back (`parse`, for a reply that
/// asked and failed to hold shape).
///
/// Both caps are start values — this route has no live measurement yet (that is
/// `Scripts/explanation-quality.sh`'s job, and CLAUDE.md's phase-3 note says why an offline pass
/// cannot take it). They exist as named constants rather than literals so the script's protocol
/// can point at them instead of restating them, the same reason `TextDiff`'s four constants are
/// parameters with defaults rather than numbers buried in the algorithm.
public enum ExplanationGate {
    /// The longest a single explanation sentence may be. Past it a reply is rejected outright
    /// (`.sentenceTooLong`) rather than truncated — truncating would show the reader a sentence
    /// the model never wrote.
    public static let maxSentenceLength = 160

    /// Past this many changes, `explain` is not even asked: a "правка с 41 правкой" already
    /// reads better as marks alone than as forty short sentences competing with them, and a
    /// reply that size is also the one most likely to drop or duplicate a line.
    public static let maxChangeCount = 40

    /// Past this many characters of assembled material (every change's context, было and
    /// стало added together — see `Translator.explain`), the call is skipped rather than sent
    /// at a size nobody calibrated. Only the change list travels in the prompt, never the whole
    /// document, so this is a much smaller budget than a translation chunk's.
    public static let maxMaterialCharacters = 8_000

    /// Why `explain` returns `.skipped` without ever asking the model.
    public enum SkipReason: Sendable, Equatable {
        /// `ChangeSet.changes.isEmpty` — including the `notCompared` case, which produces an
        /// empty `changes` array by construction (`TextDiff.changes`), so this one reason
        /// covers both "nothing changed" and "the diff itself was never run".
        case noChanges
        case tooManyChanges(count: Int, cap: Int)
        case tooLongForOneRequest(characters: Int, limit: Int)

        /// The stable, payload-free name `Scripts/explanation-quality.sh` greps for — the same
        /// contract `FormattingRejection.rawValue` gives `format-loss.sh`, spelled as a
        /// computed property here because a skip reason carries measurements a bare `String`
        /// enum cannot.
        public var token: String {
            switch self {
            case .noChanges: "noChanges"
            case .tooManyChanges: "tooManyChanges"
            case .tooLongForOneRequest: "tooLongForOneRequest"
            }
        }
    }

    /// Whether `explain` should ask the model at all, decided before any call is made.
    public static func skipReason(changeCount: Int, materialCharacters: Int) -> SkipReason? {
        if changeCount == 0 { return .noChanges }
        if changeCount > maxChangeCount { return .tooManyChanges(count: changeCount, cap: maxChangeCount) }
        if materialCharacters > maxMaterialCharacters {
            return .tooLongForOneRequest(characters: materialCharacters, limit: maxMaterialCharacters)
        }
        return nil
    }

    /// Why a reply that was actually sent failed the gate. Each case is a sentence the app
    /// could say and the raw value `Scripts/explanation-quality.sh` greps for — the
    /// `FormattingRejection` contract again: renaming a case renames what the script counts.
    public enum RejectReason: String, Sendable, Equatable, Error {
        /// The reply carried nothing but whitespace after cleaning.
        case empty
        /// A line that is not blank and does not parse as `"N: sentence"` — prose the reply
        /// was told not to add, a numbering scheme of its own, a second sentence tacked onto
        /// one line with no number.
        case extraProse
        /// Fewer distinct indices came back than changes were asked about.
        case missingIndex
        /// The same index appeared on two lines.
        case duplicateIndex
        /// An index outside `1...changeCount` — the model invented or renumbered one.
        case outOfRangeIndex
        /// A line's sentence, after trimming, is empty — a bare `"3:"` with nothing after it.
        case emptySentence
        /// A sentence carrying `*`, `_`, `` ` ``, `#`, `[` or `]` — markup this reply is asked
        /// never to use, since it is read as plain prose, not rendered.
        case markdownMarkers
        /// A sentence longer than `maxSentenceLength`.
        case sentenceTooLong
    }

    /// One line of the expected reply shape: `"N: sentence"`, N a bare integer, one colon, at
    /// least one space, the sentence to the end of the line.
    private static func parseLine(_ line: String) -> (index: Int, sentence: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let prefix = line[line.startIndex..<colon]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber), let index = Int(prefix) else { return nil }
        let sentence = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (index, sentence)
    }

    private static let markdownMarkerCharacters = CharacterSet(charactersIn: "*_`#[]")

    private static func containsMarkdownMarkers(_ sentence: String) -> Bool {
        sentence.unicodeScalars.contains { markdownMarkerCharacters.contains($0) }
    }

    /// Parses a cleaned reply (already through `ResponseCleaner.clean`) against the
    /// `changeCount` indices the prompt asked about. Blank lines between entries are tolerated
    /// — the rule the prompt states is "one line per change", and a model that adds spacing
    /// between them has not added prose — but any non-blank line that fails to parse as
    /// `"N: sentence"` is `.extraProse`: a line that merely *looks* like a stray comment is
    /// indistinguishable from one that is, and the whole point of this gate is not to guess.
    ///
    /// **Every check that can fail stops the parse immediately** rather than collecting every
    /// defect and picking one to report — a reply is accepted or it is not, and a
    /// first-failure report is enough for a human reading `translate-cli --explain`'s stderr to
    /// find the line that broke it.
    public static func parse(_ reply: String, changeCount: Int) -> Result<[Int: String], RejectReason> {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        var accepted: [Int: String] = [:]
        for piece in LineScanner.pieces(trimmed) {
            let line = piece.content.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let (index, sentence) = parseLine(line) else { return .failure(.extraProse) }
            guard (1...max(changeCount, 1)).contains(index) else { return .failure(.outOfRangeIndex) }
            guard accepted[index] == nil else { return .failure(.duplicateIndex) }
            guard !sentence.isEmpty else { return .failure(.emptySentence) }
            guard !containsMarkdownMarkers(sentence) else { return .failure(.markdownMarkers) }
            guard sentence.count <= maxSentenceLength else { return .failure(.sentenceTooLong) }
            accepted[index] = sentence
        }
        guard accepted.count == changeCount else { return .failure(.missingIndex) }
        return .success(accepted)
    }
}
