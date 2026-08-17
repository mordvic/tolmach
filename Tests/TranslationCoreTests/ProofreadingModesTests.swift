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

@Test func onlyErrorsAndStyleAllowsARewriteStyle() {
    // The one availability rule both the toolbar and the settings pane read (spec §7).
    #expect(!ProofreadingLevel.errorsOnly.allowsRewriteStyle)
    #expect(ProofreadingLevel.errorsAndStyle.allowsRewriteStyle)
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
