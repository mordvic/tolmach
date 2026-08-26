import Testing
import Foundation
@testable import TranslatorApp

/// Error descriptions reach the unified log `.public`, because `<private>` would make the
/// entries useless for the diagnosis they exist for. That is safe for this app's own error
/// values and for `URLError`; it is not safe on its own for the message an engine sends back.
/// LM Studio's mid-stream `error` frame carries a server-chosen string of any length, and
/// interpolated whole it would write as much of it into the log as the server cared to send.
@Test func aServerMessageLongerThanTheCapIsTruncatedAndSaysSo() {
    let long = String(repeating: "я", count: Log.maxServerMessage * 4)
    let capped = Log.capped(long)
    #expect(capped.count == Log.maxServerMessage + 1)   // the ellipsis is the one extra
    #expect(capped.hasSuffix("…"))
    #expect(long.hasPrefix(capped.dropLast()))
}

/// The messages both engines actually send are well inside the cap, and must come through
/// whole — a diagnostic truncated to nothing is the failure mode of capping too hard.
@Test func theMessagesTheEnginesActuallySendAreNotTouched() {
    for message in ["unrecognized_keys", "invalid_value",
                    "pull model manifest: file does not exist",
                    "Ollama is not reachable. Start it with `ollama serve`."] {
        #expect(Log.capped(message) == message)
    }
    // The boundary itself: exactly at the cap is not truncated.
    let exact = String(repeating: "a", count: Log.maxServerMessage)
    #expect(Log.capped(exact) == exact)
}
