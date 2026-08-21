// Sources/LMStudioKit/LMStudioDownload.swift
import Foundation

/// What `POST /api/v1/models/download` answers.
///
/// Two outcomes rather than one because the response shape differs: a real download returns a
/// `job_id` to poll, and a model already on disk returns `status: "already_downloaded"` **with
/// no job id at all** — nothing to poll, and not a failure either.
public enum DownloadStart: Sendable, Equatable {
    case alreadyDownloaded
    case job(id: String, totalBytes: Int64)
}

/// One sample of a download in flight, in the vocabulary the app already renders.
///
/// Shaped like `PullProgress` on purpose but **not** that type: `LMStudioKit` does not depend
/// on `OllamaKit`, so the engine router adapts the two into whatever the view model wants. The
/// alternative — moving `PullProgress` down into `TranslationCore` — would put a transport
/// concern in the domain layer to save one adapter.
public struct ModelDownloadProgress: Sendable, Equatable {
    /// The server's own word: `downloading`, `paused`, `completed`. Rendered through the app's
    /// `RussianCopy.pullStatus`, which is why it is carried rather than mapped to a Bool here —
    /// **`paused` in particular has to reach the user in words**: a user can pause a download in
    /// LM Studio's own window, and a bar that merely stops moving reads as a hang.
    public let status: String
    public let completed: Int64
    public let total: Int64

    public init(status: String, completed: Int64, total: Int64) {
        self.status = status
        self.completed = completed
        self.total = total
    }

    /// Nil when the server sent no byte counts — the reason `PullProgress.fraction` is optional
    /// too: a fabricated 0% makes the bar jump backwards.
    public var fraction: Double? { total > 0 ? Double(completed) / Double(total) : nil }

    /// Whether this sample is the last one.
    ///
    /// `already_downloaded` counts, and that is not a detail: it is the *only* sample a
    /// download of an installed model produces, so a stream contract keyed on «completed»
    /// alone would leave the pane treating a finished non-download as still running.
    public var isFinished: Bool { status == "completed" || status == "already_downloaded" }

    /// Whether polling should continue. A download this client does not recognise the state of
    /// is **not** polled forever: `downloading` and `paused` are the two states that resume,
    /// and anything else — a cancellation performed in LM Studio's own window, a status added
    /// by a later version — ends the stream rather than spinning at one request a second with
    /// no ceiling.
    public var invitesAnotherPoll: Bool { status == "downloading" || status == "paused" }
}

enum LMStudioDownloadParser {
    static func started(_ data: Data) throws -> DownloadStart {
        let object = try json(data)
        let status = object["status"] as? String
        if status == "already_downloaded" { return .alreadyDownloaded }
        guard let id = object["job_id"] as? String else {
            throw LMStudioError.decoding("download response without a job id: \(status ?? "no status")")
        }
        return .job(id: id, totalBytes: (object["total_size_bytes"] as? NSNumber)?.int64Value ?? 0)
    }

    /// One poll of `GET /api/v1/models/download/status/<job_id>`.
    ///
    /// `failed` throws rather than returning a sample: a download that stopped for good is not
    /// a progress value, and the caller's stream has to end with an error or the pane will sit
    /// on a stalled bar. `paused` is a sample — the user may resume it.
    /// - Parameter totalBytes: the size the *start* response reported, used when a poll omits
    ///   it. A paused download answers with no counts at all (measured shape), and a bar that
    ///   forgets the size it already knew loses its position for as long as the pause lasts.
    static func progress(_ data: Data, totalBytes: Int64 = 0) throws -> ModelDownloadProgress {
        let object = try json(data)
        guard let status = object["status"] as? String else {
            throw LMStudioError.decoding("download status without a status field")
        }
        if status == "failed" {
            throw LMStudioError.server(code: "download_failed", type: nil,
                                       message: object["message"] as? String ?? "download failed")
        }
        let reported = (object["total_size_bytes"] as? NSNumber)?.int64Value ?? 0
        return ModelDownloadProgress(
            status: status,
            completed: (object["downloaded_bytes"] as? NSNumber)?.int64Value ?? 0,
            total: reported > 0 ? reported : totalBytes)
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LMStudioError.decoding("download response was not a JSON object")
        }
        return object
    }
}
