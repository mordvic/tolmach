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

@Test func shortTermsMatchInsideLongerWords() {
    // Documented limitation, not a defect — see relevantEntries(for:).
    let glossary = Glossary(entries: [GlossaryEntry(term: "ID", translations: ["ru": "идентификатор"])])
    #expect(glossary.relevantEntries(for: "the request is valid").map(\.term) == ["ID"])
}

@Test func doNotTranslateWinsOverAnExistingTranslation() {
    let entry = GlossaryEntry(term: "FHIR", doNotTranslate: true, translations: ["ru": "ФХИР"])
    #expect(entry.requiredTranslation(for: .ru) == "FHIR")
}
