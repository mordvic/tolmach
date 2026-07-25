import Foundation

public struct TranslationOutcome: Sendable {
    public let final: String
    public let pass1: String
    public let pass2: String?
    public let chunks: [Chunk]
    public let relevantGlossary: [GlossaryEntry]
    public let detectedSource: Language?
    public let timeToFirstTokenMS: Double
    public let totalMS: Double
    public let stats: [ChatStats]
    public let strippedPreambles: [String]
    public let unwrappedFences: Int
    public let integrity: IntegrityReport
    public let glossaryViolations: [GlossaryViolation]
}

/// Orchestrates detection, chunking, prompting, streaming and post-processing.
/// Depends only on the LLMClient protocol, so it runs under a fake client in tests.
public struct Translator {
    let client: LLMClient

    public init(client: LLMClient) {
        self.client = client
    }

    public func translate(
        text: String,
        target: Language,
        tone: Tone,
        glossary: Glossary?,
        options: ChatOptions,
        twoPass: Bool,
        maxChunkCharacters: Int,
        onToken: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TranslationOutcome {
        let started = Date()
        var firstTokenAt: Date? = nil

        let detected = LanguageDetector.detect(text)
        let relevant = glossary?.relevantEntries(for: text) ?? []
        let chunks = Chunker.chunk(text, maxCharacters: maxChunkCharacters)

        var stats: [ChatStats] = []
        var strippedPreambles: [String] = []
        var unwrappedFences = 0
        var translatedChunks: [String] = []

        for chunk in chunks {
            let request = TranslationRequest(
                text: chunk.text,
                source: detected,
                target: target,
                tone: tone,
                glossaryEntries: glossary?.relevantEntries(for: chunk.text) ?? [],
                precedingContext: translatedChunks.last.map(tailContext)
            )

            let raw = try await collect(
                messages: PromptBuilder.messages(for: request),
                options: options,
                stats: &stats,
                onToken: { token in
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    onToken(token)
                }
            )

            let cleaned = ResponseCleaner.clean(raw)
            if let preamble = cleaned.strippedPreamble { strippedPreambles.append(preamble) }
            if cleaned.unwrappedCodeFence { unwrappedFences += 1 }
            translatedChunks.append(cleaned.text)
        }

        let pass1 = translatedChunks.joined(separator: "\n\n")
        var pass2: String? = nil

        if twoPass {
            let request = TranslationRequest(
                text: text,
                source: detected,
                target: target,
                tone: tone,
                glossaryEntries: relevant
            )
            let raw = try await collect(
                messages: PromptBuilder.refineMessages(original: text, translation: pass1, request: request),
                options: options,
                stats: &stats,
                onToken: onToken
            )
            let cleaned = ResponseCleaner.clean(raw)
            if let preamble = cleaned.strippedPreamble { strippedPreambles.append(preamble) }
            if cleaned.unwrappedCodeFence { unwrappedFences += 1 }
            pass2 = cleaned.text
        }

        let final = pass2 ?? pass1

        return TranslationOutcome(
            final: final,
            pass1: pass1,
            pass2: pass2,
            chunks: chunks,
            relevantGlossary: relevant,
            detectedSource: detected,
            timeToFirstTokenMS: (firstTokenAt ?? Date()).timeIntervalSince(started) * 1000,
            totalMS: Date().timeIntervalSince(started) * 1000,
            stats: stats,
            strippedPreambles: strippedPreambles,
            unwrappedFences: unwrappedFences,
            integrity: MarkupIntegrity.report(source: text, translation: final),
            glossaryViolations: GlossaryVerifier.violations(in: final, entries: relevant, target: target)
        )
    }

    func collect(
        messages: [ChatMessage],
        options: ChatOptions,
        stats: inout [ChatStats],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var buffer = ""
        var collected: ChatStats? = nil

        for try await event in client.chat(messages: messages, options: options) {
            switch event {
            case let .token(token):
                buffer += token
                onToken(token)
            case let .done(chatStats):
                collected = chatStats
            }
        }
        if let collected { stats.append(collected) }
        return buffer
    }

    /// Last couple of paragraphs of the previous chunk — enough for terminology
    /// continuity without paying for the whole document in every prompt.
    func tailContext(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        return paragraphs.suffix(2).joined(separator: "\n\n")
    }
}
