import Testing
@testable import TranslationCore

@Test func everyProofreadingLevelCarriesANonEmptyInstruction() {
    for level in ProofreadingLevel.allCases {
        #expect(!level.instruction.isEmpty)
    }
}

@Test func errorsOnlyForbidsRephrasingAndErrorsAndStyleNamesAwkwardPhrasing() {
    #expect(ProofreadingLevel.errorsOnly.instruction.lowercased().contains("do not rephrase"))
    #expect(ProofreadingLevel.errorsAndStyle.instruction.lowercased().contains("awkward"))
}

@Test func everyLevelAboveErrorsOnlyAllowsARewriteStyle() {
    // The one availability rule both the toolbar and the settings pane read (spec §7).
    #expect(!ProofreadingLevel.errorsOnly.allowsRewriteStyle)
    #expect(ProofreadingLevel.errorsAndStyle.allowsRewriteStyle)
    #expect(ProofreadingLevel.rewrite.allowsRewriteStyle)
}

@Test func rewriteFreesTheSentenceAndNeverNamesStructure() {
    // «Structure» must not appear: the shared protection rules two lines below the level
    // instruction demand exact structure preservation, and an instruction fighting its own
    // rule list is a lottery per model (issue #40 — the Q15 «rewrite within structure»
    // decision).
    let instruction = ProofreadingLevel.rewrite.instruction
    #expect(instruction.contains("sentence level"))
    #expect(!instruction.lowercased().contains("structure"))
    // Lossless rewrite, not a summary — the trust contract behind «Заменить».
    #expect(instruction.contains("every fact"))
    #expect(instruction.contains("omit nothing"))
}

@Test func rewriteKeepsTheRegisterOnlyUntilAStyleGovernsIt() {
    // Same mechanism as errorsAndStyle dropping «voice»: with «как в оригинале» the level
    // owns the register; a named style takes it over, so the clause leaves the instruction
    // rather than fighting the style beside it (measured 3/3 no-ops on the errorsAndStyle
    // pair, spec §3.1 — the same conflict shape, avoided rather than re-measured).
    #expect(ProofreadingLevel.rewrite.instruction.contains("author's register"))
    let governed = ProofreadingLevel.rewrite.instruction(styleGovernsVoice: true)
    #expect(!governed.contains("register"))
    #expect(governed.contains("every fact"))
    // errorsOnly still ignores the flag: no style ever accompanies it.
    #expect(ProofreadingLevel.errorsOnly.instruction(styleGovernsVoice: true)
            == ProofreadingLevel.errorsOnly.instruction)
}

@Test func originalContributesNoInstructionAndEveryOtherStyleDoes() {
    // «Как в оригинале» is a case, not an absence (spec §4.1) — and its instruction
    // is nil so the prompt builder has nothing to append for it.
    #expect(RewriteStyle.original.instruction == nil)
    for style in RewriteStyle.allCases where style != .original {
        #expect(style.instruction?.isEmpty == false)
    }
}

// 2026-08-10 calibration (docs/reference/OPEN-ITEMS.md, правка calibration section): candidate
// rewordings for errorsOnly, friendly, professional and plain were tried against the
// live corpus and reverted — none moved the measured output in the majority of 3 runs.
// No pin is added for reverted wording; the negative result is recorded in
// docs/reference/OPEN-ITEMS.md instead of asserted here as if it held.
