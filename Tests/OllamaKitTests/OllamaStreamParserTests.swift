// Tests/OllamaKitTests/OllamaStreamParserTests.swift
import Testing
@testable import OllamaKit
@testable import TranslationCore

@Test func parsesContentToken() {
    let event = OllamaStreamParser.parse(line: #"{"message":{"role":"assistant","content":"OK"},"done":false}"#)
    guard case .token(let text)? = event else { Issue.record("expected token"); return }
    #expect(text == "OK")
}

@Test func discardsThinkingAndEmptyContent() {
    let event = OllamaStreamParser.parse(line: #"{"message":{"role":"assistant","thinking":"let me think","content":""},"done":false}"#)
    #expect(event == nil)
}

@Test func parsesDoneWithNanosecondToMillisecondConversion() {
    let line = #"{"message":{"content":""},"done":true,"total_duration":2143180000,"load_duration":1995376625,"prompt_eval_count":64,"prompt_eval_duration":91362000,"eval_count":3,"eval_duration":50088000}"#
    guard case .done(let stats)? = OllamaStreamParser.parse(line: line) else { Issue.record("expected done"); return }
    #expect(stats.loadDurationMS == 1995.376625)
    #expect(stats.evalCount == 3)
    #expect(abs(stats.evalDurationMS - 50.088) < 0.001)
}

@Test func returnsNilForBlankOrGarbageLine() {
    #expect(OllamaStreamParser.parse(line: "") == nil)
    #expect(OllamaStreamParser.parse(line: "not json") == nil)
}
