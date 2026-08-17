# «Правка» (Proofreading + Rewrite Styles) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second operation beside translation — correcting a text in its own language, with a degree control (errors only / errors and style) and a target rewrite style — in the main window and the ⌥⌘T panel.

**Architecture:** Правка is a second route through the existing pipeline: `Translator.proofread` reuses the chunking, per-chunk streaming, cancellation and byte-for-byte assembly machinery (extracted into a shared private helper), skips every glossary stage, and returns the same `TranslationOutcome` with honestly empty glossary fields. The app layer adds a `TextOperation` dispatch in `TranslationViewModel.run()`, an operation switch in the window toolbar and the panel, and two settings defaults.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, SwiftUI/AppKit, Swift Testing. No new dependencies.

**Spec:** `docs/design/specs/2026-08-10-proofreading-design.md`. Where this plan and the spec disagree, the spec wins; where either disagrees with measured comments in the code, the code's comments win.

## Global Constraints

- Swift 6 tools, `.swiftLanguageMode(.v6)` on every target; platform floor macOS 14.
- `swift build --build-tests` must stay at **zero warnings** — a standing rule, enforced by CI.
- **No external dependencies.** The framework whitelist in CLAUDE.md is closed; this feature adds nothing to it.
- Tests: Swift Testing (`@Test`, `#expect`), names are sentences; `UserDefaults`-backed tests use `InMemoryDefaults`, never a real suite; the suite stays offline (`FakeLLMClient`).
- No test may restate the reassembly formula — call `ChunkPlan.assembled(from:)` (docs/TESTING.md).
- All user-facing strings Russian, «guillemets» and «ё»; **no backticks in strings rendered by `Text(String)`**; Russian labels for domain enums live in `RussianCopy.swift`, exhaustive with no `default:`.
- Code comments carry *why* and the measurement behind it. Do not delete code a «measured»/«load-bearing» comment justifies without updating the comment.
- Nothing derived from the user's text may be logged.
- Commits: conventional, scoped — `feat(core):`, `feat(app):`, `test(app):`, `docs(...)`. Commit messages end with the Claude co-author trailer.
- The engine (`TranslationCore`) depends on Foundation/NaturalLanguage only — no `os`, no UI types.
- Run the full suite with `swift test` (~2 s); single tests with `swift test --filter <name>`.

---

### Task 1: `ProofreadingLevel` and `RewriteStyle` in TranslationCore

**Files:**
- Create: `Sources/TranslationCore/Proofreading.swift`
- Test: `Tests/TranslationCoreTests/ProofreadingModesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum ProofreadingLevel: String, CaseIterable, Sendable { case errorsOnly, errorsAndStyle }` with `var instruction: String` and `var allowsRewriteStyle: Bool`; `public enum RewriteStyle: String, CaseIterable, Sendable { case original, friendly, business, professional, plain }` with `var instruction: String?` (nil for `.original`). Later tasks rely on these exact names.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/TranslationCoreTests/ProofreadingModesTests.swift
import Testing
@testable import TranslationCore

@Test func everyProofreadingLevelCarriesANonEmptyInstruction() {
    for level in ProofreadingLevel.allCases {
        #expect(!level.instruction.isEmpty)
    }
}

@Test func errorsOnlyForbidsRephrasingAndErrorsAndStyleNamesAwkwardPhrasing() {
    #expect(ProofreadingLevel.errorsOnly.instruction.lowercased().contains("do not rephrase"))
    #expect(ProofreadingLevel.errorsAndStyle.instruction.lowercased().contains("awkward"))
}

@Test func onlyErrorsAndStyleAllowsARewriteStyle() {
    // The one availability rule both the toolbar and the settings pane read (spec §7).
    #expect(!ProofreadingLevel.errorsOnly.allowsRewriteStyle)
    #expect(ProofreadingLevel.errorsAndStyle.allowsRewriteStyle)
}

@Test func originalContributesNoInstructionAndEveryOtherStyleDoes() {
    // «Как в оригинале» is a case, not an absence (spec §4.1) — and its instruction
    // is nil so the prompt builder has nothing to append for it.
    #expect(RewriteStyle.original.instruction == nil)
    for style in RewriteStyle.allCases where style != .original {
        #expect(style.instruction?.isEmpty == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProofreadingModesTests`
Expected: compile failure — `ProofreadingLevel` not found.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/TranslationCore/Proofreading.swift
import Foundation

/// How freely правка may change the wording. The instruction is prompt material,
/// like `Tone.instruction`; the Russian labels live in the app layer
/// (`RussianCopy.swift`), keeping this target UI-agnostic.
public enum ProofreadingLevel: String, CaseIterable, Sendable {
    case errorsOnly, errorsAndStyle

    public var instruction: String {
        switch self {
        case .errorsOnly:
            "Fix only objective errors: spelling, punctuation, and clear grammatical mistakes. "
            + "Do not rephrase, do not reorder, do not restyle — keep every wording choice the "
            + "author made. The result must differ from the original only where an error was corrected."
        case .errorsAndStyle:
            "Fix spelling, punctuation, and grammatical errors, and also smooth awkward phrasing: "
            + "remove bureaucratic constructions, needless repetition, and clumsy word order. "
            + "Preserve the author's meaning, voice, and overall structure."
        }
    }

    /// The single availability rule for the style controls: a rewrite style is a change
    /// of wording, so it is expressible only where wording may change. The toolbar and
    /// the settings pane both read this rather than restating the comparison — a restated
    /// condition is how two surfaces come to disagree (spec §7).
    public var allowsRewriteStyle: Bool { self == .errorsAndStyle }
}

/// The register a rewrite aims at. `.original` — «как в оригинале» — is a case rather
/// than an absent optional, exactly as `Tone.neutral` is a case: `nil` keeps its
/// app-wide meaning of «no override, follow the setting», and no double optional
/// appears anywhere (spec §4.1).
public enum RewriteStyle: String, CaseIterable, Sendable {
    case original, friendly, business, professional, plain

    /// Nil for `.original`: keeping the author's register needs no instruction, and an
    /// instruction saying «keep it» would dilute the level instruction next to it.
    public var instruction: String? {
        switch self {
        case .original:
            nil
        case .friendly:
            "Rewrite in a warm, friendly, informal register — the way one writes to a colleague one knows well."
        case .business:
            "Rewrite in a formal, polite business register, suitable for letters, applications, and official correspondence."
        case .professional:
            "Rewrite in a precise, professional working register, suitable for documentation, reports, and workplace communication: established terminology, no bureaucratese, no familiarity."
        case .plain:
            "Rewrite in plain language: short sentences, simple words, maximum readability — changing nothing else about the register."
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProofreadingModesTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Build with tests, check zero warnings, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning   # must print nothing
git add Sources/TranslationCore/Proofreading.swift Tests/TranslationCoreTests/ProofreadingModesTests.swift
git commit -m "feat(core): add ProofreadingLevel and RewriteStyle"
```

---

### Task 2: The proofread prompt in `PromptBuilder`

**Files:**
- Modify: `Sources/TranslationCore/PromptBuilder.swift`
- Test: `Tests/TranslationCoreTests/ProofreadPromptTests.swift` (create)

**Interfaces:**
- Consumes: `ProofreadingLevel`, `RewriteStyle` (Task 1); `Language.englishName` (exists).
- Produces: `PromptBuilder.proofreadMessages(text:language:level:style:) -> [ChatMessage]` and `PromptBuilder.proofreadSystemPrompt(language:level:style:) -> String`. `language` is `Language?`. Task 4's engine calls `proofreadMessages`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/TranslationCoreTests/ProofreadPromptTests.swift
import Testing
@testable import TranslationCore

@Test func theProofreadPromptCarriesTheLevelInstructionAndTheTranslationBan() {
    let messages = PromptBuilder.proofreadMessages(text: "Превет, мир.", language: .ru,
                                                   level: .errorsOnly, style: .original)
    let system = messages.first { $0.role == "system" }!.content
    #expect(system.contains(ProofreadingLevel.errorsOnly.instruction))
    #expect(system.contains("Never translate"))
    // The single most damaging failure is a model that helpfully translates, so a known
    // language is named twice — about the text and about the output (spec §4.2).
    #expect(system.components(separatedBy: "Russian").count >= 3)
    let user = messages.last!.content
    #expect(user.contains("<text>"))
    #expect(user.contains("Превет, мир."))
}

@Test func theStyleInstructionReachesThePromptOnlyUnderErrorsAndStyle() {
    let friendly = RewriteStyle.friendly.instruction!
    let with = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsAndStyle,
                                                   style: .friendly)
    #expect(with.contains(friendly))
    // The engine-side half of the rule the UI expresses by disabling the control:
    // a style passed with .errorsOnly never reaches the prompt (spec §4.1).
    let errorsOnly = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsOnly,
                                                         style: .friendly)
    #expect(!errorsOnly.contains(friendly))
    let original = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsAndStyle,
                                                       style: .original)
    #expect(!original.contains(friendly))
}

@Test func anUndetectedLanguageKeepsTheBanWithoutNamingALanguage() {
    let system = PromptBuilder.proofreadSystemPrompt(language: nil, level: .errorsOnly,
                                                     style: .original)
    #expect(system.contains("same language as the original"))
    #expect(!system.contains("The text is in"))
}

@Test func theProofreadPromptSharesTheProtectionRulesAndCarriesNoGlossary() {
    let system = PromptBuilder.proofreadSystemPrompt(language: .en, level: .errorsOnly,
                                                     style: .original)
    #expect(system.contains("fenced code blocks"))
    #expect(system.contains("byte for byte"))
    #expect(system.contains("URLs"))
    #expect(system.lowercased().contains("only the corrected text"))
    // Правка has no target language to key translations[target] on (spec §4.2).
    #expect(!system.contains("Terminology"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProofreadPromptTests`
Expected: compile failure — `proofreadMessages` not found.

- [ ] **Step 3: Implement — extract the shared rules, add the proofread prompt**

In `PromptBuilder.swift`, replace the four structure/protection lines inside `systemPrompt(for:)` with a reference to a new shared constant, and add the proofread functions. The extraction is **wording-neutral**: the four strings move verbatim, including the comment above the fence rule.

```swift
// Inside enum PromptBuilder, add:

/// The structure and protection rules both prompts share, extracted so the translation
/// and proofread prompts cannot drift apart (spec §4.2). Wording is unchanged from the
/// translation prompt these lines came from.
private static let protectionRules = [
    "- Preserve the original structure exactly: line breaks, blank lines, list markers, blockquote markers (>), heading levels.",
    // Fenced and inline code only. A clause covering "lines indented by four
    // or more spaces" was added and removed the same day: inside a prose
    // chunk it left indented prose — a nested list item, a quoted email —
    // untranslated, and this translator sees selections with no format
    // context to tell code from an indented paragraph.
    "- Never translate the contents of fenced code blocks (```) or inline code (`like this`). Reproduce them byte for byte, including any human-readable text inside them — a commit message, a string literal or a comment inside a code block must be left in the source language.",
    "- Never translate URLs, email addresses, file paths, CLI flags, or identifiers such as function and variable names.",
    "- Keep numbers, units, and dates in their original values.",
]
```

In `systemPrompt(for:)`, the `lines` array becomes:

```swift
var lines = [
    "You are a professional translator. Translate the user's text \(sourceClause)into \(request.target.englishName).",
    "",
    "Rules:",
    "- Output ONLY the translation. No preamble, no notes, no explanation, no quotes around it.",
]
lines.append(contentsOf: protectionRules)
lines.append("- \(request.tone.instruction)")
```

(The glossary block below it is untouched.) Then add:

```swift
/// The system prompt for правка. The language is named twice when known — about the
/// text and about the output — because the single most damaging failure of this
/// feature is a model that helpfully translates (spec §4.2). No glossary block, ever:
/// правка has no target language for `translations[target]` to key on.
public static func proofreadSystemPrompt(language: Language?, level: ProofreadingLevel,
                                         style: RewriteStyle) -> String {
    let textClause = language.map { "The text is in \($0.englishName). " } ?? ""
    let outputClause = language.map { "The corrected text must be in \($0.englishName)." }
        ?? "The corrected text must be in the same language as the original."
    var lines = [
        "You are a meticulous copy editor. Correct the user's text. "
        + "\(textClause)Never translate it: \(outputClause)",
        "",
        "Rules:",
        "- Output ONLY the corrected text. No preamble, no notes, no explanation, no quotes around it.",
    ]
    lines.append(contentsOf: protectionRules)
    lines.append("- \(level.instruction)")
    // The engine-side enforcement of the availability rule: the UI disables the style
    // control under «только ошибки», and this guard holds even for a caller that
    // bypasses the UI (spec §4.1). `.original`'s instruction is nil either way.
    if level.allowsRewriteStyle, let styleInstruction = style.instruction {
        lines.append("- \(styleInstruction)")
    }
    return lines.joined(separator: "\n")
}

public static func proofreadMessages(text: String, language: Language?,
                                     level: ProofreadingLevel,
                                     style: RewriteStyle) -> [ChatMessage] {
    [ChatMessage(role: "system",
                 content: proofreadSystemPrompt(language: language, level: level, style: style)),
     ChatMessage(role: "user", content: """
     Correct the text between the markers.

     <text>
     \(text)
     </text>
     """)]
}
```

- [ ] **Step 4: Run the new tests and the whole core suite**

Run: `swift test --filter ProofreadPromptTests` — 4 PASS.
Run: `swift test --filter PromptBuilderTests` — all existing translation-prompt tests still PASS (the extraction was wording-neutral).

- [ ] **Step 5: Zero warnings, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
git add Sources/TranslationCore/PromptBuilder.swift Tests/TranslationCoreTests/ProofreadPromptTests.swift
git commit -m "feat(core): proofread prompt, sharing the protection rules with translation"
```

---

### Task 3: Extract the shared chunk-streaming helper (pure refactor)

**Files:**
- Modify: `Sources/TranslationCore/Translator.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (file-private, used by Task 4 inside the same file): `final class ChunkRunAccumulators { var firstTokenAt: Date?; var stats: [ChatStats] }` and `Translator.streamChunkReply(_ messages:chunk:options:into:onToken:) async throws -> String`. **Behaviour must be byte-identical** — the existing suite is the harness; no test changes in this task.

- [ ] **Step 1: Run the full suite for a green baseline**

Run: `swift test`
Expected: all PASS. Record the count.

- [ ] **Step 2: Extract**

In `Translator.swift`, above `struct Translator`, add:

```swift
/// Mutable per-run accumulators for the chunk streaming shared by `translate` and
/// `proofread`: when the first *content* token reached the consumer, and the stats of
/// every per-chunk call. A reference type so the shared helper can write what the
/// calling run then reads; it never leaves the run's task, so it needs no
/// synchronisation.
private final class ChunkRunAccumulators {
    var firstTokenAt: Date? = nil
    var stats: [ChatStats] = []
}
```

Move the **entire** nested `streamChunkTranslation` function out of `translate` and into a private method on `Translator`, renamed `streamChunkReply`, carrying its whole doc comment (the buffering/fence/preamble explanation is load-bearing and moves with the code it justifies):

```swift
// Signature (the body is the existing nested function's body, unchanged except that
// `firstTokenAt` becomes `acc.firstTokenAt`, `stats.append(...)` becomes
// `acc.stats.append(...)`, and `options`/`onToken` are parameters):
private func streamChunkReply(_ messages: [ChatMessage], chunk: Chunk,
                              options: ChatOptions, into acc: ChunkRunAccumulators,
                              onToken: @escaping @Sendable (String) -> Void) async throws -> String
```

In `translate`:
- Replace `var firstTokenAt: Date? = nil` and `var stats: [ChatStats] = []` with `let acc = ChunkRunAccumulators()`.
- The per-chunk call becomes `try await streamChunkReply(PromptBuilder.messages(for: request), chunk: chunk, options: options, into: acc, onToken: onToken)`.
- The outcome's `stats:` becomes `acc.stats`, and `timeToFirstTokenMS:` becomes `acc.firstTokenAt.map { ($0.timeIntervalSince(started) - reviewWait) * 1000 }`.
- `streamTermList` stays nested in `translate` — it is glossary scaffolding and правка never runs it.

- [ ] **Step 3: Run the full suite — the refactor's whole test**

Run: `swift test`
Expected: exactly the baseline count, all PASS. Any failure means behaviour moved; fix before proceeding.

- [ ] **Step 4: Zero warnings, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
git add Sources/TranslationCore/Translator.swift
git commit -m "refactor(core): extract the per-chunk streaming into a shared helper"
```

---

### Task 4: `Translator.proofread`

**Files:**
- Modify: `Sources/TranslationCore/Translator.swift`
- Test: `Tests/TranslationCoreTests/ProofreaderTests.swift` (create)

**Interfaces:**
- Consumes: `streamChunkReply`/`ChunkRunAccumulators` (Task 3), `PromptBuilder.proofreadMessages` (Task 2).
- Produces: `public func proofread(text:level:style:source:options:maxChunkCharacters:onToken:onProgress:) async throws -> TranslationOutcome` — `style` defaults `.original`, `source` defaults nil, `onToken`/`onProgress` default no-ops. Task 7's view model calls it.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/TranslationCoreTests/ProofreaderTests.swift
import Foundation
import Testing
@testable import TranslationCore

/// Long enough that a 200-character budget splits it at the blank line into two части.
private let twoParagraphs = """
Первый абзац достаточно длинный, чтобы вместе со вторым не поместиться в один запрос, \
и поэтому текст разрезается на две части по пустой строке между абзацами.

Второй абзац такой же длинный и говорит о том же самом, чтобы разрезание случилось \
наверняка и в каждой части оказался свой кусок исходного текста.
"""

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ piece: String) { lock.lock(); text += piece; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

@Test func proofreadMakesOneCallPerChunkAndNeverATermListCall() async throws {
    let fake = FakeLLMClient(responses: ["один", "два"])
    let translator = Translator(client: fake)
    let outcome = try await translator.proofread(
        text: twoParagraphs, level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.chunks.count == 2)
    #expect(fake.receivedMessages.count == outcome.chunks.count)
    #expect(outcome.documentGlossary.isEmpty)
    #expect(outcome.checks.isEmpty)
    #expect(outcome.documentGlossaryAttempted == false)
    #expect(outcome.documentGlossaryFailure == nil)
}

@Test func proofreadAssemblesByteForByteAndTheStreamReconstructsFinal() async throws {
    let fake = FakeLLMClient(responses: ["один", "два"])
    let translator = Translator(client: fake)
    let collector = StreamCollector()
    let outcome = try await translator.proofread(
        text: twoParagraphs, level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onToken: { collector.append($0) })
    // The one formula, not a restatement of it (docs/TESTING.md).
    let plan = Chunker.plan(twoParagraphs, maxCharacters: 200)
    #expect(outcome.final == plan.assembled(from: ["один", "два"]))
    #expect(collector.value == outcome.final)
}

@Test func proofreadDetectsTheLanguageAndAStatedSourceGovernsThePrompt() async throws {
    let fake = FakeLLMClient(responses: ["исправлено"])
    let translator = Translator(client: fake)
    let outcome = try await translator.proofread(
        text: "Превет, мир — это короткий русский текст.", level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(outcome.detectedSource == .ru)
    #expect(fake.receivedMessages[0].first!.content.contains("Russian"))

    let stated = FakeLLMClient(responses: ["corrected"])
    _ = try await Translator(client: stated).proofread(
        text: "Short text.", level: .errorsOnly, source: .de,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900)
    #expect(stated.receivedMessages[0].first!.content.contains("German"))
}

@Test func anEmptyReplyLeavesTimeToFirstTokenNil() async throws {
    let fake = FakeLLMClient(responses: ["", ""])
    let translator = Translator(client: fake)
    let outcome = try await translator.proofread(
        text: twoParagraphs, level: .errorsOnly,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200)
    #expect(outcome.timeToFirstTokenMS == nil)
}

@Test func aCancellationMidStreamSurfacesAsCancellationError() async throws {
    let fake = FakeLLMClient(responses: ["достаточно длинный ответ первой части", "вторая"],
                             delayPerToken: .milliseconds(5))
    let translator = Translator(client: fake)
    let run = Task {
        try await translator.proofread(text: twoParagraphs, level: .errorsOnly,
                                       options: ChatOptions(model: "test"),
                                       maxChunkCharacters: 200)
    }
    try await Task.sleep(for: .milliseconds(15))
    run.cancel()
    await #expect(throws: CancellationError.self) { try await run.value }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProofreaderTests`
Expected: compile failure — `proofread` not found.

- [ ] **Step 3: Implement `proofread`**

Add to `struct Translator` (below `translate`):

```swift
/// Правка: the same route as `translate` — detect → chunk → per-chunk streamed calls →
/// clean → skeleton diff → byte-for-byte assembly — with **no** glossary stages: no
/// `TermExtractor`, no term-list call, no review hook, no user glossary, no
/// `GlossaryVerifier`. The dangerous machinery is `streamChunkReply`, shared with
/// `translate`, so «`final` and the `onToken` stream agree exactly» holds here by
/// construction (spec §4.3).
///
/// Returns `TranslationOutcome` rather than a parallel type: every consumer speaks it,
/// and the glossary fields come back honest and empty. `detectedSource` is the text's
/// own language; `timeToFirstTokenMS` keeps its nil-means-empty-reply contract.
public func proofread(
    text: String, level: ProofreadingLevel, style: RewriteStyle = .original,
    source: Language? = nil,
    options: ChatOptions, maxChunkCharacters: Int,
    onToken: @escaping @Sendable (String) -> Void = { _ in },
    onProgress: @escaping @Sendable (TranslationProgress) -> Void = { _ in }
) async throws -> TranslationOutcome {
    let started = Date()
    let acc = ChunkRunAccumulators()
    let detected = source ?? LanguageDetector.detect(text)
    let plan = Chunker.plan(text, maxCharacters: maxChunkCharacters)
    let chunks = plan.chunks

    onProgress(TranslationProgress(partsDone: 0, partsTotal: chunks.count,
                                   documentTermCount: 0))

    var correctedChunks: [String] = []
    for chunk in chunks {
        // Same discipline as `translate`: checked at the top of every iteration, and
        // again after the stream returns, because `AsyncThrowingStream` finishes
        // silently on cancellation instead of throwing.
        try Task.checkCancellation()
        // The separator is the source's own bytes, restored verbatim — straight to
        // `onToken`, never through the helper's emit, so it cannot stamp the
        // first-token time (same rule and reason as `translate`).
        if !chunk.separatorBefore.isEmpty { onToken(chunk.separatorBefore) }
        let messages = PromptBuilder.proofreadMessages(text: chunk.text, language: detected,
                                                       level: level, style: style)
        let cleaned = try await streamChunkReply(messages, chunk: chunk, options: options,
                                                 into: acc, onToken: onToken)
        try Task.checkCancellation()
        correctedChunks.append(cleaned)
        onProgress(TranslationProgress(partsDone: correctedChunks.count,
                                       partsTotal: chunks.count, documentTermCount: 0))
    }

    let final = plan.assembled(from: correctedChunks)
    if !chunks.isEmpty, !plan.trailingSeparator.isEmpty { onToken(plan.trailingSeparator) }

    return TranslationOutcome(
        final: final,
        chunks: chunks,
        translatedChunks: correctedChunks,
        documentGlossary: [],
        detectedSource: detected,
        checks: [],
        markupDiffs: MarkupSkeleton.diff(source: text, translation: final),
        stats: acc.stats,
        timeToFirstTokenMS: acc.firstTokenAt.map { $0.timeIntervalSince(started) * 1000 },
        totalMS: Date().timeIntervalSince(started) * 1000,
        documentGlossaryFailure: nil,
        documentGlossaryAttempted: false)
}
```

Also add one line to the doc comments of `TranslationOutcome.documentGlossary`, `.checks` and `.documentGlossaryAttempted`: «Empty/false for a правка run — правка builds no glossary (spec §4.3).»

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProofreaderTests` — 5 PASS.
Run: `swift test --filter TranslatorTests` — the translate route untouched, all PASS.

- [ ] **Step 5: Zero warnings, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
git add Sources/TranslationCore/Translator.swift Tests/TranslationCoreTests/ProofreaderTests.swift
git commit -m "feat(core): Translator.proofread — the glossary-free route through the shared pipeline"
```

---

### Task 5: `TextOperation` and the Russian copy

**Files:**
- Create: `Sources/TranslatorApp/TextOperation.swift`
- Modify: `Sources/TranslatorApp/RussianCopy.swift`
- Test: `Tests/TranslatorAppTests/RussianCopyTests.swift` (append)

**Interfaces:**
- Consumes: `ProofreadingLevel`, `RewriteStyle` (Task 1).
- Produces: `enum TextOperation: String, CaseIterable, Identifiable { case translate, proofread }` with `var label: String`; `ProofreadingLevel.russianName`, `RewriteStyle.russianName`, `RewriteStyle.russianDescription: String?`, `RussianCopy.proofreadHeader(language: Language?) -> String`. Tasks 7–11 rely on all of these.

- [ ] **Step 1: Write the failing tests** (append to `RussianCopyTests.swift`)

```swift
@Test func proofreadingLevelsAndStylesHaveRussianNames() {
    #expect(ProofreadingLevel.errorsOnly.russianName == "только ошибки")
    #expect(ProofreadingLevel.errorsAndStyle.russianName == "ошибки и стиль")
    #expect(RewriteStyle.original.russianName == "как в оригинале")
    #expect(RewriteStyle.friendly.russianName == "дружеский")
    #expect(RewriteStyle.business.russianName == "деловой")
    #expect(RewriteStyle.professional.russianName == "профессиональный")
    #expect(RewriteStyle.plain.russianName == "простой и ясный")
}

@Test func everyRewriteStyleExceptOriginalCarriesADescription() {
    // «Деловой» and «профессиональный» read as synonyms without them (spec §3).
    #expect(RewriteStyle.original.russianDescription == nil)
    for style in RewriteStyle.allCases where style != .original {
        #expect(style.russianDescription?.isEmpty == false)
    }
}

@Test func theProofreadHeaderNamesTheLanguageOnlyWhenKnown() {
    #expect(RussianCopy.proofreadHeader(language: .ru) == "правка · русский")
    #expect(RussianCopy.proofreadHeader(language: nil) == "правка")
}

@Test func textOperationLabelsAreTheVocabularyWords() {
    #expect(TextOperation.translate.label == "Перевод")
    #expect(TextOperation.proofread.label == "Правка")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RussianCopyTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
// Sources/TranslatorApp/TextOperation.swift
import Foundation

/// Which of the app's two operations a surface is performing. App-layer, not
/// TranslationCore: the engine has two entry points and no need for a switch between
/// them; the switch is a UI concept (spec §5).
enum TextOperation: String, CaseIterable, Identifiable {
    case translate, proofread
    var id: String { rawValue }

    /// The vocabulary words from the spec's §1, used by the window's and the panel's
    /// segmented switches alike.
    var label: String {
        switch self {
        case .translate: "Перевод"
        case .proofread: "Правка"
        }
    }
}
```

In `RussianCopy.swift`, beside the `Tone` extension (same reasoning comment applies — exhaustive, no `default:`):

```swift
extension ProofreadingLevel {
    var russianName: String {
        switch self {
        case .errorsOnly: "только ошибки"
        case .errorsAndStyle: "ошибки и стиль"
        }
    }
}

extension RewriteStyle {
    var russianName: String {
        switch self {
        case .original: "как в оригинале"
        case .friendly: "дружеский"
        case .business: "деловой"
        case .professional: "профессиональный"
        case .plain: "простой и ясный"
        }
    }

    /// «Деловой» and «профессиональный» in one list read as synonyms — at DeepL they
    /// live on different axes. The descriptions are what tells them apart, rendered as
    /// `.help` in the toolbar and as a caption in settings (spec §3).
    var russianDescription: String? {
        switch self {
        case .original: nil
        case .friendly: "Тёплый, неформальный тон — как коллеге, которого хорошо знаешь."
        case .business: "Письма, заявления, официальная переписка."
        case .professional: "Документация, отчёты, рабочий тон без канцелярита."
        case .plain: "Короткие предложения, простые слова — максимальная читабельность."
        }
    }
}
```

In `enum RussianCopy`:

```swift
/// The panel's and the window's header line for правка: there is no direction to
/// draw, so the line names the operation and the language it worked in. The language
/// is omitted rather than replaced by «язык не определён» — правка ran fine without
/// it, unlike translation, where the detector picked the target (spec §5).
static func proofreadHeader(language: Language?) -> String {
    language.map { "правка · \($0.russianName)" } ?? "правка"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RussianCopyTests` — all PASS.

- [ ] **Step 5: Zero warnings, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
git add Sources/TranslatorApp/TextOperation.swift Sources/TranslatorApp/RussianCopy.swift Tests/TranslatorAppTests/RussianCopyTests.swift
git commit -m "feat(app): TextOperation and the Russian copy for правка"
```

---

### Task 6: The two settings defaults

**Files:**
- Modify: `Sources/TranslatorApp/AppSettings.swift`
- Test: `Tests/TranslatorAppTests/AppSettingsTests.swift` (append)

**Interfaces:**
- Consumes: `ProofreadingLevel`, `RewriteStyle`.
- Produces: `AppSettings.defaultProofreadingLevel: ProofreadingLevel` (key `"proofreadingLevel"`, default `.errorsOnly`) and `AppSettings.defaultRewriteStyle: RewriteStyle` (key `"rewriteStyle"`, default `.original`). Task 7 resolves overrides against them.

- [ ] **Step 1: Write the failing tests** (append to `AppSettingsTests.swift`)

```swift
@Test func proofreadingDefaultsAreTheSafeOnes() {
    let settings = AppSettings(defaults: InMemoryDefaults())
    // «Только ошибки» and «как в оригинале»: the tool touches someone's finished
    // text, and no surveyed product defaults to a tone (spec §3, §7).
    #expect(settings.defaultProofreadingLevel == .errorsOnly)
    #expect(settings.defaultRewriteStyle == .original)
}

@Test func proofreadingSettingsRoundTripAndSurviveGarbage() {
    let defaults = InMemoryDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.defaultProofreadingLevel = .errorsAndStyle
    settings.defaultRewriteStyle = .business
    #expect(settings.defaultProofreadingLevel == .errorsAndStyle)
    #expect(settings.defaultRewriteStyle == .business)
    // A plist is user-writable; an unreadable value falls back to the default
    // rather than to a crash or an absent control.
    defaults.set("nonsense", forKey: "proofreadingLevel")
    defaults.set("nonsense", forKey: "rewriteStyle")
    #expect(settings.defaultProofreadingLevel == .errorsOnly)
    #expect(settings.defaultRewriteStyle == .original)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppSettingsTests`
Expected: compile failure.

- [ ] **Step 3: Implement** — in `AppSettings`, beside `defaultTone`, following the file's hand-written `access`/`withMutation` shape exactly:

```swift
var defaultProofreadingLevel: ProofreadingLevel {
    get {
        access(keyPath: \.defaultProofreadingLevel)
        return ProofreadingLevel(rawValue: string("proofreadingLevel", "errorsOnly")) ?? .errorsOnly
    }
    set {
        withMutation(keyPath: \.defaultProofreadingLevel) {
            defaults.set(newValue.rawValue, forKey: "proofreadingLevel")
        }
    }
}
var defaultRewriteStyle: RewriteStyle {
    get {
        access(keyPath: \.defaultRewriteStyle)
        return RewriteStyle(rawValue: string("rewriteStyle", "original")) ?? .original
    }
    set {
        withMutation(keyPath: \.defaultRewriteStyle) {
            defaults.set(newValue.rawValue, forKey: "rewriteStyle")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppSettingsTests` — all PASS.

- [ ] **Step 5: Zero warnings, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
git add Sources/TranslatorApp/AppSettings.swift Tests/TranslatorAppTests/AppSettingsTests.swift
git commit -m "feat(app): default степень and стиль правки in AppSettings"
```

---

### Task 7: `TranslationViewModel` — `run()`, the proofread branch, resolved values

**Files:**
- Modify: `Sources/TranslatorApp/TranslationViewModel.swift`
- Test: `Tests/TranslatorAppTests/TranslationViewModelTests.swift` (append; reuse that file's existing model-construction helper for `translator`/`settings`/`glossary` — it already builds a model over `FakeLLMClient` and `InMemoryDefaults`)

**Interfaces:**
- Consumes: `Translator.proofread` (Task 4), `TextOperation` (Task 5), settings defaults (Task 6).
- Produces, relied on by Tasks 8–11:
  - `var operation: TextOperation` (default `.translate`)
  - `var proofreadingLevelOverride: ProofreadingLevel?`, `var rewriteStyleOverride: RewriteStyle?`
  - `private(set) var resolvedOperation: TextOperation?`, `private(set) var resolvedProofreadingLevel: ProofreadingLevel?`
  - `func run() async` — dispatches on `operation`
  - `var offersAnotherVariant: Bool` — `state == .finished && resolvedProofreadingLevel == .errorsAndStyle`
  - `var rewriteStyleSelectable: Bool` — `(proofreadingLevelOverride ?? settings.defaultProofreadingLevel).allowsRewriteStyle`

- [ ] **Step 1: Write the failing tests** (append)

```swift
@Test func runUnderProofreadSendsTheCopyEditorPromptAndSetsResolvedValues() async {
    // Build with the file's helper; the fake must queue one reply: "Исправлено."
    let (model, fake) = makeModel(responses: ["Исправлено."])
    model.sourceText = "Превет, мир."
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsAndStyle
    model.rewriteStyleOverride = .friendly
    await model.run()
    #expect(model.state == .finished)
    #expect(model.translatedText == "Исправлено.")
    let system = fake.receivedMessages[0].first!.content
    #expect(system.contains("copy editor"))
    #expect(system.contains(RewriteStyle.friendly.instruction!))
    #expect(model.resolvedOperation == .proofread)
    #expect(model.resolvedProofreadingLevel == .errorsAndStyle)
    #expect(model.resolvedTarget == nil)
}

@Test func runUnderTranslateStillTranslatesAndRecordsTheOperation() async {
    let (model, fake) = makeModel(responses: ["Hello, world."])
    model.sourceText = "Привет, мир."
    await model.run()
    #expect(model.state == .finished)
    #expect(fake.receivedMessages[0].first!.content.contains("translator"))
    #expect(model.resolvedOperation == .translate)
    #expect(model.resolvedProofreadingLevel == nil)
}

@Test func anotherVariantIsOfferedOnlyForAFinishedErrorsAndStyleRun() async {
    let (model, _) = makeModel(responses: ["Исправлено.", "Исправлено."])
    model.sourceText = "Превет."
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsOnly
    await model.run()
    // «Ещё вариант» of a deterministic minimal diff is a contradiction (spec §2).
    #expect(!model.offersAnotherVariant)
    model.proofreadingLevelOverride = .errorsAndStyle
    await model.run()
    #expect(model.offersAnotherVariant)
}

@Test func adoptMovesTheResolvedOperationWithTheRun() async {
    let (panel, _) = makeModel(responses: ["Исправлено."])
    panel.sourceText = "Превет."
    panel.operation = .proofread
    panel.proofreadingLevelOverride = .errorsAndStyle
    await panel.run()
    let (window, _) = makeModel(responses: [])
    #expect(window.adopt(from: panel))
    #expect(window.resolvedOperation == .proofread)
    #expect(window.resolvedProofreadingLevel == .errorsAndStyle)
    #expect(window.offersAnotherVariant)
}

@Test func aProofreadRunIgnoresTheSourceOverrideLeftFromTranslateMode() async {
    // «Из: немецкий» set while translating must not tell правка the text is German:
    // the control is hidden in правка mode, so an invisible leftover would govern
    // the prompt with nothing on screen saying so.
    let (model, fake) = makeModel(responses: ["Исправлено."])
    model.sourceText = "Превет, мир — это русский текст."
    model.sourceOverride = .de
    model.operation = .proofread
    await model.run()
    #expect(!fake.receivedMessages[0].first!.content.contains("German"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranslationViewModelTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

3a. New stored/computed state on `TranslationViewModel`:

```swift
var operation: TextOperation = .translate
var proofreadingLevelOverride: ProofreadingLevel?
var rewriteStyleOverride: RewriteStyle?
/// Which operation and — for правка — which степень produced `outcome`. Assigned and
/// cleared with `outcome`/`resolvedTarget` (the pairing rule those two already obey):
/// a header or an «Ещё вариант» must never describe another operation's result.
private(set) var resolvedOperation: TextOperation?
private(set) var resolvedProofreadingLevel: ProofreadingLevel?

/// «Ещё вариант» is offered only where variance is the point: a finished run whose
/// степень allowed wording to move. Under «только ошибки» the promise is a
/// deterministic minimal diff — another variant of that promise is a contradiction
/// (spec §2, product review 2026-08-10).
var offersAnotherVariant: Bool {
    state == .finished && resolvedProofreadingLevel == .errorsAndStyle
}

/// The availability rule for the style controls, resolved the way the next run would
/// resolve the level. Both the toolbar and the settings pane read the rule from
/// `ProofreadingLevel.allowsRewriteStyle` rather than restating the comparison.
var rewriteStyleSelectable: Bool {
    (proofreadingLevelOverride ?? settings.defaultProofreadingLevel).allowsRewriteStyle
}

func run() async {
    switch operation {
    case .translate: await translate()
    case .proofread: await proofread()
    }
}
```

3b. Extract the shared run machinery. Everything in `translate()` from `clearedPrevious = false` down through the `do`/`catch` moves into one private method; `translate()` keeps its config (detect/target/tone/options, gate, review hook) and passes two closures:

```swift
/// The shared half of every run: the ordered token stream, the spec-8 clear-on-first-
/// content rule, the `await consumer.value` barrier, the empty-reply guard, and the
/// three endings. `translate()` and `proofread()` differ only in the config they
/// compute, the engine call inside `start`, and the resolved values `finish` assigns
/// — everything here is the code `translate()` always ran, moved without change.
private func execute(
    start: (@escaping @Sendable (String) -> Void) -> Task<TranslationOutcome, Error>,
    finish: (TranslationOutcome) -> Void
) async {
    clearedPrevious = false
    let (pieces, continuation) = AsyncStream<String>.makeStream()
    let consumer = Task { @MainActor [weak self] in
        // ... the existing consumer body, moved verbatim (pending buffer, spec-8
        // clear, outcome dropped with the text) ...
    }
    let run = start({ continuation.yield($0) })
    task = run
    do {
        let result = try await run.value
        continuation.finish()
        await consumer.value
        guard result.timeToFirstTokenMS != nil else {
            state = .failed("Модель вернула пустой ответ. Попробуйте ещё раз.")
            return
        }
        finish(result)
        translatedText = result.final
        state = .finished
    } catch is CancellationError {
        continuation.finish()
        await consumer.value
        state = .interrupted
    } catch {
        continuation.finish()
        await consumer.value
        // Ask the task, not the error — the existing comment moves with this code.
        state = run.isCancelled ? .interrupted : .failed(Self.message(for: error))
    }
}
```

`translate()` becomes its existing config section (guards, `detected`/`target`/`tone`/`options`, `state = .running`, the two resets, `gateRequested`, the `review` closure) followed by:

```swift
await execute(start: { onToken in
    Task { [translator, glossary, settings] in
        try await translator.translate(
            text: text, target: target, tone: tone,
            userGlossary: glossary.glossary,
            source: detected,
            options: options,
            maxChunkCharacters: settings.chunkSize,
            ignoredTerms: glossary.mutedSet,
            onToken: onToken,
            reviewDocumentTerms: review)
    }
}, finish: { result in
    documentTermsUnavailable = gateRequested
        && result.documentGlossaryAttempted && !raisedTermsSheet
    resolvedTarget = target
    resolvedOperation = .translate
    resolvedProofreadingLevel = nil
    outcome = result
    if let failure = result.documentGlossaryFailure {
        Log.engine.error("""
            document glossary abandoned; this run translated \
            \(result.chunks.count, privacy: .public) chunks without the terminology \
            pass: \(failure, privacy: .public)
            """)
    }
})
```

3c. The new branch:

```swift
private func proofread() async {
    guard state != .running else { return }
    let text = sourceText
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    // Detected fresh, deliberately ignoring `sourceOverride`: that picker is hidden in
    // правка mode, so a value left over from translate mode would govern the prompt
    // with nothing on screen saying so.
    let detected = LanguageDetector.detect(text)
    let level = proofreadingLevelOverride ?? settings.defaultProofreadingLevel
    let style = rewriteStyleOverride ?? settings.defaultRewriteStyle
    let options = ChatOptions(model: settings.interactiveModel,
                              temperature: settings.temperature,
                              keepAlive: settings.keepAlive)
    state = .running
    // Правка never raises the terms sheet, but the notice must not outlive its run
    // either — same reset `translate()` performs.
    documentTermsUnavailable = false
    raisedTermsSheet = false
    await execute(start: { onToken in
        Task { [translator, settings] in
            try await translator.proofread(
                text: text, level: level, style: style, source: detected,
                options: options, maxChunkCharacters: settings.chunkSize,
                onToken: onToken)
        }
    }, finish: { result in
        resolvedTarget = nil
        resolvedOperation = .proofread
        resolvedProofreadingLevel = level
        outcome = result
    })
}
```

3d. Pairing maintenance:
- `adopt(from:)`: add `resolvedOperation = other.resolvedOperation` and `resolvedProofreadingLevel = other.resolvedProofreadingLevel` beside `resolvedTarget = other.resolvedTarget`.
- `swapLanguages()`: beside `resolvedTarget = nil`, add `resolvedOperation = nil; resolvedProofreadingLevel = nil`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranslationViewModelTests` — all new and existing PASS (existing tests call `translate()` directly; its behaviour is unchanged).

- [ ] **Step 5: Zero warnings, full suite, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
swift test
git add Sources/TranslatorApp/TranslationViewModel.swift Tests/TranslatorAppTests/TranslationViewModelTests.swift
git commit -m "feat(app): run() dispatches between translate and proofread in the view model"
```

---

### Task 8: `PrimaryAction` — title and dispatch by operation

**Files:**
- Modify: `Sources/TranslatorApp/MainWindowView.swift` (the `PrimaryAction` type at its top)
- Test: `Tests/TranslatorAppTests/PrimaryActionTests.swift` (create; build `FileQueueModel` the way `FileQueueModelTests.swift` does, with no-op `save`/`saveAs` closures)

**Interfaces:**
- Consumes: `TranslationViewModel.run()`, `.operation` (Task 7).
- Produces: `PrimaryAction.startTitle: String` («Перевести»/«Исправить»), `start` calling `text.run()` in `.text` mode; `canSwap == false` while the text model's operation is `.proofread`. Tasks 9's toolbar button and menu item read `startTitle`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/TranslatorAppTests/PrimaryActionTests.swift
import Testing
@testable import TranslatorApp

@MainActor
@Test func theStartTitleFollowsTheOperationInTextModeOnly() {
    let text = makeTextModel()          // the same helpers the queue/view-model tests use
    let queue = makeQueueModel()
    text.operation = .proofread
    #expect(PrimaryAction.forMode(.text, text: text, queue: queue).startTitle == "Исправить")
    text.operation = .translate
    #expect(PrimaryAction.forMode(.text, text: text, queue: queue).startTitle == "Перевести")
    // «Файлы» is translation-only whatever the text model's switch says (spec §6).
    text.operation = .proofread
    #expect(PrimaryAction.forMode(.files, text: text, queue: queue).startTitle == "Перевести")
}

@MainActor
@Test func swapIsUnavailableUnderProofread() {
    let text = makeTextModel()
    let queue = makeQueueModel()
    text.sourceOverride = .en
    text.targetOverride = .ru
    text.operation = .proofread
    #expect(!PrimaryAction.forMode(.text, text: text, queue: queue).canSwap)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PrimaryActionTests`
Expected: compile failure — `startTitle` not found.

- [ ] **Step 3: Implement** — in `PrimaryAction`:

```swift
/// «Перевести» or «Исправить» — read by the toolbar button and the «Перевод» menu
/// item both, so the two cannot disagree (spec §6).
let startTitle: String
```

In `forMode`, `.text` case: `startTitle: text.operation == .proofread ? "Исправить" : "Перевести"`, `start: { await text.run() }`, and `canSwap: text.operation == .translate && text.canSwapLanguages` (there are no languages to exchange in правка). `.files` case: `startTitle: "Перевести"` (unchanged behaviour otherwise — the queue never proofs).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PrimaryActionTests` — PASS.

- [ ] **Step 5: Zero warnings, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
git add Sources/TranslatorApp/MainWindowView.swift Tests/TranslatorAppTests/PrimaryActionTests.swift
git commit -m "feat(app): PrimaryAction carries startTitle and dispatches run() by operation"
```

---

### Task 9: The window — toolbar switch, степень/стиль menus, pane title, «Ещё вариант», menu item

**Files:**
- Modify: `Sources/TranslatorApp/MainWindowView.swift` (toolbar, `TranslationPane` call)
- Modify: `Sources/TranslatorApp/TranslationPane.swift` (optional «Ещё вариант» slot)
- Modify: `Sources/TranslatorApp/TranslatorApp.swift` (menu item title)

**Interfaces:**
- Consumes: `TextOperation`, `russianName`/`russianDescription` (Task 5), `PrimaryAction.startTitle` (Task 8), `model.rewriteStyleSelectable`/`offersAnotherVariant`/`run()` (Task 7).
- Produces: UI only; no new API. Verified by build + the full suite (the logic it renders is pinned in Tasks 7–8).

- [ ] **Step 1: `TranslationPane` gains an optional second header action**

```swift
// New property after `onCopy`:
/// «Ещё вариант» — present only when the window offers it (a finished правка whose
/// степень was «ошибки и стиль», spec §6). Nil hides the button entirely, so the
/// queue's use of this pane never shows it.
var onAnotherVariant: (() -> Void)? = nil
```

In `PaneHeader`'s content, before «Скопировать»:

```swift
if let onAnotherVariant {
    Button("Ещё вариант", action: onAnotherVariant)
        .buttonStyle(.link)
}
```

- [ ] **Step 2: The toolbar in `MainWindowView`**

At the top of the `toolbar` builder, insert the operation switch as the first `.navigation` item; wrap the four translation controls («Из», ⇄, «В», «Тон») so they render only when translating; and add the two правка menus. `@ToolbarContentBuilder` accepts `if` directly:

```swift
ToolbarItem(placement: .navigation) {
    if mode == .text {
        Picker("", selection: $model.operation) {
            ForEach(TextOperation.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Что сделать с текстом: перевести или исправить на его же языке")
        .disabled(action.isRunning)
    }
}
```

Each of the four existing translation `ToolbarItem`s wraps its control in `if mode == .files || model.operation == .translate { ... }` — hidden, not disabled, because they answer questions правка does not ask (spec §6); «Файлы» keeps them always, being translation-only. Then two new items, rendered only under `mode == .text && model.operation == .proofread`:

```swift
ToolbarItem(placement: .navigation) {
    if mode == .text, model.operation == .proofread {
        directionMenu(label: "Степень",
                      value: model.proofreadingLevelOverride?.russianName ?? Self.toneDefault,
                      help: "Насколько свободно менять формулировки") {
            Picker("Степень", selection: $model.proofreadingLevelOverride) {
                Text(Self.toneDefault).tag(ProofreadingLevel?.none)
                ForEach(ProofreadingLevel.allCases, id: \.self) {
                    Text($0.russianName).tag(ProofreadingLevel?.some($0))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
ToolbarItem(placement: .navigation) {
    if mode == .text, model.operation == .proofread {
        directionMenu(label: "Стиль",
                      value: model.rewriteStyleOverride?.russianName ?? Self.toneDefault,
                      help: "В какой стиль переписать; доступно при «ошибки и стиль»") {
            Picker("Стиль", selection: $model.rewriteStyleOverride) {
                Text(Self.toneDefault).tag(RewriteStyle?.none)
                ForEach(RewriteStyle.allCases, id: \.self) { style in
                    Text(style.russianName).tag(RewriteStyle?.some(style))
                        .help(style.russianDescription ?? "")
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        // Disabled, not hidden: the DeepL/Apple rule — an inapplicable control says
        // so instead of silently ignoring input (spec §3, §6).
        .disabled(!model.rewriteStyleSelectable)
    }
}
```

The primary-action item's button label becomes `PrimaryButtonColour.label(action.startTitle)`.

- [ ] **Step 3: Pane title and «Ещё вариант» wiring** — the `TranslationPane` call becomes:

```swift
TranslationPane(title: mode == .text
                    ? (model.operation == .proofread ? "Правка" : "Перевод")
                    : queue.selectedTitle,
                text: mode == .text ? model.translatedText : queue.selectedText,
                isRunning: mode == .text ? action.isRunning : queue.selectedIsRunning,
                onCopy: { Task { await action.copy() } },
                onAnotherVariant: mode == .text && model.offersAnotherVariant
                    ? { Task { await model.run() } } : nil)
```

- [ ] **Step 4: The «Перевод» menu item title** — in `TranslatorApp.swift`'s `.commands`, the start item becomes:

```swift
Button(action.startTitle) { Task { await action.start() } }
```

(`action` is already computed there from `mode`, `translation`, `queue`; `startTitle` reads `translation.operation`, which the app owns, so the menu re-renders on the switch.)

- [ ] **Step 5: Build, full suite, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
swift test
git add Sources/TranslatorApp/MainWindowView.swift Sources/TranslatorApp/TranslationPane.swift Sources/TranslatorApp/TranslatorApp.swift
git commit -m "feat(app): the window's Правка mode — switch, степень/стиль, Ещё вариант"
```

---

### Task 10: The panel and `HotkeyCoordinator`

**Files:**
- Modify: `Sources/TranslatorApp/HotkeyCoordinator.swift`
- Modify: `Sources/TranslatorApp/PanelView.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift` (`PanelHost` wiring)
- Test: `Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift` (append), `Tests/TranslatorAppTests/PanelViewTests.swift` (append)

**Interfaces:**
- Consumes: `panelModel.run()`/`operation`/`offersAnotherVariant` (Task 7), `RussianCopy.proofreadHeader` (Task 5).
- Produces: `HotkeyCoordinator.switchOperation(to: TextOperation) async`, `HotkeyCoordinator.anotherVariant() async`; `PanelView.direction(outcome:target:operation:)` (the old two-parameter signature is **removed**, both call sites updated); `PanelView.status(for:awaitingTerms:operation:)` with «Исправляю…» as the правка progress message; `PanelView.announcement(for:operation:)` with «Правка готова».

- [ ] **Step 1: Write the failing coordinator tests** (append; use the file's existing fake-selection setup)

```swift
@MainActor
@Test func switchingTheOperationRerunsTheCapturedSelectionWithoutReadingANewOne() async {
    // Arrange the coordinator with a captured selection and a finished translate run,
    // following the file's existing press/selection fixtures. The fake queues one
    // translate reply and one proofread reply.
    let harness = makePressedCoordinator(responses: ["перевод", "правка"])
    await harness.coordinator.switchOperation(to: .proofread)
    #expect(harness.coordinator.panelModel.operation == .proofread)
    // The re-run went to the model with the *captured* text — the reader was not asked
    // again (same reasoning as retry(): the selection may be long gone).
    #expect(harness.selectionReads == 1)
    let system = harness.fake.receivedMessages.last!.first!.content
    #expect(system.contains("copy editor"))
}

@MainActor
@Test func aNewPressResetsTheOperationToTranslate() async {
    let harness = makePressedCoordinator(responses: ["перевод", "правка", "перевод снова"])
    await harness.coordinator.switchOperation(to: .proofread)
    await harness.press()
    // The hotkey is predictable: every press starts with перевод (spec §8).
    #expect(harness.coordinator.panelModel.operation == .translate)
}

@MainActor
@Test func switchingToTheOperationAlreadyShownDoesNothing() async {
    let harness = makePressedCoordinator(responses: ["перевод"])
    let callsBefore = harness.fake.receivedMessages.count
    await harness.coordinator.switchOperation(to: .translate)
    #expect(harness.fake.receivedMessages.count == callsBefore)
}
```

- [ ] **Step 2: Write the failing PanelView tests** (append)

```swift
@Test func theHeaderLineSaysПравкаForAProofreadOutcome() {
    // Build any finished outcome fixture the file already uses; only these three
    // parameters decide the line.
    let outcome = makeFinishedOutcome(detected: .ru)
    #expect(PanelView.direction(outcome: outcome, target: nil, operation: .proofread)
            == "правка · русский")
    #expect(PanelView.direction(outcome: outcome, target: .en, operation: .translate)
            == RussianCopy.direction(from: outcome.detectedSource, to: .en))
}

@Test func theProgressRowAndTheAnnouncementSpeakTheOperationsLanguage() {
    #expect(PanelView.status(for: .running, operation: .proofread)?.message == "Исправляю…")
    #expect(PanelView.status(for: .running, operation: .translate)?.message == "Перевожу…")
    #expect(PanelView.announcement(for: .finished, operation: .proofread) == "Правка готова")
    #expect(PanelView.announcement(for: .finished, operation: .translate) == "Перевод готов")
}
```

- [ ] **Step 3: Run both filters, verify compile failures**

Run: `swift test --filter HotkeyCoordinatorTests` and `swift test --filter PanelViewTests`
Expected: compile failures on the new names.

- [ ] **Step 4: Implement the coordinator**

```swift
/// The panel's «Перевод | Правка» switch. Re-runs the **already captured** selection
/// under the other operation — it never reads a new one: the user's selection may be
/// long gone, and silently operating on something else would be worse than a control
/// that does nothing (retry()'s reasoning, verbatim; spec §8).
func switchOperation(to operation: TextOperation) async {
    guard case .text = selection, panelModel.state != .running,
          panelModel.operation != operation else { return }
    panelModel.operation = operation
    await runTranslation()
}

/// «Ещё вариант» — the same re-run under the same operation; temperature is what
/// varies the rendering. Offered by the view only for a finished «ошибки и стиль»
/// правка (`offersAnotherVariant`).
func anotherVariant() async {
    guard case .text = selection, panelModel.state != .running else { return }
    await runTranslation()
}
```

In `handlePress`, immediately before `panelModel.sourceText = text`:

```swift
// Every press starts with перевод, whatever the previous presentation's switch
// said: the hotkey is predictable, the switch is per-presentation (spec §8).
panelModel.operation = .translate
```

In `runTranslation()`, `await panelModel.translate()` becomes `await panelModel.run()`.

- [ ] **Step 5: Implement the panel view**

- `direction` gains the operation:

```swift
nonisolated static func direction(outcome: TranslationOutcome?, target: Language?,
                                  operation: TextOperation?) -> String? {
    guard let outcome else { return nil }
    if operation == .proofread {
        return RussianCopy.proofreadHeader(language: outcome.detectedSource)
    }
    guard let target else { return nil }
    return RussianCopy.direction(from: outcome.detectedSource, to: target)
}
```

Call site in `header`: `Self.direction(outcome: model.outcome, target: model.resolvedTarget, operation: model.resolvedOperation)`.

- `status(for:awaitingTerms:)` gains `operation: TextOperation = .translate`; only the progress message changes: `operation == .proofread ? "Исправляю…" : "Перевожу…"`. The `status` computed property passes `model.operation` (the presentation's operation — what is running now).
- `announcement(for:)` gains `operation: TextOperation = .translate`; `.finished` returns `operation == .proofread ? "Правка готова" : "Перевод готов"`. Update the call in `TranslatorApp.configurePanel` to pass `coordinator.panelModel.resolvedOperation ?? .translate`.
- The switch, in `header` between the direction text and the `Spacer`:

```swift
Picker("", selection: Binding(get: { model.operation },
                              set: { onSwitchOperation($0) })) {
    ForEach(TextOperation.allCases) { Text($0.label).tag($0) }
}
.pickerStyle(.segmented)
.controlSize(.mini)
.labelsHidden()
.fixedSize()
.disabled(model.state == .running || awaitingRun)
.accessibilityLabel("Операция: перевод или правка")
```

with the new callbacks (defaulted, like every other on this view):

```swift
var onSwitchOperation: (TextOperation) -> Void = { _ in }
var onAnotherVariant: () -> Void = {}
```

- «Ещё вариант» in the pinned button row, after «Открыть в окне»:

```swift
if model.offersAnotherVariant {
    Button("Ещё вариант", action: onAnotherVariant)
}
```

- In `TranslatorApp.configurePanel`'s `PanelHost` construction, wire both:
  `onSwitchOperation: { op in Task { await coordinator.switchOperation(to: op) } }` and
  `onAnotherVariant: { Task { await coordinator.anotherVariant() } }` (threaded through `PanelHost`'s properties to `PanelView`, same shape as `onRetry`).

- [ ] **Step 6: Run the filters, then the whole suite**

Run: `swift test --filter HotkeyCoordinatorTests`, `swift test --filter PanelViewTests`, then `swift test`
Expected: all PASS (including `TranslationPanelTests`, which lay out the real panel with the new chrome).

- [ ] **Step 7: Zero warnings, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
git add Sources/TranslatorApp/HotkeyCoordinator.swift Sources/TranslatorApp/PanelView.swift Sources/TranslatorApp/TranslatorApp.swift Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift Tests/TranslatorAppTests/PanelViewTests.swift
git commit -m "feat(app): the panel's Правка switch and Ещё вариант through the coordinator"
```

---

### Task 11: The settings pane

**Files:**
- Modify: `Sources/TranslatorApp/SettingsGeneralView.swift`

**Interfaces:**
- Consumes: `defaultProofreadingLevel`/`defaultRewriteStyle` (Task 6), `russianName`/`russianDescription` (Task 5), `ProofreadingLevel.allowsRewriteStyle` (Task 1).
- Produces: UI only. The availability rule itself is already pinned by Task 1's test.

- [ ] **Step 1: Add the section** — in `SettingsGeneralView`, after `Section("Перевод")`:

```swift
Section("Правка") {
    Picker("Степень по умолчанию", selection: $settings.defaultProofreadingLevel) {
        ForEach(ProofreadingLevel.allCases, id: \.self) { Text($0.russianName).tag($0) }
    }
    Text("«Только ошибки» — орфография, пунктуация и грамматика, формулировки не "
         + "трогаются. «Ошибки и стиль» — плюс канцелярит, повторы и неуклюжие обороты.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    Picker("Стиль по умолчанию", selection: $settings.defaultRewriteStyle) {
        ForEach(RewriteStyle.allCases, id: \.self) { Text($0.russianName).tag($0) }
    }
    // Disabled, not hidden — the same constructive rule as the toolbar (spec §7),
    // read from the one property both surfaces share.
    .disabled(!settings.defaultProofreadingLevel.allowsRewriteStyle)
    if let description = settings.defaultRewriteStyle.russianDescription {
        Text(description)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    Text("Панель по сочетанию клавиш использует эти значения; в окне их можно "
         + "переопределить на месте.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
```

- [ ] **Step 2: Verify the pane still fits its fixed frame**

The four tabs share one 560 × 480 frame from `settingsPane()`, and `.formStyle(.grouped)` installs its own `NSScrollView` at any content size (measured — CLAUDE.md), so a taller form scrolls rather than clips. Nothing to change; this step is the check that you did **not** «fix» the fixed frame.

- [ ] **Step 3: Build, full suite, commit**

```bash
swift build --build-tests 2>&1 | grep -i warning
swift test
git add Sources/TranslatorApp/SettingsGeneralView.swift
git commit -m "feat(app): степень and стиль правки defaults in Основные"
```

---

### Task 12: Documentation, the app bundle, and the manual quality gate

**Files:**
- Modify: `CLAUDE.md`, `CONTEXT.md`, `docs/OPEN-ITEMS.md`
- Create: `docs/proofreading-gate/` (ten corpus files)

**Interfaces:**
- Consumes: everything above, finished and green.
- Produces: the documentation the spec's §12 promises, and the corpus the spec's §11.1 gate runs on. **The gate itself needs a live Ollama and a human eyeball — it is executed by the user, not by this plan.**

- [ ] **Step 1: CLAUDE.md** — in «The translation pipeline», after the pipeline description paragraph, add:

```markdown
- **Правка is a second route through the same pipeline, not a second pipeline.**
  `Translator.proofread` shares the chunking, the per-chunk streaming
  (`streamChunkReply`), the cancellation discipline and `ChunkPlan.assembled(from:)`
  with `translate`, and runs **no** glossary stage: no term-list call, no review hook,
  no `GlossaryVerifier`. It returns `TranslationOutcome` with honestly empty glossary
  fields (`documentGlossaryAttempted == false` is the marker). The style instruction
  reaches the prompt only under `.errorsAndStyle` — `PromptBuilder` enforces it and the
  UI disables the control. See `docs/design/specs/2026-08-10-proofreading-design.md`.
```

- [ ] **Step 2: CONTEXT.md** — add a «## Правка» section with the spec §1 vocabulary, in the file's own format (headword — English gloss, → types, _Avoid_ list):

```markdown
## Правка

**Правка** — *proofreading*
The app's second operation: correcting a text in its own language instead of
translating it. One switch selects between «Перевод» and «Правка».
→ `Translator.proofread`, `TextOperation`, `ProofreadingLevel`, `RewriteStyle`
_Avoid_: корректура, редактура, улучшение

**Степень** — *degree*
How freely правка may change wording: «только ошибки» / «ошибки и стиль».
→ `ProofreadingLevel`
_Avoid_: уровень, глубина

**Стиль (правки)** — *rewrite style*
The register a rewrite aims at: «как в оригинале», «дружеский», «деловой»,
«профессиональный», «простой и ясный». Meaningful only under «ошибки и стиль».
→ `RewriteStyle`
_Avoid_: тон — that word belongs to translation's `Tone`

**«Ещё вариант»** — *another variant*
Re-run the same правка for a different rendering. Offered only for a finished
«ошибки и стиль» run — «ещё вариант» of a deterministic minimal diff is a
contradiction.
_Avoid_: «Повторить» — that is the failure retry
```

- [ ] **Step 3: The gate corpus** — create `docs/proofreading-gate/` with ten short files, each named for what it seeds (`ru-spelling.txt`, `ru-punctuation.txt`, `ru-grammar.txt`, `ru-inline-code.txt`, `ru-fenced-block.txt`, `en-spelling.txt`, `en-grammar.txt`, `en-inline-code.txt`, `ru-mixed.txt`, `en-mixed.txt`). Each file: 3–6 sentences with deliberately seeded errors; the two code files must carry an identifier-bearing inline span and a fenced block respectively. Example shape (write all ten):

```
// docs/proofreading-gate/ru-inline-code.txt
Функцыя `parseDocument()` принемает путь к файлу и возвращает разобраный документ.
Если файл не найден, она бросает ошибку — но толко после троекратной попытки.
Имя функции `parseDocument()` менять нельзя ни в коем случае.
```

- [ ] **Step 4: OPEN-ITEMS.md** — add to §1 (manual checks owed to a human):

```markdown
- **The правка quality gate (spec §11.1) has not been run.** Before the feature
  merges: paste each file from `docs/proofreading-gate/` into the window's «Правка»
  mode against the live default model. Per text: the output language equals the
  input language; every seeded error fixed or at least not worsened; code, URLs and
  identifiers byte-identical; under «только ошибки» the wording outside the seeded
  errors unchanged (eyeball diff). Run each of the four rewrite styles once on one
  text and check register shift without meaning drift. Record the results here. If
  the model fails, the feature waits on prompt calibration or a model decision — it
  does not ship on the offline suite alone.
```

- [ ] **Step 5: Final verification and commit**

```bash
swift build --build-tests 2>&1 | grep -i warning   # zero
swift test                                          # entire suite green
./Scripts/make-app-bundle.sh                        # bundle assembles
git add CLAUDE.md CONTEXT.md docs/OPEN-ITEMS.md docs/proofreading-gate/
git commit -m "docs: правка pipeline notes, vocabulary, and the manual quality-gate corpus"
```

- [ ] **Step 6: Tell the user what remains**

The manual gate (Step 4's checklist) is theirs to run against a live Ollama; the toolbar's правка-mode fit should also be eyeballed on the running bundle (fewer controls than translate mode, so the 700 pt minimum is expected to hold — the spec's §6 says verify, not assume).

---

## Self-review notes

- **Spec coverage:** §1→Task 12 (CONTEXT.md); §2→Tasks 7–11; §4.1→Task 1; §4.2→Task 2; §4.3→Tasks 3–4; §5→Task 7; §6→Tasks 8–9; §7→Tasks 6, 11; §8→Task 10; §9→shared machinery (Task 7) + no queue/CLI changes anywhere; §10 needs no code; §11→each task's tests; §11.1→Task 12; §12→Task 12.
- **Type consistency:** `ProofreadingLevel.allowsRewriteStyle` (Tasks 1, 2, 7, 11); `streamChunkReply(_:chunk:options:into:onToken:)` (Tasks 3, 4); `run()`/`offersAnotherVariant`/`rewriteStyleSelectable`/`resolvedOperation`/`resolvedProofreadingLevel` (Tasks 7–10); `proofreadMessages(text:language:level:style:)` (Tasks 2, 4); `startTitle` (Tasks 8, 9).
- Test helpers named in Tasks 7, 8, 10 (`makeModel`, `makeTextModel`, `makeQueueModel`, `makePressedCoordinator`, `makeFinishedOutcome`) refer to the existing fixtures in their respective test files — reuse or extend those, do not build a parallel fixture set.
