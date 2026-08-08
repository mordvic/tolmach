// Sources/TranslatorApp/FileQueueModel.swift
import Foundation
import Observation
import AppKit
import TextCapture
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
    ///
    /// **Takes the target, and takes a URL rather than a `FileJob`.** It used to take the
    /// задание and work the language out again by re-detecting the text and applying the
    /// settings rule — which ignored the toolbar's override, so a file translated into
    /// German was written as `a.ru.md`. Worse, the задание it was handed was a copy taken
    /// before `resolvedTarget` was assigned, so even reading that field would have found
    /// nil. Passing the language explicitly removes both: there is nothing to re-derive and
    /// no struct to go stale.
    private let save: @Sendable (_ source: URL, _ text: String, _ target: Language) async -> SaveOutcome
    /// Writing to a destination the user chose. Separate from `save` because the two differ
    /// on collisions: that one must never overwrite, this one must — the save panel has
    /// already asked.
    private let saveAs: @Sendable (String, URL) async -> SaveOutcome
    /// Injected so tests can write to a board of their own rather than the real clipboard —
    /// same reasoning and the same default as `TranslationViewModel.pasteboard`.
    private let pasteboard: NSPasteboard

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
    /// Set by `cancel()` and cleared by `run()`.
    ///
    /// Cancelling the running task is not enough on its own: a cancel landing between one
    /// задание finishing and the next starting has no task to reach, and the loop would
    /// carry straight on into the next file after the user pressed «Отмена».
    private var cancelled = false
    /// The «Термины документа» sheet this queue is waiting on, or nil.
    private(set) var pendingTermsRequest: DocumentTermsRequest?
    /// Called the moment a terms sheet is raised, so whoever can present it is told rather
    /// than left to notice.
    ///
    /// **Not an `.onChange` in a view.** The escalation used to be one, attached to the
    /// `Window` scene's content — and this app is `LSUIElement` with `MenuBarExtra` first
    /// precisely so that window is *not* open at launch. With it closed the view does not
    /// exist, the observer never runs, and the sheet appears nowhere at all while the run
    /// sits waiting on an answer nobody can give. A closure set once from `launch()` does
    /// not depend on any view being alive.
    var onTermsRequested: (() -> Void)?
    /// Whether this run is suspended on the terms sheet rather than on the model.
    ///
    /// A named property and not `pendingTermsRequest != nil` written at each view, for
    /// `canSwapLanguages`' reason: two surfaces read it — the panel's status row and the
    /// window's status bar — and a restated condition is how they come to disagree about
    /// what the app is doing.
    var isAwaitingTerms: Bool { pendingTermsRequest != nil }
    /// Set when a sheet came back with «Больше не спрашивать в этом прогоне» ticked. A
    /// statement about this sitting and not a preference, so `run()` clears it.
    private var suppressTermsForThisRun = false
    /// Whether this задание's run reached the review point at all. See where it is read.
    private var raisedTermsSheet = false
    /// Seconds this attempt spent waiting for a human in the terms sheet. See
    /// `markInterrupted`, which is the one path with no `TranslationOutcome` to ask.
    private var termsWait: TimeInterval = 0

    init(translator: Translator, settings: AppSettings, glossary: GlossaryStore,
         save: @escaping @Sendable (URL, String, Language) async -> SaveOutcome,
         saveAs: @escaping @Sendable (String, URL) async -> SaveOutcome,
         pasteboard: NSPasteboard = .general) {
        self.translator = translator
        self.settings = settings
        self.glossary = glossary
        self.save = save
        self.saveAs = saveAs
        self.pasteboard = pasteboard
    }

    /// «Скопировать» in «Файлы».
    ///
    /// Copies what the pane is *showing* — the selected задание — and delegates to
    /// `GeneralPasteboard.write` like the window's and the panel's copies do, so there is
    /// one write to test rather than three to keep in step.
    func copySelection() async {
        await GeneralPasteboard.write(selectedText, to: pasteboard)
    }

    /// Whether this задание still has a translation that is not on disk anywhere.
    ///
    /// True after a run with «Рядом с исходником» off — nothing was written — and after a
    /// write that was refused, because a refusal is precisely what «Сохранить как…» exists
    /// to get past, and retrying beside the source is legitimate once access is granted.
    ///
    /// A rule on the model rather than a condition restated in the row, for
    /// `canSwapLanguages`' reason: the buttons have to answer before they are pressed.
    func needsSaving(_ job: FileJob) -> Bool {
        job.state == .finished && job.result != nil && job.result?.savedTo == nil
    }

    /// Whether this задание has text worth writing somewhere the user picks.
    ///
    /// Wider than `needsSaving` by exactly one state, and narrower than it in what it
    /// offers. `FileJob.State.interrupted` promises the partial translation is kept, and
    /// until now the row offered no way to get it onto disk at all — the only route was
    /// selecting it and copying. But «Сохранить рядом с исходником» writes the canonical
    /// `techdoc-en.ru.md`, and a half-finished translation under that name is
    /// indistinguishable from a complete one; a partial goes out only through «Сохранить
    /// как…», where the user names it themselves.
    func canSaveElsewhere(_ job: FileJob) -> Bool {
        guard job.result?.savedTo == nil, let final = job.result?.final, !final.isEmpty
        else { return false }
        return job.state == .finished || job.state == .interrupted
    }

    /// The name the automatic save would have used, for the save panel's default.
    func suggestedName(for id: FileJob.ID) -> String {
        guard let job = jobs.first(where: { $0.id == id }), target(for: job) != nil else { return "" }
        // A partial is offered as a draft, never under the canonical name — the panel
        // overwrites what it is pointed at, so suggesting that name and letting the user
        // press Return is how a truncated file lands over a complete translation.
        return OutputNaming.destination(for: job.url, target: target(for: job) ?? .ru,
                                        draft: job.state == .interrupted,
                                        exists: { _ in false }).lastPathComponent
    }

    /// «Сохранить рядом с исходником» on a finished row.
    func saveBesideSource(_ id: FileJob.ID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              let text = jobs[index].result?.final,
              let target = target(for: jobs[index]) else { return }
        let outcome = await save(jobs[index].url, text, target)
        // Re-found by id: the await above is a suspension, and an index taken before it is
        // a promise about an array nobody held still.
        guard let now = jobs.firstIndex(where: { $0.id == id }) else { return }
        apply(outcome, to: now)
    }

    /// «Сохранить как…», once the user has picked a destination.
    func save(_ id: FileJob.ID, to url: URL) async {
        guard jobs.contains(where: { $0.id == id }),
              let text = jobs.first(where: { $0.id == id })?.result?.final else { return }
        let outcome = await saveAs(text, url)
        guard let now = jobs.firstIndex(where: { $0.id == id }) else { return }
        apply(outcome, to: now)
    }

    private func apply(_ outcome: SaveOutcome, to index: Int) {
        switch outcome {
        case .saved(let url):
            jobs[index].result?.savedTo = url
            // The problem goes with the failure it described: the file is saved now, and a
            // stale sentence under a saved row is worse than none.
            jobs[index].saveProblem = nil
        case .refused(let problem):
            jobs[index].saveProblem = problem
        }
    }

    /// The language a задание was translated into, or nil if it has not run.
    ///
    /// The run's own answer and nothing else. It used to fall back to re-detecting the text
    /// and applying the settings rule, which was two mistakes: the run is the only place the
    /// toolbar's override was ever known, and the detection ran on the main actor over a
    /// file this queue lets be 2 MB. Both callers — the save panel's suggested name and the
    /// on-demand save — are offered only for a задание that has a result, so the fallback
    /// was unreachable as well as wrong.
    private func target(for job: FileJob) -> Language? { job.resolvedTarget }

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
    /// Read the dropped files and queue them, both off the main actor.
    ///
    /// The reading is the expensive half — up to 2 MB per file, any number of files — and it
    /// used to happen inside the drop closure, on the main actor, before this was even
    /// reached. `QueueDrop.acceptable` is what the closure asks now: extension and size, no
    /// bytes.
    func add(droppedURLs urls: [URL]) async {
        let items = await Task.detached(priority: .userInitiated) { QueueDrop.read(urls) }.value
        await add(dropped: items)
    }

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
        // The same guard `run()` applies at its own exit, for the same reason: «нажмите
        // "Перевести", чтобы продолжить» over a button `canStart` has disabled is a sentence
        // with no way out, and removing the last unfinished задание reaches that state just
        // as finishing it does.
        if pausedAfterWarnings, !hasWorkLeft { pausedAfterWarnings = false }
    }

    /// The one-line instruction under the list, or nil when there is nothing to say.
    ///
    /// A rule on the model rather than a condition in the view, because it has to agree with
    /// two other surfaces at once. It says «продолжить» rather than «начать» once anything
    /// has been attempted — a queue holding a failed row was inviting the user to «начать» —
    /// and it says nothing at all while `statusLine` is already instructing, which is how
    /// «…чтобы начать» came to sit directly under «…чтобы продолжить».
    ///
    /// The *health* half of «is that button pressable» is deliberately not here: Ollama's
    /// state belongs to the window, so the view pairs this with `PrimaryAction`'s answer.
    var startHint: String? {
        guard !isRunning, hasWorkLeft, !pausedAfterWarnings else { return nil }
        let attempted = jobs.contains { $0.state != .queued && $0.state != .unreadable }
        return attempted ? "Нажмите «Перевести», чтобы продолжить"
                         : "Нажмите «Перевести», чтобы начать"
    }

    /// Whether any задание is still waiting to be translated. The same question
    /// `PrimaryAction`'s `canStart` asks, so the pause above and that button cannot
    /// disagree about whether there is anything to continue.
    var hasWorkLeft: Bool {
        jobs.contains { $0.state != .finished && $0.state != .unreadable }
    }

    /// The queue's half of «may the window switch modes right now».
    ///
    /// **Only its half.** The window pairs this with the text model's state, because a run
    /// on either side is a run that switching would abandon — see `MainWindowView`'s own
    /// `canChangeMode`. This one also guards the queue's own controls, which exist only in
    /// «Файлы» and so have nothing to ask the text model about: the drop target and the
    /// row context menu.
    ///
    /// A property of the model and not a condition restated in the view, for
    /// `TranslationViewModel.canSwapLanguages`' reason: the control has to answer before it
    /// is pressed, and a view that re-derived the rule would keep offering a switch for a
    /// case added later.
    var canChangeMode: Bool { !isRunning }

    private var selectedJob: FileJob? { jobs.first { $0.id == selection } }

    /// The result whose warnings the status bar's disclosure opens.
    var selectedResult: JobResult? { selectedJob?.result }

    /// The language the selected задание was translated into, for the warnings view's
    /// term lookups. Nil before it has run, which is also when there are no warnings.
    var selectedTarget: Language? { selectedJob?.resolvedTarget }

    /// Which задание is in flight, or nil. The row uses it to tell «this file is the one
    /// waiting on the sheet» from «this file is merely in a queue that is».
    var runningID: FileJob.ID? {
        jobs.first { if case .running = $0.state { true } else { false } }?.id
    }

    /// Whether the задание the pane is showing is the one being translated.
    ///
    /// Not `isRunning`, which answers about the *queue*. The right pane is selection-driven
    /// — that is the whole argument on `selectedText` — and taking the queue's answer for
    /// the empty state undid half of it: clicking a still-queued row while file 3 ran gave
    /// the pane empty text and «running», so it drew a blank scroll view instead of the
    /// «здесь появится перевод» placeholder.
    var selectedIsRunning: Bool {
        guard let job = selectedJob, case .running = job.state else { return false }
        return true
    }

    /// «Перевод · techdoc-en.md», or the plain header with nothing selected.
    var selectedTitle: String {
        selectedJob.map { "Перевод · \($0.url.lastPathComponent)" } ?? "Перевод"
    }

    /// What the right pane shows: the live stream when the selected задание is the one
    /// running, its stored result otherwise.
    ///
    /// Selection-driven and not stream-driven, deliberately. Wiring the pane to
    /// `streamingText` alone shows the running file's text under the selected file's name
    /// the moment a user clicks a finished задание while the queue carries on — which is
    /// exactly when they are most likely to click one.
    var selectedText: String {
        guard let job = selectedJob else { return "" }
        if case .running = job.state { return streamingText }
        return job.result?.final ?? ""
    }

    /// The one line the status bar shows in «Файлы», or nil when there is nothing to say.
    /// Nil rather than «0 из 2», which would imply work is under way.
    var statusLine: String? {
        if pausedAfterWarnings {
            return "Очередь остановлена на предупреждениях — нажмите «Перевести», чтобы продолжить"
        }
        // `.unreadable` заданиям are not counted at all: `run()` skips them, so including
        // them promised work the queue will never do — «2-й файл из 5» over a queue that
        // will translate three.
        let counted = translatable
        guard let index = counted.firstIndex(where: { if case .running = $0.state { true } else { false } }),
              case let .running(progress) = counted[index].state
        else { return nil }
        // Parts are counted across the whole queue, not within the current file: the
        // sentence is about how much of the *queue* is left, and a per-file count next to a
        // per-queue file count would be two scales in one line.
        //
        // Only заданиям that actually **finished** contribute their parts as done. Crediting
        // every preceding row regardless of state counted a failed or interrupted file's
        // parts as translated, over-reporting the queue by exactly the work that did not
        // happen.
        //
        // The running задание contributes the engine's own total, not its drop-time
        // estimate — `FileJob.partsTotal`'s doc comment says so, and mixing the two put
        // «20 частей из 13» on screen for a user who changed «размер части» after dropping.
        // The ones that have not run can only offer the estimate, and that is honest: they
        // have no other number yet.
        //
        // Counted over the **whole** queue, not just the rows before the running one. A
        // resume starts at the first unfinished задание, which can sit before files that
        // already finished — «Перевожу 1-й файл из 2 — 0 частей из 20» with half the work
        // already on disk. `fileTotal` deliberately keeps counting the finished ones,
        // unlike the `.unreadable` rows above: those the queue will never translate, while
        // these it already has, and dropping them would make «N-й файл из M» shrink under
        // the reader as the queue advanced.
        // Every row offers the best number it has: the engine's if it ever ran, the
        // estimate if it has not. Mixing the two *within one sum* is what made the total
        // shrink as the queue advanced — see `FileJob.actualPartsTotal`.
        let done = counted.reduce(0) { $0 + ($1.state == .finished ? $1.parts : 0) }
            + progress.partsDone
        let total = counted.enumerated().reduce(0) { sum, pair in
            sum + (pair.offset == index ? progress.partsTotal : pair.element.parts)
        }
        return RussianCopy.queuePosition(fileIndex: index, fileTotal: counted.count,
                                         partsDone: done, partsTotal: total)
    }

    /// The заданиям the queue will actually translate.
    ///
    /// One spelling of «not `.unreadable`», because `statusLine` and the window header both
    /// need it: the header counted raw `jobs` and put «Файлы · 5» above the bar's «из 3».
    var translatable: [FileJob] { jobs.filter { $0.state != .unreadable } }
    var translatableCount: Int { translatable.count }

    /// Translate every задание that is not already finished, one at a time.
    ///
    /// Sequential and not concurrent: Ollama holds one model in memory and `keep_alive` is
    /// load-bearing (measured — cold load ~2000 ms against ~155 ms warm), so running files
    /// in parallel multiplies requests against one server without multiplying throughput.
    ///
    /// Started by «Перевести» and never by a drop: a drop that immediately began minutes
    /// of work would make a mis-aimed drag expensive to undo.
    /// - Parameters describe the toolbar's three pickers. They are passed in per run rather
    ///   than stored, because the toolbar belongs to the window and one owner for those
    ///   values is what stops two models disagreeing about which language was chosen. Nil
    ///   means «no override», and the settings rule applies — exactly as in the text pane.
    func run(source: Language? = nil, target: Language? = nil, tone: Tone? = nil) async {
        guard !isRunning else { return }
        isRunning = true
        // Read before it is cleared: continuing a queue that paused itself is the *same*
        // sitting, and the tick below must survive it.
        let resuming = pausedAfterWarnings
        pausedAfterWarnings = false
        // «Больше не спрашивать в этом прогоне» is the user's, and a `stopOnWarnings` pause
        // is the queue's — so a pause may not undo it. It did: a pause ends `run()`, and
        // pressing «Перевести» to continue re-entered here and cleared the box. Thirteen
        // files with the gate on, the tick made on the first and the queue pausing on the
        // third, put the sheet back on the fourth for a user who had explicitly said no
        // more. Cancelling *is* an end — that one clears it, as a fresh press should.
        if !resuming { suppressTermsForThisRun = false }
        cancelled = false
        defer { isRunning = false }

        // The work list is re-asked after every pass, but never for a задание **this run**
        // has already attempted. Both halves are load-bearing, and each closes the failure
        // the other one opens.
        //
        // `attempted` is what makes re-asking safe. `.failed` is not `.finished`, so a plain
        // re-scan finds the задание it has just failed and translates it again, forever, on
        // the main actor — `aFileThatFailsIsNotRetriedWithinTheSameRun` is that guard.
        //
        // Re-asking is what makes the list complete. A задание can appear *after* the run
        // began, and the window is narrower than «dropped mid-run»: both doors into the
        // queue are shut while it runs, but a drop accepted a moment **before** «Перевести»
        // finishes reading and planning on a detached task hundreds of milliseconds later.
        // With a single snapshot those rows arrived too late to be seen, and the run walked
        // past them and stopped with «в очереди» on screen.
        //
        // `.interrupted` and `.failed` are in the list on purpose: resuming retries what did
        // not work, because a queue that steps over a file it failed to translate reports
        // success for work it never performed. `.unreadable` is not — there is nothing to
        // retry.
        var attempted: Set<FileJob.ID> = []
        while true {
            let pending = jobs.filter {
                $0.state != .finished && $0.state != .unreadable && !attempted.contains($0.id)
            }.map(\.id)
            guard !pending.isEmpty else { return }
            for id in pending {
                attempted.insert(id)
                // Looked up by id rather than carried as an index: `remove(_:)` is refused
                // while running, but nothing here should depend on that from a distance.
                guard !cancelled else { return }
                guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
                if await translate(at: index, source: source, target: target, tone: tone) {
                    // «Нажмите "Перевести", чтобы продолжить» over a disabled button is a
                    // sentence with no way out: `canStart` is false once nothing is
                    // unfinished, so a pause earned by the *last* задание could never be
                    // dismissed.
                    if pausedAfterWarnings, !hasWorkLeft { pausedAfterWarnings = false }
                    return
                }
            }
        }
    }

    /// Stops the running задание, whether it is waiting on the network or on a human.
    ///
    /// The request is cancelled **first**, for `TranslationViewModel.cancel()`'s reason: a
    /// run suspended inside the review hook has no network call to interrupt, so cancelling
    /// only the task would leave it on a continuation nobody resumes.
    func cancel() {
        cancelled = true
        pendingTermsRequest?.cancel()
        current?.cancel()
    }

    /// Raise the sheet and wait, unless this run has already been told not to ask again.
    private func askAboutTerms(_ draft: DocumentTermsDraft) async throws -> [GlossaryEntry] {
        // A «Отмена» landing between the engine's last cancellation check and this
        // point would otherwise bring the window forward and put up a sheet for a run
        // the user has just stopped, to be dismissed by hand.
        guard !cancelled else { throw CancellationError() }
        try Task.checkCancellation()
        raisedTermsSheet = true
        guard !suppressTermsForThisRun else { return draft.documentEntries }
        let request = DocumentTermsRequest(draft: draft)
        pendingTermsRequest = request
        onTermsRequested?()
        let askedAt = Date()
        defer {
            pendingTermsRequest = nil
            termsWait += Date().timeIntervalSince(askedAt)
        }
        let answer = try await request.answer()
        // Read after the answer, not before: the tick and the button are one decision, and
        // reading it earlier would take a value the user had not finished making.
        suppressTermsForThisRun = request.suppressForRun
        return answer
    }

    /// Both cancellation paths land here, so «whatever text arrived is kept» is one
    /// statement rather than two that can drift.
    private func markInterrupted(_ index: Int, started: Date) {
        jobs[index].state = .interrupted
        jobs[index].result = JobResult(final: streamingText, checks: [], markupDiffs: [],
                                       documentGlossary: [],
                                       // Minus the reader's deliberation, exactly as the
                                       // success path gets it for free from `totalMS`. There
                                       // is no outcome on this path to take it from, so the
                                       // wait is measured here — one name must not mean two
                                       // different things depending on which branch set it.
                                       elapsedMS: Int((Date().timeIntervalSince(started) - termsWait) * 1000))
    }

    /// - Returns: whether the queue should stop here.
    private func translate(at index: Int, source: Language?, target overrideTarget: Language?,
                           tone overrideTone: Tone?) async -> Bool {
        let job = jobs[index]
        /// Where every write after a suspension goes.
        ///
        /// The bare `index` is safe only because `remove(_:)` refuses while running and
        /// `add` appends — a pair of facts held together by nothing but themselves, across
        /// suspensions that with the terms gate can last minutes. `saveBesideSource` was
        /// already changed to re-find by id for this reason; the run itself was still
        /// trusting the number, and any later «убрать завершённые» would write one file's
        /// result onto another file's row.
        func row() -> Int? { jobs.firstIndex(where: { $0.id == job.id }) }
        // The selection is deliberately **not** moved here. Following the running file
        // would yank a finished translation out from under whoever is reading it, and the
        // status bar already says which file is running.
        streamingText = ""
        // Dropped at the instant the attempt starts, the same pairing `translate()` keeps in
        // `TranslationViewModel`: a result that outlives its attempt is rendered under the
        // next one. A задание retried after being interrupted carries the partial text of
        // the first try, and a second try that fails would have shown it under «Модель
        // вернула пустой ответ.» as though it belonged there.
        jobs[index].result = nil
        // Everything the previous attempt said goes with its result. `documentTermsUnavailable`
        // is only recomputed on the success path, so a retry that was interrupted or failed
        // kept an orange «термины документа не удалось подготовить» describing a run that
        // never reached the review point at all; `saveProblem` described a write for text
        // that no longer exists.
        jobs[index].documentTermsUnavailable = false
        jobs[index].saveProblem = nil
        // `job.parts`, not `job.partsTotal`: a **retried** задание has already been planned
        // by the engine once, and seeding the row with the drop-time estimate made the queue
        // total fall for as long as it took the first `onProgress` to arrive — which is not
        // instant, the off-actor detect of up to 2 MB runs first. Measured on paper: file B
        // finished at an engine count of 2, file A cancelled after the engine planned 3
        // against an estimate of 1, and the bar goes «2 части из 5» → «2 части из 3». This
        // was the one call site not reading the rule `FileJob.parts` exists to state.
        jobs[index].state = .running(TranslationProgress(partsDone: 0,
                                                         partsTotal: job.parts,
                                                         documentTermCount: 0))

        // Detected off the main actor, for the reason `add(dropped:)` plans off it:
        // `NLLanguageRecognizer.processString` reads the whole string with no prefix cap,
        // and this queue deliberately accepts 2 MB files. On the actor it beat the window at
        // the start of every файл — which is exactly when the user is watching the queue
        // advance. Skipped entirely when the toolbar named a source.
        let detected: Language?
        if let source {
            detected = source
        } else {
            let text = job.text
            detected = await Task.detached(priority: .userInitiated) {
                LanguageDetector.detect(text)
            }.value
        }
        let target = overrideTarget ?? settings.targetLanguage(forDetected: detected)
        // Recorded before the run rather than after it, so «Сохранить как…» suggests the
        // right name even for a задание that was interrupted or failed.
        // Through `row()`, not the bare index: `LanguageDetector.detect` above is a
        // suspension like any other, and this write is the first thing after it.
        guard let afterDetect = row() else { return false }
        jobs[afterDetect].resolvedTarget = target
        // Resolved here, on the main actor, rather than inside the run's `Task`: reading
        // `settings` from there is what Swift 6 flags as sending a non-Sendable value, and
        // the value is a fact about the moment the run started anyway.
        let tone = overrideTone ?? settings.defaultTone
        let options = ChatOptions(model: settings.resolvedBatchModel,
                                  temperature: settings.temperature,
                                  keepAlive: settings.keepAlive)
        let started = Date()
        raisedTermsSheet = false
        termsWait = 0

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
                // Stored beside the state, not only in it: `.finished` carries no
                // progress, and the queue counter needs this number after the задание
                // stops running or it falls back to the drop-time estimate mid-queue.
                self.jobs[at].actualPartsTotal = value.partsTotal
                if case .running = self.jobs[at].state { self.jobs[at].state = .running(value) }
            }
        }

        // Read **once**, at the top of the attempt, and used for both the hook and the
        // notice below. Read twice, a user who turned the gate on while a queue was running
        // made every file already in flight evaluate «gate wanted, terms sought, no sheet
        // shown» — an orange «не удалось подготовить» for a run that never asked.
        let gateRequested = settings.reviewDocumentTerms
        var review: (@Sendable (DocumentTermsDraft) async throws -> [GlossaryEntry])?
        if gateRequested {
            // An `if` and not a ternary: a ternary infers a non-`@Sendable` closure, and the
            // conversion is refused with a «failed to produce diagnostic» rather than a
            // useful message.
            review = { [weak self] draft in
                guard let self else { throw CancellationError() }
                return try await self.askAboutTerms(draft)
            }
        }

        let run = Task { [translator, glossary, settings] in
            try await translator.translate(
                text: job.text, target: target, tone: tone,
                userGlossary: glossary.glossary,
                // Detected once, above, and handed over — so the engine does not read a
                // 2 MB file end to end a second time, and the toolbar's «Из» governs what
                // the model is told rather than only where the text goes.
                source: detected,
                options: options,
                maxChunkCharacters: settings.chunkSize,
                ignoredTerms: glossary.mutedSet,
                onToken: { continuation.yield($0) },
                onProgress: { progressContinuation.yield($0) },
                reviewDocumentTerms: review)
        }
        current = run
        // A cancel that landed between creating the task and storing it here had nothing to
        // reach: `current` was still the previous run's. The task then finished normally
        // and the user's «Отмена» did nothing to the file it was pressed on.
        if cancelled { run.cancel() }

        func drain() async {
            continuation.finish()
            progressContinuation.finish()
            await consumer.value
            await progressConsumer.value
        }

        do {
            let outcome = try await run.value
            await drain()
            guard let at = row() else { return false }
            guard outcome.timeToFirstTokenMS != nil else {
                // The engine's «nothing was ever emitted» signal. Reporting success would
                // write an empty file beside the source.
                jobs[at].state = .failed("Модель вернула пустой ответ.")
                return false
            }
            var result = JobResult(final: outcome.final, checks: outcome.checks,
                                   markupDiffs: outcome.markupDiffs,
                                   documentGlossary: outcome.documentGlossary,
                                   // The engine's own measurement, not a second one taken
                                   // here: `started` is stamped before the terms sheet can
                                   // go up, so recomputing counted the reader's deliberation
                                   // as translation time. `totalMS` already excludes it.
                                   elapsedMS: Int(outcome.totalMS))
            if settings.saveNextToSource {
                // The writer says where it wrote. Recomputing the destination here would
                // ask the filesystem *after* the write, find the name taken by that very
                // write, and answer with the next number — a «показать в Finder» link
                // pointing at a file that does not exist.
                // `async`, and the closure the app installs does its work off the main
                // actor — like every other expensive thing here. `QueueDrop.read`,
                // `Chunker.plan` and `LanguageDetector.detect` were each moved off it with a
                // comment saying why; the write was the one that stayed, and it is the
                // heaviest: `OutputNaming` can make up to 999 `fileExists` probes before a
                // 2 MB atomic write and a move.
                let written = await save(job.url, outcome.final, target)
                // Re-found: that call is the longest suspension in this function — up to 999
                // `fileExists` probes and a 2 MB atomic write — and `at` was taken before it.
                guard let afterSave = row() else { return false }
                switch written {
                case .saved(let url):
                    result.savedTo = url
                    jobs[afterSave].saveProblem = nil
                case .refused(let problem):
                    jobs[afterSave].saveProblem = problem
                }
            }
            // «The gate was asked for, terms were actually sought, and no sheet appeared».
            //
            // Not `documentGlossaryFailure != nil`: that is nil when the term-list call
            // succeeded and parsed to nothing, which still leaves the user waiting. And not
            // «more than one часть» either — that claimed a failure for every prose document
            // `TermExtractor` found no candidates in, where nothing was attempted and
            // nothing went wrong.
            guard let final = row() else { return false }
            jobs[final].documentTermsUnavailable = gateRequested
                && outcome.documentGlossaryAttempted && !raisedTermsSheet
            jobs[final].result = result
            jobs[final].state = .finished
            if settings.stopOnWarnings, result.hasWarnings {
                pausedAfterWarnings = true
                return true
            }
            return false
        } catch is CancellationError {
            await drain()
            guard let at = row() else { return true }
            markInterrupted(at, started: started)
            return true
        } catch {
            await drain()
            // Ask the task, not the error, for `TranslationViewModel`'s reason: a producer
            // that finishes inside `onTermination`'s window surfaces a URLError(.cancelled)
            // rather than a CancellationError, and reporting that as a failure would show
            // English right after the user pressed Cancel.
            guard let at = row() else { return true }
            if run.isCancelled {
                // The same treatment as the `CancellationError` branch above, and it has to
                // be: this branch exists because an identical cancellation can surface as
                // `URLError(.cancelled)` instead. Leaving the result unset here made
                // `FileJob.State.interrupted`'s promise — «whatever text arrived is kept» —
                // true on one of the two paths and false on the other, so the partial
                // translation the user was watching vanished from the pane depending on
                // which error the stream happened to produce.
                markInterrupted(at, started: started)
                return true
            }
            jobs[at].state = .failed(TranslationViewModel.message(for: error))
            return false
        }
    }
}
