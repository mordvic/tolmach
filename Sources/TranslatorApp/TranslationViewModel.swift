// Sources/TranslatorApp/TranslationViewModel.swift
import Foundation
import Observation
import OllamaKit
import TranslationCore

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
    private var task: Task<TranslationOutcome, Error>?
    private var clearedPrevious = false

    var sourceText = ""
    var translatedText = ""
    var state: TranslationState = .idle
    var outcome: TranslationOutcome?
    /// The target the last run actually resolved — the override if there was one, the
    /// settings rule otherwise. `TranslationOutcome` carries no target, and
    /// `GlossaryEntry.translations` is keyed by language, so without this the warnings
    /// panel could only guess which translation of a term to show.
    private(set) var resolvedTarget: Language?
    /// Overridden in the main window when the user picks a source explicitly.
    var sourceOverride: Language?
    var targetOverride: Language?
    var toneOverride: Tone?

    init(translator: Translator, settings: AppSettings, glossary: GlossaryStore) {
        self.translator = translator; self.settings = settings; self.glossary = glossary
    }

    /// Known before the run because chunking depends on the input alone. Lets the window
    /// say "3 фрагмента" up front instead of leaving the user with an opaque spinner.
    var expectedChunkCount: Int {
        Chunker.chunk(sourceText, maxCharacters: settings.chunkSize).count
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
        let options = ChatOptions(model: settings.interactiveModel,
                                  temperature: settings.temperature,
                                  keepAlive: settings.keepAlive)

        state = .running

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
                    // separator is not output. `Translator` writes the "\n\n" between
                    // chunks straight to `onToken` instead of through its `emit`, so that
                    // piece never stamps the first-token time; counting it as output would
                    // clear the pane for a multi-chunk run that then reports an empty
                    // reply, which is precisely the case spec 8 says must be survivable.
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
        let run = Task { [translator, glossary, settings] in
            try await translator.translate(
                text: text, target: target, tone: tone,
                userGlossary: glossary.glossary, options: options,
                maxChunkCharacters: settings.chunkSize,
                ignoredTerms: glossary.mutedSet,
                onToken: { continuation.yield($0) })
        }
        task = run

        do {
            let result = try await run.value
            continuation.finish()
            await consumer.value
            // Nothing was ever emitted: the model returned an empty reply rather than
            // translating to nothing. Reporting success here would show a blank pane.
            guard result.timeToFirstTokenMS != nil else {
                state = .failed("Модель вернула пустой ответ. Попробуйте ещё раз.")
                return
            }
            // Written here rather than beside the `let target` that computes it, for the
            // same reason `clearedPrevious` is written where it is. The warnings panel
            // renders these two as a pair — the checks come from `outcome`, the translation
            // to show for each term is looked up by `resolvedTarget` — so a moment where
            // one is this run's and the other is the last run's is a moment the panel can
            // render a wrong translation. Assigning at the top of `translate()` is not
            // observably wrong today, only because no `await` sits between there and
            // `state = .running`; that is a fact about this function's body, not an
            // invariant. Assigned together, the pair cannot come apart.
            resolvedTarget = target
            outcome = result
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

    func cancel() { task?.cancel() }

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
            "Ollama не запущена. Запустите её командой `ollama serve`."
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
