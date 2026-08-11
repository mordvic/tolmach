// Tests/TranslationCoreTests/ModelPolicyTests.swift
import Testing
@testable import TranslationCore

@Test func defaultsMatchMeasuredRoles() {
    #expect(ModelPolicy.defaultModel(for: .interactive) == "aya-expanse:8b")
    #expect(ModelPolicy.defaultModel(for: .background) == "gpt-oss:20b")
}

@Test func blacklistedModelsCarryAReason() {
    #expect(ModelPolicy.blacklistReason(for: "gemma3n:e4b") != nil)
    #expect(ModelPolicy.blacklistReason(for: "qwen3:30b") != nil)
    #expect(ModelPolicy.blacklistReason(for: "aya-expanse:8b") == nil)
}

@Test func aQuietRunAsksAnOrdinaryModelToStopReasoning() {
    #expect(ModelPolicy.thinkRequest(for: "qwen3:8b", quiet: true, level: .low) == .off)
    #expect(ModelPolicy.thinkRequest(for: "gemma4:26b", quiet: true, level: .low) == .off)
    // A model that cannot reason at all is sent `false` too: measured HTTP 200 on all four
    // such models, and no branch is cheaper than a branch that has to be kept true. Named
    // literally rather than through `defaultModel(for:)` — the lookup could change, the
    // measurement about this model cannot.
    #expect(ModelPolicy.thinkRequest(for: "aya-expanse:8b", quiet: true, level: .low) == .off)
}

@Test func aQuietRunAsksGptOssForALevelBecauseGptOssIgnoresBeingSwitchedOff() {
    #expect(ModelPolicy.thinkRequest(for: "gpt-oss:20b", quiet: true, level: .low) == .level(.low))
    #expect(ModelPolicy.thinkRequest(for: "gpt-oss:120b", quiet: true, level: .high) == .level(.high))
}

@Test func aQuietRunLeavesAModelAloneWhenDisablingWouldPutTheReasoningInTheTranslation() {
    #expect(ModelPolicy.thinkRequest(for: "qwen3:30b", quiet: true, level: .low) == nil)
    // The neighbouring tag must not be caught by the same prefix.
    #expect(ModelPolicy.thinkRequest(for: "qwen3:8b", quiet: true, level: .low) == .off)
}

@Test func aModelInBothTablesIsAskedForALevelRatherThanLeftAlone() {
    // Nothing is in both today. The order is pinned anyway, because the two rules answer
    // differently and only one of them produces a working instruction.
    #expect(ModelPolicy.thinkingLevelsOnly.contains("gpt-oss"))
    #expect(ModelPolicy.thinkingDisableLeaks["qwen3:30b"] != nil)
}

@Test func anUnquietRunSendsNothingWhateverTheModelAndWhateverTheLevel() {
    for model in ["qwen3:8b", "gpt-oss:20b", "qwen3:30b", "aya-expanse:8b"] {
        for level in ThinkRequest.Level.allCases {
            #expect(ModelPolicy.thinkRequest(for: model, quiet: false, level: level) == nil)
        }
    }
}

@Test func everyReasonInTheDisableLeaksTableIsWorthReading() {
    // Same contract as the blacklist: a table of bare prefixes is a table nobody dares change.
    for (prefix, reason) in ModelPolicy.thinkingDisableLeaks {
        #expect(!prefix.isEmpty)
        #expect(reason.count > 40)
    }
}
