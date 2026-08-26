// Tests/OllamaKitTests/PullProgressParserTests.swift
import Testing
@testable import OllamaKit

@Test func parsesADownloadProgressLine() throws {
    let line = #"{"status":"pulling manifest","completed":128,"total":512}"#
    let progress = try PullProgressParser.parse(line: line)
    #expect(progress?.status == "pulling manifest")
    #expect(progress?.completed == 128)
    #expect(progress?.total == 512)
    #expect(progress?.fraction == 0.25)
}

@Test func aStatusWithoutByteCountsHasNoFraction() throws {
    // Ollama sends bare status lines ("verifying sha256 digest") with no totals.
    let progress = try PullProgressParser.parse(line: #"{"status":"verifying sha256 digest"}"#)
    #expect(progress?.status == "verifying sha256 digest")
    #expect(progress?.fraction == nil)
}

@Test func aZeroTotalDoesNotDivideByZero() throws {
    let progress = try PullProgressParser.parse(line: #"{"status":"x","completed":0,"total":0}"#)
    #expect(progress?.fraction == nil)
}

@Test func blankAndGarbageLinesYieldNothing() throws {
    #expect(try PullProgressParser.parse(line: "") == nil)
    #expect(try PullProgressParser.parse(line: "not json") == nil)
}

/// The defect. Requiring `status` made an in-stream `{"error": …}` line answer nil, so it was
/// dropped and `pull` finished without throwing: the bar cleared, no error was set, the list
/// reloaded, and the model was simply not there.
///
/// Measured 2026-08-26 against Ollama 0.32.14 — `POST /api/pull` for a model that does not exist
/// answers **HTTP 200**, sends `{"status":"pulling manifest"}`, then exactly this line and
/// nothing further. `LMStudioDownload` has thrown on its equivalent since it was written.
@Test func anErrorLineIsThrownRatherThanReadAsNoProgress() {
    #expect(throws: OllamaError.self) {
        _ = try PullProgressParser.parse(line: #"{"error":"pull model manifest: file does not exist"}"#)
    }
}

/// The line that precedes it in the same measured stream still parses, so the throw above is
/// about the error key and not about anything else on the wire.
@Test func theStatusLineBeforeAnErrorStillParses() throws {
    #expect(try PullProgressParser.parse(line: #"{"status":"pulling manifest"}"#)?.status
            == "pulling manifest")
}
