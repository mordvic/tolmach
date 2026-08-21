// Tests/LMStudioKitTests/LMStudioErrorParserTests.swift
import Testing
import Foundation
@testable import LMStudioKit

@Test func a401BecomesTheOneFailureTheUserCanActOnRatherThanAGenericRefusal() {
    // Authentication is off by default — measured 2026-08-21, HTTP 200 with no header — so a
    // 401 means the user switched «Require Authentication» on. This app holds no token by
    // design, so the remedy is a specific sentence, not «HTTP 401».
    let mapped = LMStudioErrorParser.parse(body: Data(#"{"error":{"message":"unauthorized"}}"#.utf8),
                                           status: 401)
    #expect(mapped == .authenticationRequired)
}

@Test func aRefusalKeepsTheServersMachineCodeSoRussianCopyCanBeKeyedOnIt() {
    // Keyed on `code`, never on the prose: the message is English and the server is free to
    // rephrase it. All three of these were observed verbatim on 2026-08-21.
    let body = #"""
    {"error":{"message":"Invalid model identifier \"translategemma:27b\".","type":"invalid_request","param":"model","code":"model_not_found"}}
    """#
    let mapped = LMStudioErrorParser.parse(body: Data(body.utf8), status: 404)
    #expect(mapped == .server(code: "model_not_found", type: "invalid_request",
                              message: "Invalid model identifier \"translategemma:27b\"."))
}

@Test func aBodyThatIsNotTheServersErrorObjectKeepsTheStatusAndTheBytes() {
    // A proxy, a crash page, an empty body. Reporting «the server refused and said nothing»
    // would throw away the only evidence there is.
    let mapped = LMStudioErrorParser.parse(body: Data("<html>502</html>".utf8), status: 502)
    #expect(mapped == .httpStatus(502, "<html>502</html>"))
}
