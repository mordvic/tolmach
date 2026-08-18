// Sources/TranslatorApp/TranslationViewModel.swift
import Foundation
import Observation
import AppKit
import OllamaKit
import TranslationCore
import TextCapture

/// Why one view model will not take over another's run.
///
/// `sourceBusy` and `targetBusy` are the same underlying fact — `state` moves with the text
/// but the `Task` behind it cannot — seen from the two ends. They are separate cases because
/// the panel says something different about each: its own run finishing is a matter of
/// seconds and needs no words, while the window being busy is invisible from the panel and
/// has to be stated.
enum AdoptionRefusal: Equatable {
    /// Adopting from oneself. Not reachable through the app; the guard exists so the
    /// assignments below cannot silently become self-assignments.
    case sameModel
    /// This model is mid-translation. Overwriting it would leave its own task writing into
    /// state it no longer owns.
    case targetBusy
    /// The other model is mid-translation, so its `.running` state would arrive here with no
    /// task behind it and no way out — see `adopt(from:)`.
    case sourceBusy
}

enum TranslationState: Equatable {
    case idle, running, finished, interrupted
    case failed(String)
}

@Observable
@MainActor
final class TranslationViewModel {
    private let translator: Translator
    private let settings: AppSettings
    private let glossary: GlossaryStore
    /// Injected so tests can write to a board of their own rather than the real clipboard —
    /// same reasoning and the same default as `HotkeyCoordinator.pasteboard`.
    private let pasteboard: NSPasteboard
    private var task: Task<TranslationOutcome, Error>?
    private var clearedPrevious = false
    /// Whether this run reached the review point at all. See `documentTermsUnavailable`.
    private var raisedTermsSheet = false

    var sourceText = ""
    var translatedText = ""
    var state: TranslationState = .idle
    var outcome: TranslationOutcome?
    /// The target the last run actually resolved — the override if there was one, the
    /// settings rule otherwise. `TranslationOutcome` carries no target, and
    /// `GlossaryEntry.translations` is keyed by language, so without this the warnings
    /// panel could only guess which translation of a term to show.
    private(set) var resolvedTarget: Language?
    /// Which operation and — for правка — which степень produced `outcome`. Assigned and
    /// cleared with `outcome`/`resolvedTarget` (the pairing rule those two already obey):
    /// a header or an «Ещё вариант» must never describe another operation's result.
    private(set) var resolvedOperation: TextOperation?
    private(set) var resolvedProofreadingLevel: ProofreadingLevel?
    /// The степень's other half — the стиль the finished правка was actually rendered in.
    ///
    /// Added alongside `resolvedProofreadingLevel` rather than left to be re-derived from
    /// `rewriteStyleOverride ?? setting`, because that expression answers «what the *next* run
    /// would use», and after `adopt(from:)` the run on screen is somebody else's. Without it
    /// an adopted правка could be re-run through «Ещё вариант» in a different register from
    /// the one the user is looking at.
    private(set) var resolvedRewriteStyle: RewriteStyle?
    /// Overridden in the main window when the user picks a source explicitly.
    var sourceOverride: Language?
    var targetOverride: Language?
    var toneOverride: Tone?
    /// Which operation the next `run()` performs, and the two per-run overrides that only
    /// matter under правка. Mirrors `sourceOverride`/`targetOverride`/`toneOverride`'s shape:
    /// `nil` means «follow the setting».
    var operation: TextOperation = .translate
    var proofreadingLevelOverride: ProofreadingLevel?
    var rewriteStyleOverride: RewriteStyle?
    /// The «Термины документа» sheet this run is waiting on, or nil.
    ///
    /// Cleared in the same `defer` that ends the wait, so a cancelled or failed run cannot
    /// leave a modal over a window that has already finished.
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
    /// The user asked for the gate and it could not be prepared.
    ///
    /// The engine keeps swallowing a failed term-list call — that is right when nobody
    /// asked — but it is wrong to stay quiet when the user is waiting for a gate that will
    /// never open: the run's terminology then differs from what they were promised with
    /// nothing on screen to say so.
    private(set) var documentTermsUnavailable = false

    init(translator: Translator, settings: AppSettings, glossary: GlossaryStore,
         pasteboard: NSPasteboard = .general) {
        self.translator = translator; self.settings = settings; self.glossary = glossary
        self.pasteboard = pasteboard
    }

    /// The window's «Скопировать».
    ///
    /// Same shape as `HotkeyCoordinator.copyResult()` for the panel — both delegate to
    /// `GeneralPasteboard.write`, which is where the empty-guard and the serialised,
    /// off-actor write live, so the two copy paths cannot diverge in how they touch
    /// `NSPasteboard.general`. Kept here rather than in `TranslatorApp` so it is testable
    /// against a scratch board the way the panel's copy already is, without constructing
    /// the whole app.
    func copyToPasteboard() async {
        await GeneralPasteboard.write(translatedText, to: pasteboard)
    }

    /// Why `adopt(from:)` would refuse right now, or `nil` if it would not.
    ///
    /// A separate function, and returning a reason rather than a Bool, because the panel's
    /// «Открыть в окне» has to answer two questions the moment it draws: whether to offer
    /// the button at all, and what to tell the user when it does not. Deriving either from a
    /// restatement of the rule is how the two drift — the button stays lit for a refusal the
    /// view has never heard of, and the caption blames the wrong thing. This is the same
    /// treatment `WarningsView.hasContent` got, for the same reason.
    func adoptionRefusal(from other: TranslationViewModel) -> AdoptionRefusal? {
        if other === self { return .sameModel }
        // Order matters only for the message: when both are running, saying «the window is
        // busy» is the more useful half, because the panel's own run is already visible to
        // the user as a spinner and a «Отмена» button.
        if state == .running { return .targetBusy }
        if other.state == .running { return .sourceBusy }
        return nil
    }

    /// Take over a translation another view model performed — the panel handing its result
    /// to the window.
    ///
    /// It lives here rather than at the call site because the five values it moves are one
    /// unit, and writing them from outside is what broke: an earlier `handOffToWindow` set
    /// `sourceText` and `translatedText` directly and left `state` and `outcome` alone, so a
    /// window that had already finished a translation of its own went on rendering that
    /// run's «Готово за N мс» and that run's markup and glossary warnings underneath the
    /// text it had just been handed. `translate()` maintains the same pairing — it drops
    /// `outcome` at the instant it replaces `translatedText` — and this is the only other
    /// place allowed to move either.
    ///
    /// Refuses while this model is mid-translation, and says so with its return value rather
    /// than by doing half the job. Adopting under a running task would let that task's own
    /// completion overwrite what was just adopted, and cancelling it first does not help:
    /// the cancellation lands later and writes `.interrupted` over the adopted state. The
    /// caller keeps its panel on screen instead, so the result is not lost.
    /// Refuses when *either* model is mid-translation, and the source half of that is not
    /// symmetry for its own sake. `state` moves with the text, but the `Task` behind it does
    /// not and cannot: it belongs to the other model and goes on writing there. Adopting a
    /// `.running` state therefore hands this model a state it has no way to leave —
    /// `cancel()` is `task?.cancel()` on a nil task, `translate()` refuses while `.running`,
    /// and the window renders «Отмена» rather than «Перевести» — so the pane stays wedged on
    /// a spinner until the app is quit. The panel's «Открыть в окне» is disabled while its
    /// run is in flight for the same reason, but the guard belongs here, where no call site
    /// can miss it.
    @discardableResult
    func adopt(from other: TranslationViewModel) -> Bool {
        guard adoptionRefusal(from: other) == nil else { return false }
        sourceText = other.sourceText
        translatedText = other.translatedText
        outcome = other.outcome
        resolvedTarget = other.resolvedTarget
        resolvedOperation = other.resolvedOperation
        resolvedProofreadingLevel = other.resolvedProofreadingLevel
        resolvedRewriteStyle = other.resolvedRewriteStyle
        // `run()` dispatches on `operation`, not on `resolvedOperation` — so the adopted
        // run's own «Ещё вариант» and a toolbar switch left on the wrong setting must both
        // describe the run now on screen, not whatever this model was doing before.
        operation = other.operation
        // The правка pair moves too, and it moves *resolved* rather than copied: what the
        // adopted run actually used, falling back to nothing only when there was no правка.
        //
        // Leaving them behind was a defect rather than an omission, because
        // `offersAnotherVariant` reads `resolvedProofreadingLevel`, which *did* move. So the
        // window offered «Ещё вариант» for an adopted «ошибки и стиль» правка and then ran it
        // under whatever степень its own toolbar was left on — `proofread()` resolves
        // `proofreadingLevelOverride ?? setting` — and the button promising another rendering
        // of the text on screen delivered a different amount of change. Copying the *other
        // model's overrides* would only half-fix it: the panel sets none, so the re-run would
        // fall through to this window's settings, which are equally not what produced the text
        // on screen. Pinning what the run resolved is what makes an adopted правка
        // self-describing. `anAdoptedProofreadCanBeRerunWithoutConsultingTheSettings` asserts
        // the prompt, not the properties.
        //
        proofreadingLevelOverride = other.proofreadingLevelOverride ?? other.resolvedProofreadingLevel
        rewriteStyleOverride = other.rewriteStyleOverride ?? other.resolvedRewriteStyle
        // «Из», «В» and «Тон» move too, and for a while they could not: the toolbar bound both
        // of the window's modes to this model, so these three doubled as the *queue's*
        // configuration and clearing them here reset a queue's language — the next «Перевести»
        // then wrote every file in the settings-default one. They are `FileQueueModel`'s own
        // now, which is what makes moving them safe as well as right: they describe this
        // model's run, and this model's run is now somebody else's.
        //
        // Taking the other's values means *clearing* ours whenever the source had none, which
        // is the direction that matters: `knownTarget` is `targetOverride ?? resolvedTarget`,
        // so a window that kept its own «В» after adopting named a language the translation on
        // screen is not in.
        sourceOverride = other.sourceOverride
        targetOverride = other.targetOverride
        toneOverride = other.toneOverride
        // Moved with the rest, for this function's own reason: a value that outlives the run
        // it describes is rendered under the next one. Left behind, the window's orange
        // «Термины документа не удалось подготовить» stayed under an adopted translation it
        // had nothing to do with — and a panel run that *did* lose its terms said nothing
        // once adopted.
        documentTermsUnavailable = other.documentTermsUnavailable
        state = other.state
        // `clearedPrevious` is deliberately not touched. It is written and read only inside
        // `translate()`, which resets it before every run, so an assignment here would be
        // dead — and a mutation test proved it: removing it changed nothing. Left out rather
        // than kept as insurance, because a line that cannot matter reads as though it does.
        return true
    }

    /// Known before the run because chunking depends on the input alone. Lets the window
    /// say "3 фрагмента" up front instead of leaving the user with an opaque spinner.
    var expectedChunkCount: Int {
        Chunker.plan(sourceText, maxCharacters: settings.chunkSize).chunks.count
    }

    /// The source language as the next run would resolve it, or nil if nobody knows yet.
    ///
    /// The override first, then what the last finished run detected. Not
    /// `LanguageDetector.detect(sourceText)`: detection is the *translation's* job and
    /// running it here would make a toolbar button re-detect on every keystroke, and would
    /// promise a language the run may not agree with.
    private var knownSource: Language? { sourceOverride ?? outcome?.detectedSource }
    private var knownTarget: Language? { targetOverride ?? resolvedTarget }

    /// Whether ⇄ has two languages to exchange.
    ///
    /// A property rather than a `Bool` returned by `swapLanguages()`, for the same reason
    /// `adoptionRefusal(from:)` is a property of the rule and not of the attempt: the button
    /// must answer before it is pressed, and a view that re-derived the condition would
    /// keep offering a swap for a case added later.
    var canSwapLanguages: Bool {
        state != .running && knownSource != nil && knownTarget != nil
    }

    /// Translate the other way: the languages change places and the translation becomes the
    /// new source.
    ///
    /// The translation is moved rather than copied because the alternative is worse in both
    /// directions — left in place it would be a translation of text that is no longer in the
    /// source pane, and cleared without being moved it would throw away the only thing the
    /// user has to translate back.
    func swapLanguages() {
        guard canSwapLanguages, let source = knownSource, let target = knownTarget else { return }
        sourceOverride = target
        targetOverride = source
        if !translatedText.isEmpty {
            sourceText = translatedText
            translatedText = ""
        }
        // Dropped with the text it described, the same pairing `translate()` maintains: an
        // outcome that outlives its text renders the previous run's markup diffs and
        // glossary checks under whatever is on screen now.
        outcome = nil
        resolvedTarget = nil
        resolvedOperation = nil
        resolvedProofreadingLevel = nil
        resolvedRewriteStyle = nil
        state = .idle
    }

    /// «Ещё вариант» is offered only where variance is the point: a finished правка run
    /// whose степень allowed wording to move. Under «только ошибки» the promise is a
    /// deterministic minimal diff — another variant of that promise is a contradiction
    /// (spec §2, product review 2026-08-10). The `operation == .proofread` conjunct is not
    /// redundant with `resolvedProofreadingLevel`: without it, flipping the toolbar switch
    /// to «Перевод» after a finished правка left the button lit and re-running it would
    /// translate rather than re-proof — the button must disappear rather than lie about
    /// which operation it is about to run.
    var offersAnotherVariant: Bool {
        state == .finished && operation == .proofread && resolvedProofreadingLevel == .errorsAndStyle
            // Re-running an identity is not a variant (spec §2.1).
            && (outcome?.modelChunkCount ?? 0) > 0
    }

    /// Whether «Заменить» (issue #27) may write this result back into the source application.
    /// Gated on `.finished`, not merely on non-empty text — unlike «Скопировать», which is
    /// deliberately available the moment the first token lands so an interrupted run's partial
    /// output is not stranded, «Заменить» must never write a half-streamed answer into another
    /// application. Named and placed beside `offersAnotherVariant` so the same seam that tests
    /// button-availability rules on this model covers it too, rather than leaving the rule
    /// inlined in `PanelView`'s `.disabled(...)` where only a rendered view could pin it.
    var offersReplace: Bool { state == .finished && !translatedText.isEmpty }

    /// The availability rule for the style controls, resolved the way the next run would
    /// resolve the level. Both the toolbar and the settings pane read the rule from
    /// `ProofreadingLevel.allowsRewriteStyle` rather than restating the comparison.
    var rewriteStyleSelectable: Bool {
        (proofreadingLevelOverride ?? settings.defaultProofreadingLevel).allowsRewriteStyle
    }

    /// Dispatches on `operation` — the toolbar's and the panel's one entry point, so neither
    /// has to know which method a given operation runs.
    func run() async {
        switch operation {
        case .translate: await translate()
        case .proofread: await proofread()
        }
    }

    func translate() async {
        // One run at a time. Two concurrent runs share `translatedText` and
        // `clearedPrevious`, so both consumers append into the same pane and the user sees
        // two source texts interleaved; `task = run` would also orphan the first run,
        // leaving `cancel()` able to stop only the second, and whichever run finished last
        // would win — possibly the older request.
        guard state != .running else { return }

        let text = sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let detected = sourceOverride ?? LanguageDetector.detect(text)
        let target = targetOverride ?? settings.targetLanguage(forDetected: detected)
        let tone = toneOverride ?? settings.defaultTone
        let options = settings.chatOptions(model: settings.interactiveModel)

        state = .running
        // Reset beside the other per-run state: a notice that outlived its run would say
        // this translation went without its terms when the previous one did.
        documentTermsUnavailable = false
        raisedTermsSheet = false

        // Only when asked for. A nil hook is byte-for-byte the behaviour that shipped,
        // which is what the engine's pinning test guarantees.
        //
        // Built with an `if` and not a ternary: a ternary infers a non-`@Sendable` closure,
        // and converting one to this parameter's `@Sendable` type is refused — with a
        // «failed to produce diagnostic» from the compiler rather than a useful message.
        // Read **once**, for the hook and for the notice below alike. Read twice, turning
        // the gate on mid-translation made this run report that terms «не удалось
        // подготовить» when it had never asked for them.
        let gateRequested = settings.reviewDocumentTerms
        var review: (@Sendable (DocumentTermsDraft) async throws -> [GlossaryEntry])?
        if gateRequested {
            review = { [weak self] draft in
                guard let self else { throw CancellationError() }
                return try await self.askAboutTerms(draft)
            }
        }

        await execute(start: { onToken in
            Task { [translator, glossary, settings] in
                try await translator.translate(
                    text: text, target: target, tone: tone,
                    userGlossary: glossary.glossary,
                    // The picker reaches the engine now. It used to pick the target and stop
                    // there, so a user correcting a misdetection changed where the text was
                    // going and not what it was read as.
                    source: detected,
                    options: options,
                    maxChunkCharacters: settings.chunkSize,
                    ignoredTerms: glossary.mutedSet,
                    onToken: onToken,
                    reviewDocumentTerms: review)
            }
        }, finish: { result in
            // Written here rather than beside the `let target` that computes it, for the
            // same reason `clearedPrevious` is written where it is. The warnings panel
            // renders these two as a pair — the checks come from `outcome`, the translation
            // to show for each term is looked up by `resolvedTarget` — so a moment where
            // one is this run's and the other is the last run's is a moment the panel can
            // render a wrong translation. Assigning at the top of `translate()` is not
            // observably wrong today, only because no `await` sits between there and
            // `state = .running`; that is a fact about this function's body, not an
            // invariant. Assigned together, the pair cannot come apart.
            // The gate was asked for and could not be prepared. Recorded here rather than
            // logged, unlike the swallowed failure itself: the user is waiting for
            // something that will never appear.
            // «The gate was asked for, terms were actually sought, and no sheet appeared».
            //
            // Not `documentGlossaryFailure != nil`: that is nil when the term-list call
            // succeeded and parsed to nothing, which still leaves the user waiting for a
            // table that never comes. And not «more than one часть» either — that claimed a
            // failure for every prose document `TermExtractor` found no candidates in, where
            // nothing was attempted and nothing went wrong.
            documentTermsUnavailable = gateRequested
                && result.documentGlossaryAttempted && !raisedTermsSheet
            resolvedTarget = target
            resolvedOperation = .translate
            resolvedProofreadingLevel = nil
            resolvedRewriteStyle = nil
            outcome = result
            // The one place the engine's swallowed document-glossary failure is recorded. The
            // user is deliberately not told — it is a diagnostic about an enhancement, not a
            // warning about their translation — but «this long document was translated without
            // the terminology pass» is exactly the invisible difference that shows up later as
            // inconsistent terminology and cannot otherwise be traced. See
            // `TranslationOutcome.documentGlossaryFailure`.
            if let failure = result.documentGlossaryFailure {
                Log.engine.error("""
                    document glossary abandoned; this run translated \
                    \(result.chunks.count, privacy: .public) chunks without the terminology \
                    pass: \(failure, privacy: .public)
                    """)
            }
        })
    }

    /// Правка's run: same shared machinery as `translate()` (see `execute`), no glossary,
    /// no gate.
    private func proofread() async {
        guard state != .running else { return }
        let text = sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Deliberately ignoring `sourceOverride`: that picker is hidden in правка mode, so a
        // value left over from translate mode would govern the prompt with nothing on screen
        // saying so. Passed as nil rather than detected here — `translator.proofread`'s own
        // `source ?? LanguageDetector.detect(text)` then runs off the main actor instead of on
        // it, with identical behaviour.
        let level = proofreadingLevelOverride ?? settings.defaultProofreadingLevel
        let style = rewriteStyleOverride ?? settings.defaultRewriteStyle
        // Правка's own model, which follows the interactive one unless the user chose
        // otherwise — `AppSettings.proofreadModel` carries the measurement behind the split.
        let options = settings.chatOptions(model: settings.resolvedProofreadModel)
        state = .running
        // Правка never raises the terms sheet, but the notice must not outlive its run
        // either — same reset `translate()` performs.
        documentTermsUnavailable = false
        raisedTermsSheet = false
        await execute(start: { onToken in
            Task { [translator, settings] in
                try await translator.proofread(
                    text: text, level: level, style: style, source: nil,
                    options: options, maxChunkCharacters: settings.chunkSize,
                    onToken: onToken)
            }
        }, finish: { result in
            resolvedTarget = nil
            resolvedOperation = .proofread
            resolvedProofreadingLevel = level
            resolvedRewriteStyle = style
            outcome = result
        })
    }

    /// The shared half of every run: the ordered token stream, the spec-8 clear-on-first-
    /// content rule, the `await consumer.value` barrier, the empty-reply guard, and the
    /// three endings. `translate()` and `proofread()` differ only in the config they
    /// compute, the engine call inside `start`, and the resolved values `finish` assigns
    /// — everything here is the code `translate()` always ran, moved without change.
    private func execute(
        start: (@escaping @Sendable (String) -> Void) -> Task<TranslationOutcome, Error>,
        finish: (TranslationOutcome) -> Void
    ) async {
        // Reset before the consumer exists, not after. Today the ordering could not
        // actually be observed the other way round — `translate()` is @MainActor and
        // runs straight from the `Task` creation to here without suspending, so the
        // consumer body cannot interleave — but that is a fact about this function's
        // body, not about the invariant. Assigning first makes "the consumer never
        // sees a stale `true` from the previous run" structural instead of something
        // a future `await` inserted above could quietly break.
        clearedPrevious = false

        // Pieces travel through an AsyncStream rather than a Task-per-token. `onToken` is
        // called serially by the engine, and a stream preserves that order on the way to
        // the main actor.
        //
        // The per-token `Task { @MainActor in … }` alternative is rejected for two reasons,
        // and it is worth being precise about which is which. Its ordering is *not*
        // observably wrong today: MainActor's executor is a serial FIFO queue, so tasks
        // enqueued serially do run in order — measured at 20k tasks, in order every time.
        // What it lacks is the guarantee. Order there is a property of the current
        // executor implementation, not of the language, whereas a stream's is contractual.
        // Second, and independently: `await consumer.value` below is a barrier. It
        // guarantees every piece the producer yielded has been applied *before* `state`
        // flips and before `translatedText = result.final` overwrites. The per-token form
        // has no such barrier — its stragglers merely happen to drain while this function
        // is suspended.
        let (pieces, continuation) = AsyncStream<String>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            // Whitespace-only pieces are held here rather than triggering the clear.
            // Discarded outright if real content never follows.
            var pending = ""
            for await piece in pieces {
                guard let self else { return }
                if !self.clearedPrevious {
                    // Spec 8: a failed run must not clobber the previous result, so the
                    // old text stays until new output actually arrives — and a bare chunk
                    // separator is not output. `Translator` writes the inter-chunk
                    // separator (the source's own whitespace, restored verbatim) straight
                    // to `onToken` instead of through its `emit`, so that piece never
                    // stamps the first-token time; counting it as output would clear the
                    // pane for a multi-chunk run that then reports an empty reply, which
                    // is precisely the case spec 8 says must be survivable.
                    if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pending += piece
                        continue
                    }
                    self.translatedText = ""
                    // Dropped at the same instant the text is, so the two always describe
                    // the same run. On the interrupted and failed paths `translatedText`
                    // becomes the new run's partial output while `outcome` would otherwise
                    // still hold the previous run's glossary checks and markup diffs —
                    // and Task 9 renders warnings from it, so it would describe a document
                    // that is no longer on screen.
                    self.outcome = nil
                    self.clearedPrevious = true
                    self.translatedText += pending
                    pending = ""
                }
                self.translatedText += piece
            }
        }

        // Hold the translating task itself, not a wrapper around it. Cancelling a wrapper
        // would leave the inner unstructured task running — `Task {}` does not inherit
        // cancellation from the task that created it.
        let run = start({ continuation.yield($0) })
        task = run

        do {
            let result = try await run.value
            continuation.finish()
            await consumer.value
            // Nothing was ever emitted: the model returned an empty reply rather than
            // translating to nothing. Reporting success here would show a blank pane.
            // nil TTFT means «empty reply» only when something was actually model-bound: an
            // all-code document legitimately finishes with nil TTFT and modelChunkCount == 0
            // (spec §2.1, the renegotiated contract — pass-through chunks made the old reading
            // fail a successful run).
            guard result.modelChunkCount == 0 || result.timeToFirstTokenMS != nil else {
                state = .failed("Модель вернула пустой ответ. Попробуйте ещё раз.")
                return
            }
            finish(result)
            translatedText = result.final
            state = .finished
        } catch is CancellationError {
            continuation.finish()
            await consumer.value
            state = .interrupted
        } catch {
            continuation.finish()
            await consumer.value
            // Ask the task, not the error. `AsyncThrowingStream.cancel()` runs
            // `onTermination` before `finish()`, so a producer that reaches
            // `continuation.finish(throwing:)` inside that window surfaces a
            // `URLError(.cancelled)` — which `mapTransportError` passes through unchanged
            // — instead of a `CancellationError`. Reporting that as `.failed` would show
            // the user an English `localizedDescription` right after they pressed Cancel.
            state = run.isCancelled ? .interrupted : .failed(Self.message(for: error))
        }
    }

    /// Stops the run, whether it is waiting on the network or on a human.
    ///
    /// The request is cancelled **first**. A run suspended inside the review hook has no
    /// network call to interrupt, so `task?.cancel()` alone would leave it sitting on a
    /// continuation nobody resumes — forever, and invisibly, which is the whole reason
    /// `DocumentTermsRequest` exists.
    func cancel() {
        pendingTermsRequest?.cancel()
        task?.cancel()
    }

    /// Only `translate()`, `proofread()` and `adopt(from:)` write this in the app; a test
    /// needs to set up the state one run leaves behind without running one.
    ///
    /// Below `cancel()` and not above it: inserted between that function and its own doc
    /// comment, it captured a load-bearing explanation of cancellation ordering and left
    /// `cancel()` undocumented.
    func setDocumentTermsUnavailableForTesting(_ value: Bool) { documentTermsUnavailable = value }

    /// Raise the sheet and wait for an answer.
    ///
    /// The `defer` is about the *sheet*, not the continuation: `DocumentTermsRequest`
    /// guarantees exactly one resume whichever way this ends, and clearing the property
    /// here is what stops a cancelled run leaving a modal on screen.
    private func askAboutTerms(_ draft: DocumentTermsDraft) async throws -> [GlossaryEntry] {
        // A ⌘. landing between the engine's last cancellation check and this point
        // would otherwise put up a sheet for a run the user has just stopped.
        try Task.checkCancellation()
        raisedTermsSheet = true
        let request = DocumentTermsRequest(draft: draft)
        pendingTermsRequest = request
        onTermsRequested?()
        defer { pendingTermsRequest = nil }
        return try await request.answer()
    }

    static func message(for error: Error) -> String {
        if let ollama = error as? OllamaErrorBridge { return ollama.russianMessage }
        return error.localizedDescription
    }
}

/// Keeps the Russian copy for transport failures in the app layer rather than in
/// OllamaKit, whose messages are developer-facing English by design.
protocol OllamaErrorBridge { var russianMessage: String { get } }

/// Declared by Task 7 and left unconformed, so until now every `OllamaError` fell through
/// `message(for:)`'s cast and reached the user as `errorDescription`'s English.
///
/// Exhaustive with no `default:` on purpose: a fourth `OllamaError` case should fail to
/// compile here rather than quietly start showing English again.
extension OllamaError: OllamaErrorBridge {
    var russianMessage: String {
        switch self {
        case .notRunning:
            // Guillemets rather than backticks: this string is rendered by `Text(String)`,
            // which never parses Markdown, so backticks would show as grave accents.
            "Ollama не запущена. Запустите её командой «ollama serve»."
        // The body is omitted deliberately: `httpStatus`'s payload is a raw server
        // response — English at best, a page of HTML at worst — and it is already in the
        // ollama log. The code is the part that helps.
        case let .httpStatus(code, _):
            "Ollama ответила ошибкой \(code)."
        case .decoding:
            "Не удалось разобрать ответ Ollama."
        }
    }
}
