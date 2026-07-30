// Tests/OllamaKitTests/PullProgressParserTests.swift
import Testing
@testable import OllamaKit

@Test func parsesADownloadProgressLine() {
    let line = #"{"status":"pulling manifest","completed":128,"total":512}"#
    let progress = PullProgressParser.parse(line: line)
    #expect(progress?.status == "pulling manifest")
    #expect(progress?.completed == 128)
    #expect(progress?.total == 512)
    #expect(progress?.fraction == 0.25)
}

@Test func aStatusWithoutByteCountsHasNoFraction() {
    // Ollama sends bare status lines ("verifying sha256 digest") with no totals.
    let progress = PullProgressParser.parse(line: #"{"status":"verifying sha256 digest"}"#)
    #expect(progress?.status == "verifying sha256 digest")
    #expect(progress?.fraction == nil)
}

@Test func aZeroTotalDoesNotDivideByZero() {
    let progress = PullProgressParser.parse(line: #"{"status":"x","completed":0,"total":0}"#)
    #expect(progress?.fraction == nil)
}

@Test func blankAndGarbageLinesYieldNothing() {
    #expect(PullProgressParser.parse(line: "") == nil)
    #expect(PullProgressParser.parse(line: "not json") == nil)
}
