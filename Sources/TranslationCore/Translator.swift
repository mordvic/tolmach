// Sources/TranslationCore/Translator.swift
import Foundation

public struct TranslationOutcome: Sendable {
    public let final: String
    public let chunks: [Chunk]
    /// Cleaned translation of each chunk, index-aligned with `chunks`. Needed to measure
    /// whether a term renders the same way in every chunk — see the acceptance task.
    public let translatedChunks: [String]
    public let documentGlossary: [GlossaryEntry]
    public let detectedSource: Language?
    public let checks: [GlossaryCheck]
    public let markupDiffs: [MarkupDiff]
    public let stats: [ChatStats]
    public let timeToFirstTokenMS: Double
    public let totalMS: Double
}

public struct Translator {
    let client: LLMClient
    public init(client: LLMClient) { self.client = client }

    public func translate(
        text: String, target: Language, tone: Tone, userGlossary: Glossary?,
        options: ChatOptions, maxChunkCharacters: Int,
        ignoredTerms: Set<String> = [],
        onToken: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TranslationOutcome {
        let started = Date()
        var firstTokenAt: Date? = nil
        var stats: [ChatStats] = []

        let detected = LanguageDetector.detect(text)
        let chunks = Chunker.chunk(text, maxCharacters: maxChunkCharacters)

        func stream(_ messages: [ChatMessage], isTranslationOutput: Bool) async throws -> String {
            var buffer = ""
            for try await event in client.chat(messages: messages, options: options) {
                switch event {
                case .token(let token):
                    buffer += token
                    // The term-list call is internal scaffolding: its tokens must never
                    // reach the consumer, and must not set the first-token timestamp.
                    guard isTranslationOutput else { continue }
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    onToken(token)
                case .done(let s): stats.append(s)
                }
            }
            return buffer
        }

        // Document glossary. Needs more than one chunk to be worth anything, and a known
        // source language — parsing the source with the target's tagger yields garbage
        // terms that would then be forced into every chunk.
        var documentEntries: [GlossaryEntry] = []
        if chunks.count > 1, let source = detected {
            let terms = TermExtractor.extract(from: text, language: source)
            if !terms.isEmpty {
                let raw = try await stream(PromptBuilder.termListMessages(terms: terms, target: target),
                                           isTranslationOutput: false)
                documentEntries = DocumentGlossary.parse(raw, knownTerms: terms, target: target)
            }
        }

        // Per-chunk translation. The user glossary is filtered by occurrence; the document
        // glossary is not — see the task notes for why the two rules differ.
        var translatedChunks: [String] = []
        for chunk in chunks {
            let relevantUser = userGlossary?.relevantEntries(for: chunk.text) ?? []
            let merged = GlossaryMerge.merge(user: relevantUser, document: documentEntries)
            let request = TranslationRequest(text: chunk.text, source: detected, target: target,
                                             tone: tone, glossaryEntries: merged)
            let raw = try await stream(PromptBuilder.messages(for: request), isTranslationOutput: true)
            translatedChunks.append(ResponseCleaner.clean(raw).text)
        }
        let final = translatedChunks.joined(separator: "\n\n")

        let allEntries = GlossaryMerge.merge(user: userGlossary?.relevantEntries(for: text) ?? [],
                                             document: documentEntries)
        return TranslationOutcome(
            final: final,
            chunks: chunks,
            translatedChunks: translatedChunks,
            documentGlossary: documentEntries,
            detectedSource: detected,
            checks: GlossaryVerifier.check(translation: final, entries: allEntries,
                                           target: target, ignored: ignoredTerms),
            markupDiffs: MarkupSkeleton.diff(source: text, translation: final),
            stats: stats,
            timeToFirstTokenMS: (firstTokenAt ?? Date()).timeIntervalSince(started) * 1000,
            totalMS: Date().timeIntervalSince(started) * 1000)
    }
}
