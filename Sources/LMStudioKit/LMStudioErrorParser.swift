// Sources/LMStudioKit/LMStudioErrorParser.swift
import Foundation

/// Reads LM Studio's error object, which arrives in two places in the same shape: as the body
/// of a failed HTTP response, and as the payload of an `error` event mid-stream.
///
/// One function for both, because the two channels were observed carrying identical objects on
/// 2026-08-21 — `{"error":{"message","type","param"?,"code"?}}` — and two parsers would drift.
enum LMStudioErrorParser {
    /// The object may be `{"error": {...}}` (what both channels send) or, defensively, the
    /// inner object itself. A body that is neither is reported as an undecodable one rather
    /// than as an empty message: «the server refused and said nothing» is a lie worth avoiding.
    static func parse(_ object: [String: Any]) -> LMStudioError {
        let inner = (object["error"] as? [String: Any]) ?? object
        guard let message = inner["message"] as? String else {
            return .decoding("error object without a message: \(inner.keys.sorted())")
        }
        return .server(code: inner["code"] as? String,
                       type: inner["type"] as? String,
                       message: message)
    }

    /// Same, from raw response bytes, with the one status that carries its own meaning.
    ///
    /// 401 is lifted out before the body is read: authentication is off by default (measured
    /// 2026-08-21 — HTTP 200 with no `Authorization` header), so a 401 says the user switched
    /// «Require Authentication» on, and this app is designed to hold no token. That is a
    /// sentence with a remedy in it, and it must not be flattened into whatever prose the
    /// server happened to send.
    static func parse(body data: Data, status: Int) -> LMStudioError {
        if status == 401 { return .authenticationRequired }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .httpStatus(status, String(data: data, encoding: .utf8) ?? "")
        }
        return parse(object)
    }
}
