import Foundation
import TranslationCore

/// Runs one ячейка through the app's own route — `Translator.proofread`, `PromptBuilder`,
/// the chunker, the cleaner — so what is measured is the product and not a copy of its prompt.
public struct Runner: Sendable {
    private let translator: Translator
    private let chunk: Int

    public init(translator: Translator, chunk: Int) {
        self.translator = translator
        self.chunk = chunk
    }

    /// Reasoning is asked for the way the app asks at its **defaults** — quiet, `low` —
    /// through `ModelPolicy`, and not the way one install's settings happen to say. A harness
    /// that followed a user setting would move its own baseline (the reason `acceptance` and
    /// `translate-cli` stay outside `AppSettings`), and one that sent no `think` key at all
    /// would measure a product nobody runs: Ollama's own default for a capable model is to
    /// reason.
    public static func options(for configuration: Configuration) -> ChatOptions {
        ChatOptions(model: configuration.model, temperature: configuration.temperature, keepAlive: "30m",
                    think: ModelPolicy.thinkRequest(for: configuration.model, quiet: true, level: .low))
    }

    /// Throws for a cancellation and for nothing else: every other failure is the cell's
    /// result, recorded in `CellRecord.error`, because one refused connection at 03:00 must
    /// not cost the rest of the night.
    public func run(_ cell: Cell) async throws -> CellRecord {
        let c = cell.configuration
        func record(reply: String, outcome: TranslationOutcome?, error: String?) -> CellRecord {
            CellRecord(item: cell.item.name, language: cell.item.language.rawValue, configuration: c,
                       run: cell.run, source: cell.item.text, reply: reply, facts: cell.item.facts,
                       mechanics: MechanicalChecks.evaluate(source: cell.item.text, reply: reply,
                                                            expectedLanguage: cell.item.language,
                                                            sameLanguage: true, facts: cell.item.facts),
                       ttftMS: outcome?.timeToFirstTokenMS, totalMS: outcome?.totalMS ?? 0,
                       modelChunkCount: outcome?.modelChunkCount ?? 0,
                       markupDiffs: outcome?.markupDiffs.count ?? 0,
                       markupNotCompared: outcome?.markupNotCompared ?? false, error: error)
        }

        guard c.operation == "proofread",
              let level = c.level.flatMap(ProofreadingLevel.init(rawValue:)),
              let style = c.style.flatMap(RewriteStyle.init(rawValue:)) else {
            return record(reply: "", outcome: nil, error: "unsupported configuration: \(c.operation)")
        }
        do {
            let outcome = try await translator.forRun().proofread(
                text: cell.item.text, level: level, style: style, source: cell.item.language,
                options: Self.options(for: c), maxChunkCharacters: chunk)
            return record(reply: outcome.final, outcome: outcome, error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return record(reply: "", outcome: nil, error: String(describing: error))
        }
    }
}
