// Tests/OllamaKitTests/OllamaUnloadBodyTests.swift
import Testing
import Foundation
@testable import OllamaKit

@Test func anUnloadBodyCarriesAnEmptyMessageListAndAZeroKeepAlive() {
    // Ollama has no unload endpoint: «if the messages array is empty and the keep_alive
    // parameter is set to 0, a model will be unloaded from memory», answering
    // `done_reason: "unload"`. Both halves are load-bearing — a non-empty list would translate
    // something, and a missing zero would *extend* the model's stay instead of ending it.
    let body = OllamaUnloadBody.json(model: "translategemma:27b")
    #expect(body["model"] as? String == "translategemma:27b")
    #expect((body["messages"] as? [[String: String]])?.isEmpty == true)
    #expect(body["keep_alive"] as? Int == 0)
    // A JSON *number*, not the string «0». `keep_alive` accepts a duration string elsewhere in
    // this client («30m»), and «0» as a string is the shape most likely to be written by
    // someone copying `ChatOptions.keepAlive`.
    #expect(body["keep_alive"] as? String == nil)
}

@Test func anUnloadDoesNotAskForAStreamItWouldHaveToDrain() {
    #expect(OllamaUnloadBody.json(model: "aya-expanse:8b")["stream"] as? Bool == false)
}

@Test func theUnloadBodyIsSerialisableAsJSON() {
    #expect(throws: Never.self) {
        try JSONSerialization.data(withJSONObject: OllamaUnloadBody.json(model: "aya-expanse:8b"))
    }
}

@Test func onlyADoneReasonOfUnloadConfirmsTheModelWasFreed() {
    // HTTP 200 is not the confirmation. A server that ignored the zero answers 200 with
    // `done_reason: "stop"`, and calling that a successful unload would show «выгружено» over
    // an unchanged memory figure.
    #expect(OllamaUnloadBody.confirmsUnload(Data(#"{"done":true,"done_reason":"unload"}"#.utf8)) == true)
    #expect(OllamaUnloadBody.confirmsUnload(Data(#"{"done":true,"done_reason":"stop"}"#.utf8)) == false)
}

@Test func anUnreadableReplyIsNotReadAsARefusalToUnload() {
    // Nil, not false: this round trip has never been seen on a live server, so «said nothing»
    // must not be reported to the user as «said no».
    #expect(OllamaUnloadBody.confirmsUnload(Data("not json".utf8)) == nil)
    #expect(OllamaUnloadBody.confirmsUnload(Data(#"{"done":true}"#.utf8)) == nil)
}
