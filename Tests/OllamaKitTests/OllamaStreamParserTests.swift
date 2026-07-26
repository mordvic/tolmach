// Tests/OllamaKitTests/OllamaStreamParserTests.swift
import Testing
@testable import OllamaKit
@testable import TranslationCore

@Test func parsesContentToken() {
    let events = OllamaStreamParser.parse(line: #"{"message":{"role":"assistant","content":"OK"},"done":false}"#)
    #expect(events.count == 1)
    guard case .token(let text) = events.first else { Issue.record("expected token"); return }
    #expect(text == "OK")
}

@Test func discardsThinkingAndEmptyContent() {
    let events = OllamaStreamParser.parse(line: #"{"message":{"role":"assistant","thinking":"let me think","content":""},"done":false}"#)
    #expect(events.isEmpty)
}

@Test func parsesDoneWithNanosecondToMillisecondConversion() {
    let line = #"{"message":{"content":""},"done":true,"total_duration":2143180000,"load_duration":1995376625,"prompt_eval_count":64,"prompt_eval_duration":91362000,"eval_count":3,"eval_duration":50088000}"#
    let events = OllamaStreamParser.parse(line: line)
    #expect(events.count == 1)
    guard case .done(let stats) = events.first else { Issue.record("expected done"); return }
    #expect(stats.loadDurationMS == 1995.376625)
    #expect(stats.evalCount == 3)
    #expect(abs(stats.evalDurationMS - 50.088) < 0.001)
}

@Test func returnsEmptyForBlankOrGarbageLine() {
    #expect(OllamaStreamParser.parse(line: "").isEmpty)
    #expect(OllamaStreamParser.parse(line: "not json").isEmpty)
}

@Test func combinedContentAndDoneFrameReturnsBothEventsTokenFirst() {
    // A frame carrying both a real (non-empty) content token and done:true must
    // not lose the token. Previously the done check ran first and returned early,
    // silently truncating the translation by one token whenever a frame like this
    // arrived.
    let line = #"{"message":{"content":"."},"done":true,"total_duration":1,"load_duration":1,"prompt_eval_count":1,"prompt_eval_duration":1,"eval_count":1,"eval_duration":1}"#
    let events = OllamaStreamParser.parse(line: line)
    #expect(events.count == 2)
    guard case .token(let text) = events[0] else { Issue.record("expected token first"); return }
    #expect(text == ".")
    guard case .done = events[1] else { Issue.record("expected done second"); return }
}
