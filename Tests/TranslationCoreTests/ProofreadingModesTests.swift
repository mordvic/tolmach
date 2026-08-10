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
