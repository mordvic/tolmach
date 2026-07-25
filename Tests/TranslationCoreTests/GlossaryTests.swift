// Tests/TranslationCoreTests/GlossaryTests.swift
import Testing
@testable import TranslationCore

private let glossary = Glossary(entries: [
    GlossaryEntry(term: "FHIR", doNotTranslate: true),
    GlossaryEntry(term: "profile server", translations: ["ru": "сервер профилей", "de": "Profilserver"]),
    GlossaryEntry(term: "changelog", translations: ["ru": "журнал изменений"]),
])

@Test func onlyMatchingTermsAreRelevant() {
    let relevant = glossary.relevantEntries(for: "The profile server rejects invalid FHIR resources.")
    #expect(Set(relevant.map(\.term)) == ["FHIR", "profile server"])
}

@Test func matchingIsCaseInsensitive() {
    #expect(glossary.relevantEntries(for: "the PROFILE SERVER").map(\.term) == ["profile server"])
}

@Test func requiredTranslationRespectsDoNotTranslate() {
    let fhir = GlossaryEntry(term: "FHIR", doNotTranslate: true)
    #expect(fhir.requiredTranslation(for: .ru) == "FHIR")
    let server = GlossaryEntry(term: "profile server", translations: ["ru": "сервер профилей"])
    #expect(server.requiredTranslation(for: .ru) == "сервер профилей")
    #expect(server.requiredTranslation(for: .de) == nil)
}
