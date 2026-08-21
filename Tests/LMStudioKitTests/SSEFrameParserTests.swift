// Tests/LMStudioKitTests/SSEFrameParserTests.swift
import Testing
import Foundation
@testable import LMStudioKit

@Test func aDataLineYieldsItsDecodedPayloadAndItsType() {
    let frame = SSEFrameParser.frame(from: #"data: {"type":"message.delta","content":"Привет"}"#)
    #expect(frame?.type == "message.delta")
    #expect(frame?.json["content"] as? String == "Привет")
}

@Test func theEventLineIsIgnoredBecauseThePayloadCarriesItsOwnType() {
    // The framing is `event: <type>` then `data: <json>`. The type is in both, on every frame
    // measured, so this parser reads the payload only — which is what keeps it stateless, and
    // what keeps it testable one line at a time.
    #expect(SSEFrameParser.frame(from: "event: message.delta") == nil)
}

@Test func aDataLineIsAcceptedWithOrWithoutTheSpaceAfterTheColon() {
    // Both are legal SSE. A parser that took only one of them would be reading the wire by
    // luck rather than by contract.
    #expect(SSEFrameParser.frame(from: #"data:{"type":"message.end"}"#)?.type == "message.end")
    #expect(SSEFrameParser.frame(from: #"data: {"type":"message.end"}"#)?.type == "message.end")
}

@Test func theLinesThatCarryNoPayloadYieldNoFrame() {
    // Blank lines separate frames; `[DONE]` is the sentinel other OpenAI-shaped servers send
    // and is not JSON. Neither may become a frame, and neither may throw.
    for line in ["", "  ", "data: ", "data: [DONE]", ": keep-alive", "id: 7"] {
        #expect(SSEFrameParser.frame(from: line) == nil, "«\(line)» became a frame")
    }
}

@Test func aPayloadThatIsNotJSONOrCarriesNoTypeIsIgnoredRatherThanThrowing() {
    // Same discipline as `OllamaStreamParser`: a line this client cannot read is skipped, so
    // one malformed frame cannot end a translation that is otherwise arriving.
    #expect(SSEFrameParser.frame(from: "data: not json") == nil)
    #expect(SSEFrameParser.frame(from: #"data: {"content":"Привет"}"#) == nil)
    #expect(SSEFrameParser.frame(from: #"data: ["message.delta"]"#) == nil)
}
