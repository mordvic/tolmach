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
