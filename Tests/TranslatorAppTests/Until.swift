import Foundation
import Observation
import Testing

/// Suspends until `condition` holds, waking on the changes it reads rather than on a clock —
/// and gives up only when `run` has ended without it, never because time passed.
///
/// The waits this replaces polled with a deadline: `waitUntil` in `TranslationViewModelTests`,
/// `yieldUntil` and its three wrappers in `FileQueueModelTests`, each ten seconds, and
/// `waitForSheet`'s two. A deadline is a bet on how long the run has to wait for the main actor,
/// and `swift test` starts every test of the run at once: each `await` back onto the main actor
/// queues behind the whole suite's main-actor work, so on a three-core GitHub runner a test that
/// does nothing asynchronous reported 8.5 s, and the whole run takes eight to eleven. Under that,
/// «not yet» outlived the deadline (`FileQueueModelTests.swift:164`,
/// `TranslationViewModelTests.swift:111`, reproduced under load), and one test that gave up early
/// then hung the suite: `turningTheGateOnMidRunDoesNotAccuseTheRunOfLosingItsTerms` turned the
/// gate on before its run had read it, the run raised a sheet nobody answered, and
/// `await run.value` never returned — CI's twenty-minute timeout instead of a red test.
///
/// **What it waits on.** Everything `condition` reads through an `@Observable` object — a model's
/// state, a test double's call count — is tracked, and the first change to any of it wakes the
/// wait to check again. The model's changes happen on the main actor; a double's may happen on
/// the thread that called it, which is why `Wake` locks.
///
/// **Why the window is no wider than the yield loop's was.** The wake is queued on the main
/// actor at the moment of the change. The run carries on only to the end of that main-actor turn
/// — its next real suspension — and whatever ends that suspension reaches the main actor behind
/// the test. That is the earliest point a loop that yielded could have seen the change, and a
/// yield loop could see it far later, after the run had moved on. (A run's `await` on work that
/// has already finished does not suspend, so «its next real suspension» can be further along
/// than the code reads; a test that needs the run stopped at one particular `await` has to hold
/// what that `await` waits for, as the held clients here do.)
///
/// **Why it cannot hang.** `run` ending is a wake-up of its own. A run that finishes without
/// the condition records an issue here, at the caller's line, and returns `false`, so the test
/// fails at the wait instead of running on into an `await` that nothing will resume.
@MainActor
@discardableResult
func until<T>(_ description: Comment, while run: Task<T, Never>,
              sourceLocation: SourceLocation = #_sourceLocation,
              _ condition: @MainActor () -> Bool) async -> Bool {
    let watch = RunWatch(run)
    while true {
        let wake = Wake()
        var holds = false
        // Checked inside the tracking closure, so a change landing between the check and the
        // registration — possible for a double changed off the main actor — still wakes us.
        withObservationTracking { holds = condition() } onChange: { wake.fire() }
        if holds { return true }
        if watch.ended {
            Issue.record("the run ended before \(description)", sourceLocation: sourceLocation)
            return false
        }
        watch.wake = wake
        await wake.wait()
    }
}

/// Notes when a run has ended and wakes whichever wait is current.
@MainActor
private final class RunWatch {
    var ended = false
    var wake: Wake?

    init<T>(_ run: Task<T, Never>) {
        Task { [weak self] in
            _ = await run.value
            self?.ended = true
            self?.wake?.fire()
        }
    }
}

/// A one-shot wake-up that may be fired from any thread, before or after it is waited on.
private final class Wake: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        fired = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
