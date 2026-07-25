// Tests/TranslationCoreTests/TermExtractorTests.swift
import Testing
@testable import TranslationCore

@Test func extractsRepeatedContentTermsInFrequencyOrder() {
    let text = """
    The profile server validates each resource. The profile server rejects an invalid resource.
    A resource that fails validation is reported. The validation resource report is machine readable.
    """
    let terms = TermExtractor.extract(from: text, language: .en, minFrequency: 2)
    let lowered = terms.map { $0.lowercased() }
    #expect(lowered.contains("resource"))
    #expect(lowered.contains("profile server") || lowered.contains("server"))
    // "validates"/"validation" collapse by lemma but "readable" appears once → excluded.
    #expect(!lowered.contains("readable"))
}

@Test func singleOccurrenceTermsAreExcluded() {
    let terms = TermExtractor.extract(from: "A unique sentence with no repetition whatsoever.", language: .en, minFrequency: 2)
    #expect(terms.isEmpty)
}

@Test func resultIsCappedAtMax() {
    let words = (0..<60).map { "alpha\($0) alpha\($0)" }.joined(separator: " ")
    let terms = TermExtractor.extract(from: words, language: .en, max: 20, minFrequency: 2)
    #expect(terms.count <= 20)
}

@Test func nounPhrasesDoNotSpanSentenceBoundaries() {
    // "laptop" ends one sentence, "Local" starts the next — never one phrase.
    let text = """
    Running a model on a laptop. Local models crossed a threshold. \
    Running a model on a laptop. Local models crossed a threshold.
    """
    let terms = TermExtractor.extract(from: text, language: .en, minFrequency: 2)
    #expect(!terms.contains { $0.lowercased().contains("laptop local") })
}

@Test func stopWordsAreExcludedAsStandaloneTerms() {
    let text = "The most other thing. The most other thing. The most other thing."
    let terms = TermExtractor.extract(from: text, language: .en, minFrequency: 2)
    let lowered = terms.map { $0.lowercased() }
    #expect(!lowered.contains("most"))
    #expect(!lowered.contains("other"))
}

@Test func phrasesAnchoredOnAStopWordAreExcluded() {
    let text = """
    The same resource is returned. The same resource is cached. \
    The same resource is validated once more.
    """
    let terms = TermExtractor.extract(from: text, language: .en, minFrequency: 2)
    #expect(!terms.contains { $0.lowercased() == "same resource" })
    // "resource" itself still qualifies — only the stop-word-anchored phrase is dropped.
    #expect(terms.contains { $0.lowercased() == "resource" })
}
