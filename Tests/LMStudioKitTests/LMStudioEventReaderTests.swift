// Tests/LMStudioKitTests/LMStudioEventReaderTests.swift
import Testing
import Foundation
@testable import LMStudioKit
@testable import TranslationCore

private func events(_ line: String) throws -> [ChatEvent] {
    guard let frame = SSEFrameParser.frame(from: line) else { return [] }
    return try LMStudioEventReader.events(for: frame)
}

@Test func aMessageDeltaCarriesItsTokenInTheContentField() throws {
    // Not `delta`: the field is `content`, verbatim from the server on 2026-08-21. The
    // documentation index this project first read said `delta`, and a client believing it
    // streams nothing at all.
    let read = try events(#"data: {"type":"message.delta","content":"Привет"}"#)
    #expect(read == [.token("Привет")])
}

@Test func aReasoningDeltaYieldsNoTokenEvenThoughItCarriesTheSameContentField() throws {
    // The property this whole module exists to preserve: a model's reasoning must not reach the
    // translation. Both events carry `content`, and the *only* thing telling them apart is
    // `type` — so the fixture uses identical content on purpose. A reader that forwarded any
    // `content` it saw would pass a test that used different strings.
    let reasoning = try events(#"data: {"type":"reasoning.delta","content":"Привет"}"#)
    let message = try events(#"data: {"type":"message.delta","content":"Привет"}"#)
    #expect(reasoning.isEmpty)
    #expect(message == [.token("Привет")])
}

@Test func theLifecycleEventsYieldNothingAndMayRepeatWithoutDisturbingTheTokens() throws {
    // `prompt_processing.end` arrived **twice** in one measured `gpt-oss` stream, and
    // `message.start` / `message.end` carry `{}`. A reader that assumed one of each, or that
    // treated an empty object as malformed, would break on a stream the server really sends.
    let lifecycle = [
        #"data: {"type":"chat.start","model_instance_id":"openai/gpt-oss-20b"}"#,
        #"data: {"type":"model_load.start","model_instance_id":"openai/gpt-oss-20b"}"#,
        #"data: {"type":"model_load.progress","model_instance_id":"x","progress":0.5}"#,
        #"data: {"type":"model_load.end","model_instance_id":"x","load_time_seconds":8.134}"#,
        #"data: {"type":"prompt_processing.start"}"#,
        #"data: {"type":"prompt_processing.end"}"#,
        #"data: {"type":"prompt_processing.end"}"#,
        #"data: {"type":"reasoning.start"}"#,
        #"data: {"type":"reasoning.end"}"#,
        #"data: {"type":"message.start"}"#,
        #"data: {"type":"message.end"}"#,
    ]
    for line in lifecycle { #expect(try events(line).isEmpty, "\(line) produced an event") }
}

@Test func aWholeMeasuredStreamYieldsTheTranslationAndNothingElse() throws {
    // The `gpt-oss` run of 2026-08-21 in miniature: reasoning first, then the answer. What a
    // caller receives must be the answer alone, in order, followed by completion.
    let stream = [
        #"data: {"type":"chat.start","model_instance_id":"openai/gpt-oss-20b"}"#,
        #"data: {"type":"reasoning.start"}"#,
        #"data: {"type":"reasoning.delta","content":"Translate \"Hello, world.\""}"#,
        #"data: {"type":"reasoning.delta","content":" It's \"Привет, мир.\""}"#,
        #"data: {"type":"reasoning.end"}"#,
        #"data: {"type":"message.start"}"#,
        #"data: {"type":"message.delta","content":"Привет"}"#,
        #"data: {"type":"message.delta","content":", мир."}"#,
        #"data: {"type":"message.end"}"#,
        #"data: {"type":"chat.end","result":{"stats":{"input_tokens":87,"total_output_tokens":31}}}"#,
    ]
    let read = try stream.flatMap { try events($0) }
    #expect(read.count == 3)
    #expect(read[0] == .token("Привет"))
    #expect(read[1] == .token(", мир."))
    guard case let .done(stats) = read[2] else {
        Issue.record("the stream did not end with a done event")
        return
    }
    // 31 output tokens against 2 content deltas — the trace is counted by the server and
    // discarded here, which is exactly the state this module is supposed to leave a caller in.
    #expect(stats.evalCount == 31)
}

@Test func anEmptyMessageDeltaIsNotAToken() throws {
    // `OllamaStreamParser` has the same guard: a done frame was observed carrying
    // `"content":""`, and an empty token would stamp the time-to-first-token clock with
    // nothing on screen.
    #expect(try events(#"data: {"type":"message.delta","content":""}"#).isEmpty)
}

@Test func statisticsAreReadFromChatEndsNestedResultAndNotFromItsTopLevel() throws {
    // Captured from the live server on 2026-08-21. The documentation puts `usage` and
    // `message` at the top level of this event; the server nests everything under `result`,
    // so a reader following the documentation finds no numbers at all.
    let line = #"""
    data: {"type":"chat.end","result":{"model_instance_id":"google/gemma-4-e4b","output":[{"type":"message","content":"Привет, мир. Это тест."}],"stats":{"input_tokens":35,"total_output_tokens":8,"reasoning_output_tokens":0,"tokens_per_second":57.67937836049972,"time_to_first_token_seconds":0.107,"model_load_time_seconds":7.183}}}
    """#
    let read = try events(line)
    guard case let .done(stats) = read.first else {
        Issue.record("chat.end did not produce a done event: \(read)")
        return
    }
    #expect(stats.promptEvalCount == 35)
    #expect(stats.evalCount == 8)
    #expect((stats.loadDurationMS).rounded() == 7183)
    // Reported in seconds by this server and in nanoseconds by Ollama's; both are converted at
    // the client boundary, so a caller never learns which server it was talking to.
    #expect(stats.loadDurationMS > 1000)
}

@Test func generationSpeedSurvivesTheConversionInsteadOfReadingAsZero() throws {
    // `ChatStats.tokensPerSecond` divides by `evalDurationMS`, and this server reports a speed
    // rather than a duration. Leaving the duration at zero made a model generating 57.7 tokens
    // a second report a flat 0 — so the duration is inverted from the server's own figure.
    let line = #"""
    data: {"type":"chat.end","result":{"stats":{"input_tokens":35,"total_output_tokens":8,"tokens_per_second":57.67937836049972,"model_load_time_seconds":7.183}}}
    """#
    guard case let .done(stats) = try events(line).first else {
        Issue.record("chat.end did not produce a done event")
        return
    }
    #expect((stats.tokensPerSecond * 100).rounded() / 100 == 57.68)
}

@Test func aChatEndWithoutASpeedLeavesTheDurationAbsentRatherThanInventingOne() throws {
    // The other half of the rule above: a fabricated duration is worse than an absent one,
    // because it reads as a measurement.
    guard case let .done(stats) = try events(#"data: {"type":"chat.end","result":{"stats":{"total_output_tokens":8}}}"#).first else {
        Issue.record("chat.end did not produce a done event")
        return
    }
    #expect(stats.evalDurationMS == 0)
    #expect(stats.tokensPerSecond == 0)
}

@Test func anErrorEventThrowsInsteadOfLettingTheStreamFinishQuietly() {
    // The documented behaviour, and the hazard: «the final payload will still be sent in
    // chat.end». A reader that merely carried on would hand a caller half a translation
    // labelled success — the same shape as a cancelled `AsyncThrowingStream` finishing
    // instead of throwing.
    let line = #"data: {"type":"error","error":{"type":"invalid_request","message":"\"model\" is required","code":"missing"}}"#
    #expect(throws: LMStudioError.server(code: "missing", type: "invalid_request",
                                         message: "\"model\" is required")) {
        try events(line)
    }
}
