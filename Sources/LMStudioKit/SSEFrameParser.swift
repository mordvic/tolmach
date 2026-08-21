// Sources/LMStudioKit/SSEFrameParser.swift
import Foundation

/// One `data:` payload off the wire, with the `type` it declares.
///
/// Internal, and holding `Any`, for the reason `OllamaStreamParser` returns `[ChatEvent]`
/// rather than the dictionary it decoded: a JSON object is not `Sendable`, and the only
/// consumer is `LMStudioEventReader`, which turns it into values that are.
struct SSEFrame {
    let type: String
    let json: [String: Any]
}

/// The `event:` / `data:` framing, one line at a time.
///
/// **The `event:` line is deliberately ignored.** It carries the same string as the payload's
/// own `type` field — observed on every frame of every stream measured on 2026-08-21 — and
/// reading the type out of the payload keeps this function stateless. Assembling a frame from
/// two lines would need state that survives between them, and state is what makes a stream
/// parser hard to test at all; `OllamaStreamParser` is stateless for the same reason.
///
/// Only single-line payloads are read. SSE permits a payload split across several `data:`
/// lines, LM Studio sends one line per frame, and a split payload here yields nothing rather
/// than half an object.
enum SSEFrameParser {
    static func frame(from line: String) -> SSEFrame? {
        guard let payload = payload(of: line), payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let type = object["type"] as? String { return SSEFrame(type: type, json: object) }
        // A payload carrying an error object but **no** `type` is still an error frame.
        //
        // The documented event always has one — «The type of the event. Always `error`» — so
        // this branch is for a shape nobody has seen. It exists because the two failure
        // directions are not equally bad: dropping such a frame lets the run finish as a
        // success with half a translation in it, which is the one outcome the reader's throw
        // exists to prevent, while treating it as an error costs a spurious failure on a frame
        // this server does not send.
        if object["error"] is [String: Any] { return SSEFrame(type: "error", json: object) }
        return nil
    }

    /// `data:` with or without the conventional single space after the colon — both are legal
    /// SSE, and a client that only accepted one of them would be reading the wire by luck.
    private static func payload(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)
    }
}
