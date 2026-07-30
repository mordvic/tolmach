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

@Test func userEntriesWinOnCollision() {
    let user = [GlossaryEntry(term: "profile server", translations: ["ru": "СЕРВЕР ПРОФИЛЕЙ"])]
    let document = [GlossaryEntry(term: "Profile Server", translations: ["ru": "сервер профилей"]),
                    GlossaryEntry(term: "resource", translations: ["ru": "ресурс"])]
    let merged = GlossaryMerge.merge(user: user, document: document)
    #expect(merged.count == 2)
    let ps = merged.first { $0.term.lowercased() == "profile server" }
    #expect(ps?.requiredTranslation(for: .ru) == "СЕРВЕР ПРОФИЛЕЙ")
}
