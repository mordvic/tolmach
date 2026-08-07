// Sources/TranslatorApp/DocumentTermsRequest.swift
import Foundation
import Observation
import TranslationCore

/// One question put to the user — «are these the right terms?» — and the guarantee that it
/// is answered exactly once.
///
/// **This type exists for a failure that has no symptom.** The engine's review hook is
/// `async`; the answer comes from a human on the main actor; and cancellation arrives from
/// somewhere else entirely — ⌘., the toolbar's «Отмена», the queue being cleared, the
/// window closing. A checked continuation nobody resumes is not a crash and not an error:
/// it is a run suspended forever, and `Task.checkCancellation()` cannot reach it because it
/// is not running. A continuation resumed *twice* is the opposite failure and traps the
/// process.
///
/// This is the same shape as the trap CLAUDE.md records for `AsyncThrowingStream` —
/// cancellation *finishes* instead of throwing, so «not resumed» looks like nothing
/// happening — and that one already cost this project a truncated document reported as a
/// success. So «exactly once» is a property of this type, checked by tests that drive all
/// four orders, rather than something every call site is trusted to arrange.
@Observable
@MainActor
final class DocumentTermsRequest: Identifiable {
    let id = UUID()
    let draft: DocumentTermsDraft
    /// What the sheet edits. Seeded from the draft's document entries; the user's own
    /// entries are not here because they are not editable — see `DocumentTermsDraft`.
    var entries: [GlossaryEntry]
    /// «Больше не спрашивать в этом прогоне». Lives on the request rather than in settings
    /// because it is a statement about this sitting, not a preference: the queue reads it
    /// after the sheet closes and forgets it when the run ends.
    var suppressForRun = false

    private enum Outcome {
        case proceed([GlossaryEntry])
        case cancel
    }
    /// Set the moment a decision is made, whether or not anyone is waiting yet. A queue can
    /// cancel before `answer()` is reached, and without this the continuation would be
    /// created after the decision and never resumed.
    private var decided: Outcome?
    private var continuation: CheckedContinuation<[GlossaryEntry], Error>?

    init(draft: DocumentTermsDraft) {
        self.draft = draft
        self.entries = draft.documentEntries
    }

    /// The engine's side. Suspends until someone decides.
    func answer() async throws -> [GlossaryEntry] {
        if let decided { return try Self.result(of: decided) }
        return try await withCheckedThrowingContinuation { continuation in
            // Re-checked inside, because a decision can land between the check above and
            // this closure running.
            if let decided {
                continuation.resume(with: Result { try Self.result(of: decided) })
            } else {
                self.continuation = continuation
            }
        }
    }

    func proceed() { finish(.proceed(entries)) }

    func cancel() { finish(.cancel) }

    private func finish(_ outcome: Outcome) {
        // Every call after the first is a no-op, deliberately and silently. The sheet's
        // button, Esc and an external cancel can all arrive within one run loop turn, and
        // the second of them must not trap the process.
        guard decided == nil else { return }
        decided = outcome
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: Result { try Self.result(of: outcome) })
    }

    private static func result(of outcome: Outcome) throws -> [GlossaryEntry] {
        switch outcome {
        case .proceed(let entries): return entries
        // `CancellationError` and not a bespoke type: the engine already treats it as
        // «abort this run», so a refusal travels the path cancellation already has.
        case .cancel: throw CancellationError()
        }
    }
}
