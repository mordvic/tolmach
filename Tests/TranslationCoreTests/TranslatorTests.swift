import Testing
@testable import TranslationCore

private let multiChunkText = """
The resource is valid and the resource is published by the server. \
The server validates the resource before publishing the resource.

Another paragraph about the resource and the server, long enough to force a split \
so the resource and the server both recur across chunks.
"""

@Test func singleChunkSkipsTermExtractionAndReturnsCleanedText() async throws {
    let fake = FakeLLMClient(responses: ["Here is the translation:\nПривет, мир."])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.final == "Привет, мир.")
    #expect(fake.receivedMessages.count == 1) // no term-list call for a single chunk
    #expect(outcome.detectedSource == .en)
    #expect(outcome.documentGlossary.isEmpty)
}

@Test func multiChunkRunsTermListCallFirst() async throws {
    // response 0 = the term list, then one response per chunk
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.chunks.count > 1)
    #expect(fake.receivedMessages.count == outcome.chunks.count + 1) // +1 term-list call
    #expect(outcome.documentGlossary.contains { $0.term.lowercased() == "resource" })
}

@Test func everyDocumentTermGoesIntoEveryChunkPrompt() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "один", "два", "три", "четыре",
    ])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    // Skip index 0 (the term-list call); every remaining prompt carries every term.
    let chunkPrompts = fake.receivedMessages.dropFirst().map { $0.first!.content }
    #expect(chunkPrompts.count == outcome.chunks.count)
    for prompt in chunkPrompts {
        #expect(prompt.contains("ресурс"))
        #expect(prompt.contains("сервер"))
    }
}

@Test func unrecognisedSourceLanguageSkipsTheGlossaryButStillTranslates() async throws {
    // Ukrainian: recognised by NLLanguageRecognizer, absent from our nine targets.
    let ukrainian = String(repeating: "Сервер перевіряє ресурс перед публікацією ресурсу. ", count: 12)
        + "\n\n" + String(repeating: "Ще один абзац про ресурс і сервер для поділу. ", count: 12)
    let fake = FakeLLMClient(responses: ["one", "two", "three", "four", "five"])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: ukrainian, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.detectedSource == nil)
    #expect(outcome.documentGlossary.isEmpty)
    #expect(fake.receivedMessages.count == outcome.chunks.count) // no term-list call
    #expect(!outcome.final.isEmpty)
}

@Test func reportsGlossaryAndMarkupChecks() async throws {
    let fake = FakeLLMClient(responses: ["See https://x.org here."]) // URL kept bare, matches source
    let translator = Translator(client: fake)
    let glossary = Glossary(entries: [GlossaryEntry(term: "x", translations: ["en": "x"])])
    let outcome = try await translator.translate(
        text: "See https://x.org here.", target: .en, tone: .neutral, userGlossary: glossary,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.markupDiffs.isEmpty)
    #expect(outcome.checks.allSatisfy { $0.status != .missing })
}
