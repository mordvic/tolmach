import Testing
import Foundation
@testable import OllamaKit

/// What these can and cannot say, stated up front because it decides how to read them.
///
/// **Covered:** the table of intervals, and that `request(_:timeout:method:)` puts the one it
/// is handed onto the `URLRequest` — which is the whole reason that builder exists as a
/// function rather than as four inline constructions.
///
/// **Not covered:** the wiring. Whether `chat` asks for `Timeout.interactive` and `models()`
/// for `Timeout.probe` cannot be observed from a test process: the requests are built inside
/// the calls, and the only way to see one is to let it reach a server. Pointing `chat` at
/// `Timeout.pull` would leave every assertion here green. This is `docs/reference/TESTING.md` shape 5 —
/// testing the builder while the wiring goes unchecked — and it is written down rather than
/// papered over, because the alternative on offer is a test that waits out a real timeout.
struct OllamaTimeoutTests {}

/// The three are an ordering before they are three numbers, and the ordering is the part that
/// carries meaning: a health probe must give up before a translation does, and a translation
/// before a multi-gigabyte download. Asserted as `<` rather than as three literals so that
/// re-tuning any one of them stays possible while inverting two of them does not.
@Test func theTimeoutsAreOrderedByHowLongTheirCallIsAllowedToBeSilent() {
    #expect(OllamaClient.Timeout.probe < OllamaClient.Timeout.interactive)
    #expect(OllamaClient.Timeout.interactive < OllamaClient.Timeout.pull)
}

/// The literals too, because the ordering alone would survive all three being set to the same
/// order of magnitude — which is exactly the state this change exists to leave behind, when
/// every call shared 120 s. Each number's reasoning is on `OllamaClient.Timeout`; a change
/// here should be a change there.
@Test func theInteractivePathIsNotAllowedToInheritTheDownloadTimeout() {
    #expect(OllamaClient.Timeout.probe == 10)
    #expect(OllamaClient.Timeout.interactive == 30)
    #expect(OllamaClient.Timeout.pull == 120)
}

/// The builder's contract, all three parts of it. Path and method are asserted alongside the
/// interval on purpose: a builder that dropped the method would send every request as `GET`,
/// and `/api/chat` would answer 405 rather than translating — a failure that has nothing to do
/// with timeouts and would otherwise be found by a human with a running server.
@Test func theRequestBuilderAppliesTheTimeoutThePathAndTheMethod() {
    let client = OllamaClient()

    let probe = client.request("api/tags", timeout: OllamaClient.Timeout.probe)
    #expect(probe.timeoutInterval == 10)
    #expect(probe.httpMethod == "GET")
    #expect(probe.url?.path == "/api/tags")

    let chat = client.request("api/chat", timeout: OllamaClient.Timeout.interactive, method: "POST")
    #expect(chat.timeoutInterval == 30)
    #expect(chat.httpMethod == "POST")
    #expect(chat.url?.path == "/api/chat")
}

/// The per-request override has to be *narrower* than the session's own value or it buys
/// nothing — `URLRequest.timeoutInterval` supersedes
/// `URLSessionConfiguration.timeoutIntervalForRequest`, so a request asking for more than the
/// session allows is the one case where the table above would be silently ineffective.
@Test func theSessionsOwnTimeoutIsTheCeilingTheOverridesStayUnder() {
    let client = OllamaClient()
    #expect(client.session.configuration.timeoutIntervalForRequest == OllamaClient.Timeout.pull)
    #expect(OllamaClient.Timeout.interactive < client.session.configuration.timeoutIntervalForRequest)
    #expect(OllamaClient.Timeout.probe < client.session.configuration.timeoutIntervalForRequest)
}

/// The base URL is not rewritten by the builder. `appendingPathComponent` on a URL that
/// already carries a port is where an off-by-one in the path would show up as a request to the
/// wrong host entirely.
@Test func theBuilderKeepsTheHostAndPortItWasConfiguredWith() {
    let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:99999")!)
    let request = client.request("api/ps", timeout: OllamaClient.Timeout.probe)
    #expect(request.url?.absoluteString == "http://127.0.0.1:99999/api/ps")
}
