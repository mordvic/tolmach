// Tests/TranslationCoreTests/DocumentGlossaryTests.swift
import Testing
@testable import TranslationCore

@Test func pairsTermsByEchoedSourceTerm() {
    let raw = """
    profile server => сервер профилей
    changelog => журнал изменений
    """
    let entries = DocumentGlossary.parse(raw, knownTerms: ["profile server", "changelog"], target: .ru)
    #expect(entries.count == 2)
    #expect(entries.first { $0.term == "profile server" }?.requiredTranslation(for: .ru) == "сервер профилей")
}

@Test func aDroppedLineCannotShiftLaterPairings() {
    // The model skipped "changelog" entirely. The survivors must keep their own
    // translations — never inherit the next line's.
    let raw = """
    profile server => сервер профилей
    resource => ресурс
    """
    let entries = DocumentGlossary.parse(raw, knownTerms: ["profile server", "changelog", "resource"], target: .ru)
    #expect(entries.count == 2)
    #expect(entries.first { $0.term == "resource" }?.requiredTranslation(for: .ru) == "ресурс")
    #expect(entries.contains { $0.term == "changelog" } == false)
}

@Test func dropsUnparseableUnknownDuplicateAndEmptyLines() {
    let raw = """
    Here is the glossary:
    profile server => сервер профилей
    profile server => дубликат
    unknown term => что-то
    changelog =>
    """
    let entries = DocumentGlossary.parse(raw, knownTerms: ["profile server", "changelog"], target: .ru)
    #expect(entries.map(\.term) == ["profile server"])
    #expect(entries[0].requiredTranslation(for: .ru) == "сервер профилей")
}

@Test func matchingTheEchoedTermIsCaseInsensitive() {
    let entries = DocumentGlossary.parse("Profile Server => сервер профилей",
                                         knownTerms: ["profile server"], target: .ru)
    // The canonical term from knownTerms is kept, not the model's echo.
    #expect(entries.map(\.term) == ["profile server"])
}

@Test func thePromptOrderPutsTheDocumentBlockFirstAndKeepsTheSameSet() {
    // `forPrompt` exists for Ollama's prefix cache: the document block is identical for
    // every часть and the user's block is not, so the stable one goes first. Same set as
    // `merge`, same collision rule (the user's rendering survives, the document's is
    // dropped), only the order differs — and with no user entries the two are identical,
    // which is what keeps the acceptance harness's prompts byte-for-byte unchanged.
    let user = [GlossaryEntry(term: "profile server", translations: ["ru": "СЕРВЕР ПРОФИЛЕЙ"])]
    let document = [GlossaryEntry(term: "Profile Server", translations: ["ru": "сервер профилей"]),
                    GlossaryEntry(term: "resource", translations: ["ru": "ресурс"])]
    let prompt = GlossaryMerge.forPrompt(user: user, document: document)
    #expect(prompt.map(\.term) == ["resource", "profile server"])
    #expect(prompt.first { $0.term == "profile server" }?.requiredTranslation(for: .ru) == "СЕРВЕР ПРОФИЛЕЙ")
    #expect(Set(prompt.map(\.term)) == Set(GlossaryMerge.merge(user: user, document: document).map(\.term)))
    #expect(GlossaryMerge.forPrompt(user: [], document: document).map(\.term)
            == GlossaryMerge.merge(user: [], document: document).map(\.term))
}

@Test func userEntriesWinOnCollision() {
    let user = [GlossaryEntry(term: "profile server", translations: ["ru": "СЕРВЕР ПРОФИЛЕЙ"])]
    let document = [GlossaryEntry(term: "Profile Server", translations: ["ru": "сервер профилей"]),
                    GlossaryEntry(term: "resource", translations: ["ru": "ресурс"])]
    let merged = GlossaryMerge.merge(user: user, document: document)
    #expect(merged.count == 2)
    let ps = merged.first { $0.term.lowercased() == "profile server" }
    #expect(ps?.requiredTranslation(for: .ru) == "СЕРВЕР ПРОФИЛЕЙ")
}
