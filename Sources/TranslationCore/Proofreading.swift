import Foundation

/// How freely правка may change the wording. The instruction is prompt material,
/// like `Tone.instruction`; the Russian labels live in the app layer
/// (`RussianCopy.swift`), keeping this target UI-agnostic.
public enum ProofreadingLevel: String, CaseIterable, Sendable {
    case errorsOnly, errorsAndStyle, rewrite

    public var instruction: String {
        switch self {
        case .errorsOnly:
            // 2026-08-10 calibration: the baseline corpus run (docs/reference/OPEN-ITEMS.md, правка
            // calibration section) showed this wording rephrasing beyond seeded errors on
            // file 02 (verb reordered, 3/3) and file 06 ("Thanks for" → "Thank you for",
            // 3/3). A candidate append — "If a sentence contains no error, reproduce it
            // unchanged, word for word." — was tried and re-measured: both failures
            // persisted 3/3, byte-identical to the pre-edit output, so the append changed
            // nothing observable. Reverted; the failure is recorded as a model limitation
            // in docs/reference/OPEN-ITEMS.md rather than left as a silent, ineffective prompt edit.
            "Fix only objective errors: spelling, punctuation, and clear grammatical mistakes. "
            + "Do not rephrase, do not reorder, do not restyle — keep every wording choice the "
            + "author made. The result must differ from the original only where an error was corrected."
        case .errorsAndStyle:
            "Fix spelling, punctuation, and grammatical errors, and also smooth awkward phrasing: "
            + "remove bureaucratic constructions, needless repetition, and clumsy word order. "
            + "Preserve the author's meaning, voice, and overall structure."
        case .rewrite:
            // «At the sentence level», and the word «structure» deliberately absent: the
            // shared protection rules two lines below this in the prompt demand exact
            // structure preservation, and an instruction inviting restructuring would
            // fight its own rule list — which rule wins is a lottery per model. Free
            // structural rewriting is a recorded non-goal (issue #40, the «rewrite
            // within structure» decision); the pipeline enforces the same boundary by
            // construction anyway — chunk separators are the source's own bytes.
            "Rewrite the text freely at the sentence level: reorder, split, or merge "
            + "sentences, replace wording, and dissolve bureaucratic phrasing wherever it "
            + "helps clarity and flow. Preserve the meaning, every fact, and the author's "
            + "register. Add nothing; omit nothing of substance."
        }
    }

    /// The single availability rule for the style controls: a rewrite style is a change
    /// of wording, so it is expressible wherever wording may change — every level above
    /// «только ошибки». The toolbar and the settings pane both read this rather than
    /// restating the comparison — a restated condition is how two surfaces come to
    /// disagree (spec §7).
    public var allowsRewriteStyle: Bool { self != .errorsOnly }

    /// The style-aware variant. When a named style accompanies a level, the clause naming
    /// what the style now owns leaves the preservation list — «voice» for `errorsAndStyle`,
    /// «the author's register» for `rewrite` — because keeping both instructions produced
    /// measured 3/3 no-ops on «дружеский» and «простой» (spec §3.1;
    /// docs/reference/OPEN-ITEMS.md §5). `errorsOnly` ignores the flag: no style ever
    /// accompanies it.
    public func instruction(styleGovernsVoice: Bool) -> String {
        guard styleGovernsVoice else { return instruction }
        switch self {
        case .errorsOnly:
            return instruction
        case .errorsAndStyle:
            return "Fix spelling, punctuation, and grammatical errors, and also smooth awkward phrasing: "
                + "remove bureaucratic constructions, needless repetition, and clumsy word order. "
                + "Preserve the author's meaning and overall structure."
        case .rewrite:
            return "Rewrite the text freely at the sentence level: reorder, split, or merge "
                + "sentences, replace wording, and dissolve bureaucratic phrasing wherever it "
                + "helps clarity and flow. Preserve the meaning and every fact. "
                + "Add nothing; omit nothing of substance."
        }
    }
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
            // 2026-08-10 calibration: the baseline corpus run showed this wording produced
            // output byte-identical to `.original`'s in 3/3 runs on file 11 — no observable
            // register shift. A more specific candidate ("direct address, light
            // contractions... no stiffness") was tried and re-measured: still
            // byte-identical to `.original` in 3/3 runs. Reverted; recorded as a model
            // limitation in docs/reference/OPEN-ITEMS.md rather than left as an ineffective edit.
            "Rewrite in a warm, friendly, informal register — the way one writes to a colleague one knows well."
        case .business:
            "Rewrite in a formal, polite business register, suitable for letters, applications, and official correspondence."
        case .professional:
            // 2026-08-10 calibration: the baseline corpus run showed no reliable register
            // shift on file 11 (2/3 runs changed only «пара»→«несколько»; the 3rd diverged
            // further — the only text-level instability in the corpus). A candidate append
            // ("Prefer established terminology over invented phrasing.") was tried, as the
            // nearest fix available though the observed failure was not literally the
            // "bureaucratese or familiarity" the decision table names; re-measured: the
            // same 2-of-3-no-shift/1-of-3-partial-shift pattern recurred. Reverted; recorded
            // as a model limitation in docs/reference/OPEN-ITEMS.md.
            "Rewrite in a precise, professional working register, suitable for documentation, reports, and workplace communication: established terminology, no bureaucratese, no familiarity."
        case .plain:
            // 2026-08-10 calibration: the baseline corpus run showed this wording produced
            // output byte-identical to `.original`'s in 3/3 runs on file 11 — no
            // simplification observed. A more specific candidate ("break long sentences...
            // replace abstract nouns with verbs...") was tried and re-measured: 2/3 runs
            // still byte-identical to `.original`, the 3rd only a cosmetic synonym swap —
            // no sentence was actually shortened or simplified. Reverted; recorded as a
            // model limitation in docs/reference/OPEN-ITEMS.md.
            "Rewrite in plain language: short sentences, simple words, maximum readability — changing nothing else about the register."
        }
    }
}
