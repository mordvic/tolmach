// Sources/LMStudioKit/RedirectPolicy.swift
import Foundation

/// A `URLSession` delegate that refuses every HTTP redirect.
///
/// **This is what makes «text never leaves the machine» true against a hostile port, rather than
/// only against a misconfigured one.** ADR 0009 keeps the host as a literal in code so nobody
/// can point this app at a remote server — but a session with no delegate follows redirects by
/// default, and a `307`/`308` re-POSTs the *body*. So any unprivileged process that binds
/// `127.0.0.1:1234` while LM Studio is down can answer every request with
/// `307 Location: https://…` and receive the user's selection, their glossary and the whole
/// prompt, with no error and no trace in the UI. The loopback literal is not a boundary if the
/// transport will walk across it when asked politely.
///
/// Returning `nil` from the delegate does not fail the task: the redirect response itself
/// becomes the result, so the client's own status guard sees a `3xx` and throws
/// `httpStatus` — an ordinary failed request rather than a silent success somewhere else.
///
/// **There is no configuration flag for this.** `URLSessionConfiguration` has no
/// «do not redirect»; a delegate is the only mechanism, which is why this type exists at all.
///
/// **The session holds it strongly until `invalidate*()`, and that is deliberate.** These
/// clients live for the whole process and are never invalidated, so the delegate lives that long
/// too. Written down because it looks exactly like a leak to anyone auditing this file later.
///
/// Duplicated in `OllamaKit`, for the reason `BoundedLines` is: the two transport modules do
/// not depend on each other, and the domain layer knows nothing about transports.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
