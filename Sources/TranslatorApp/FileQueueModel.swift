// Sources/TranslatorApp/FileQueueModel.swift
import Foundation
import Observation
import TranslationCore

/// The file queue: what is in it, what is running, and what happened to each file.
///
/// A model of its own and **not** an extension of `TranslationViewModel`. One run per
/// model, guarded per instance, is the rule that keeps the window and the panel from
/// overwriting each other — it is why `adopt(from:)` refuses while either side is
/// running. A queue living inside a view model that also serves a text pane would put two
/// independent runs behind one guard.
@Observable
@MainActor
final class FileQueueModel {
    private let translator: Translator
    private let settings: AppSettings
    private let glossary: GlossaryStore
    /// Writing is injected so a queue can be run end to end in a test without touching a
    /// filesystem, and so the save-panel fallback lives at the app's edge rather than
    /// inside the runner.
    ///
    /// **Returns the URL it wrote**, not just success or failure. An earlier design
    /// returned only a problem and let the runner recompute the destination for its
    /// «saved here» link — which asks the filesystem *after* the write, finds the name
    /// now taken by that very write, and answers with the next number. The link would
    /// have pointed at a file that does not exist. Only the writer knows where the bytes
    /// went.
    private let save: (FileJob, String) -> SaveOutcome

    private var current: Task<TranslationOutcome, Error>?

    var jobs: [FileJob] = []
    var selection: FileJob.ID?
    private(set) var isRunning = false
    /// A property of the **queue**, not of a задание.
    ///
    /// The file that earned the pause is `.finished` — it finished, and it was written.
    /// Modelling this as a sixth `FileJob.State` would make one file's outcome and the
    /// queue's willingness to continue the same value, so dismissing the pause would have
    /// to restate the задание.
    private(set) var pausedAfterWarnings = false
    /// The text streaming into the right pane right now, for the задание being run.
    private(set) var streamingText = ""

    init(translator: Translator, settings: AppSettings, glossary: GlossaryStore,
         save: @escaping (FileJob, String) -> SaveOutcome) {
        self.translator = translator
        self.settings = settings
        self.glossary = glossary
        self.save = save
    }

    func add(_ new: [FileJob]) {
        jobs.append(contentsOf: new)
        if selection == nil { selection = jobs.first?.id }
    }

    /// Turn a drop into заданиями, planning each readable file off the main actor.
    ///
    /// Planning lives here and not in the view for two reasons. It needs
    /// `settings.chunkSize` — a view using the 900 that happens to be its default would
    /// promise «4 части» to a user who set 500 and then serve them seven — and
    /// `Chunker.plan` is a line split plus a `String.count` per block plus sentence
    /// enumeration over oversized ones, which for twenty 2 MB files is not work to do
    /// while the drop animation is still running.
    func add(dropped items: [QueueDrop.Item]) async {
        let chunkSize = settings.chunkSize
        let planned = await Task.detached(priority: .userInitiated) {
            items.map { item -> FileJob in
                guard let text = item.text else {
                    var job = FileJob(url: item.url, text: "", partsTotal: 0)
                    job.state = .unreadable
                    return job
                }
                return FileJob(url: item.url, text: text,
                               partsTotal: Chunker.plan(text, maxCharacters: chunkSize).chunks.count)
            }
        }.value
        add(planned)
    }

    func remove(_ id: FileJob.ID) {
        guard !isRunning else { return }
        jobs.removeAll { $0.id == id }
        if selection == id { selection = jobs.first?.id }
    }

    /// Whether the window may switch between «Текст» and «Файлы» right now.
    ///
    /// A property of the model and not a condition restated in the view, for
    /// `TranslationViewModel.canSwapLanguages`' reason: the control has to answer before
    /// it is pressed, and a view that re-derived the rule would keep offering a switch for
    /// a case added later. One window has one primary button; switching mid-run would let
    /// «Перевести» start a text translation behind a running queue.
    var canChangeMode: Bool { !isRunning }

    /// Translate every задание that is not already finished, one at a time.
    ///
    /// Sequential and not concurrent: Ollama holds one model in memory and `keep_alive` is
    /// load-bearing (measured — cold load ~2000 ms against ~155 ms warm), so running files
    /// in parallel multiplies requests against one server without multiplying throughput.
    ///
    /// Started by «Перевести» and never by a drop: a drop that immediately began minutes
    /// of work would make a mis-aimed drag expensive to undo.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        pausedAfterWarnings = false
        defer { isRunning = false }

        // **The work list is decided once, here.** `.interrupted` and `.failed` are in it
        // on purpose — resuming retries what did not work, because a queue that steps over
        // a file it failed to translate reports success for work it never performed — and
        // `.unreadable` is not, because there is nothing to retry.
        //
        // Re-scanning instead of snapshotting is a hang, not a slowdown: `.failed` is not
        // `.finished`, so a loop asking «what is unfinished?» after each задание would
        // find the one it had just failed and translate it again, forever, on the main
        // actor. `aFileThatFailsIsNotRetriedWithinTheSameRun` is the guard.
        let pending = jobs.filter { $0.state != .finished && $0.state != .unreadable }.map(\.id)
        for id in pending {
            // Looked up by id rather than carried as an index: `remove(_:)` is refused
            // while running, but nothing here should depend on that from a distance.
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
            if await translate(at: index) { return }
        }
    }

    func cancel() { current?.cancel() }

    /// - Returns: whether the queue should stop here.
    private func translate(at index: Int) async -> Bool {
        let job = jobs[index]
        // The selection is deliberately **not** moved here. Following the running file
        // would yank a finished translation out from under whoever is reading it, and the
        // status bar already says which file is running.
        streamingText = ""
        jobs[index].state = .running(TranslationProgress(partsDone: 0,
                                                         partsTotal: job.partsTotal,
                                                         documentTermCount: 0))

        let detected = LanguageDetector.detect(job.text)
        let target = settings.targetLanguage(forDetected: detected)
        let options = ChatOptions(model: settings.resolvedBatchModel,
                                  temperature: settings.temperature,
                                  keepAlive: settings.keepAlive)
        let started = Date()

        // Pieces travel through a stream rather than a Task-per-token, for
        // `TranslationViewModel.translate`'s reason: `onToken` is called serially by the
        // engine and a stream preserves that order on the way to the main actor, which a
        // per-token unstructured Task only happens to do.
        let (pieces, continuation) = AsyncStream<String>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await piece in pieces { self?.streamingText += piece }
        }
        let (progress, progressContinuation) = AsyncStream<TranslationProgress>.makeStream()
        let jobID = job.id
        let progressConsumer = Task { @MainActor [weak self] in
            for await value in progress {
                guard let self, let at = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                if case .running = self.jobs[at].state { self.jobs[at].state = .running(value) }
            }
        }

        let run = Task { [translator, glossary, settings] in
            try await translator.translate(
                text: job.text, target: target, tone: settings.defaultTone,
                userGlossary: glossary.glossary, options: options,
                maxChunkCharacters: settings.chunkSize,
                ignoredTerms: glossary.mutedSet,
                onToken: { continuation.yield($0) },
                onProgress: { progressContinuation.yield($0) })
        }
        current = run

        func drain() async {
            continuation.finish()
            progressContinuation.finish()
            await consumer.value
            await progressConsumer.value
        }

        do {
            let outcome = try await run.value
            await drain()
            guard outcome.timeToFirstTokenMS != nil else {
                // The engine's «nothing was ever emitted» signal. Reporting success would
                // write an empty file beside the source.
                jobs[index].state = .failed("Модель вернула пустой ответ.")
                return false
            }
            var result = JobResult(final: outcome.final, checks: outcome.checks,
                                   markupDiffs: outcome.markupDiffs,
                                   elapsedMS: Int(Date().timeIntervalSince(started) * 1000))
            if settings.saveNextToSource {
                // The writer says where it wrote. Recomputing the destination here would
                // ask the filesystem *after* the write, find the name taken by that very
                // write, and answer with the next number — a «показать в Finder» link
                // pointing at a file that does not exist.
                switch save(job, outcome.final) {
                case .saved(let url):
                    result.savedTo = url
                    jobs[index].saveProblem = nil
                case .refused(let problem):
                    jobs[index].saveProblem = problem
                }
            }
            jobs[index].result = result
            jobs[index].state = .finished
            if settings.stopOnWarnings, result.hasWarnings {
                pausedAfterWarnings = true
                return true
            }
            return false
        } catch is CancellationError {
            await drain()
            jobs[index].state = .interrupted
            jobs[index].result = JobResult(final: streamingText, checks: [], markupDiffs: [],
                                           elapsedMS: Int(Date().timeIntervalSince(started) * 1000))
            return true
        } catch {
            await drain()
            // Ask the task, not the error, for `TranslationViewModel`'s reason: a producer
            // that finishes inside `onTermination`'s window surfaces a URLError(.cancelled)
            // rather than a CancellationError, and reporting that as a failure would show
            // English right after the user pressed Cancel.
            if run.isCancelled {
                jobs[index].state = .interrupted
                return true
            }
            jobs[index].state = .failed(TranslationViewModel.message(for: error))
            return false
        }
    }
}
