import Foundation

/// How freely правка may change the wording. The instruction is prompt material,
/// like `Tone.instruction`; the Russian labels live in the app layer
/// (`RussianCopy.swift`), keeping this target UI-agnostic.
public enum ProofreadingLevel: String, CaseIterable, Sendable {
    case errorsOnly, errorsAndStyle

    public var instruction: String {
        switch self {
        case .errorsOnly:
            "Fix only objective errors: spelling, punctuation, and clear grammatical mistakes. "
            + "Do not rephrase, do not reorder, do not restyle — keep every wording choice the "
            + "author made. The result must differ from the original only where an error was corrected."
        case .errorsAndStyle:
            "Fix spelling, punctuation, and grammatical errors, and also smooth awkward phrasing: "
            + "remove bureaucratic constructions, needless repetition, and clumsy word order. "
            + "Preserve the author's meaning, voice, and overall structure."
        }
    }

    /// The single availability rule for the style controls: a rewrite style is a change
    /// of wording, so it is expressible only where wording may change. The toolbar and
    /// the settings pane both read this rather than restating the comparison — a restated
    /// condition is how two surfaces come to disagree (spec §7).
    public var allowsRewriteStyle: Bool { self == .errorsAndStyle }
}

/// The register a rewrite aims at. `.original` — «как в оригинале» — is a case rather
/// than an absent optional, exactly as `Tone.neutral` is a case: `nil` keeps its
/// app-wide meaning of «no override, follow the setting», and no double optional
/// appears anywhere (spec §4.1).
public enum RewriteStyle: String, CaseIterable, Sendable {
    case original, friendly, business, professional, plain

    /// Nil for `.original`: keeping the author's register needs no instruction, and an
    /// instruction saying «keep it» would dilute the level instruction next to it.
    public var instruction: String? {
        switch self {
        case .original:
            nil
        case .friendly:
            "Rewrite in a warm, friendly, informal register — the way one writes to a colleague one knows well."
        case .business:
            "Rewrite in a formal, polite business register, suitable for letters, applications, and official correspondence."
        case .professional:
            "Rewrite in a precise, professional working register, suitable for documentation, reports, and workplace communication: established terminology, no bureaucratese, no familiarity."
        case .plain:
            "Rewrite in plain language: short sentences, simple words, maximum readability — changing nothing else about the register."
        }
    }
}
