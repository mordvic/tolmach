# Translation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless translation engine — `OllamaKit` (HTTP client) plus `TranslationCore` (domain logic), a thin `translate-cli` harness, and an `acceptance` run that holds the engine to the prototype's measured baseline.

**Architecture:** `TranslationCore` depends only on the `LLMClient` protocol, never on Ollama or SwiftUI, so it is fully unit-tested with a fake client. `OllamaKit` implements `LLMClient` over the Ollama HTTP API. `translate-cli` wires them together for manual end-to-end smoke tests against a live model. This is Plan 1 of 2; the macOS app shell (menu bar, popup panel, main window, text capture, permissions, settings persistence) is Plan 2 and consumes this engine unchanged.

**Tech Stack:** Swift, Swift Package Manager, Foundation, NaturalLanguage (`NLLanguageRecognizer`, `NLTagger`), Swift Testing (`import Testing`). No external package dependencies — native frameworks only.

**Provenance:** A throwaway prototype on the `prototype/translation-engine` git branch validated the engine's shape and produced the measurements this design rests on. Components marked *(lift from prototype)* have a validated reference implementation there; adapt it to the interfaces below. Components marked *(new)* did not exist in the prototype and are the spec's fixes to defects the prototype exposed.

A second experiment (same branch, `swift run Experiment`) settled the two mechanisms this plan previously took on faith:

- **Document glossary — adopted.** Cross-chunk term adherence rose from 64–68% to 88% over two runs, fixing the exact drift originally measured. Its known cost is roughly one wrong entry in eleven; three attempts to fix that by feeding context into the term list all failed, because the cause is the term being translated in isolation rather than any lack of information. Mitigation is to surface the glossary in the UI (Plan 2), not more prompt engineering.
- **Second pass — cut.** The corrector framing removed the destructive behaviour of the editor framing but replaced it with uselessness: one edited letter in one run, nothing at all in the other, at 2× the wall clock.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec.

- **Swift tools version:** 6.0. **Platform floor:** macOS 14. **Language mode:** Swift 5 (`swiftLanguageMode(.v5)`) on every target — matches the validated prototype and avoids strict-concurrency churn; the spec does not require Swift 6 mode.
- **No external dependencies.** Foundation, NaturalLanguage, and Swift Testing only.
- **Ollama base URL:** `http://127.0.0.1:11434`.
- **Target languages (all equal):** RU, EN, DE, FR, ES, PT, IT, ZH, JA.
- **Defaults:** `keep_alive` = `"30m"`; chunk size = `900` characters; temperature = `0.2`; term-extraction cap = `20` terms; minimum term frequency = `2`.
- **No second pass.** Both framings were measured and both failed; `refineMessages`, `TwoPassGuard` and the length guard are out of v1 entirely. Do not add them back.
- **Document glossary rules**, all three validated by experiment: the model returns `source term => translation` and pairings are matched by the **echoed term, never by line position**; **every** document term is injected into **every** chunk with no occurrence filtering; the preparatory pass is skipped when the source language is not recognised.
- **Ollama request rule (empirically required):** never send the `think` parameter; always read and **discard** `message.thinking` from responses. Sending `"think": false` moves reasoning into `message.content` and corrupts the translation.
- **Ollama durations** arrive in nanoseconds and are converted to milliseconds at the `OllamaKit` boundary.
- **Sendable:** all value types crossing the `LLMClient` boundary (`ChatMessage`, `ChatOptions`, `ChatEvent`, `ChatStats`, requests, outcomes) are `Sendable`.

## File Structure

```
Package.swift                                     # SPM manifest, 3 targets + 2 test targets
Sources/
  TranslationCore/
    Language.swift            # Language enum + LanguageDetector + NLLanguage mapping
    Tone.swift                # Tone enum + per-tone system-prompt instruction
    Chunker.swift             # Chunk + Chunker (atomic fenced code)
    Glossary.swift            # GlossaryEntry + Glossary (occurrence filtering)
    TermExtractor.swift       # NLTagger-based repeated-term extraction
    LemmaMatcher.swift        # lemma-sequence matching for inflected languages
    GlossaryVerifier.swift    # 3-state glossary check over LemmaMatcher
    DocumentGlossary.swift    # per-document term glossary + merge with user glossary
    PromptBuilder.swift       # TranslationRequest + system/user/corrector/term-list messages
    ResponseCleaner.swift     # strip preambles + unwrap whole-answer code fence
    MarkupSkeleton.swift      # structural token sequence + diff
    ModelPolicy.swift         # role→model mapping + blacklist with reasons
    LLMClient.swift           # LLMClient protocol + ChatMessage/ChatOptions/ChatEvent/ChatStats
    Translator.swift          # orchestration + TranslationOutcome
  OllamaKit/
    OllamaStreamParser.swift  # pure NDJSON-line → ChatEvent parser (thinking discarded)
    OllamaClient.swift        # OllamaClient: LLMClient (models(), chat())
    OllamaError.swift         # typed errors
  translate-cli/
    main.swift                # thin end-to-end harness
  acceptance/
    main.swift                # corpus run enforcing the prototype baseline
corpus/                       # committed acceptance texts, three content types
Tests/
  TranslationCoreTests/       # one file per component
  OllamaKitTests/
    OllamaStreamParserTests.swift
```

**Deferred to Plan 2 (app shell):** `OllamaKit` `pull()` and `ps()` (consumed by UI status/error flows), `keep_alive` warmup on launch, `AppSettings` persistence, `TextCapture`, `TranslatorApp`. `LLMClient` value types live in `TranslationCore` (per spec 3.1: the protocol is declared in the core; `OllamaKit` implements it).

---

### Task 1: Package scaffold + Language & Tone foundation

**Files:**
- Create: `Package.swift`
- Create: `Sources/TranslationCore/Language.swift`
- Create: `Sources/TranslationCore/Tone.swift`
- Create: `.gitignore` (if absent: add `.build/`, `.swiftpm/`)
- Test: `Tests/TranslationCoreTests/LanguageTests.swift`

**Interfaces:**
- Produces: `enum Language: String, CaseIterable, Sendable` cases `ru, en, de, fr, es, pt, it, zh, ja`; `var englishName: String`; `var shortCode: String`; `var nlLanguage: NLLanguage`.
- Produces: `enum LanguageDetector { static func detect(_ text: String) -> Language? }`.
- Produces: `enum Tone: String, CaseIterable, Sendable` cases `neutral, formal, casual, technical, literal`; `var instruction: String`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslationCoreTests/LanguageTests.swift
import Testing
@testable import TranslationCore

@Test func detectsRussianAndEnglish() {
    #expect(LanguageDetector.detect("Сервер профилей проверяет ресурсы перед публикацией.") == .ru)
    #expect(LanguageDetector.detect("The profile server validates resources before publishing.") == .en)
}

@Test func detectReturnsNilForUnsupportedOrEmpty() {
    #expect(LanguageDetector.detect("") == nil)
}

@Test func everyLanguageHasEnglishNameAndCode() {
    for language in Language.allCases {
        #expect(!language.englishName.isEmpty)
        #expect(language.shortCode.count == 2)
    }
}

@Test func toneInstructionsAreNonEmptyAndDistinct() {
    let instructions = Tone.allCases.map(\.instruction)
    #expect(Set(instructions).count == Tone.allCases.count)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LanguageTests`
Expected: FAIL — `TranslationCore` / `Language` not defined (no build).

- [ ] **Step 3: Write the manifest and minimal implementation**

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "local-translator",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TranslationCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "OllamaKit", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "translate-cli", dependencies: ["TranslationCore", "OllamaKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OllamaKitTests", dependencies: ["OllamaKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```

```swift
// Sources/TranslationCore/Language.swift
import Foundation
import NaturalLanguage

public enum Language: String, CaseIterable, Sendable {
    case ru, en, de, fr, es, pt, it, zh, ja

    public var englishName: String {
        switch self {
        case .ru: "Russian"; case .en: "English"; case .de: "German"
        case .fr: "French"; case .es: "Spanish"; case .pt: "Portuguese"
        case .it: "Italian"; case .zh: "Chinese (Simplified)"; case .ja: "Japanese"
        }
    }

    public var shortCode: String { rawValue.uppercased() }

    public var nlLanguage: NLLanguage {
        switch self {
        case .ru: .russian; case .en: .english; case .de: .german
        case .fr: .french; case .es: .spanish; case .pt: .portuguese
        case .it: .italian; case .zh: .simplifiedChinese; case .ja: .japanese
        }
    }

    static func from(_ nlCode: String) -> Language? {
        switch nlCode {
        case "ru": .ru; case "en": .en; case "de": .de; case "fr": .fr
        case "es": .es; case "pt": .pt; case "it": .it
        case "zh-Hans", "zh-Hant", "zh": .zh; case "ja": .ja
        default: nil
        }
    }
}

public enum LanguageDetector {
    public static func detect(_ text: String) -> Language? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        return Language.from(code)
    }
}
```

```swift
// Sources/TranslationCore/Tone.swift
import Foundation

public enum Tone: String, CaseIterable, Sendable {
    case neutral, formal, casual, technical, literal

    public var instruction: String {
        switch self {
        case .neutral:
            "Use a neutral register that matches the source."
        case .formal:
            "Use a formal, polite business register. Prefer the formal form of address where the target language distinguishes it."
        case .casual:
            "Use a relaxed, conversational register, as a colleague would write to a teammate."
        case .technical:
            "Use precise technical language. Prefer established industry terminology over everyday synonyms."
        case .literal:
            "Stay as close to the source wording and sentence structure as the target language allows, even if the result reads stiffly."
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LanguageTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Package.swift .gitignore Sources/TranslationCore/Language.swift Sources/TranslationCore/Tone.swift Tests/TranslationCoreTests/LanguageTests.swift
git commit -m "feat(core): package scaffold, Language detection and Tone"
```

---

### Task 2: Chunker *(lift from prototype)*

**Files:**
- Create: `Sources/TranslationCore/Chunker.swift`
- Test: `Tests/TranslationCoreTests/ChunkerTests.swift`

**Interfaces:**
- Produces: `struct Chunk: Sendable, Equatable { let index: Int; let text: String; let containsCodeFence: Bool }`.
- Produces: `enum Chunker { static func chunk(_ text: String, maxCharacters: Int) -> [Chunk] }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslationCoreTests/ChunkerTests.swift
import Testing
@testable import TranslationCore

private let doc = """
First paragraph that is fairly long and descriptive about the subject at hand.

Second paragraph, also with enough words to matter for the budgeting logic here.

```bash
profile-server publish --ig ./ig.json --strict --out ./dist

echo "a blank line lives inside this fenced block on purpose"
```

Final paragraph after the code, closing the document out with a few more words.
"""

@Test func fencedCodeBlockIsNeverSplit() {
    let chunks = Chunker.chunk(doc, maxCharacters: 120)
    let codeChunks = chunks.filter(\.containsCodeFence)
    #expect(codeChunks.count == 1)
    let code = codeChunks[0].text
    #expect(code.contains("profile-server publish"))
    #expect(code.contains("blank line lives inside"))
    // The fence stays balanced: an even number of ``` markers.
    #expect(code.components(separatedBy: "```").count % 2 == 1)
}

@Test func chunksAreContiguousAndIndexed() {
    let chunks = Chunker.chunk(doc, maxCharacters: 120)
    #expect(chunks.count > 1)
    for (offset, chunk) in chunks.enumerated() { #expect(chunk.index == offset) }
}

@Test func shortTextIsOneChunk() {
    let chunks = Chunker.chunk("Just a sentence.", maxCharacters: 900)
    #expect(chunks.count == 1)
    #expect(chunks[0].containsCodeFence == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChunkerTests`
Expected: FAIL — `Chunker` not defined.

- [ ] **Step 3: Write the implementation**

Adapt the prototype's validated `Chunker` (branch `prototype/translation-engine`, `Sources/TranslationEngine/Chunker.swift`). Behaviour required: split on blank lines into paragraph blocks; keep a ```` ``` ```` fenced block whole even when it exceeds `maxCharacters` and even when it contains blank lines; a non-code block larger than the budget is split on sentence boundaries via `enumerateSubstrings(..., options: .bySentences)`; accumulate blocks into chunks under the budget; a chunk is flagged `containsCodeFence` if any block folded into it was a fence; empty input yields no chunks, non-empty-but-blank yields one chunk.

```swift
// Sources/TranslationCore/Chunker.swift
import Foundation

public struct Chunk: Sendable, Equatable {
    public let index: Int
    public let text: String
    public let containsCodeFence: Bool
}

public enum Chunker {
    struct Block { let text: String; let isCodeFence: Bool }

    public static func chunk(_ text: String, maxCharacters: Int) -> [Chunk] {
        let blocks = blocks(in: text)
        var chunks: [Chunk] = []
        var current = ""
        var currentHasFence = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append(Chunk(index: chunks.count, text: trimmed, containsCodeFence: currentHasFence))
            current = ""; currentHasFence = false
        }

        for block in blocks {
            let pieces: [Block] = (block.text.count > maxCharacters && !block.isCodeFence)
                ? splitBySentences(block.text, maxCharacters: maxCharacters).map { Block(text: $0, isCodeFence: false) }
                : [block]
            for piece in pieces {
                if !current.isEmpty && current.count + piece.text.count + 2 > maxCharacters { flush() }
                if !current.isEmpty { current += "\n\n" }
                current += piece.text
                currentHasFence = currentHasFence || piece.isCodeFence
            }
        }
        flush()

        if chunks.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks = [Chunk(index: 0, text: trimmed, containsCodeFence: false)] }
        }
        return chunks
    }

    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer: [String] = []
        var fenceBuffer: [String] = []
        var insideFence = false

        func flushProse() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(Block(text: joined, isCodeFence: false)) }
            buffer = []
        }

        for line in text.components(separatedBy: .newlines) {
            let isMarker = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if insideFence {
                fenceBuffer.append(line)
                if isMarker {
                    blocks.append(Block(text: fenceBuffer.joined(separator: "\n"), isCodeFence: true))
                    fenceBuffer = []; insideFence = false
                }
                continue
            }
            if isMarker { flushProse(); insideFence = true; fenceBuffer = [line]; continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushProse() } else { buffer.append(line) }
        }
        if insideFence && !fenceBuffer.isEmpty {
            blocks.append(Block(text: fenceBuffer.joined(separator: "\n"), isCodeFence: true))
        }
        flushProse()
        return blocks
    }

    static func splitBySentences(_ text: String, maxCharacters: Int) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            if let substring { sentences.append(substring) }
        }
        if sentences.isEmpty { sentences = [text] }
        var out: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty && current.count + sentence.count + 1 > maxCharacters {
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = ""
            }
            if !current.isEmpty { current += " " }
            current += sentence
        }
        if !current.isEmpty { out.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ChunkerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/Chunker.swift Tests/TranslationCoreTests/ChunkerTests.swift
git commit -m "feat(core): paragraph chunker with atomic fenced code blocks"
```

---

### Task 3: Glossary — entries and occurrence filtering *(lift from prototype)*

**Files:**
- Create: `Sources/TranslationCore/Glossary.swift`
- Test: `Tests/TranslationCoreTests/GlossaryTests.swift`

**Interfaces:**
- Produces: `struct GlossaryEntry: Sendable, Codable, Equatable { let term: String; let doNotTranslate: Bool; let translations: [String: String]; init(term:doNotTranslate:translations:); func requiredTranslation(for: Language) -> String? }`.
- Produces: `struct Glossary: Sendable { let entries: [GlossaryEntry]; init(entries:); func relevantEntries(for text: String) -> [GlossaryEntry] }`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GlossaryTests`
Expected: FAIL — `Glossary` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/Glossary.swift
import Foundation

public struct GlossaryEntry: Sendable, Codable, Equatable {
    public let term: String
    public let doNotTranslate: Bool
    public let translations: [String: String]

    public init(term: String, doNotTranslate: Bool = false, translations: [String: String] = [:]) {
        self.term = term; self.doNotTranslate = doNotTranslate; self.translations = translations
    }

    public func requiredTranslation(for language: Language) -> String? {
        doNotTranslate ? term : translations[language.rawValue]
    }
}

public struct Glossary: Sendable {
    public let entries: [GlossaryEntry]
    public init(entries: [GlossaryEntry]) { self.entries = entries }

    public func relevantEntries(for text: String) -> [GlossaryEntry] {
        let haystack = text.lowercased()
        return entries.filter { haystack.contains($0.term.lowercased()) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GlossaryTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/Glossary.swift Tests/TranslationCoreTests/GlossaryTests.swift
git commit -m "feat(core): user glossary with occurrence filtering"
```

---

### Task 4: TermExtractor *(new)*

**Files:**
- Create: `Sources/TranslationCore/TermExtractor.swift`
- Test: `Tests/TranslationCoreTests/TermExtractorTests.swift`

**Interfaces:**
- Produces: `enum TermExtractor { static func extract(from text: String, language: Language, max: Int = 20, minFrequency: Int = 2) -> [String] }`. Returns surface terms (original casing of first occurrence), ordered by descending lemma-frequency.

Behaviour (spec 4.4): use `NLTagger` over `.lexicalClass` and `.lemma` to collect candidates — single nouns/adjectives plus 2–3-word noun phrases; count occurrences by lemma so inflected forms collapse; drop stop-words and candidates under `minFrequency`; sort by descending frequency; cap at `max`.

**Punctuation must not be omitted from the tag enumeration.** A noun phrase may never span a sentence or clause boundary, so punctuation tokens are kept and act as separators. Enumerating with `.omitPunctuation` silently joins `…on a laptop. Local language models…` into a phantom phrase. The implementation below materialises the token stream first, with `nil` marking a boundary — this is the shape validated in the experiment.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TermExtractorTests`
Expected: FAIL — `TermExtractor` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/TermExtractor.swift
import Foundation
import NaturalLanguage

public enum TermExtractor {
    // Minimal multi-language stop set; extend as needed. Lowercased.
    static let stopWords: Set<String> = [
        "the", "a", "an", "of", "to", "and", "or", "is", "are", "be", "been", "was", "were",
        "in", "on", "for", "that", "this", "with", "as", "it", "its", "by", "at", "from",
        "not", "no", "but", "than", "then", "so", "such", "which", "what", "who", "when",
        "have", "has", "had", "do", "does", "did", "can", "will", "would", "many", "much",
        "more", "most", "other", "same", "own", "one", "two", "first", "last", "new", "old",
        "и", "в", "на", "с", "по", "не", "что", "как", "это", "для", "от", "или", "но",
    ]

    struct Token {
        let surface: String
        let lemma: String
        let isNoun: Bool
        let isAdjective: Bool
        var isContent: Bool { isNoun || isAdjective }
    }

    /// Content words in document order. `nil` marks anything else — punctuation, verbs,
    /// determiners — and acts as a hard boundary so no noun phrase spans one.
    static func tokens(of text: String, language: Language) -> [Token?] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        tagger.setLanguage(language.nlLanguage, range: text.startIndex..<text.endIndex)

        var out: [Token?] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace]) { tag, range in
            let surface = String(text[range])
            guard let tag, tag == .noun || tag == .adjective else { out.append(nil); return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            out.append(Token(surface: surface,
                             lemma: ((lemma?.isEmpty == false) ? lemma! : surface).lowercased(),
                             isNoun: tag == .noun,
                             isAdjective: tag == .adjective))
            return true
        }
        return out
    }

    public static func extract(from text: String, language: Language, max: Int = 20, minFrequency: Int = 2) -> [String] {
        let stream = tokens(of: text, language: language)
        // key = lemma (lowercased) -> (occurrences, first surface form, discovery order)
        var counts: [String: (count: Int, surface: String, order: Int)] = [:]

        func note(_ key: String, _ surface: String) {
            guard key.count > 2, !stopWords.contains(key) else { return }
            if let existing = counts[key] {
                counts[key] = (existing.count + 1, existing.surface, existing.order)
            } else {
                counts[key] = (1, surface, counts.count)
            }
        }

        // Single nouns and adjectives.
        for case let token? in stream where token.isContent {
            note(token.lemma, token.surface)
        }

        // 2–3-word noun phrases: runs of noun/adjective ending in a noun.
        var run: [Token] = []
        func flush() {
            guard run.count >= 2 else { run = []; return }
            for size in [2, 3] where run.count >= size {
                for start in 0...(run.count - size) {
                    let window = Array(run[start..<(start + size)])
                    guard window.last!.isNoun else { continue }
                    note(window.map(\.lemma).joined(separator: " "),
                         window.map(\.surface).joined(separator: " "))
                }
            }
            run = []
        }
        for entry in stream {
            if let token = entry, token.isContent { run.append(token) } else { flush() }
        }
        flush()

        return counts
            .filter { $0.value.count >= minFrequency }
            .sorted { ($0.value.count, $1.value.order) > ($1.value.count, $0.value.order) }
            .prefix(max)
            .map(\.value.surface)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TermExtractorTests`
Expected: PASS (3 tests). If NLTagger tags differ on this OS build and a specific assertion is brittle, keep the `resource`/cap/`minFrequency` assertions (robust) and relax only the noun-phrase `||` branch — do not weaken the frequency or cap guarantees.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/TermExtractor.swift Tests/TranslationCoreTests/TermExtractorTests.swift
git commit -m "feat(core): NLTagger-based repeated-term extraction"
```

---

### Task 5: LemmaMatcher *(new)*

**Files:**
- Create: `Sources/TranslationCore/LemmaMatcher.swift`
- Test: `Tests/TranslationCoreTests/LemmaMatcherTests.swift`

**Interfaces:**
- Produces: `enum LemmaMatcher { static func lemmas(of text: String, language: Language) -> [String]; static func matches(expected: String, in translation: String, language: Language) -> Bool? }`. Returns `nil` when the expected term cannot be reduced to lemmas (treated downstream as "unverifiable").

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslationCoreTests/LemmaMatcherTests.swift
import Testing
@testable import TranslationCore

@Test func matchesAcrossEnglishInflection() {
    // gating case — English lemmatization is reliable
    #expect(LemmaMatcher.matches(expected: "implementation guide",
                                 in: "Publishing the implementation guides locally.",
                                 language: .en) == true)
}

@Test func reportsAbsenceWhenTermIsNotPresent() {
    #expect(LemmaMatcher.matches(expected: "profile server",
                                 in: "The database cluster restarted overnight.",
                                 language: .en) == false)
}

@Test func matchesAcrossRussianCase() {
    // real-world target: genitive «руководства» must match nominative «руководство»
    let result = LemmaMatcher.matches(expected: "руководство по реализации",
                                      in: "Публикация руководства по реализации на сервере.",
                                      language: .ru)
    // Accept true; tolerate nil (unverifiable) but never a false negative.
    #expect(result != false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LemmaMatcherTests`
Expected: FAIL — `LemmaMatcher` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/LemmaMatcher.swift
import Foundation
import NaturalLanguage

public enum LemmaMatcher {
    public static func lemmas(of text: String, language: Language) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(language.nlLanguage, range: text.startIndex..<text.endIndex)
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
            let lemma = tag?.rawValue
            let surface = String(text[range])
            out.append((lemma?.isEmpty == false ? lemma! : surface).lowercased())
            return true
        }
        return out
    }

    /// nil  → cannot verify (expected term produced no lemmas)
    /// true → expected lemma sequence occurs contiguously in the translation
    /// false→ it does not
    public static func matches(expected: String, in translation: String, language: Language) -> Bool? {
        let needle = lemmas(of: expected, language: language)
        guard !needle.isEmpty else { return nil }
        let haystack = lemmas(of: translation, language: language)
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LemmaMatcherTests`
Expected: PASS (3 tests). The Russian assertion uses `!= false` deliberately: the fix's contract is "never a false positive on correct inflection," so `true` or `nil` both satisfy it.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/LemmaMatcher.swift Tests/TranslationCoreTests/LemmaMatcherTests.swift
git commit -m "feat(core): lemma-sequence matching for inflected languages"
```

---

### Task 6: GlossaryVerifier — three states *(new)*

**Files:**
- Create: `Sources/TranslationCore/GlossaryVerifier.swift`
- Test: `Tests/TranslationCoreTests/GlossaryVerifierTests.swift`

**Interfaces:**
- Consumes: `GlossaryEntry`, `Language`, `LemmaMatcher`.
- Produces: `enum GlossaryStatus: Sendable, Equatable { case satisfied, missing, unverifiable }`.
- Produces: `struct GlossaryCheck: Sendable, Equatable { let term: String; let expected: String; let status: GlossaryStatus }`.
- Produces: `enum GlossaryVerifier { static func check(translation: String, entries: [GlossaryEntry], target: Language, ignored: Set<String> = []) -> [GlossaryCheck] }`. `ignored` holds terms the user muted; those are skipped entirely.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslationCoreTests/GlossaryVerifierTests.swift
import Testing
@testable import TranslationCore

@Test func satisfiedWhenExpectedFormPresentAcrossInflection() {
    let entries = [GlossaryEntry(term: "implementation guide", translations: ["ru": "руководство по реализации"])]
    let checks = GlossaryVerifier.check(translation: "Публикация руководства по реализации.",
                                        entries: entries, target: .ru)
    #expect(checks.count == 1)
    #expect(checks[0].status != .missing) // satisfied or unverifiable — never a false alarm
}

@Test func missingWhenExpectedFormAbsent() {
    let entries = [GlossaryEntry(term: "profile server", translations: ["en": "profile server"])]
    let checks = GlossaryVerifier.check(translation: "The database cluster restarted.",
                                        entries: entries, target: .en)
    #expect(checks[0].status == .missing)
}

@Test func ignoredTermsAreSkipped() {
    let entries = [GlossaryEntry(term: "profile server", translations: ["en": "profile server"])]
    let checks = GlossaryVerifier.check(translation: "The database cluster restarted.",
                                        entries: entries, target: .en, ignored: ["profile server"])
    #expect(checks.isEmpty)
}

@Test func entriesWithNoRequiredTranslationAreSkipped() {
    let entries = [GlossaryEntry(term: "profile server", translations: ["de": "Profilserver"])] // no .en
    let checks = GlossaryVerifier.check(translation: "text", entries: entries, target: .en)
    #expect(checks.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GlossaryVerifierTests`
Expected: FAIL — `GlossaryVerifier` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/GlossaryVerifier.swift
import Foundation

public enum GlossaryStatus: Sendable, Equatable { case satisfied, missing, unverifiable }

public struct GlossaryCheck: Sendable, Equatable {
    public let term: String
    public let expected: String
    public let status: GlossaryStatus
}

public enum GlossaryVerifier {
    public static func check(translation: String, entries: [GlossaryEntry], target: Language,
                             ignored: Set<String> = []) -> [GlossaryCheck] {
        entries.compactMap { entry in
            guard !ignored.contains(entry.term) else { return nil }
            guard let expected = entry.requiredTranslation(for: target) else { return nil }
            let status: GlossaryStatus
            switch LemmaMatcher.matches(expected: expected, in: translation, language: target) {
            case true: status = .satisfied
            case false: status = .missing
            case nil: status = .unverifiable
            }
            return GlossaryCheck(term: entry.term, expected: expected, status: status)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GlossaryVerifierTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/GlossaryVerifier.swift Tests/TranslationCoreTests/GlossaryVerifierTests.swift
git commit -m "feat(core): three-state glossary verifier over lemma matching"
```

---

### Task 7: DocumentGlossary + merge *(new)*

**Files:**
- Create: `Sources/TranslationCore/DocumentGlossary.swift`
- Test: `Tests/TranslationCoreTests/DocumentGlossaryTests.swift`

**Interfaces:**
- Produces: `enum DocumentGlossary { static func parse(_ raw: String, knownTerms: [String], target: Language) -> [GlossaryEntry] }` — reads the model's `source term => translation` lines and pairs them **by the echoed term**, case-insensitively, against `knownTerms`. Lines that do not parse, name an unknown term, repeat a term, or carry an empty translation are dropped.
- Produces: `enum GlossaryMerge { static func merge(user: [GlossaryEntry], document: [GlossaryEntry]) -> [GlossaryEntry] }` — user entries win on term collision (case-insensitive).

Matching by echoed term rather than by line position is a safety property, not a style choice: a model that drops one line mid-list would otherwise shift every later pairing, and the resulting wrong terminology is then forced into every chunk. Dropping unparseable lines degrades to a smaller glossary; misalignment degrades to silently wrong output. The experiment exercised this — when a prompt variant broke the format completely, the parser returned nothing instead of thirteen mismatched pairs.

The LLM call that produces `raw` lives in `Translator` (Task 12); this type is pure so it stays unit-testable.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DocumentGlossaryTests`
Expected: FAIL — `DocumentGlossary` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/DocumentGlossary.swift
import Foundation

public enum DocumentGlossary {
    public static func parse(_ raw: String, knownTerms: [String], target: Language) -> [GlossaryEntry] {
        // Canonical spelling comes from knownTerms, so the model's echo may differ in case.
        let canonical = Dictionary(knownTerms.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var out: [GlossaryEntry] = []

        for line in raw.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let translated = parts[1].trimmingCharacters(in: .whitespaces)
            guard let term = canonical[key], !translated.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(GlossaryEntry(term: term, translations: [target.rawValue: translated]))
        }
        return out
    }
}

public enum GlossaryMerge {
    public static func merge(user: [GlossaryEntry], document: [GlossaryEntry]) -> [GlossaryEntry] {
        let userTerms = Set(user.map { $0.term.lowercased() })
        return user + document.filter { !userTerms.contains($0.term.lowercased()) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DocumentGlossaryTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/DocumentGlossary.swift Tests/TranslationCoreTests/DocumentGlossaryTests.swift
git commit -m "feat(core): document glossary and user-wins merge"
```

---

### Task 8: PromptBuilder *(lift + extend from prototype)*

**Files:**
- Create: `Sources/TranslationCore/PromptBuilder.swift`
- Test: `Tests/TranslationCoreTests/PromptBuilderTests.swift`

**Files:**
- Create: `Sources/TranslationCore/LLMClient.swift` — value types only; the `LLMClient` protocol itself is appended in Task 12
- Create: `Sources/TranslationCore/PromptBuilder.swift`
- Test: `Tests/TranslationCoreTests/PromptBuilderTests.swift`

**Interfaces:**
- Produces: `struct ChatMessage: Sendable, Equatable { let role: String; let content: String }`, `struct ChatOptions: Sendable`, `struct ChatStats: Sendable`, `enum ChatEvent: Sendable`. These live in `LLMClient.swift` alongside the protocol that Task 12 adds; they are created here because `PromptBuilder` returns `[ChatMessage]` and this task comes first.
- Produces: `struct TranslationRequest: Sendable { text: String; source: Language?; target: Language; tone: Tone; glossaryEntries: [GlossaryEntry] }`. There is deliberately **no** `precedingContext` — the prototype had one and it failed to hold terminology together; the document glossary replaces it (spec 4.4).
- Produces: `enum PromptBuilder { static func messages(for: TranslationRequest) -> [ChatMessage]; static func systemPrompt(for: TranslationRequest) -> String; static func userPrompt(for: TranslationRequest) -> String; static func termListMessages(terms: [String], target: Language) -> [ChatMessage] }`. There is deliberately **no** `refineMessages` — the second pass is cut from v1 (see Global Constraints).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslationCoreTests/PromptBuilderTests.swift
import Testing
@testable import TranslationCore

@Test func systemPromptForbidsPreambleAndProtectsCode() {
    let request = TranslationRequest(text: "hello", source: .en, target: .de, tone: .technical)
    let system = PromptBuilder.systemPrompt(for: request)
    #expect(system.contains("German"))
    #expect(system.lowercased().contains("only the translation"))
    #expect(system.contains("code")) // code-block protection rule present
    #expect(system.contains(Tone.technical.instruction))
}

@Test func glossaryEntriesAppearInSystemPrompt() {
    let request = TranslationRequest(
        text: "the profile server", source: .en, target: .ru, tone: .neutral,
        glossaryEntries: [
            GlossaryEntry(term: "FHIR", doNotTranslate: true),
            GlossaryEntry(term: "profile server", translations: ["ru": "сервер профилей"]),
        ])
    let system = PromptBuilder.systemPrompt(for: request)
    #expect(system.contains("FHIR"))
    #expect(system.contains("сервер профилей"))
}

@Test func termListPromptDemandsEchoedTermFormat() {
    let messages = PromptBuilder.termListMessages(terms: ["profile server", "changelog"], target: .ru)
    let system = messages.first { $0.role == "system" }!.content
    // The "=>" contract is what makes the parser immune to line shifts.
    #expect(system.contains("=>"))
    #expect(system.lowercased().contains("echo"))
    let user = messages.last!.content
    #expect(user.contains("profile server"))
    #expect(user.contains("changelog"))
    // No numbering: a numbered reply would put "1. " inside the parsed term.
    #expect(!user.contains("1."))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PromptBuilderTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/LLMClient.swift  (value types; protocol appended in Task 12)
import Foundation

public struct ChatMessage: Sendable, Equatable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public struct ChatOptions: Sendable {
    public let model: String
    public let temperature: Double
    public let keepAlive: String
    public init(model: String, temperature: Double = 0.2, keepAlive: String = "30m") {
        self.model = model; self.temperature = temperature; self.keepAlive = keepAlive
    }
}

public struct ChatStats: Sendable {
    public let loadDurationMS: Double
    public let promptEvalCount: Int
    public let promptEvalDurationMS: Double
    public let evalCount: Int
    public let evalDurationMS: Double
    public init(loadDurationMS: Double, promptEvalCount: Int, promptEvalDurationMS: Double, evalCount: Int, evalDurationMS: Double) {
        self.loadDurationMS = loadDurationMS; self.promptEvalCount = promptEvalCount
        self.promptEvalDurationMS = promptEvalDurationMS; self.evalCount = evalCount; self.evalDurationMS = evalDurationMS
    }
    public var tokensPerSecond: Double { evalDurationMS > 0 ? Double(evalCount) / (evalDurationMS / 1000) : 0 }
}

public enum ChatEvent: Sendable {
    case token(String)
    case done(ChatStats)
}
```

```swift
// Sources/TranslationCore/PromptBuilder.swift
import Foundation

public struct TranslationRequest: Sendable {
    public let text: String
    public let source: Language?
    public let target: Language
    public let tone: Tone
    public let glossaryEntries: [GlossaryEntry]
    public init(text: String, source: Language?, target: Language, tone: Tone, glossaryEntries: [GlossaryEntry] = []) {
        self.text = text; self.source = source; self.target = target; self.tone = tone; self.glossaryEntries = glossaryEntries
    }
}

public enum PromptBuilder {
    public static func messages(for request: TranslationRequest) -> [ChatMessage] {
        [ChatMessage(role: "system", content: systemPrompt(for: request)),
         ChatMessage(role: "user", content: userPrompt(for: request))]
    }

    public static func systemPrompt(for request: TranslationRequest) -> String {
        let sourceClause = request.source.map { "from \($0.englishName) " } ?? ""
        var lines = [
            "You are a professional translator. Translate the user's text \(sourceClause)into \(request.target.englishName).",
            "",
            "Rules:",
            "- Output ONLY the translation. No preamble, no notes, no explanation, no quotes around it.",
            "- Preserve the original structure exactly: line breaks, blank lines, list markers, heading levels.",
            "- Never translate the contents of fenced code blocks (```) or inline code (`like this`). Reproduce them byte for byte.",
            "- Never translate URLs, email addresses, file paths, CLI flags, or identifiers such as function and variable names.",
            "- Keep numbers, units, and dates in their original values.",
            "- \(request.tone.instruction)",
        ]
        if !request.glossaryEntries.isEmpty {
            lines.append("")
            lines.append("Terminology you MUST follow:")
            for entry in request.glossaryEntries {
                if entry.doNotTranslate {
                    lines.append("- \"\(entry.term)\" — leave untranslated, exactly as written.")
                } else if let required = entry.translations[request.target.rawValue] {
                    lines.append("- \"\(entry.term)\" — translate as \"\(required)\".")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func userPrompt(for request: TranslationRequest) -> String {
        """
        Translate the text between the markers into \(request.target.englishName).

        <text>
        \(request.text)
        </text>
        """
    }

    /// The `=>` echo contract is load-bearing: it lets the parser match by term instead
    /// of by line position, so a dropped line costs one entry rather than corrupting
    /// every later pairing. Verbatim from the validated experiment prompt.
    public static func termListMessages(terms: [String], target: Language) -> [ChatMessage] {
        let system = """
        You translate a list of glossary terms into \(target.englishName).

        Output one line per input term, in exactly this format:
        source term => translation

        Echo the source term exactly as given in English, then " => ", then the translation. \
        No numbering, no commentary, no extra lines. Do not translate anything except the terms. \
        Keep identifiers and product names untranslated when they have no established \
        target-language form.
        """
        let user = terms.joined(separator: "\n")
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PromptBuilderTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/LLMClient.swift Sources/TranslationCore/PromptBuilder.swift Tests/TranslationCoreTests/PromptBuilderTests.swift
git commit -m "feat(core): prompt builder with corrector and term-list prompts"
```

---

### Task 9: ResponseCleaner *(lift from prototype)*

**Files:**
- Create: `Sources/TranslationCore/ResponseCleaner.swift`
- Test: `Tests/TranslationCoreTests/ResponseCleanerTests.swift`

**Interfaces:**
- Produces: `struct CleanedResponse: Sendable, Equatable { let text: String; let strippedPreamble: String?; let unwrappedCodeFence: Bool }`.
- Produces: `enum ResponseCleaner { static func clean(_ raw: String) -> CleanedResponse }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslationCoreTests/ResponseCleanerTests.swift
import Testing
@testable import TranslationCore

@Test func stripsLeadingPreambleLine() {
    let cleaned = ResponseCleaner.clean("Here is the translation:\nПривет, мир.")
    #expect(cleaned.text == "Привет, мир.")
    #expect(cleaned.strippedPreamble != nil)
}

@Test func stripsMarkdownEmphasizedPreamble() {
    let cleaned = ResponseCleaner.clean("**Translation:**\nHallo Welt.")
    #expect(cleaned.text == "Hallo Welt.")
}

@Test func unwrapsWholeAnswerCodeFence() {
    let cleaned = ResponseCleaner.clean("```\nMerely wrapped prose.\n```")
    #expect(cleaned.text == "Merely wrapped prose.")
    #expect(cleaned.unwrappedCodeFence)
}

@Test func leavesLegitimateInnerCodeFenceAlone() {
    let raw = "Run this:\n\n```bash\nls -la\n```"
    let cleaned = ResponseCleaner.clean(raw)
    #expect(cleaned.text == raw)
    #expect(cleaned.unwrappedCodeFence == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ResponseCleanerTests`
Expected: FAIL — `ResponseCleaner` not defined.

- [ ] **Step 3: Write the implementation**

Adapt the prototype's validated `ResponseCleaner` (branch `prototype/translation-engine`). Required behaviour: strip a leading line if it is a known preamble label (with or without `*`/`#`/`_` emphasis and trailing `:`), across EN/RU/DE/FR/ES; unwrap the answer only when the entire text is a single fence (first line starts ```` ``` ````, last line is ```` ``` ````, no inner fence markers); trim.

```swift
// Sources/TranslationCore/ResponseCleaner.swift
import Foundation

public struct CleanedResponse: Sendable, Equatable {
    public let text: String
    public let strippedPreamble: String?
    public let unwrappedCodeFence: Bool
}

public enum ResponseCleaner {
    static let preamblePatterns: Set<String> = [
        "here is the translation", "here's the translation", "here is the translated text",
        "translation", "translated text",
        "вот перевод", "перевод", "übersetzung",
        "voici la traduction", "traduction", "aquí está la traducción", "traducción",
    ]

    public static func clean(_ raw: String) -> CleanedResponse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped: String? = nil
        var unwrapped = false

        if let newline = text.firstIndex(of: "\n") {
            let firstLine = String(text[text.startIndex..<newline])
            if isPreambleLine(firstLine) {
                stripped = firstLine
                text = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lines = text.components(separatedBy: .newlines)
        if lines.count >= 2,
           lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```",
           !lines[1..<(lines.count - 1)].contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            text = lines[1..<(lines.count - 1)].joined(separator: "\n")
            unwrapped = true
        }

        return CleanedResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               strippedPreamble: stripped, unwrappedCodeFence: unwrapped)
    }

    static func isPreambleLine(_ line: String) -> Bool {
        let normalized = line.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard normalized.count <= 60 else { return false }
        let core = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ":.!— -"))
        return preamblePatterns.contains(core)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ResponseCleanerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/ResponseCleaner.swift Tests/TranslationCoreTests/ResponseCleanerTests.swift
git commit -m "feat(core): response cleaner strips preambles and stray fences"
```

---

### Task 10: MarkupSkeleton *(new — replaces prototype's substring check)*

**Files:**
- Create: `Sources/TranslationCore/MarkupSkeleton.swift`
- Test: `Tests/TranslationCoreTests/MarkupSkeletonTests.swift`

**Interfaces:**
- Produces: `enum MarkupToken: Sendable, Equatable, Hashable { case heading(level: Int); case listItem(depth: Int); case blockquote; case codeBlock(hash: Int, lang: String); case inlineCode(String); case url(bare: Bool); case paragraphBreak; case hardLineBreak }`.
- Produces: `struct MarkupDiff: Sendable, Equatable { let expected: MarkupToken?; let actual: MarkupToken?; let note: String }` — `expected == nil` means the translation added a token, `actual == nil` means it dropped one.
- Produces: `enum MarkupSkeleton { static func tokens(of text: String) -> [MarkupToken]; static func diff(source: String, translation: String) -> [MarkupDiff] }`.

Rationale (spec 4.7): presence-only checks missed all three real defects — a bare URL rewritten as a markdown link, a broken blockquote, and a paragraph split by trailing double-spaces. Structural token comparison catches them.

**Two requirements that distinguish this from the naive version:**

1. **Diff by sequence alignment (LCS), not by index.** Comparing position *i* to position *i* means one dropped token shifts everything after it, turning a single defect into a cascade of spurious warnings. That is precisely the cry-wolf failure the glossary verifier was made cautious to avoid, and it must not be reintroduced here.
2. **`paragraphBreak` and `hardLineBreak` are separate tokens, and neither is filtered out.** The `gpt-oss` defect was trailing double-spaces creating hard breaks inside a paragraph — it *looked* like a shattered paragraph but is a different token. Filtering paragraph structure out of the comparison would drop the ability to catch the very defect that motivated the checker.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslationCoreTests/MarkupSkeletonTests.swift
import Testing
@testable import TranslationCore

@Test func distinguishesBareFromLinkedURL() {
    let bare = MarkupSkeleton.tokens(of: "See https://build.fhir.org/x.html for details.")
    #expect(bare.contains(.url(bare: true)))
    let linked = MarkupSkeleton.tokens(of: "See [https://build.fhir.org/x.html](https://build.fhir.org/x.html).")
    #expect(linked.contains(.url(bare: false)))
}

@Test func diffFlagsURLTurnedIntoLink() {
    let diffs = MarkupSkeleton.diff(source: "See https://x.org here.",
                                    translation: "Смотри [https://x.org](https://x.org) здесь.")
    #expect(!diffs.isEmpty)
}

@Test func preservesInlineCodeExactly() {
    let tokens = MarkupSkeleton.tokens(of: "Set `keep_alive` to `30m`.")
    #expect(tokens.contains(.inlineCode("keep_alive")))
    #expect(tokens.contains(.inlineCode("30m")))
}

@Test func diffFlagsDroppedInlineCode() {
    let diffs = MarkupSkeleton.diff(source: "Set `keep_alive` now.", translation: "Установите keep_alive сейчас.")
    #expect(diffs.contains { $0.expected == .inlineCode("keep_alive") })
}

@Test func identicalStructureProducesNoDiff() {
    let src = "## Title\n\nText with `code` and https://x.org bare."
    let tr = "## Заголовок\n\nТекст с `code` и https://x.org без ссылки."
    #expect(MarkupSkeleton.diff(source: src, translation: tr).isEmpty)
}

@Test func detectsHardLineBreaksAddedInsideAParagraph() {
    // The gpt-oss defect: trailing double-spaces shatter one paragraph into lines.
    let src = "One flowing paragraph that stays whole."
    let tr = "Одна строка,  \nразорванная  \nжёсткими переносами."
    let diffs = MarkupSkeleton.diff(source: src, translation: tr)
    #expect(diffs.contains { $0.actual == .hardLineBreak })
}

@Test func oneDroppedTokenProducesOneDiffNotACascade() {
    // Four inline codes, the second dropped. A positional comparison would report
    // three mismatches; alignment must report exactly one deletion.
    let src = "`alpha` then `beta` then `gamma` then `delta`."
    let tr = "`alpha` затем затем `gamma` затем `delta`."
    let diffs = MarkupSkeleton.diff(source: src, translation: tr)
    #expect(diffs.count == 1)
    #expect(diffs[0].expected == .inlineCode("beta"))
    #expect(diffs[0].actual == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MarkupSkeletonTests`
Expected: FAIL — `MarkupSkeleton` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/MarkupSkeleton.swift
import Foundation

public enum MarkupToken: Sendable, Equatable, Hashable {
    case heading(level: Int)
    case listItem(depth: Int)
    case blockquote
    case codeBlock(hash: Int, lang: String)
    case inlineCode(String)
    case url(bare: Bool)
    case paragraphBreak
    case hardLineBreak
}

public struct MarkupDiff: Sendable, Equatable {
    public let expected: MarkupToken?
    public let actual: MarkupToken?
    public let note: String
}

public enum MarkupSkeleton {
    public static func tokens(of text: String) -> [MarkupToken] {
        var tokens: [MarkupToken] = []
        var fenceBuffer: [String] = []
        var fenceLang = ""
        var insideFence = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideFence {
                if trimmed.hasPrefix("```") {
                    tokens.append(.codeBlock(hash: fenceBuffer.joined(separator: "\n").hashValue, lang: fenceLang))
                    fenceBuffer = []; fenceLang = ""; insideFence = false
                } else { fenceBuffer.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") {
                insideFence = true
                fenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty { tokens.append(.paragraphBreak); continue }
            if let level = headingLevel(trimmed) { tokens.append(.heading(level: level)) }
            if trimmed.hasPrefix(">") { tokens.append(.blockquote) }
            if let depth = listDepth(line) { tokens.append(.listItem(depth: depth)) }
            tokens.append(contentsOf: inlineTokens(in: line))
            // Markdown hard break: two or more trailing spaces on a non-blank line.
            if line.hasSuffix("  ") { tokens.append(.hardLineBreak) }
        }
        if insideFence { tokens.append(.codeBlock(hash: fenceBuffer.joined(separator: "\n").hashValue, lang: fenceLang)) }
        return tokens
    }

    /// Aligns the two token sequences and reports the minimal edit script. Index-wise
    /// comparison is wrong here: one dropped token would shift every later position and
    /// bury a single real defect under a cascade of false ones.
    public static func diff(source: String, translation: String) -> [MarkupDiff] {
        let want = tokens(of: source)
        let got = tokens(of: translation)

        // Longest common subsequence lengths.
        var lcs = Array(repeating: Array(repeating: 0, count: got.count + 1), count: want.count + 1)
        if !want.isEmpty && !got.isEmpty {
            for i in stride(from: want.count - 1, through: 0, by: -1) {
                for j in stride(from: got.count - 1, through: 0, by: -1) {
                    lcs[i][j] = want[i] == got[j] ? lcs[i + 1][j + 1] + 1
                                                  : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var diffs: [MarkupDiff] = []
        var i = 0, j = 0
        while i < want.count && j < got.count {
            if want[i] == got[j] { i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] {
                diffs.append(MarkupDiff(expected: want[i], actual: nil, note: "dropped in translation"))
                i += 1
            } else {
                diffs.append(MarkupDiff(expected: nil, actual: got[j], note: "added in translation"))
                j += 1
            }
        }
        while i < want.count {
            diffs.append(MarkupDiff(expected: want[i], actual: nil, note: "dropped in translation")); i += 1
        }
        while j < got.count {
            diffs.append(MarkupDiff(expected: nil, actual: got[j], note: "added in translation")); j += 1
        }
        return diffs
    }

    static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) ? hashes : nil
    }

    static func listDepth(_ line: String) -> Int? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
        let isOrdered = trimmed.first?.isNumber == true && trimmed.contains(". ")
        guard isBullet || isOrdered else { return nil }
        return leading / 2
    }

    static func inlineTokens(in line: String) -> [MarkupToken] {
        var tokens: [MarkupToken] = []

        // inline code spans
        var current: String? = nil
        for character in line {
            if character == "`" {
                if let open = current { if !open.isEmpty { tokens.append(.inlineCode(open)) }; current = nil }
                else { current = "" }
            } else if current != nil { current?.append(character) }
        }

        // URLs, flagged bare vs. inside a markdown link
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = line as NSString
            for match in detector.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let start = match.range.location
                // "](" immediately before the URL, or "[" ... "](" wrapping → linked
                let precededByLinkParen = start >= 2 && ns.substring(with: NSRange(location: start - 2, length: 2)) == "]("
                let precededByParen = start >= 1 && ns.substring(with: NSRange(location: start - 1, length: 1)) == "("
                tokens.append(.url(bare: !(precededByLinkParen || precededByParen)))
            }
        }
        return tokens
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MarkupSkeletonTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/MarkupSkeleton.swift Tests/TranslationCoreTests/MarkupSkeletonTests.swift
git commit -m "feat(core): structural markup skeleton and diff"
```

---

### Task 11: ModelPolicy *(new)*

**Files:**
- Create: `Sources/TranslationCore/ModelPolicy.swift`
- Test: `Tests/TranslationCoreTests/ModelPolicyTests.swift`

**Interfaces:**
- Produces: `enum ModelRole: Sendable { case interactive, background }`.
- Produces: `enum ModelPolicy { static func defaultModel(for: ModelRole) -> String; static let blacklist: [String: String]; static func blacklistReason(for model: String) -> String? }`. `blacklistReason` matches by model-name prefix (so `gemma3n:e4b` and any tag variant match).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranslationCoreTests/ModelPolicyTests.swift
import Testing
@testable import TranslationCore

@Test func defaultsMatchMeasuredRoles() {
    #expect(ModelPolicy.defaultModel(for: .interactive) == "aya-expanse:8b")
    #expect(ModelPolicy.defaultModel(for: .background) == "gpt-oss:20b")
}

@Test func blacklistedModelsCarryAReason() {
    #expect(ModelPolicy.blacklistReason(for: "gemma3n:e4b") != nil)
    #expect(ModelPolicy.blacklistReason(for: "qwen3:30b") != nil)
    #expect(ModelPolicy.blacklistReason(for: "aya-expanse:8b") == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelPolicyTests`
Expected: FAIL — `ModelPolicy` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/ModelPolicy.swift
import Foundation

public enum ModelRole: Sendable { case interactive, background }

public enum ModelPolicy {
    public static func defaultModel(for role: ModelRole) -> String {
        switch role {
        case .interactive: "aya-expanse:8b"
        case .background: "gpt-oss:20b"
        }
    }

    /// model-name prefix → reason shown in settings
    public static let blacklist: [String: String] = [
        "gemma3n": "Port: corrupts identifiers character-by-character (e.g. `StructureDefiinition` inside inline code). Unsafe for technical documentation.",
        "qwen3:30b": "78 seconds of reasoning before the first character of translation. Too slow for any interactive use.",
    ]

    public static func blacklistReason(for model: String) -> String? {
        for (prefix, reason) in blacklist where model.hasPrefix(prefix) { return reason }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ModelPolicyTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/ModelPolicy.swift Tests/TranslationCoreTests/ModelPolicyTests.swift
git commit -m "feat(core): model policy with measured defaults and blacklist"
```

---

### Task 12: LLMClient protocol, FakeLLMClient, Translator *(orchestration — lift + extend)*

**Files:**
- Modify: `Sources/TranslationCore/LLMClient.swift` (append the `LLMClient` protocol)
- Create: `Sources/TranslationCore/Translator.swift` (`Translator`, `TranslationOutcome`)
- Create: `Tests/TranslationCoreTests/FakeLLMClient.swift` (test double)
- Test: `Tests/TranslationCoreTests/TranslatorTests.swift`

**Interfaces:**
- Consumes: every component from Tasks 1–11.
- Produces: `protocol LLMClient: Sendable { func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> }`.
- Produces: `struct TranslationOutcome: Sendable { let final: String; let chunks: [Chunk]; let documentGlossary: [GlossaryEntry]; let detectedSource: Language?; let checks: [GlossaryCheck]; let markupDiffs: [MarkupDiff]; let stats: [ChatStats]; let timeToFirstTokenMS: Double; let totalMS: Double }`. `documentGlossary` is surfaced deliberately — Plan 2's UI shows it so a human can spot a wrongly translated term, which is the agreed mitigation for that known defect.
- Produces: `struct Translator { init(client: LLMClient); func translate(text:target:tone:userGlossary:options:maxChunkCharacters:ignoredTerms:onToken:) async throws -> TranslationOutcome }`.

**Orchestration order (spec 3.6, 4.4):** detect source → build the document glossary, but **only when there is more than one chunk and the source language was recognised** (extract terms → one term-list call → parse by echoed term) → per chunk: merge the *filtered* user entries with **all** document entries, build prompt, stream, clean → join → run `GlossaryVerifier` and `MarkupSkeleton.diff` on the result.

Three details are load-bearing and each has a test below:

- **Document entries are never filtered by occurrence.** They come from this document and are capped at 20, so there is nothing irrelevant to filter; filtering by surface form would drop a term in exactly the chunks where it appears in another inflected form — the chunks that need it most.
- **The preparatory pass is skipped when `LanguageDetector` returns nil.** Otherwise the source text is parsed with the *target* language's tagger, producing garbage terms that are then forced into every chunk. Note that detection returns nil both for unrecognisable input and for a language outside our nine — Ukrainian or Polish source text is realistic. Translation itself proceeds normally; only the glossary is skipped.
- **The user glossary still filters by occurrence**, exactly as in Task 3. The two glossaries deliberately obey opposite rules; `CONTEXT.md` records why.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/TranslationCoreTests/FakeLLMClient.swift
import Foundation
@testable import TranslationCore

/// Deterministic fake. Returns queued responses in order; records the prompts it saw.
final class FakeLLMClient: LLMClient, @unchecked Sendable {
    private(set) var receivedMessages: [[ChatMessage]] = []
    private var responses: [String]
    init(responses: [String]) { self.responses = responses }

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        receivedMessages.append(messages)
        let reply = responses.isEmpty ? "" : responses.removeFirst()
        return AsyncThrowingStream { continuation in
            for piece in reply.map(String.init) { continuation.yield(.token(piece)) }
            continuation.yield(.done(ChatStats(loadDurationMS: 10, promptEvalCount: 5,
                promptEvalDurationMS: 5, evalCount: reply.count, evalDurationMS: 20)))
            continuation.finish()
        }
    }
}
```

```swift
// Tests/TranslationCoreTests/TranslatorTests.swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranslatorTests`
Expected: FAIL — `LLMClient` protocol / `Translator` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Append to Sources/TranslationCore/LLMClient.swift
public protocol LLMClient: Sendable {
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error>
}
```

```swift
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

        func stream(_ messages: [ChatMessage], markFirstToken: Bool) async throws -> String {
            var buffer = ""
            for try await event in client.chat(messages: messages, options: options) {
                switch event {
                case .token(let token):
                    if markFirstToken && firstTokenAt == nil { firstTokenAt = Date() }
                    buffer += token; onToken(token)
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
                                           markFirstToken: false)
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
            let raw = try await stream(PromptBuilder.messages(for: request), markFirstToken: true)
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranslatorTests`
Expected: PASS (5 tests). Then run the full core suite: `swift test` — all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslationCore/LLMClient.swift Sources/TranslationCore/Translator.swift Tests/TranslationCoreTests/FakeLLMClient.swift Tests/TranslationCoreTests/TranslatorTests.swift
git commit -m "feat(core): translator orchestration with document glossary"
```

---

### Task 13: OllamaKit — stream parser and client *(lift from prototype)*

**Files:**
- Create: `Sources/OllamaKit/OllamaStreamParser.swift`
- Create: `Sources/OllamaKit/OllamaError.swift`
- Create: `Sources/OllamaKit/OllamaClient.swift`
- Test: `Tests/OllamaKitTests/OllamaStreamParserTests.swift`

**Interfaces:**
- Consumes: `ChatMessage`, `ChatOptions`, `ChatEvent`, `ChatStats`, `LLMClient` from `TranslationCore`.
- Produces: `enum OllamaStreamParser { static func parse(line: String) -> ChatEvent? }` — pure, so it is fixture-tested without a live server. Ignores `message.thinking`; emits `.token` only for non-empty `message.content`; emits `.done` on `done == true` with ns→ms conversion.
- Produces: `struct OllamaModel: Sendable { let name: String; let sizeBytes: Int64; var sizeGB: Double }`.
- Produces: `enum OllamaError: LocalizedError { case notRunning; case httpStatus(Int, String); case decoding(String) }`.
- Produces: `struct OllamaClient: LLMClient { init(baseURL: URL = ...); func models() async throws -> [OllamaModel]; func chat(...) -> AsyncThrowingStream<ChatEvent, Error> }`.

The stream parser is the only unit-tested piece (spec 10); `models()`/`chat()` are exercised by the CLI in Task 14 against a live server.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OllamaKitTests/OllamaStreamParserTests.swift
import Testing
@testable import OllamaKit
@testable import TranslationCore

@Test func parsesContentToken() {
    let event = OllamaStreamParser.parse(line: #"{"message":{"role":"assistant","content":"OK"},"done":false}"#)
    guard case .token(let text)? = event else { Issue.record("expected token"); return }
    #expect(text == "OK")
}

@Test func discardsThinkingAndEmptyContent() {
    let event = OllamaStreamParser.parse(line: #"{"message":{"role":"assistant","thinking":"let me think","content":""},"done":false}"#)
    #expect(event == nil)
}

@Test func parsesDoneWithNanosecondToMillisecondConversion() {
    let line = #"{"message":{"content":""},"done":true,"total_duration":2143180000,"load_duration":1995376625,"prompt_eval_count":64,"prompt_eval_duration":91362000,"eval_count":3,"eval_duration":50088000}"#
    guard case .done(let stats)? = OllamaStreamParser.parse(line: line) else { Issue.record("expected done"); return }
    #expect(stats.loadDurationMS == 1995.376625)
    #expect(stats.evalCount == 3)
    #expect(abs(stats.evalDurationMS - 50.088) < 0.001)
}

@Test func returnsNilForBlankOrGarbageLine() {
    #expect(OllamaStreamParser.parse(line: "") == nil)
    #expect(OllamaStreamParser.parse(line: "not json") == nil)
}
```

Note: `ChatEvent` needs `Equatable` for the `== nil` comparisons on optionals. Add `extension ChatEvent: Equatable` in the test file only if not already `Equatable`; simpler — the tests above use pattern matching for the value cases and `== nil` only on `Optional<ChatEvent>` where the wrapped type must be Equatable. Make `ChatStats` and `ChatEvent` conform to `Equatable` in `LLMClient.swift` (append `: Equatable`) as part of this task, since it is harmless and the parser tests rely on it.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OllamaStreamParserTests`
Expected: FAIL — `OllamaStreamParser` not defined.

- [ ] **Step 3: Write the implementation**

First make the event types Equatable (append to `Sources/TranslationCore/LLMClient.swift`):

```swift
extension ChatStats: Equatable {}
extension ChatEvent: Equatable {
    public static func == (lhs: ChatEvent, rhs: ChatEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.token(a), .token(b)): a == b
        case let (.done(a), .done(b)): a == b
        default: false
        }
    }
}
```

```swift
// Sources/OllamaKit/OllamaStreamParser.swift
import Foundation
import TranslationCore

public enum OllamaStreamParser {
    public static func parse(line: String) -> ChatEvent? {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if (object["done"] as? Bool) == true { return .done(stats(from: object)) }

        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            return .token(content) // message.thinking is intentionally ignored
        }
        return nil
    }

    static func stats(from object: [String: Any]) -> ChatStats {
        func ms(_ key: String) -> Double { ((object[key] as? NSNumber)?.doubleValue ?? 0) / 1_000_000 }
        func count(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        return ChatStats(loadDurationMS: ms("load_duration"), promptEvalCount: count("prompt_eval_count"),
                         promptEvalDurationMS: ms("prompt_eval_duration"), evalCount: count("eval_count"),
                         evalDurationMS: ms("eval_duration"))
    }
}
```

```swift
// Sources/OllamaKit/OllamaError.swift
import Foundation

public enum OllamaError: LocalizedError {
    case notRunning
    case httpStatus(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Ollama is not reachable on 127.0.0.1:11434. Start it with `ollama serve`."
        case let .httpStatus(code, body): "Ollama returned HTTP \(code): \(body)"
        case let .decoding(detail): "Could not decode Ollama response: \(detail)"
        }
    }
}
```

```swift
// Sources/OllamaKit/OllamaClient.swift
import Foundation
import TranslationCore

public struct OllamaModel: Sendable {
    public let name: String
    public let sizeBytes: Int64
    public var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }
}

public struct OllamaClient: LLMClient {
    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: config)
    }

    public func models() async throws -> [OllamaModel] {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
        guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
        guard http.statusCode == 200 else { throw OllamaError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["models"] as? [[String: Any]] else { throw OllamaError.decoding("unexpected /api/tags shape") }
        return raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return OllamaModel(name: name, sizeBytes: (entry["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    public func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": options.model, "stream": true, "keep_alive": options.keepAlive,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "options": ["temperature": options.temperature],
                    ])
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OllamaError.notRunning }
                    guard http.statusCode == 200 else { throw OllamaError.httpStatus(http.statusCode, "see ollama logs") }
                    for try await line in bytes.lines {
                        if let event = OllamaStreamParser.parse(line: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter OllamaStreamParserTests`
Expected: PASS (4 tests). Then `swift test` — entire suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OllamaKit Tests/OllamaKitTests Sources/TranslationCore/LLMClient.swift
git commit -m "feat(ollama): stream parser discarding thinking, and HTTP client"
```

---

### Task 14: translate-cli harness + end-to-end smoke *(new)*

**Files:**
- Create: `Sources/translate-cli/main.swift`
- Manual test only (exercises a live Ollama; not in CI).

**Interfaces:**
- Consumes: `OllamaClient`, `Translator`, `Language`, `Tone`, `ModelPolicy` from the two library modules.

CLI contract: `translate-cli --to <lang> [--from <lang>] [--tone <tone>] [--model <name>] [--chunk <n>] [text]`. If `text` is omitted, read stdin. Streams tokens to stdout as they arrive; prints a metrics footer (TTFT, total ms, chunk count, document glossary size, glossary checks, markup diffs) to stderr so stdout stays a clean translation.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/translate-cli/main.swift
import Foundation
import OllamaKit
import TranslationCore

func value(for flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard let toRaw = value(for: "--to", in: args), let target = Language(rawValue: toRaw) else {
    FileHandle.standardError.write(Data("usage: translate-cli --to <ru|en|de|fr|es|pt|it|zh|ja> [--from L] [--tone neutral|formal|casual|technical|literal] [--model NAME] [--chunk N] [text]\n".utf8))
    exit(2)
}
let source = value(for: "--from", in: args).flatMap(Language.init(rawValue:))
let tone = value(for: "--tone", in: args).flatMap(Tone.init(rawValue:)) ?? .neutral
let model = value(for: "--model", in: args) ?? ModelPolicy.defaultModel(for: .interactive)
// No --two-pass flag: the second pass is cut from v1 (see Global Constraints).
let chunk = value(for: "--chunk", in: args).flatMap(Int.init) ?? 900

let positional = args.filter { !$0.hasPrefix("--") }
    .filter { arg in ![toRaw, source?.rawValue, tone.rawValue, model, String(chunk)].compactMap { $0 }.contains(arg) }
let text = positional.last ?? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write(Data("no input text\n".utf8)); exit(2)
}

if let reason = ModelPolicy.blacklistReason(for: model) {
    FileHandle.standardError.write(Data("warning: model \(model) is blacklisted — \(reason)\n".utf8))
}

let translator = Translator(client: OllamaClient())
let options = ChatOptions(model: model, temperature: 0.2, keepAlive: "30m")

do {
    let outcome = try await translator.translate(
        text: text, target: target, tone: tone, userGlossary: nil,
        options: options, maxChunkCharacters: chunk,
        onToken: { FileHandle.standardOutput.write(Data($0.utf8)) })
    FileHandle.standardOutput.write(Data("\n".utf8))
    var footer = "\n— \(Int(outcome.timeToFirstTokenMS))ms TTFT · \(Int(outcome.totalMS))ms total · \(outcome.chunks.count) chunk(s)"
    if !outcome.documentGlossary.isEmpty { footer += " · \(outcome.documentGlossary.count) document terms" }
    let missing = outcome.checks.filter { $0.status == .missing }
    if !missing.isEmpty { footer += " · glossary misses: \(missing.map(\.term).joined(separator: ", "))" }
    if !outcome.markupDiffs.isEmpty { footer += " · \(outcome.markupDiffs.count) markup diff(s)" }
    FileHandle.standardError.write(Data((footer + "\n").utf8))
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: End-to-end smoke against live Ollama**

Ensure `ollama serve` is running and `aya-expanse:8b` is pulled.

Run:
```bash
swift run translate-cli --to de "The profile server validates every StructureDefinition before publishing."
```
Expected: German translation on stdout; metrics footer on stderr; `StructureDefinition` reproduced unchanged.

- [ ] **Step 4: Verify markup and chunk behaviour end to end**

Run:
```bash
printf '## Publishing\n\nRun `profile-server publish` first. See https://build.fhir.org/x.html for details.\n\nA second paragraph that is long enough to matter for the chunker when the budget is small.' | swift run translate-cli --to ru --chunk 120
```
Expected: heading, inline code `profile-server publish`, and the bare URL all preserved; stderr shows more than one chunk and no markup diffs (or a listed diff if the model altered structure).

- [ ] **Step 5: Commit**

```bash
git add Sources/translate-cli/main.swift
git commit -m "feat(cli): end-to-end translate harness over the engine"
```

---

### Task 15: Acceptance harness — does the engine actually fix the measured defects? *(new)*

**Files:**
- Create: `corpus/techdoc-en.md`, `corpus/techdoc-ru.md`, `corpus/email-en.md`, `corpus/article-en.md`
- Create: `Sources/acceptance/main.swift`
- Modify: `Package.swift` (add the `acceptance` executable target, depending on `TranslationCore` and `OllamaKit`)
- Manual only — needs a live Ollama, never runs in CI.

**Interfaces:**
- Consumes: `Translator`, `TranslationOutcome.translatedChunks`, `LemmaMatcher`, `MarkupSkeleton`, `ModelPolicy`, `OllamaClient`.

Unit tests prove each component behaves; nothing so far proves the *engine* fixed the defects that justified rebuilding it. This task closes that gap by re-running the original measurements against the real engine and failing loudly if they regress.

**Thresholds**, taken from the prototype's measured baseline:

| Check | Threshold | Baseline it comes from |
|---|---|---|
| Cross-chunk term adherence, chunked texts | ≥ 85% | prototype scored 88% twice; below 85% means the document glossary regressed |
| Markup diffs on `techdoc-*` | 0 | code blocks, inline code and URLs survived every prototype run |
| Time to first token, interactive model | < 1000 ms | prototype measured 330–570 ms warm |

Adherence is the experiment's metric: for every (term, chunk) pair where the *source* chunk contains a document-glossary term, does the *translated* chunk carry that term's agreed translation? Matching is by lemma, so inflection does not produce false failures.

- [ ] **Step 1: Write the corpus**

Four files. `article-en.md` must exceed 2000 characters so it chunks at the default budget — an acceptance run where nothing chunks would silently skip the glossary entirely. `techdoc-en.md` and `techdoc-ru.md` must each contain a fenced code block, at least two inline code spans, a bare URL and a blockquote. Reuse the prototype's sample texts as a starting point; they are known to exercise the defects.

- [ ] **Step 2: Write the harness**

```swift
// Sources/acceptance/main.swift
import Foundation
import OllamaKit
import TranslationCore

let model = ModelPolicy.defaultModel(for: .interactive)
let client = OllamaClient()
let translator = Translator(client: client)
let corpus = try FileManager.default
    .contentsOfDirectory(atPath: "corpus")
    .filter { $0.hasSuffix(".md") }
    .sorted()

var failures: [String] = []

for name in corpus {
    let text = try String(contentsOfFile: "corpus/\(name)", encoding: .utf8)
    let target: Language = name.hasSuffix("-ru.md") ? .en : .ru
    let outcome = try await translator.translate(
        text: text, target: target, tone: .technical, userGlossary: nil,
        options: ChatOptions(model: model), maxChunkCharacters: 900)

    // 1. Cross-chunk term adherence.
    var honoured = 0, applicable = 0
    if outcome.chunks.count > 1, let source = outcome.detectedSource {
        for entry in outcome.documentGlossary {
            guard let expected = entry.requiredTranslation(for: target) else { continue }
            for (index, chunk) in outcome.chunks.enumerated() {
                guard LemmaMatcher.matches(expected: entry.term, in: chunk.text, language: source) == true
                else { continue }
                applicable += 1
                if LemmaMatcher.matches(expected: expected, in: outcome.translatedChunks[index],
                                        language: target) == true { honoured += 1 }
            }
        }
    }
    let adherence = applicable == 0 ? 100.0 : Double(honoured) / Double(applicable) * 100

    // 2. Markup integrity on the technical documents.
    let markupOK = !name.hasPrefix("techdoc") || outcome.markupDiffs.isEmpty

    // 3. Latency.
    let ttft = outcome.timeToFirstTokenMS

    print("\(name): adherence \(String(format: "%.1f%%", adherence)) (\(honoured)/\(applicable)) · " +
          "\(outcome.chunks.count) chunks · \(outcome.documentGlossary.count) terms · " +
          "\(outcome.markupDiffs.count) markup diffs · TTFT \(Int(ttft)) ms")
    for diff in outcome.markupDiffs {
        print("    markup: expected \(String(describing: diff.expected)) actual \(String(describing: diff.actual))")
    }

    if applicable > 0 && adherence < 85 { failures.append("\(name): adherence \(String(format: "%.1f%%", adherence)) < 85%") }
    if !markupOK { failures.append("\(name): \(outcome.markupDiffs.count) markup diffs, expected 0") }
    if ttft >= 1000 { failures.append("\(name): TTFT \(Int(ttft)) ms >= 1000 ms") }
}

if failures.isEmpty {
    print("\nACCEPTED — engine meets the prototype baseline")
} else {
    print("\nFAILED")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Run the acceptance harness**

Ensure `ollama serve` is running with `aya-expanse:8b` pulled.

Run: `swift run acceptance`
Expected: every corpus file reported, then `ACCEPTED`. If a check fails the harness exits non-zero and names the file and metric — that is a real regression, not flakiness to retry away. Investigate before proceeding.

- [ ] **Step 5: Commit**

```bash
git add corpus Sources/acceptance/main.swift Package.swift
git commit -m "feat(acceptance): corpus harness enforcing the prototype baseline"
```

---

## Self-Review

**Spec coverage** (spec section → task):
- 3.1 OllamaKit (thinking discard, ns→ms) → Task 13. ✅ `pull()`/`ps()` explicitly deferred to Plan 2.
- 3.2 TranslationCore components → Tasks 1–12 (every row of the spec table has a task). ✅
- 3.6 hotkey data flow (engine portion: detect→extract→chunk→prompt→clean→verify) → Task 12. ✅ Capture/panel portion is Plan 2.
- 4.1 prompt rules → Task 8. 4.2 tone → Task 1. 4.3 chunking → Task 2. ✅
- 4.4 terminology continuity (extract → term-list call → doc glossary → unfiltered per-chunk injection, skipped when the source language is unknown) → Tasks 4, 7, 12. ✅
- 4.5 user glossary occurrence filtering → Task 3. 4.6 three-state verifier → Tasks 5, 6. ✅
- 4.7 MarkupSkeleton with LCS alignment, `paragraphBreak` and `hardLineBreak` → Task 10. ✅
- 4.8 second pass → **removed from the spec and from this plan**; both framings were measured and both failed. Nothing to implement.
- 4.9 streaming + cancellation → Task 12 (`onToken`, `AsyncThrowingStream`) and Task 13 (`onTermination` cancels the URLSession task). ✅
- 5 ModelPolicy defaults + blacklist with reasons → Task 11. ✅ 5.1 keep_alive default in `ChatOptions` → Task 8; launch warmup deferred to Plan 2.
- 8 error handling: `OllamaError` (not running, http status) → Task 13; 120s timeout → Task 13 `URLSessionConfiguration`. ✅ Retry/UI flows are Plan 2.
- 10 testing: core with fake client → Tasks 1–12; OllamaKit fixture parsing → Task 13; live-model acceptance run → Task 15. ✅

**Gaps found and resolved:** keep_alive launch warmup, `pull()`/`ps()`, showing the document glossary in the UI (spec 7.3, the agreed mitigation for a wrongly translated term), and all capture/permission/UI behaviour are Plan-2 concerns; each is labelled deferred rather than silently dropped. `TranslationOutcome.documentGlossary` is exposed here specifically so Plan 2 can display it. No engine requirement is left without a task.

**Placeholder scan:** no TBD/TODO/"handle edge cases"/"similar to Task N"; every code step carries real code. ✅

**Type consistency:** `ChatMessage`/`ChatOptions`/`ChatEvent`/`ChatStats` are created in Task 8 (`LLMClient.swift`) and the `LLMClient` protocol appended in Task 12 — Task 8 states this split up front, so no task references an undefined type. `TranslationRequest` has no `precedingContext` and `PromptBuilder` has no `refineMessages`; both absences are stated explicitly where a reader would expect them. `DocumentGlossary.parse(_:knownTerms:target:)` has one signature across Tasks 7 and 12. `TranslationOutcome` fields (`final`, `chunks`, `translatedChunks`, `documentGlossary`, `detectedSource`, `checks`, `markupDiffs`, `stats`, `timeToFirstTokenMS`, `totalMS`) are used identically in Tasks 12, 14 and 15. `GlossaryCheck.status` (`.satisfied/.missing/.unverifiable`) is used identically in Tasks 6, 12, 14. ✅

**Experiment traceability:** every mechanism this plan builds is either lifted from validated prototype code or backed by a measurement recorded in the prototype README — the document glossary's three rules (echo-matching, no filtering, skip on unknown language), the LCS diff, and the removal of the second pass all trace to a specific run.

---

## Execution Handoff

Plan complete. Plan 2 (macOS app shell) will be written after the engine is green.
