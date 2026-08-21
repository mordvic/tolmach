// Sources/LMStudioKit/LMStudioError.swift
import Foundation

/// What LM Studio can refuse with, in the shape it refuses in.
///
/// English, like `OllamaError`'s: these strings reach `translate-cli` and the log. The app
/// renders Russian keyed by `code`, which is why `server` carries the machine-readable code
/// beside the prose — mapping a *message* would break the first time the server rephrased one.
public enum LMStudioError: LocalizedError, Equatable {
    /// Nothing listening. The server is off, or on another port.
    case notRunning
    /// HTTP 401 — «Require Authentication» is switched on in LM Studio's server settings.
    /// A case of its own because it is the one failure with a specific remedy the user can
    /// perform, and the app is designed to hold no token (design §13).
    case authenticationRequired
    /// The server's own error object, from an HTTP body or from an `error` event mid-stream.
    /// `code` is what the app keys Russian copy on: `unrecognized_keys`, `invalid_value`,
    /// `model_not_found`, `internal_error` were all observed on 2026-08-21.
    case server(code: String?, type: String?, message: String)
    case httpStatus(Int, String)
    case decoding(String)

    /// Whether this is «I could not read the answer» rather than «the server refused».
    ///
    /// Read by `LMStudioErrorParser.parse(body:status:)` to decide whether an HTTP failure's
    /// status is still the most informative thing it has.
    var isUndecodable: Bool {
        if case .decoding = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            "LM Studio is not reachable. Start its server with `lms server start`."
        case .authenticationRequired:
            "LM Studio requires an API token. Turn «Require Authentication» off in Developer → Server Settings."
        case let .server(code, type, message):
            "LM Studio refused the request (\(code ?? type ?? "error")): \(message)"
        case let .httpStatus(code, body):
            "LM Studio returned HTTP \(code): \(body)"
        case let .decoding(detail):
            "Could not decode LM Studio response: \(detail)"
        }
    }
}
