// Sources/TranslatorApp/TranslationViewModel.swift
import Foundation
import Observation
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
        // the main actor; spawning a separate `Task { @MainActor in … }` per piece would
        // not — those are scheduled independently and could apply out of order, assembling
        // the translation scrambled.
        let (pieces, continuation) = AsyncStream<String>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await piece in pieces {
                guard let self else { return }
                // Spec 8: a failed run must not clobber the previous result, so the old
                // text stays until new output actually arrives.
                if !self.clearedPrevious { self.translatedText = ""; self.clearedPrevious = true }
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
            state = .failed(Self.message(for: error))
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
