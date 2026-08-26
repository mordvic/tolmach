import Testing
import Foundation
@testable import LMStudioKit

/// ADR 0009 keeps the host as a literal in code so nobody can point this app at a remote
/// server — but a `URLSession` with no delegate follows redirects by default, and a `307`/`308`
/// re-POSTs the **body**. So any unprivileged process that binds the configured loopback port
/// while the engine is down can answer `307 Location: https://…` and receive the user's
/// selection, their glossary and the whole prompt, with no error and no trace in the UI.
///
/// Tested by calling the delegate method directly. That is the whole of the decision — there is
/// no `URLSessionConfiguration` flag for it — and it needs no server to check.
@Test func everyRedirectIsRefusedByLMStudiosClientToo() async {
    let policy = RedirectPolicy()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: URLRequest(url: LMStudioClient.defaultBaseURL))
    defer { task.cancel(); session.invalidateAndCancel() }

    for status in [301, 302, 303, 307, 308] {
        let response = HTTPURLResponse(url: LMStudioClient.defaultBaseURL, statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://evil.example/collect"])!
        let followed: URLRequest? = await withCheckedContinuation { continuation in
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: URL(string: "https://evil.example/collect")!)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(followed == nil, "a \(status) was followed")
    }
}

/// A redirect **to loopback** is refused too, and deliberately so. «Same host» is not a
/// property this code can check meaningfully — whatever is answering on the port chose the
/// `Location` — and a rule with an exception is a rule someone has to get right twice.
@Test func aRedirectToLoopbackIsRefusedByLMStudiosClientToo() async {
    let policy = RedirectPolicy()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: URLRequest(url: LMStudioClient.defaultBaseURL))
    defer { task.cancel(); session.invalidateAndCancel() }

    let response = HTTPURLResponse(url: LMStudioClient.defaultBaseURL, statusCode: 307,
                                   httpVersion: "HTTP/1.1", headerFields: [:])!
    let followed: URLRequest? = await withCheckedContinuation { continuation in
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                          newRequest: URLRequest(url: LMStudioClient.baseURL(port: 1235))) {
            continuation.resume(returning: $0)
        }
    }
    #expect(followed == nil)
}
