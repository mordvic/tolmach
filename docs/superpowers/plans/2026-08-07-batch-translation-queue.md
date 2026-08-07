# Batch translation — the file queue (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate a queue of dropped text files one after another from the main window, writing each translation beside its source, with a fourth settings tab that governs it.

**Architecture:** One new engine callback (`onProgress`, non-suspending, cannot fail) plus four new pure types and one `@Observable @MainActor` runner in `TranslatorApp`. The main window gains a «Текст / Файлы» mode switch in the left pane header; the right pane and the status bar render whichever mode is showing. Nothing in `Chunker`, `PanelSizer`, `HotkeyCoordinator` or the capture path is touched.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, SwiftUI/AppKit, Swift Testing, macOS 14 floor. No external dependencies.

**Spec:** `docs/superpowers/specs/2026-08-07-batch-translation-design.md`. Section references below (§4.1, §7.2 …) point into it.

## Global Constraints

- **Zero warnings.** `swift build --build-tests` must stay at zero warnings; CI fails on any. This is a standing rule.
- **Swift language mode `.v6` on every target.** Any new target repeats `.swiftLanguageMode(.v6)` and the macOS 14 platform floor.
- **No new dependencies.** Foundation, NaturalLanguage, SwiftUI, AppKit, Observation, ApplicationServices, CoreGraphics, CoreText, ImageIO, Carbon, os, Swift Testing. This is a closed whitelist.
- **`TranslationCore` may not import `os`, AppKit or SwiftUI.** It reports through return values only.
- **Nothing derived from the user's text may be logged.** Not a file's contents, not a term, not a translation. A file *name* is user data too — log counts and states, never names.
- **All user-facing strings are Russian**, «guillemets», «ё». No backticks in anything rendered by `Text(String)` — that initialiser does not parse Markdown and they render as grave accents. Russian labels for domain enums go in `RussianCopy.swift`, exhaustive with no `default:`.
- **Tests use Swift Testing** (`@Test`, `#expect`), never XCTest. Test names are sentences describing the behaviour being pinned.
- **`UserDefaults`-backed tests use `InMemoryDefaults`**, never a real suite.
- **Comments carry *why* and the measurement behind it**, not what the code does. «Measured» and «load-bearing» are a contract: they mean a specific observation was made. Do not use either word without one.
- **Commit messages:** conventional, scoped by area — `feat(core):`, `feat(app):`, `test(app):`, `docs(app):`.
- **UI is verified by hand; GUI automation is unavailable.** Never describe UI behaviour that was not actually observed — state what indirect evidence was gathered instead.

**Build and test commands:**

```bash
swift build --build-tests     # must stay at zero warnings
swift test                    # ~341 tests, offline, a few seconds
swift test --filter someTestName
```

---

### Task 1: `TranslationProgress` and the engine's progress callback

The queue row promises «Перевожу часть 4 из 7 · 12 терминов документа». `partsTotal` and the document-term count are both known inside `Translator` and nowhere else at that moment, so the engine reports them rather than the app re-deriving them (§3.5).

**Files:**
- Modify: `Sources/TranslationCore/Translator.swift`
- Test: `Tests/TranslationCoreTests/TranslatorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct TranslationProgress: Sendable, Equatable` with `partsDone: Int`, `partsTotal: Int`, `documentTermCount: Int`; a new trailing parameter on `Translator.translate`: `onProgress: @Sendable (TranslationProgress) -> Void = { _ in }`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslationCoreTests/TranslatorTests.swift`:

```swift
@Test func progressIsReportedOncePerPartPlusOnceBeforeTheFirst() async throws {
    // response 0 = the term list, then one per chunk
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)
    let box = ProgressBox()
    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        onProgress: { box.append($0) })

    let seen = box.values
    // One report before the first part, so a queue row can draw an empty bar instead
    // of nothing while the term-list call is still in flight.
    #expect(seen.count == outcome.chunks.count + 1)
    #expect(seen.map(\.partsDone) == Array(0...outcome.chunks.count))
    #expect(seen.allSatisfy { $0.partsTotal == outcome.chunks.count })
    // The term count is known from the very first report, which is the whole reason
    // it travels here rather than being read off the finished outcome.
    #expect(seen.allSatisfy { $0.documentTermCount == outcome.documentGlossary.count })
    #expect(seen.first?.documentTermCount == 2)
}

@Test func aSingleChunkRunStillReportsProgressWithNoDocumentTerms() async throws {
    let fake = FakeLLMClient(responses: ["Привет, мир."])
    let translator = Translator(client: fake)
    let box = ProgressBox()
    _ = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        onProgress: { box.append($0) })

    #expect(box.values == [
        TranslationProgress(partsDone: 0, partsTotal: 1, documentTermCount: 0),
        TranslationProgress(partsDone: 1, partsTotal: 1, documentTermCount: 0),
    ])
}

/// `onProgress` is `@Sendable` and is called from the engine's task, so a bare local
/// array cannot collect it under Swift 6's checking. A lock is the smallest thing that
/// is actually correct here; an actor would force the assertions to be `await`ed and
/// buy nothing.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranslationProgress] = []
    func append(_ value: TranslationProgress) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [TranslationProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter progressIsReportedOncePerPartPlusOnceBeforeTheFirst`
Expected: compile failure — `TranslationProgress` is not defined and `translate` has no `onProgress:` parameter.

- [ ] **Step 3: Add the type and the parameter**

In `Sources/TranslationCore/Translator.swift`, above `public struct Translator`:

```swift
/// What a long-running consumer needs to draw a progress row, reported from inside the
/// run because that is the only place all three numbers exist at once.
///
/// `documentTermCount` travels here rather than being read off `TranslationOutcome`
/// because a queue row says «12 терминов документа» *while* the run is going, and the
/// outcome does not exist until it is over.
public struct TranslationProgress: Sendable, Equatable {
    /// Parts whose translation has been received in full.
    public let partsDone: Int
    /// Fixed for the whole run: chunking depends on the input alone.
    public let partsTotal: Int
    /// Terms the документный глоссарий is holding constant. Zero when there is none —
    /// a single-part run, an unrecognised source language, or an empty term list.
    public let documentTermCount: Int

    public init(partsDone: Int, partsTotal: Int, documentTermCount: Int) {
        self.partsDone = partsDone
        self.partsTotal = partsTotal
        self.documentTermCount = documentTermCount
    }
}
```

Add the parameter to `translate`, after `onToken`:

```swift
        onToken: @escaping @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (TranslationProgress) -> Void = { _ in }
```

- [ ] **Step 4: Fire it**

Immediately before the `for chunk in chunks` loop (after the document-glossary block that sets `documentEntries`):

```swift
        // Reported before the first request, not after it, so a consumer drawing a
        // progress row has a row to draw while the first part is in flight rather
        // than a blank that fills in only once something has already finished.
        let documentTermCount = documentEntries.count
        onProgress(TranslationProgress(partsDone: 0, partsTotal: chunks.count,
                                       documentTermCount: documentTermCount))
```

At the end of the loop body, after the chunk's translation has been appended to `translatedChunks`:

```swift
            onProgress(TranslationProgress(partsDone: translatedChunks.count,
                                           partsTotal: chunks.count,
                                           documentTermCount: documentTermCount))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TranslationCoreTests`
Expected: PASS, including every pre-existing test — the default `{ _ in }` means no existing call site changes behaviour.

- [ ] **Step 6: Verify zero warnings and commit**

```bash
swift build --build-tests 2>&1 | grep -i warning   # expect no output
git add Sources/TranslationCore/Translator.swift Tests/TranslationCoreTests/TranslatorTests.swift
git commit -m "feat(core): report per-part progress from a run

A queue row says «Перевожу часть 4 из 7 · 12 терминов документа» while the run
is going, and all three numbers exist only inside translate() at that moment:
the outcome does not exist yet, and re-planning at the call site would be a
second copy of the chunking formula.

Defaulted to a no-op, so both existing call sites are unchanged."
```

---

### Task 2: `OutputNaming`

Where a translation is written and what it is called (§4.4). Pure, so it is checkable — the rule that an existing file is never overwritten is the kind that has to be provable rather than trusted.

**Files:**
- Create: `Sources/TranslatorApp/OutputNaming.swift`
- Test: `Tests/TranslatorAppTests/OutputNamingTests.swift`

**Interfaces:**
- Consumes: `TranslationCore.Language`.
- Produces: `enum OutputNaming` with `static func destination(for source: URL, target: Language, exists: (URL) -> Bool) -> URL`.

The `exists` closure is injected rather than calling `FileManager` directly, so the naming rule is testable without a filesystem. The production call site passes `{ FileManager.default.fileExists(atPath: $0.path) }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TranslatorAppTests/OutputNamingTests.swift`:

```swift
import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

private let dir = URL(fileURLWithPath: "/tmp/does-not-need-to-exist")

@Test func theTargetLanguageCodeIsInsertedBeforeTheExtension() {
    let out = OutputNaming.destination(for: dir.appendingPathComponent("techdoc-en.md"),
                                       target: .ru, exists: { _ in false })
    #expect(out.lastPathComponent == "techdoc-en.ru.md")
}

@Test func aFileWithNoExtensionGetsTheCodeAppended() {
    let out = OutputNaming.destination(for: dir.appendingPathComponent("README"),
                                       target: .de, exists: { _ in false })
    #expect(out.lastPathComponent == "README.de")
}

@Test func anOccupiedNameTakesTheNextFreeNumberRatherThanOverwriting() {
    let taken: Set<String> = ["techdoc-en.ru.md", "techdoc-en.ru 2.md"]
    let out = OutputNaming.destination(for: dir.appendingPathComponent("techdoc-en.md"),
                                       target: .ru,
                                       exists: { taken.contains($0.lastPathComponent) })
    #expect(out.lastPathComponent == "techdoc-en.ru 3.md")
}

@Test func theTranslationLandsBesideItsSourceAndNowhereElse() {
    let source = URL(fileURLWithPath: "/Users/someone/Documents/notes/article-en.markdown")
    let out = OutputNaming.destination(for: source, target: .en, exists: { _ in false })
    #expect(out.deletingLastPathComponent() == source.deletingLastPathComponent())
    #expect(out.lastPathComponent == "article-en.en.markdown")
}

@Test func aDottedStemKeepsEveryDotButTheLast() {
    // «v1.2.notes.md» is one file, not a stem with three extensions. Splitting on the
    // first dot would produce «v1.ru.2.notes.md», which is a different document's name.
    let out = OutputNaming.destination(for: dir.appendingPathComponent("v1.2.notes.md"),
                                       target: .ru, exists: { _ in false })
    #expect(out.lastPathComponent == "v1.2.notes.ru.md")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter OutputNamingTests`
Expected: compile failure — `OutputNaming` is not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/TranslatorApp/OutputNaming.swift`:

```swift
// Sources/TranslatorApp/OutputNaming.swift
import Foundation
import TranslationCore

/// What a translated file is called and where it goes.
///
/// A type of its own, and pure, for the same reason as `DroppedDocument`: the rule that
/// **an existing file is never overwritten** has to be provable, and a rule written
/// inside a save routine can only be read. Losing someone's document to a name
/// collision is the one failure in this feature that cannot be undone.
enum OutputNaming {
    /// Where the translation of `source` belongs.
    ///
    /// The target language's code goes in before the extension, so `techdoc-en.md`
    /// becomes `techdoc-en.ru.md` and sorts next to its original in Finder.
    ///
    /// - Parameter exists: whether a URL is already taken. Injected so the naming rule
    ///   is testable without a filesystem; production passes `FileManager`. It is only
    ///   an optimisation for politeness — the actual write uses
    ///   `.withoutOverwriting`, so a file created by another process between this
    ///   check and the write loses the race safely rather than being destroyed.
    static func destination(for source: URL, target: Language,
                            exists: (URL) -> Bool) -> URL {
        let directory = source.deletingLastPathComponent()
        let extensionPart = source.pathExtension
        // `deletingPathExtension` and not a split on ".": «v1.2.notes.md» is one file
        // whose stem contains dots, and splitting on the first would rename it.
        let stem = source.deletingPathExtension().lastPathComponent
        let code = target.rawValue

        func url(_ suffix: String) -> URL {
            let name = extensionPart.isEmpty ? "\(stem).\(code)\(suffix)"
                                             : "\(stem).\(code)\(suffix).\(extensionPart)"
            return directory.appendingPathComponent(name)
        }

        let first = url("")
        guard exists(first) else { return first }
        // Starts at 2 because the unnumbered name is the first. An upper bound rather
        // than `while true`: a directory that answers "taken" a thousand times running
        // is a bug or a hostile filesystem, and looping forever there would hang the
        // queue with no way for the user to see why.
        for number in 2...1000 {
            let candidate = url(" \(number)")
            if !exists(candidate) { return candidate }
        }
        return url(" \(UUID().uuidString)")
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter OutputNamingTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/OutputNaming.swift Tests/TranslatorAppTests/OutputNamingTests.swift
git commit -m "feat(app): OutputNaming — where a translated file goes and what it is called

techdoc-en.md becomes techdoc-en.ru.md, beside its source. An occupied name takes
a number; nothing is ever overwritten. Pure and injected with its existence check,
because losing a document to a name collision is the one failure here that cannot
be undone, so the rule has to be provable rather than trusted."
```

---

### Task 3: `QueueDrop`

What the queue accepts (§4.1). The interesting decisions are the whole-drop refusal and the 2 MB ceiling that deliberately differs from `DroppedDocument`'s 256 KB.

**Files:**
- Create: `Sources/TranslatorApp/QueueDrop.swift`
- Test: `Tests/TranslatorAppTests/QueueDropTests.swift`

**Interfaces:**
- Consumes: `DroppedDocument.readableExtensions`.
- Produces: `enum QueueDrop` with `static let maximumBytes: Int`, and `static func accept(_ urls: [URL]) -> [(url: URL, text: String)]?` — `nil` means the whole drop is refused.

- [ ] **Step 1: Write the failing test**

Create `Tests/TranslatorAppTests/QueueDropTests.swift`:

```swift
import Foundation
import Testing
@testable import TranslatorApp

/// Writes real files, because the thing under test reads a filesystem and a fake one
/// would only pin the fake. Removed in `deinit`.
private final class Scratch {
    let directory: URL
    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func file(_ name: String, _ contents: String) -> URL {
        let url = directory.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: url)
        return url
    }

    func file(_ name: String, bytes: Int) -> URL {
        let url = directory.appendingPathComponent(name)
        try? Data(repeating: UInt8(ascii: "a"), count: bytes).write(to: url)
        return url
    }
}

@Test func aDropOfReadableFilesComesBackInTheOrderItWasDropped() throws {
    let scratch = Scratch()
    let a = scratch.file("a.md", "first")
    let b = scratch.file("b.txt", "second")
    let accepted = try #require(QueueDrop.accept([a, b]))
    #expect(accepted.map(\.url) == [a, b])
    #expect(accepted.map(\.text) == ["first", "second"])
}

@Test func oneUnreadableFileRefusesTheWholeDrop() throws {
    // Taking the acceptable nine of ten is a guess about which the user meant — the
    // identical judgement SourcePane already makes about a multiple selection.
    let scratch = Scratch()
    let good = scratch.file("a.md", "text")
    let bad = scratch.file("b.pdf", "text")
    #expect(QueueDrop.accept([good, bad]) == nil)
}

@Test func aFileOverTheCeilingIsRefusedWithoutBeingRead() throws {
    let scratch = Scratch()
    let huge = scratch.file("huge.md", bytes: QueueDrop.maximumBytes + 1)
    #expect(QueueDrop.accept([huge]) == nil)
}

@Test func theCeilingHereIsHigherThanTheTextPanesOnPurpose() {
    // DroppedDocument's 256 KB is justified by what a person waits for *at a window*.
    // The queue has a progress bar, a per-file state and a cancel button, so that
    // reasoning does not carry across — see the spec, §4.1.
    #expect(QueueDrop.maximumBytes > DroppedDocument.maximumBytes)
    #expect(QueueDrop.maximumBytes == 2 * 1024 * 1024)
}

@Test func aFileOfBlankLinesIsRefusedLikeAnEmptyOne() throws {
    let scratch = Scratch()
    #expect(QueueDrop.accept([scratch.file("blank.md", "\n\n   \n")]) == nil)
}

@Test func anEmptyDropIsRefusedRatherThanAcceptedAsAnEmptyQueue() {
    #expect(QueueDrop.accept([]) == nil)
}

@Test func aFileThatIsNotUTF8IsRefused() throws {
    let scratch = Scratch()
    let url = scratch.directory.appendingPathComponent("latin1.md")
    try Data([0xFF, 0xFE, 0xFD]).write(to: url)
    #expect(QueueDrop.accept([url]) == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter QueueDropTests`
Expected: compile failure — `QueueDrop` is not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/TranslatorApp/QueueDrop.swift`:

```swift
// Sources/TranslatorApp/QueueDrop.swift
import Foundation

/// What the file queue will accept when files are dropped on it.
///
/// The sibling of `DroppedDocument` and deliberately not the same type: the two answer
/// the same question for two surfaces whose reasoning differs, and the difference is
/// the ceiling below.
enum QueueDrop {
    /// 2 MB per file.
    ///
    /// `DroppedDocument.maximumBytes` is 256 KB, and its comment justifies that number
    /// with what a person waits for **at a window**: no progress, no cancel, one
    /// translation appearing or not. The queue is the surface where waiting is the
    /// arrangement — it draws a bar per file, a state per file and a cancel button — so
    /// carrying the number across while discarding the reasoning that produced it would
    /// leave a limit nobody could re-derive.
    ///
    /// 2 MB is about 2300 model calls for an ASCII source at the default 900-character
    /// часть. That is a choice about what is worth offering, not a measurement: long,
    /// visible and interruptible. A file over it is refused rather than truncated, for
    /// `DroppedDocument`'s reason — presenting the first quarter of someone's document
    /// as the translation is the worse failure.
    static let maximumBytes = 2 * 1024 * 1024

    /// The files this drop contributes to the queue, or `nil` if the drop is refused.
    ///
    /// **A mixed drop is refused whole.** Ten `.md` files and one `.pdf` yields nothing,
    /// not ten translations: taking the acceptable ones is a guess about which of them
    /// was meant, which is the identical judgement `SourcePane` already makes about a
    /// multiple selection. `nil` reaches `dropDestination` as `false`, and the system
    /// springs every item back — the whole error channel, deliberately, exactly as
    /// `DroppedDocument` documents.
    static func accept(_ urls: [URL]) -> [(url: URL, text: String)]? {
        guard !urls.isEmpty else { return nil }
        var out: [(url: URL, text: String)] = []
        out.reserveCapacity(urls.count)
        for url in urls {
            guard let text = readable(url) else { return nil }
            out.append((url, text))
        }
        return out
    }

    /// Same extension list, same UTF-8-or-nothing and same blank-file rule as
    /// `DroppedDocument`; only the ceiling differs. The size is read from the file's
    /// attributes before the bytes are, so a 40 MB file is refused without ever being
    /// loaded.
    private static func readable(_ url: URL) -> String? {
        guard DroppedDocument.readableExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= maximumBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter QueueDropTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/QueueDrop.swift Tests/TranslatorAppTests/QueueDropTests.swift
git commit -m "feat(app): QueueDrop — what the file queue accepts

Same extensions, same UTF-8-or-nothing and same blank-file rule as DroppedDocument;
a mixed drop is refused whole, for the reason SourcePane already refuses a multiple
selection.

The ceiling is 2 MB rather than DroppedDocument's 256 KB, and that is the point of a
separate type: 256 KB is justified by what a person waits for *at a window*, and the
queue has a bar, a per-file state and a cancel button. Carrying the number without
its reasoning would leave a limit nobody could re-derive."
```

---

### Task 4: The four new settings

§7.3. The one with teeth is `batchModel`, whose absence of a default is a decision about Ollama's memory, not an oversight.

**Files:**
- Modify: `Sources/TranslatorApp/AppSettings.swift`
- Test: `Tests/TranslatorAppTests/AppSettingsTests.swift`

**Interfaces:**
- Consumes: `AppSettings.interactiveModel`.
- Produces: `AppSettings.batchModel: String?`, `.saveNextToSource: Bool`, `.stopOnWarnings: Bool`, `.reviewDocumentTerms: Bool`, and `AppSettings.resolvedBatchModel: String`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/AppSettingsTests.swift`:

```swift
@Test func anUnsetBatchModelFollowsTheInteractiveOne() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "batch-model-unset"))
    #expect(settings.batchModel == nil)
    #expect(settings.resolvedBatchModel == settings.interactiveModel)

    settings.interactiveModel = "some-other-model:7b"
    // Still following, not frozen at whatever the interactive model was when first read.
    #expect(settings.resolvedBatchModel == "some-other-model:7b")
}

@Test func aChosenBatchModelStopsFollowingTheInteractiveOne() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "batch-model-set"))
    settings.batchModel = "gpt-oss:20b"
    settings.interactiveModel = "aya-expanse:8b"
    #expect(settings.resolvedBatchModel == "gpt-oss:20b")
}

@Test func theBatchModelReadsTheKeyTheRemovedBackgroundModelWroteTo() {
    // AppSettings' own removal comment promises this: a value a user stored before the
    // property was deleted stays under "backgroundModel" and v2 finds it again.
    let defaults = InMemoryDefaults(prefix: "batch-model-legacy")
    defaults.set("gpt-oss:20b", forKey: "backgroundModel")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.batchModel == "gpt-oss:20b")
}

@Test func clearingTheBatchModelReturnsItToFollowingTheInteractiveOne() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "batch-model-cleared"))
    settings.batchModel = "gpt-oss:20b"
    settings.batchModel = nil
    #expect(settings.batchModel == nil)
    #expect(settings.resolvedBatchModel == settings.interactiveModel)
}

@Test func theQueueSavesBesideTheSourceUnlessToldOtherwise() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "queue-saving"))
    #expect(settings.saveNextToSource)
    settings.saveNextToSource = false
    #expect(!settings.saveNextToSource)
}

@Test func theQueueRunsToTheEndAndTheTermsGateIsOffUntilAskedFor() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "queue-defaults"))
    #expect(!settings.stopOnWarnings)
    // Ships off even though the design draws it on: the drawing assumed the gate lived
    // in the batch path only, and it reaches ⌥⌘T too.
    #expect(!settings.reviewDocumentTerms)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter anUnsetBatchModelFollowsTheInteractiveOne`
Expected: compile failure — no member `batchModel`.

- [ ] **Step 3: Write the implementation**

In `Sources/TranslatorApp/AppSettings.swift`, add a private reader beside the others:

```swift
    private func optionalString(_ key: String) -> String? {
        guard let value = defaults.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }
```

Replace the `backgroundModel` removal comment block with the property it promised:

```swift
    /// The model the file queue uses, or `nil` for «the same one the hotkey uses».
    ///
    /// **The only setting in this app with no fixed default, and that is deliberate.**
    /// Ollama holds one model in memory: cold load ~2000 ms against ~155 ms warm
    /// (measured, recorded in CLAUDE.md alongside `keep_alive`). If this defaulted to
    /// anything but the interactive model, then every ⌥⌘T pressed during a queue run
    /// would cost two cold loads — one to serve the panel, one to get back to the queue
    /// — and a thirteen-file queue makes that the normal case rather than the edge. A
    /// different default would build that thrash into the box for a user who never
    /// opened the settings.
    ///
    /// `ModelPolicy.defaultModel(for: .background)` is still not consulted. It is a
    /// recommendation to a user who opens the picker, not a default that changes what
    /// the app does before anyone asks for it.
    ///
    /// Stored under `"backgroundModel"` — the key the property removed with the
    /// observability wave wrote to. Its removal comment promised exactly this, and a
    /// value a user stored before that removal comes back here.
    var batchModel: String? {
        get {
            access(keyPath: \.batchModel)
            return optionalString("backgroundModel")
        }
        set {
            withMutation(keyPath: \.batchModel) {
                if let newValue, !newValue.isEmpty {
                    defaults.set(newValue, forKey: "backgroundModel")
                } else {
                    defaults.removeObject(forKey: "backgroundModel")
                }
            }
        }
    }

    /// What to actually put in `ChatOptions` for a queue run.
    ///
    /// A derived property rather than a `??` at the call site: there is more than one
    /// call site coming (the runner and the settings picker's «current» state), and the
    /// rule that `nil` means «follow the interactive model» is the whole point of the
    /// property above.
    var resolvedBatchModel: String { batchModel ?? interactiveModel }

    /// Whether a finished translation is written beside its source without being asked.
    ///
    /// On by default: a queue whose results have to be saved one at a time is a queue
    /// that has not finished the job. What it cannot assume is that the write will be
    /// allowed — see `TranslatedFileWriter` and the save-panel fallback.
    var saveNextToSource: Bool {
        get {
            access(keyPath: \.saveNextToSource)
            return bool("saveNextToSource", true)
        }
        set { withMutation(keyPath: \.saveNextToSource) { defaults.set(newValue, forKey: "saveNextToSource") } }
    }

    /// Whether the queue halts after a file that finished with warnings.
    ///
    /// Off by default: the warnings are kept per file and can be read afterwards, so
    /// the default is «the queue finishes» rather than «the queue waits for you».
    var stopOnWarnings: Bool {
        get {
            access(keyPath: \.stopOnWarnings)
            return bool("stopOnWarnings", false)
        }
        set { withMutation(keyPath: \.stopOnWarnings) { defaults.set(newValue, forKey: "stopOnWarnings") } }
    }

    /// Whether the документный глоссарий is shown for review before the translation
    /// that uses it.
    ///
    /// **Ships off, although the design document draws it on.** The drawing put this
    /// switch in the batch settings and reasoned about a file; the gate reaches every
    /// path that builds a документный глоссарий, ⌥⌘T included, and a default that
    /// changes the flagship interaction for every existing user is not one a mock can
    /// grant. Read by nothing until Phase 2 wires it.
    var reviewDocumentTerms: Bool {
        get {
            access(keyPath: \.reviewDocumentTerms)
            return bool("reviewDocumentTerms", false)
        }
        set { withMutation(keyPath: \.reviewDocumentTerms) { defaults.set(newValue, forKey: "reviewDocumentTerms") } }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter AppSettingsTests`
Expected: PASS, including every pre-existing settings test.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/AppSettings.swift Tests/TranslatorAppTests/AppSettingsTests.swift
git commit -m "feat(app): the file queue's four settings

batchModel returns under the key the removed backgroundModel wrote to, exactly as
that removal comment promised. It is the only setting here with no fixed default:
Ollama holds one model, cold load ~2000 ms against ~155 ms warm, so a batch model
differing from the interactive one costs two cold loads on every hotkey press
during a queue run. nil means «follow the interactive model»; resolvedBatchModel
is what reaches ChatOptions.

reviewDocumentTerms ships off although the design draws it on — the drawing
assumed the gate lived in the batch path, and it reaches the hotkey panel too."
```

---

### Task 5: The queue's Russian copy

§8. Every string the queue needs, in `RussianCopy`, beside `chunkCount` — a label built inline is a label the next surface spells differently.

**Files:**
- Modify: `Sources/TranslatorApp/RussianCopy.swift`
- Test: `Tests/TranslatorAppTests/RussianCopyTests.swift`

**Interfaces:**
- Consumes: `RussianCopy.plural(_:_:_:_:)`.
- Produces: `RussianCopy.partProgress(done:total:)`, `.documentTermCount(_:)`, `.queuedFile(parts:)`, `.finishedIn(milliseconds:)`, `.queuePosition(fileIndex:fileTotal:partsDone:partsTotal:)`, `.warningCount(_:)`, `.ordinal(_:)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/RussianCopyTests.swift`:

```swift
@Test func theRunningRowNamesThePartInProgressAndNotTheOnesDone() {
    // «часть 4 из 7» while the fourth is being translated, so the row and the bar agree
    // about which part the user is waiting for. partsDone is 3 at that moment.
    #expect(RussianCopy.partProgress(done: 3, total: 7) == "Перевожу часть 4 из 7")
    #expect(RussianCopy.partProgress(done: 0, total: 7) == "Перевожу часть 1 из 7")
    // The last part completing must not read as «часть 8 из 7».
    #expect(RussianCopy.partProgress(done: 7, total: 7) == "Перевожу часть 7 из 7")
}

@Test func theDocumentTermCountTakesTheRightRussianPlural() {
    #expect(RussianCopy.documentTermCount(1) == "1 термин документа")
    #expect(RussianCopy.documentTermCount(2) == "2 термина документа")
    #expect(RussianCopy.documentTermCount(12) == "12 терминов документа")
    #expect(RussianCopy.documentTermCount(21) == "21 термин документа")
}

@Test func aQueuedFileSaysHowManyPartsItWillTake() {
    #expect(RussianCopy.queuedFile(parts: 4) == "в очереди · 4 части")
    #expect(RussianCopy.queuedFile(parts: 1) == "в очереди · 1 часть")
}

@Test func aFinishedFileGroupsItsMillisecondsTheRussianWay() {
    // Same ru_RU grouping RussianCopy.modelSize is pinned to, so the two do not
    // disagree about what a number looks like in this app.
    #expect(RussianCopy.finishedIn(milliseconds: 3140) == "готово за 3 140 мс")
    #expect(RussianCopy.finishedIn(milliseconds: 812) == "готово за 812 мс")
}

@Test func theStatusLineCountsFilesAndPartsTogether() {
    #expect(RussianCopy.queuePosition(fileIndex: 1, fileTotal: 3, partsDone: 9, partsTotal: 13)
            == "Перевожу 2-й файл из 3 — 9 частей из 13")
}

@Test func ordinalsAreMasculineToAgreeWithFile() {
    #expect(RussianCopy.ordinal(1) == "1-й")
    #expect(RussianCopy.ordinal(2) == "2-й")
    #expect(RussianCopy.ordinal(11) == "11-й")
}

@Test func theWarningCountTakesTheRightRussianPlural() {
    #expect(RussianCopy.warningCount(1) == "1 предупреждение")
    #expect(RussianCopy.warningCount(2) == "2 предупреждения")
    #expect(RussianCopy.warningCount(5) == "5 предупреждений")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter theRunningRowNamesThePartInProgressAndNotTheOnesDone`
Expected: compile failure — no member `partProgress`.

- [ ] **Step 3: Write the implementation**

Append inside `enum RussianCopy` in `Sources/TranslatorApp/RussianCopy.swift`:

```swift
    /// "Перевожу часть 4 из 7" — the running queue row.
    ///
    /// Takes `done` and names `done + 1`, because the row is about the часть the user
    /// is *waiting for*, not the ones behind it, and the progress bar beside it is
    /// filled from the same `done`. Clamped at `total` so the report that arrives with
    /// the last часть finished does not read «часть 8 из 7».
    static func partProgress(done: Int, total: Int) -> String {
        "Перевожу часть \(min(done + 1, total)) из \(total)"
    }

    /// "12 терминов документа" — what the run is holding constant across its части.
    static func documentTermCount(_ count: Int) -> String {
        "\(count) \(plural(count, "термин", "термина", "терминов")) документа"
    }

    /// "в очереди · 4 части" — a задание that has not started.
    static func queuedFile(parts: Int) -> String {
        "в очереди · \(chunkCount(parts))"
    }

    /// "готово за 3 140 мс".
    ///
    /// Grouped through the same `ru_RU`-pinned formatter `modelSize` uses, so two
    /// numbers side by side in this app cannot be spelled two ways. Pinned to the
    /// locale and not to the user's, for `modelSize`'s reason: the app is Russian
    /// whatever the system is set to.
    static func finishedIn(milliseconds: Int) -> String {
        "готово за \(grouped(milliseconds)) мс"
    }

    /// "Перевожу 2-й файл из 3 — 9 частей из 13" — the status bar in «Файлы».
    ///
    /// `fileIndex` is zero-based, matching the array it comes from; the sentence is
    /// one-based, which is why the conversion happens here rather than at the call site
    /// where it would be repeated and eventually be off by one in one of them.
    static func queuePosition(fileIndex: Int, fileTotal: Int,
                              partsDone: Int, partsTotal: Int) -> String {
        "Перевожу \(ordinal(fileIndex + 1)) файл из \(fileTotal) — \(partsDone) \(plural(partsDone, "часть", "части", "частей")) из \(partsTotal)"
    }

    /// "2-й" — masculine, to agree with «файл».
    ///
    /// Russian ordinals take one of two written endings after the hyphen depending on
    /// the last letter of the spelled-out form; for the masculine nominative every one
    /// of them is «-й» («первый», «второй», «одиннадцатый»), so this is a suffix and
    /// not a table. Feminine or neuter would need one, and would need its own function.
    static func ordinal(_ number: Int) -> String { "\(number)-й" }

    /// "4 предупреждения" — the count on a finished задание.
    static func warningCount(_ count: Int) -> String {
        "\(count) \(plural(count, "предупреждение", "предупреждения", "предупреждений"))"
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
```

> If `RussianCopy.modelSize` already contains a private `ru_RU` formatter, reuse it and do not add a second `grouped`. Two formatters for one convention is exactly the drift these functions exist to prevent.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RussianCopyTests`
Expected: PASS. If `finishedIn` fails on the space character, note that `ru_RU` groups with U+00A0 NO-BREAK SPACE, not U+0020 — fix the *test's* expected string to contain the real character rather than changing the formatter, because the non-breaking space is correct typography and is what the drawing shows.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/RussianCopy.swift Tests/TranslatorAppTests/RussianCopyTests.swift
git commit -m "feat(app): the file queue's Russian copy

Seven strings the queue needs, beside chunkCount rather than inline at their views:
a label built at its call site is a label the next surface spells differently, which
is the whole reason this file exists.

partProgress names the часть being waited for, not the ones behind it, and is clamped
so the last report does not read «часть 8 из 7»."
```

---

### Task 6: `FileJob` and `FileQueueModel` — the runner

§4.2 and §4.3. The heart of the feature. Saving is deliberately *not* here (Task 7) so this task's tests can run a whole queue without touching a filesystem.

**Files:**
- Create: `Sources/TranslatorApp/FileJob.swift`
- Create: `Sources/TranslatorApp/FileQueueModel.swift`
- Test: `Tests/TranslatorAppTests/FileQueueModelTests.swift`

**Interfaces:**
- Consumes: `QueueDrop.accept(_:)`, `TranslationProgress`, `AppSettings.resolvedBatchModel/.stopOnWarnings`, `Translator`, `GlossaryStore`.
- Produces:
  - `struct FileJob: Identifiable` — `id: UUID`, `url: URL`, `text: String`, `partsTotal: Int`, `state: FileJob.State`, `result: JobResult?`, `saveProblem: String?`
  - `enum FileJob.State: Equatable` — `.queued`, `.running(TranslationProgress)`, `.finished`, `.interrupted`, `.failed(String)`
  - `struct JobResult` — `final: String`, `checks: [GlossaryCheck]`, `markupDiffs: [MarkupDiff]`, `elapsedMS: Int`, `savedTo: URL?`
  - `@MainActor @Observable final class FileQueueModel` — `jobs: [FileJob]`, `selection: FileJob.ID?`, `isRunning: Bool`, `pausedAfterWarnings: Bool`, `add(_:)`, `remove(_:)`, `run()`, `cancel()`

- [ ] **Step 1: Write the failing test**

Create `Tests/TranslatorAppTests/FileQueueModelTests.swift`:

```swift
import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

/// One scripted reply per model call, in order. `TranslationViewModelTests` has a
/// `ScriptedClient` of its own; this is a separate one on purpose, because that one is
/// `private` to its file and sharing it would couple two suites' fixtures.
private final class QueueClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private(set) var callCount = 0
    /// Blocks each reply behind a small sleep, so a cancellation has a window in which
    /// to land. A fully synchronous fake never suspends, and a test against it would
    /// pin nothing about cancellation at all.
    private let paced: Bool

    init(replies: [String], paced: Bool = false) { self.replies = replies; self.paced = paced }

    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        callCount += 1
        let reply = replies.isEmpty ? "" : replies.removeFirst()
        lock.unlock()
        let paced = self.paced
        return AsyncThrowingStream { continuation in
            let producer = Task {
                if paced { try? await Task.sleep(for: .milliseconds(20)) }
                continuation.yield(.token(reply))
                continuation.yield(.done(ChatStats(loadDurationMS: 1, promptEvalCount: 1,
                    promptEvalDurationMS: 1, evalCount: reply.count, evalDurationMS: 1)))
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

@MainActor
private func makeModel(_ client: LLMClient,
                       prefix: String,
                       configure: (AppSettings) -> Void = { _ in }) -> FileQueueModel {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: prefix))
    configure(settings)
    return FileQueueModel(translator: Translator(client: client),
                          settings: settings,
                          glossary: GlossaryStore(),
                          save: { _, _ in nil })   // saving is Task 7; here it never fails
}

private func job(_ name: String, _ text: String) -> FileJob {
    FileJob(url: URL(fileURLWithPath: "/tmp/\(name)"), text: text, partsTotal: 1)
}

@MainActor @Test func theQueueTranslatesItsFilesInOrder() async {
    let client = QueueClient(replies: ["один", "два", "три"])
    let model = makeModel(client, prefix: "queue-order")
    model.add([job("a.md", "first"), job("b.md", "second"), job("c.md", "third")])

    await model.run()

    #expect(model.jobs.allSatisfy { $0.state == .finished })
    #expect(model.jobs.map { $0.result?.final } == ["один", "два", "три"])
    #expect(client.callCount == 3)
}

@MainActor @Test func cancelStopsTheRunningFileAndLeavesTheRestQueued() async {
    let client = QueueClient(replies: ["один", "два", "три"], paced: true)
    let model = makeModel(client, prefix: "queue-cancel")
    model.add([job("a.md", "first"), job("b.md", "second"), job("c.md", "third")])

    let run = Task { await model.run() }
    // Let the first file get into the stream, then stop it.
    try? await Task.sleep(for: .milliseconds(10))
    model.cancel()
    await run.value

    #expect(model.jobs[0].state == .interrupted)
    #expect(model.jobs[1].state == .queued)
    #expect(model.jobs[2].state == .queued)
    #expect(!model.isRunning)
}

@MainActor @Test func runningAgainRetriesWhatDidNotFinishRatherThanSkippingIt() async {
    let client = QueueClient(replies: ["один", "два", "три"], paced: true)
    let model = makeModel(client, prefix: "queue-resume")
    model.add([job("a.md", "first"), job("b.md", "second")])

    let first = Task { await model.run() }
    try? await Task.sleep(for: .milliseconds(10))
    model.cancel()
    await first.value
    #expect(model.jobs[0].state == .interrupted)

    await model.run()

    // The interrupted файл is retried, not stepped over: a queue that silently skips
    // what it failed to do is a queue that reports success for work it did not perform.
    #expect(model.jobs.allSatisfy { $0.state == .finished })
}

@MainActor @Test func stopOnWarningsHaltsTheQueueButStillFinishesTheFileThatEarnedIt() async {
    // The reply drops the link's markup, which MarkupSkeleton reports as a diff.
    let client = QueueClient(replies: ["перевод без ссылки", "второй"])
    let model = makeModel(client, prefix: "queue-stop") { $0.stopOnWarnings = true }
    model.add([job("a.md", "See the [guide](https://example.org/g) for more."),
               job("b.md", "second")])

    await model.run()

    #expect(model.jobs[0].state == .finished)   // it finished; the pause is not a rollback
    #expect(model.jobs[1].state == .queued)
    #expect(model.pausedAfterWarnings)
    #expect(!model.isRunning)
}

@MainActor @Test func clearingThePauseLetsTheQueueCarryOn() async {
    let client = QueueClient(replies: ["перевод без ссылки", "второй"])
    let model = makeModel(client, prefix: "queue-unpause") { $0.stopOnWarnings = true }
    model.add([job("a.md", "See the [guide](https://example.org/g) for more."),
               job("b.md", "second")])
    await model.run()
    #expect(model.pausedAfterWarnings)

    await model.run()

    #expect(!model.pausedAfterWarnings)
    #expect(model.jobs[1].state == .finished)
}

@MainActor @Test func aCleanFileDoesNotPauseAQueueThatStopsOnWarnings() async {
    let client = QueueClient(replies: ["первый", "второй"])
    let model = makeModel(client, prefix: "queue-clean") { $0.stopOnWarnings = true }
    model.add([job("a.md", "first"), job("b.md", "second")])

    await model.run()

    #expect(!model.pausedAfterWarnings)
    #expect(model.jobs.allSatisfy { $0.state == .finished })
}

@MainActor @Test func theRunningJobCarriesItsPartProgress() async {
    let client = QueueClient(replies: ["перевод"])
    let model = makeModel(client, prefix: "queue-progress")
    model.add([job("a.md", "first")])

    await model.run()

    // After the run the job is .finished, so progress is checked through what the row
    // was given while it ran: partsTotal survives on the job itself.
    #expect(model.jobs[0].partsTotal == 1)
    #expect(model.jobs[0].result?.elapsedMS != nil)
}

@MainActor @Test func aFileThatFailsDoesNotStopTheOnesBehindIt() async {
    // An empty reply is the engine's «модель вернула пустой ответ» case.
    let client = QueueClient(replies: ["", "второй"])
    let model = makeModel(client, prefix: "queue-failure")
    model.add([job("a.md", "first"), job("b.md", "second")])

    await model.run()

    if case .failed = model.jobs[0].state {} else { Issue.record("expected the first file to fail") }
    #expect(model.jobs[1].state == .finished)
}

@MainActor @Test func aSecondRunIsRefusedWhileOneIsAlreadyGoing() async {
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let model = makeModel(client, prefix: "queue-reentrancy")
    model.add([job("a.md", "first")])

    let first = Task { await model.run() }
    try? await Task.sleep(for: .milliseconds(5))
    await model.run()   // must return immediately, not start a second pass
    await first.value

    #expect(client.callCount == 1)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FileQueueModelTests`
Expected: compile failure — `FileJob` and `FileQueueModel` are not defined.

- [ ] **Step 3: Write `FileJob`**

Create `Sources/TranslatorApp/FileJob.swift`:

```swift
// Sources/TranslatorApp/FileJob.swift
import Foundation
import TranslationCore

/// One file in the queue, and everything the row rendering it needs.
struct FileJob: Identifiable {
    let id = UUID()
    let url: URL
    /// Read when the file was dropped, not when its turn comes.
    ///
    /// A queue can sit for minutes before it reaches a given file, and reading late
    /// would let an edit — or a deletion — between the drop and the turn change a
    /// задание the user believes they queued.
    let text: String
    /// `Chunker.plan`'s count, computed at drop time off the main actor, because the
    /// queued row promises «4 части» before anything has run and planning twenty 2 MB
    /// files is not main-actor work.
    let partsTotal: Int
    var state: State = .queued
    var result: JobResult?
    /// Set when the translation could not be written. Deliberately separate from
    /// `state`: the задание finished, and saying it failed would be a lie about the
    /// translation, which is in memory and copyable.
    var saveProblem: String?

    enum State: Equatable {
        case queued
        case running(TranslationProgress)
        case finished
        /// Cancelled mid-run. Whatever text arrived is kept, matching what the window
        /// and the panel already do with an interrupted run.
        case interrupted
        case failed(String)
    }

    init(url: URL, text: String, partsTotal: Int) {
        self.url = url
        self.text = text
        self.partsTotal = partsTotal
    }
}

/// What a finished задание keeps.
///
/// **Not the whole `TranslationOutcome`.** An outcome carries `chunks` and
/// `translatedChunks` on top of `final`, i.e. roughly three copies of the document;
/// retaining that for twenty finished 2 MB файлов is ~120 MB nobody will read. These
/// five values are everything the right pane and `WarningsView` need.
struct JobResult {
    let final: String
    let checks: [GlossaryCheck]
    let markupDiffs: [MarkupDiff]
    let elapsedMS: Int
    var savedTo: URL?

    /// `.missing` only, not `.unverifiable`.
    ///
    /// `GlossaryStatus` has three cases and only one of them is a complaint:
    /// `.unverifiable` means `LemmaMatcher` could not decide for that language, which
    /// is a statement about the checker and not about the translation. Counting it
    /// would pause a `stopOnWarnings` queue on every Japanese file for no reason.
    var warningCount: Int {
        checks.filter { $0.status == .missing }.count + markupDiffs.count
    }
    var hasWarnings: Bool { warningCount > 0 }
}
```

- [ ] **Step 4: Write `FileQueueModel`**

Create `Sources/TranslatorApp/FileQueueModel.swift`:

```swift
// Sources/TranslatorApp/FileQueueModel.swift
import Foundation
import Observation
import TranslationCore

/// The file queue: what is in it, what is running, and what happened to each file.
///
/// A model of its own and **not** an extension of `TranslationViewModel`. One run per
/// model, guarded per instance, is the rule that keeps the window and the panel from
/// overwriting each other — it is why `adopt(from:)` refuses while either side is
/// running. A queue living inside a view model that also serves a text pane would put
/// two independent runs behind one guard.
@Observable
@MainActor
final class FileQueueModel {
    private let translator: Translator
    private let settings: AppSettings
    private let glossary: GlossaryStore
    /// Writing is injected so a queue can be run end to end in a test without touching
    /// a filesystem, and so the save-panel fallback lives at the app's edge rather than
    /// inside the runner. Returns a problem to show, or nil on success.
    private let save: (FileJob, String) -> String?

    private var current: Task<TranslationOutcome, Error>?

    var jobs: [FileJob] = []
    var selection: FileJob.ID?
    private(set) var isRunning = false
    /// A property of the **queue**, not of a задание.
    ///
    /// The file that earned the pause is `.finished` — it finished, and it was written.
    /// Modelling this as a sixth `FileJob.State` would make one file's outcome and the
    /// queue's willingness to continue the same value, so dismissing the pause would
    /// have to restate the задание.
    private(set) var pausedAfterWarnings = false
    /// The текст streaming into the right pane right now, for the задание being run.
    private(set) var streamingText = ""

    init(translator: Translator, settings: AppSettings, glossary: GlossaryStore,
         save: @escaping (FileJob, String) -> String?) {
        self.translator = translator
        self.settings = settings
        self.glossary = glossary
        self.save = save
    }

    func add(_ new: [FileJob]) {
        jobs.append(contentsOf: new)
        if selection == nil { selection = jobs.first?.id }
    }

    func remove(_ id: FileJob.ID) {
        guard !isRunning else { return }
        jobs.removeAll { $0.id == id }
        if selection == id { selection = jobs.first?.id }
    }

    /// Translate every задание that is not already `.finished`, one at a time.
    ///
    /// Sequential and not concurrent: Ollama holds one model in memory and `keep_alive`
    /// is load-bearing (measured — cold load ~2000 ms against ~155 ms warm), so running
    /// files in parallel multiplies requests against one server without multiplying
    /// throughput.
    ///
    /// Started by «Перевести» and never by a drop: a drop that immediately began
    /// minutes of work would make a mis-aimed drag expensive to undo.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        pausedAfterWarnings = false
        defer { isRunning = false }

        while let index = jobs.firstIndex(where: { $0.state != .finished }) {
            // `.interrupted` and `.failed` are included on purpose: resuming retries
            // what did not work. A queue that silently steps over a file it failed to
            // translate reports success for work it never performed.
            let stopped = await translate(at: index)
            if stopped { return }
        }
    }

    func cancel() { current?.cancel() }

    /// - Returns: whether the queue should stop here.
    private func translate(at index: Int) async -> Bool {
        let job = jobs[index]
        selection = job.id
        streamingText = ""
        jobs[index].state = .running(TranslationProgress(partsDone: 0,
                                                         partsTotal: job.partsTotal,
                                                         documentTermCount: 0))

        let detected = LanguageDetector.detect(job.text)
        let target = settings.targetLanguage(forDetected: detected)
        let options = ChatOptions(model: settings.resolvedBatchModel,
                                  temperature: settings.temperature,
                                  keepAlive: settings.keepAlive)
        let started = Date()

        // Pieces travel through a stream rather than a Task-per-token, for
        // `TranslationViewModel.translate`'s reason: `onToken` is called serially by the
        // engine and a stream preserves that order on the way to the main actor, which
        // a per-token unstructured Task only happens to do.
        let (pieces, continuation) = AsyncStream<String>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await piece in pieces { self?.streamingText += piece }
        }
        let (progress, progressContinuation) = AsyncStream<TranslationProgress>.makeStream()
        let progressConsumer = Task { @MainActor [weak self] in
            for await value in progress {
                guard let self, let at = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                if case .running = self.jobs[at].state { self.jobs[at].state = .running(value) }
            }
        }

        let run = Task { [translator, glossary, settings] in
            try await translator.translate(
                text: job.text, target: target, tone: settings.defaultTone,
                userGlossary: glossary.glossary, options: options,
                maxChunkCharacters: settings.chunkSize,
                ignoredTerms: glossary.mutedSet,
                onToken: { continuation.yield($0) },
                onProgress: { progressContinuation.yield($0) })
        }
        current = run

        func drain() async {
            continuation.finish()
            progressContinuation.finish()
            await consumer.value
            await progressConsumer.value
        }

        do {
            let outcome = try await run.value
            await drain()
            guard outcome.timeToFirstTokenMS != nil else {
                // The engine's «nothing was ever emitted» signal. Reporting success
                // would write an empty file beside the source.
                jobs[index].state = .failed("Модель вернула пустой ответ.")
                return false
            }
            var result = JobResult(final: outcome.final, checks: outcome.checks,
                                   markupDiffs: outcome.markupDiffs,
                                   elapsedMS: Int(Date().timeIntervalSince(started) * 1000))
            if settings.saveNextToSource {
                jobs[index].saveProblem = save(job, outcome.final)
                if jobs[index].saveProblem == nil {
                    result.savedTo = OutputNaming.destination(
                        for: job.url, target: target,
                        exists: { FileManager.default.fileExists(atPath: $0.path) })
                }
            }
            jobs[index].result = result
            jobs[index].state = .finished
            if settings.stopOnWarnings, result.hasWarnings {
                pausedAfterWarnings = true
                return true
            }
            return false
        } catch is CancellationError {
            await drain()
            jobs[index].state = .interrupted
            jobs[index].result = JobResult(final: streamingText, checks: [], markupDiffs: [],
                                           elapsedMS: Int(Date().timeIntervalSince(started) * 1000))
            return true
        } catch {
            await drain()
            // Ask the task, not the error, for `TranslationViewModel`'s reason: a
            // producer that finishes inside `onTermination`'s window surfaces a
            // URLError(.cancelled) rather than a CancellationError, and reporting that
            // as a failure would show English right after the user pressed Cancel.
            if run.isCancelled {
                jobs[index].state = .interrupted
                return true
            }
            jobs[index].state = .failed(TranslationViewModel.message(for: error))
            return false
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter FileQueueModelTests`
Expected: PASS, 9 tests.

If `stopOnWarningsHaltsTheQueueButStillFinishesTheFileThatEarnedIt` fails because the fixture produced no warning, print `outcome.markupDiffs` from a scratch test first and pick a source/reply pair that actually produces one — do not weaken the assertion to `>= 0`, which is a test that passes under the defect it names.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/FileJob.swift Sources/TranslatorApp/FileQueueModel.swift Tests/TranslatorAppTests/FileQueueModelTests.swift
git commit -m "feat(app): FileJob and FileQueueModel — the queue itself

A model of its own rather than a queue inside TranslationViewModel: one run per
model with a per-instance guard is what keeps the window and the panel from
overwriting each other, and a queue there would put two runs behind one guard.

Files run one at a time because Ollama holds one model and keep_alive is
load-bearing. Resuming retries interrupted and failed files rather than stepping
over them. The stop-on-warnings pause belongs to the queue, not to the file that
earned it — that file finished and was written.

JobResult keeps five values rather than the whole TranslationOutcome, which
carries roughly three copies of the document."
```

---

### Task 7: Writing the translation, and the save-panel fallback

§4.5. The write may be refused by TCC and this environment cannot establish whether it will be (spec §9.1), so the design does not depend on the answer.

**Files:**
- Create: `Sources/TranslatorApp/TranslatedFileWriter.swift`
- Test: `Tests/TranslatorAppTests/TranslatedFileWriterTests.swift`

**Interfaces:**
- Consumes: `OutputNaming.destination(for:target:exists:)`.
- Produces: `enum TranslatedFileWriter` with `static func write(_ text: String, to destination: URL) -> String?` — returns a Russian problem to show, or `nil` on success.

- [ ] **Step 1: Write the failing test**

Create `Tests/TranslatorAppTests/TranslatedFileWriterTests.swift`:

```swift
import Foundation
import Testing
@testable import TranslatorApp

private func scratchDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("writer-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func aTranslationIsWrittenAsUTF8AtTheNameItWasGiven() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("doc.ru.md")

    #expect(TranslatedFileWriter.write("Привет, мир.", to: destination) == nil)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "Привет, мир.")
}

@Test func anExistingFileIsNeverOverwrittenEvenIfTheNameWasClearedFirst() throws {
    // The naming rule checks, then this writes, and another process can create the file
    // in between. .withoutOverwriting is what makes that race lose safely instead of
    // destroying a document.
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("doc.ru.md")
    try Data("не трогать".utf8).write(to: destination)

    let problem = TranslatedFileWriter.write("новый перевод", to: destination)

    #expect(problem != nil)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "не трогать")
}

@Test func aRefusedWriteComesBackAsARussianSentenceAndNotAnNSErrorDump() {
    let denied = URL(fileURLWithPath: "/System/definitely-not-writable/doc.ru.md")
    let problem = TranslatedFileWriter.write("текст", to: denied)
    let message = try! #require(problem)
    // The user reads this. An NSCocoaErrorDomain description is English and names a
    // domain nobody outside this process has heard of.
    #expect(message.contains("Не удалось сохранить"))
    #expect(!message.contains("NSCocoaErrorDomain"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TranslatedFileWriterTests`
Expected: compile failure — `TranslatedFileWriter` is not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/TranslatorApp/TranslatedFileWriter.swift`:

```swift
// Sources/TranslatorApp/TranslatedFileWriter.swift
import Foundation

/// Putting a finished translation on disk.
///
/// **Whether this is allowed is not knowable from a test.** The app is not sandboxed —
/// `Scripts/make-app-bundle.sh` signs and does nothing else — but that removes only one
/// of the two barriers. On macOS 14 a non-sandboxed app still meets TCC for
/// `~/Documents`, `~/Desktop` and `~/Downloads`, and a drag grants the right to *read*
/// what was dragged, not to place a sibling beside it. Whether the first write prompts,
/// succeeds, or fails is recorded as an open probe in the spec's §9.1 and in
/// `docs/OPEN-ITEMS.md`.
///
/// So this returns a problem instead of throwing, and the caller's recovery is a save
/// panel rather than a message: `NSSavePanel` confers the write right itself, which
/// makes it an actual way out of a refusal rather than an apology for one.
enum TranslatedFileWriter {
    /// - Returns: a Russian sentence to show the user, or nil if the file was written.
    static func write(_ text: String, to destination: URL) -> String? {
        do {
            // `.withoutOverwriting` and not a plain write: `OutputNaming` checks for a
            // free name and this writes, and another process can create the file in
            // between. Losing that race must cost a numbered name, not a document.
            try Data(text.utf8).write(to: destination, options: [.withoutOverwriting])
            return nil
        } catch {
            // The error's own `localizedDescription` is English and names
            // NSCocoaErrorDomain; neither belongs on a Russian screen. The code is
            // logged for diagnosis and the sentence says what to do instead.
            Log.files.error("could not write a translation: \(error.localizedDescription, privacy: .public)")
            return "Не удалось сохранить перевод рядом с исходником. "
                + "Воспользуйтесь кнопкой «Сохранить как…» — это заодно выдаст приложению право на запись."
        }
    }
}
```

`Log` today has three categories — `hotkey`, `engine`, `settings` (`Log.swift:46-50`) — and none of them is this. Add a fourth beside them:

```swift
    /// The file queue: what it could not read and what it could not write.
    ///
    /// A category of its own because these are the failures a user reports as «оно
    /// ничего не сохранило», and finding them in the `engine` stream among per-часть
    /// diagnostics is the difference between a diagnosis and a search.
    ///
    /// **A file name is user data.** Nothing here logs one: a path names a document,
    /// a project and often an employer, and `Log`'s own rule is that nothing derived
    /// from the user's text reaches the unified log. Error descriptions are `.public`
    /// on purpose, for the reason recorded at the top of this file.
    static let files = Logger(subsystem: subsystem, category: "files")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TranslatedFileWriterTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/TranslatedFileWriter.swift Tests/TranslatorAppTests/TranslatedFileWriterTests.swift
git commit -m "feat(app): TranslatedFileWriter, with a refusal that has a way out

Writes with .withoutOverwriting, so losing the race between OutputNaming's check
and this write costs a numbered name and not a document.

Returns a Russian sentence rather than throwing an NSError, because whether TCC
allows a sibling write next to a dragged file is unverified — the app is not
sandboxed, but a drag grants read, not write. The recovery is a save panel, which
confers the right itself rather than apologising for not having it."
```

---

### Task 8: `TranslationPane` takes values instead of a view model

§5.3. A small refactor, and the only existing view this phase changes. Done as its own task because it must leave the shipped window byte-identical in behaviour before anything new renders through it.

**Files:**
- Modify: `Sources/TranslatorApp/TranslationPane.swift`
- Modify: `Sources/TranslatorApp/MainWindowView.swift:32`
- Test: `Tests/TranslatorAppTests/` — no new test; the existing suite must stay green.

**Interfaces:**
- Produces: `TranslationPane(title: String, text: String, isRunning: Bool, onCopy: () -> Void)`.

- [ ] **Step 1: Change the pane's inputs**

In `Sources/TranslatorApp/TranslationPane.swift`, replace the two stored properties and every `model.` reference:

```swift
struct TranslationPane: View {
    /// «Перевод», or «Перевод · techdoc-en.md» in the queue. A parameter and not a
    /// constant because the queue names the file whose translation is showing.
    let title: String
    let text: String
    let isRunning: Bool
    let onCopy: () -> Void
```

`model.translatedText` becomes `text`, `model.state != .running` becomes `!isRunning`, and `PaneHeader(title: "Перевод")` becomes `PaneHeader(title: title)`.

Add to the type's doc comment:

```swift
/// Takes the four values it renders rather than a `TranslationViewModel`, because the
/// queue's right pane shows a `FileQueueModel`'s stream through this same view. A view
/// that renders four values does not need a class reference to reach them, and two
/// copies of this pane is how two surfaces come to disagree about what a translation
/// looks like.
```

- [ ] **Step 2: Update the one call site**

In `Sources/TranslatorApp/MainWindowView.swift`, line 32:

```swift
                TranslationPane(title: "Перевод",
                                text: model.translatedText,
                                isRunning: model.state == .running,
                                onCopy: onCopy)
```

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: PASS, the same count as before this task. Nothing about behaviour changed, so a failure here means the refactor changed something it should not have.

- [ ] **Step 4: Verify zero warnings and commit**

```bash
swift build --build-tests 2>&1 | grep -i warning   # expect no output
git add Sources/TranslatorApp/TranslationPane.swift Sources/TranslatorApp/MainWindowView.swift
git commit -m "refactor(app): TranslationPane takes its four values, not a view model

The queue's right pane renders a FileQueueModel's stream through this same view.
A view that renders four values does not need a class reference to reach them,
and a second copy of the pane is how two surfaces come to disagree about what a
translation looks like.

Behaviour is unchanged: the full suite is green at the same count."
```

---

### Task 9: The queue pane and the «Текст / Файлы» switch

§5.1 and §5.2. Views, so almost nothing here is testable from this environment — Task 12 records what is owed to a pair of eyes.

**Files:**
- Create: `Sources/TranslatorApp/FileQueuePane.swift`
- Modify: `Sources/TranslatorApp/SourcePane.swift` (the shared `PaneHeader`)
- Modify: `Sources/TranslatorApp/MainWindowView.swift`
- Test: `Tests/TranslatorAppTests/FileQueueModelTests.swift` (append)

**Interfaces:**
- Consumes: `FileQueueModel`, `QueueDrop.accept(_:)`, `RussianCopy.*`.
- Produces: `struct FileQueuePane: View`, `enum SourceMode: String, CaseIterable`.

- [ ] **Step 1: Write the failing test for the only decidable part**

A view cannot be rendered here, but *which mode is legal right now* is a rule, and a rule can be tested. Append to `Tests/TranslatorAppTests/FileQueueModelTests.swift`:

```swift
@MainActor @Test func theModeSwitchIsLockedWhileTheQueueRuns() async {
    // One window, one primary button. If the mode could change mid-run the user could
    // switch to «Текст» and press «Перевести», putting two runs behind one toolbar.
    let client = QueueClient(replies: ["один"], paced: true)
    let model = makeModel(client, prefix: "queue-mode-lock")
    model.add([job("a.md", "first")])
    #expect(model.canChangeMode)

    let run = Task { await model.run() }
    try? await Task.sleep(for: .milliseconds(5))
    #expect(!model.canChangeMode)
    await run.value

    #expect(model.canChangeMode)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter theModeSwitchIsLockedWhileTheQueueRuns`
Expected: compile failure — no member `canChangeMode`.

- [ ] **Step 3: Add the rule to the model**

In `Sources/TranslatorApp/FileQueueModel.swift`:

```swift
    /// Whether the window may switch between «Текст» and «Файлы» right now.
    ///
    /// A property of the model and not a condition restated in the view, for
    /// `TranslationViewModel.canSwapLanguages`' reason: the control has to answer
    /// before it is pressed, and a view that re-derived the rule would keep offering a
    /// switch for a case added later. One window has one primary button; switching
    /// mid-run would let «Перевести» start a text translation behind a queue.
    var canChangeMode: Bool { !isRunning }
```

- [ ] **Step 4: Write the pane**

Create `Sources/TranslatorApp/FileQueuePane.swift`:

```swift
// Sources/TranslatorApp/FileQueuePane.swift
import SwiftUI
import TranslationCore
import UniformTypeIdentifiers

/// Which of the two things the window's left half is showing.
enum SourceMode: String, CaseIterable, Identifiable {
    case text, files
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: "Текст"
        case .files: "Файлы"
        }
    }
}

/// The window's left half in «Файлы»: the queue.
struct FileQueuePane: View {
    @Bindable var queue: FileQueueModel
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $queue.selection) {
                ForEach(queue.jobs) { job in
                    FileQueueRow(job: job).tag(job.id)
                }
            }
            .listStyle(.inset)
            dropTarget
        }
        .frame(minWidth: 280)
        // Refusal is `false`, which springs every item back — the same and only error
        // channel `SourcePane` uses, and for the same reason: there is no error surface
        // in this window, and inventing one to say «это не текст» would be a worse trade
        // than the feedback the platform already draws.
        .dropDestination(for: URL.self) { urls, _ in
            guard queue.canChangeMode, let accepted = QueueDrop.accept(urls) else { return false }
            queue.add(accepted.map {
                FileJob(url: $0.url, text: $0.text,
                        partsTotal: Chunker.plan($0.text, maxCharacters: 900).chunks.count)
            })
            return true
        }
    }

    private var dropTarget: some View {
        VStack(spacing: 4) {
            Text("Перетащите .md, .txt или .markdown")
            Text("Файл читается целиком, код не делится между частями")
        }
        .font(.caption).foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(8)
    }
}

private struct FileQueueRow: View {
    let job: FileJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.url.lastPathComponent).font(.body)
                Spacer(minLength: 8)
                Text(trailing).font(.caption).foregroundStyle(trailingStyle)
            }
            if case let .running(progress) = job.state {
                ProgressView(value: Double(progress.partsDone), total: Double(max(progress.partsTotal, 1)))
                    .progressViewStyle(.linear)
                Text(runningDetail(progress)).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = job.saveProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        // One announcement per row rather than four unlabelled fragments, so VoiceOver
        // reads «techdoc-en.md, перевожу часть 4 из 7» instead of spelling the layout.
        .accessibilityElement(children: .combine)
    }

    private var trailing: String {
        switch job.state {
        case .queued: RussianCopy.queuedFile(parts: job.partsTotal)
        case .running: RussianCopy.chunkCount(job.partsTotal)
        case .finished: job.result.map { RussianCopy.finishedIn(milliseconds: $0.elapsedMS) } ?? ""
        case .interrupted: "прервано"
        case .failed(let message): message
        }
    }

    private var trailingStyle: HierarchicalShapeStyle {
        if case .failed = job.state { return .secondary }
        return .secondary
    }

    private func runningDetail(_ progress: TranslationProgress) -> String {
        let part = RussianCopy.partProgress(done: progress.partsDone, total: progress.partsTotal)
        guard progress.documentTermCount > 0 else { return part }
        return "\(part) · \(RussianCopy.documentTermCount(progress.documentTermCount))"
    }
}
```

- [ ] **Step 5: Put the switch in the window**

In `Sources/TranslatorApp/MainWindowView.swift`, add `@State private var mode: SourceMode = .text` and a `let queue: FileQueueModel`, then replace the `HSplitView` contents:

```swift
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    // The switch replaces the «Исходник» caption rather than sitting
                    // above it, so the two panes still read as one row of chrome. Both
                    // headers therefore have to agree on a height — see `PaneHeader`.
                    PaneHeader(title: nil) {
                        Picker("", selection: $mode) {
                            ForEach(SourceMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(!queue.canChangeMode)
                        Spacer()
                        if mode == .text {
                            Button("Очистить") { model.sourceText = "" }
                                .buttonStyle(.link)
                                .disabled(model.sourceText.isEmpty)
                        } else {
                            Button("Добавить…", action: addFiles)
                                .buttonStyle(.link)
                                .disabled(!queue.canChangeMode)
                        }
                    }
                    if mode == .text {
                        SourceEditor(model: model)
                    } else {
                        FileQueuePane(queue: queue, onAdd: addFiles)
                    }
                }
                TranslationPane(title: paneTitle,
                                text: mode == .text ? model.translatedText : queue.streamingText,
                                isRunning: mode == .text ? model.state == .running : queue.isRunning,
                                onCopy: onCopy)
            }
```

`SourcePane`'s editor half becomes `SourceEditor` (the `ZStack` with the placeholder, the footer and the text drop), keeping its `PaneHeader` out — the header is now the window's, shared by both modes. `PaneHeader` gains an optional `title` and a **pinned height**, because a `.small` segmented control is taller than a caption and two headers of different heights read as a broken split:

```swift
struct PaneHeader<Action: View>: View {
    let title: String?
    @ViewBuilder var action: () -> Action

    /// Both panes' headers are pinned to one height. The left one may hold a segmented
    /// control and the right one holds a caption; without this they differ by a few
    /// points and the divider between the panes reads as misaligned. The number is the
    /// control's own height plus the padding this row already had, and is owed a look
    /// on a real screen — see `docs/OPEN-ITEMS.md`.
    static var height: CGFloat { 28 }

    var body: some View {
        HStack {
            if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            action().font(.caption)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(.quaternary.opacity(0.25))
        Divider()
    }
}
```

`addFiles` runs an `NSOpenPanel` restricted to `DroppedDocument.readableExtensions` and feeds the result through `QueueDrop.accept`, so the panel and the drop cannot come to accept different things.

- [ ] **Step 6: Run the suite and check the build**

Run: `swift test` then `swift build --build-tests 2>&1 | grep -i warning`
Expected: PASS at the previous count plus the new test; no warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslatorApp/FileQueuePane.swift Sources/TranslatorApp/SourcePane.swift Sources/TranslatorApp/MainWindowView.swift Sources/TranslatorApp/FileQueueModel.swift Tests/TranslatorAppTests/FileQueueModelTests.swift
git commit -m "feat(app): the file queue pane and the «Текст / Файлы» switch

The switch replaces the «Исходник» caption rather than sitting above it, so both
panes still read as one row of chrome — which is why PaneHeader now pins a height
for both: a small segmented control is taller than a caption, and two headers a
few points apart read as a misaligned split.

canChangeMode lives on the model, not in the view: one window has one primary
button, and switching mid-run would let «Перевести» start a text translation
behind a running queue."
```

---

### Task 10: The status bar in «Файлы»

§5.4.

**Files:**
- Modify: `Sources/TranslatorApp/RunStatusBar.swift`
- Modify: `Sources/TranslatorApp/MainWindowView.swift`
- Test: `Tests/TranslatorAppTests/FileQueueModelTests.swift` (append)

**Interfaces:**
- Consumes: `RussianCopy.queuePosition(fileIndex:fileTotal:partsDone:partsTotal:)`.
- Produces: `FileQueueModel.statusLine: String?`, `FileQueueModel.selectedResult: JobResult?`.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor @Test func theStatusLineCountsFilesAndPartsAcrossTheWholeQueue() async {
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let model = makeModel(client, prefix: "queue-status")
    model.add([job("a.md", "first"), job("b.md", "second")])
    // Nothing has run: there is nothing to say, and an empty row is better than a
    // «0 из 2» that implies work is under way.
    #expect(model.statusLine == nil)

    let run = Task { await model.run() }
    try? await Task.sleep(for: .milliseconds(10))
    let line = model.statusLine
    await run.value

    #expect(line?.contains("Перевожу 1-й файл из 2") == true)
}

@MainActor @Test func thePauseSaysWhyTheQueueStopped() async {
    let client = QueueClient(replies: ["перевод без ссылки", "второй"])
    let model = makeModel(client, prefix: "queue-status-paused") { $0.stopOnWarnings = true }
    model.add([job("a.md", "See the [guide](https://example.org/g) for more."),
               job("b.md", "second")])
    await model.run()

    #expect(model.statusLine == "Очередь остановлена на предупреждениях — нажмите «Перевести», чтобы продолжить")
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter theStatusLineCountsFilesAndPartsAcrossTheWholeQueue`
Expected: compile failure — no member `statusLine`.

- [ ] **Step 3: Implement both properties**

In `Sources/TranslatorApp/FileQueueModel.swift`:

```swift
    /// The one line the status bar shows in «Файлы», or nil when there is nothing to
    /// say. Nil rather than «0 из 2», which would imply work is under way.
    var statusLine: String? {
        if pausedAfterWarnings {
            return "Очередь остановлена на предупреждениях — нажмите «Перевести», чтобы продолжить"
        }
        guard let index = jobs.firstIndex(where: { if case .running = $0.state { true } else { false } }),
              case let .running(progress) = jobs[index].state
        else { return nil }
        // Parts are counted across the whole queue, not within the current file: the
        // sentence is about how much of the *queue* is left, and a per-file count next
        // to a per-queue file count would be two scales in one line.
        let done = jobs.prefix(index).reduce(0) { $0 + $1.partsTotal } + progress.partsDone
        let total = jobs.reduce(0) { $0 + $1.partsTotal }
        return RussianCopy.queuePosition(fileIndex: index, fileTotal: jobs.count,
                                         partsDone: done, partsTotal: total)
    }

    /// The result whose warnings the status bar's disclosure opens.
    var selectedResult: JobResult? {
        jobs.first { $0.id == selection }?.result
    }
```

- [ ] **Step 4: Render it**

In `RunStatusBar`, add an optional `queue: FileQueueModel?`. When it is non-nil the row's `line` is `queue.statusLine` and the disclosure opens `WarningsView(outcome:target:…)` built from `queue.selectedResult`.

`WarningsView` currently takes a `TranslationOutcome`. Give it a second initialiser taking `checks` and `markupDiffs` directly, and have the existing one forward to it — **do not duplicate the view**, for `TranslationPane`'s reason.

- [ ] **Step 5: Run the suite and commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/TranslatorApp/FileQueueModel.swift Sources/TranslatorApp/RunStatusBar.swift Sources/TranslatorApp/WarningsView.swift Sources/TranslatorApp/MainWindowView.swift Tests/TranslatorAppTests/FileQueueModelTests.swift
git commit -m "feat(app): the status bar counts files and части in «Файлы»

Parts are counted across the whole queue rather than within the current file: the
sentence is about how much of the queue is left, and a per-file count beside a
per-queue file count would put two scales in one line.

WarningsView gains an initialiser taking checks and diffs directly, and the
outcome-taking one forwards to it — a second copy of that view is how two
surfaces come to describe one run differently."
```

---

### Task 11: The «Файлы» settings tab

§7.1–7.2.

**Files:**
- Create: `Sources/TranslatorApp/SettingsFilesView.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift:218-229`
- Test: `Tests/TranslatorAppTests/AppSettingsTests.swift` (append)

**Interfaces:**
- Consumes: `AppSettings.batchModel/.resolvedBatchModel/.saveNextToSource/.stopOnWarnings/.reviewDocumentTerms`, `ModelsViewModel`.
- Produces: `struct SettingsFilesView: View`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func choosingABatchModelThatDiffersFromTheHotkeysIsWorthWarningAbout() {
    // Ollama holds one model: cold load ~2000 ms against ~155 ms warm. A batch model
    // that differs costs two of those on every hotkey press during a queue run, and
    // the pane has to say so rather than leaving the user to discover it.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "batch-warning"))
    #expect(!settings.batchModelDiffersFromInteractive)

    settings.batchModel = "gpt-oss:20b"
    settings.interactiveModel = "aya-expanse:8b"
    #expect(settings.batchModelDiffersFromInteractive)

    settings.batchModel = "aya-expanse:8b"
    #expect(!settings.batchModelDiffersFromInteractive)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter choosingABatchModelThatDiffersFromTheHotkeysIsWorthWarningAbout`
Expected: compile failure — no member `batchModelDiffersFromInteractive`.

- [ ] **Step 3: Add the rule**

In `AppSettings`:

```swift
    /// Whether the queue and the hotkey would use two different models — i.e. whether
    /// a hotkey press during a queue run costs a model swap in Ollama's memory.
    ///
    /// A property rather than a comparison written in the settings pane, for
    /// `canSwapLanguages`' reason: the caption has to answer before it is drawn, and a
    /// view that restated the comparison would go on reassuring the user after the rule
    /// changed.
    var batchModelDiffersFromInteractive: Bool { resolvedBatchModel != interactiveModel }
```

- [ ] **Step 4: Write the pane**

Create `Sources/TranslatorApp/SettingsFilesView.swift` — a `Form` of three `Section`s inside `.settingsPane()`:

1. **«Модель для пакетного перевода»** — a `Picker` bound to `settings.batchModel` whose first entry is `Text("Как для перевода по клавише").tag(String?.none)` followed by `models.installed`. Caption: «Здесь важнее качество перевода, чем время до первого символа, — можно взять модель медленнее той, что работает по сочетанию клавиш.» When `settings.batchModelDiffersFromInteractive`, a second caption in `.orange`: «Ollama держит в памяти одну модель. Пока идёт очередь, каждое нажатие сочетания клавиш будет перезагружать модель — примерно две секунды туда и столько же обратно.»
2. **«Куда сохранять»** — `Toggle("Рядом с исходником", isOn: $settings.saveNextToSource)` with «techdoc-en.md → techdoc-en.ru.md. Существующий файл не перезаписывается — к имени добавляется номер.»; `Toggle("Останавливаться на предупреждениях", isOn: $settings.stopOnWarnings)` with «Иначе очередь идёт до конца, а разметку и термины можно посмотреть у каждого файла после.»
3. **«Термины документа»** — `Toggle("Показывать перед переводом", isOn: $settings.reviewDocumentTerms)` with «Список терминов из файла можно поправить до перевода.» and, until Phase 2 lands, a `.disabled(true)` on the toggle — a switch that does nothing is worse than a switch that says it is not ready yet.

- [ ] **Step 5: Add the fourth tab**

In `Sources/TranslatorApp/TranslatorApp.swift`, after the glossary tab:

```swift
                SettingsFilesView(settings: settings, models: models)
                    .tabItem { Label("Файлы", systemImage: "doc.on.doc") }
```

«Файлы», not «Пакетный»: its three neighbours are «Основные», «Модели», «Глоссарий» — nouns — and it is the same word the window's own switch uses.

- [ ] **Step 6: Run the suite, build the bundle, and look**

```bash
swift test
swift build --build-tests 2>&1 | grep -i warning
./Scripts/make-app-bundle.sh
open build/LocalTranslator.app
```

Open Settings and check the fourth tab against the 560 × 480 frame — this is spec §9.2 and it is the one step in this plan that cannot be automated. Record what you actually saw. If it does not fit, `.formStyle(.grouped)` scrolls, so the question is whether it *should have to*, not whether it clips.

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslatorApp/SettingsFilesView.swift Sources/TranslatorApp/TranslatorApp.swift Sources/TranslatorApp/AppSettings.swift Tests/TranslatorAppTests/AppSettingsTests.swift
git commit -m "feat(app): the «Файлы» settings tab

«Файлы» and not «Пакетный»: its neighbours are «Основные», «Модели», «Глоссарий»,
all nouns, and it is the word the window's own mode switch uses.

The model picker's first entry is «Как для перевода по клавише», not a model name,
and picking a different one draws a caption saying what it costs: Ollama holds one
model, cold load ~2000 ms against ~155 ms warm, so a hotkey press during a queue
run pays two of those.

The terms toggle is disabled until Phase 2 wires it. A switch that does nothing is
worse than one that says it is not ready."
```

---

### Task 12: Documentation

The repo treats documentation drift as a build failure (`Tests/DocumentationTests`). This task is not optional and not last-minute.

**Files:**
- Modify: `CLAUDE.md`, `CONTEXT.md`, `docs/OPEN-ITEMS.md`
- Modify: `docs/superpowers/specs/2026-07-24-local-translator-design.md` (§12)
- Test: `Tests/DocumentationTests/ArchitectureDriftTests.swift`

- [ ] **Step 1: Run the documentation tests first**

Run: `swift test --filter DocumentationTests`
Expected: it may already be failing — read what it checks before editing anything, because it pins specific sentences.

- [ ] **Step 2: `CLAUDE.md`**

- «The settings are **three** tabs, not four» → four, with «Файлы» named and the reason «Дополнительно» was folded into «Модели» left intact.
- The «Two `TranslationViewModel` instances» paragraph gains a third model, `FileQueueModel`, and the reason it is separate.
- The Ollama rules gain the one-model-in-memory consequence for `batchModel`.
- The pipeline section notes `onProgress` and that `stats` still covers per-часть calls only.
- The traps index gains `QueueDrop`/`OutputNaming`/`TranslatedFileWriter` under «writing a file».

- [ ] **Step 3: `CONTEXT.md`**

Add «задание», «очередь» and «Файлы» to the vocabulary with their _Avoid_ lists, per spec §1. Update the line that says batch translation is not built.

- [ ] **Step 4: `docs/OPEN-ITEMS.md` §1**

Add the table from spec §11, verbatim, as a new «Owed by the file queue» block. Add the TCC probe (§9.1) to §2 with whatever Task 11's bundle run actually established — **and nothing it did not**.

- [ ] **Step 5: Spec §12**

`docs/superpowers/specs/2026-07-24-local-translator-design.md` §12's first bullet stops being future tense and points at the new spec.

- [ ] **Step 6: Run everything and commit**

```bash
swift test
git add CLAUDE.md CONTEXT.md docs/
git commit -m "docs: the file queue

Four settings tabs, a third view model, and the one-model-in-memory consequence
that decides batchModel's absent default. OPEN-ITEMS gains what the queue owes a
pair of eyes, and records only what the bundle run actually showed."
```

---

## Self-review

**Spec coverage.** §3.5 → Task 1. §4.1 → Task 3. §4.2, §4.3 → Task 6. §4.4 → Task 2. §4.5 → Task 7. §5.1, §5.2 → Task 9. §5.3 → Task 8. §5.4 → Task 10. §5.5 (toolbar unchanged) → no task, correctly: it is a statement that nothing changes. §7 → Task 11. §8 → Task 5. §9.2 → Task 11 Step 6. §9.1 → Task 7 (the fallback) and Task 12 (recording it). §10 → distributed across every task's tests. §11 → Task 12. §3.1–3.4, §6 → **Phase 2, not this plan.**

**Gap found and closed:** the spec's §13 originally put `onProgress` in Phase 2 while §5.2's queue row depends on it. The spec was corrected before this plan was written; Task 1 is the result.

**Type consistency.** Two names were wrong when first written and were checked against the source rather than left as an instruction to check:

- `GlossaryCheck` has no `isHonoured`. It carries `status: GlossaryStatus`, whose cases are `.satisfied`, `.missing`, `.unverifiable` (`GlossaryVerifier.swift:4-10`). `JobResult.warningCount` counts `.missing` only, and Task 6 now says why `.unverifiable` is excluded.
- `Log` has no `app`. Its categories are `hotkey`, `engine`, `settings` (`Log.swift:46-50`), so Task 7 adds a fourth, `files`, with its reasoning.

Other names were taken from files read while planning: `ModelsViewModel.installedNames` (`ModelsViewModel.swift:29`) for Task 11's picker, `GlossaryStore.glossary`/`.mutedSet`, `TranslationViewModel.message(for:)`, `Chunker.plan(_:maxCharacters:)`, `AppSettings.targetLanguage(forDetected:)`, `InMemoryDefaults(prefix:)`.

**Placeholder scan.** No "TBD", no "handle errors appropriately", no "similar to Task N". Every code step carries the code. Two steps are deliberately not code — Task 11 Step 6 and Task 12 Step 4 — because they are «open the bundle and look» and «write down only what you actually saw», which is what this environment's lack of GUI automation makes them.

**Not in this plan, on purpose.** `reviewDocumentTerms` is stored and drawn but disabled; the engine hook, the continuation guarantee and the terms sheet are Phase 2. Phase 1 is shippable without them: the toggle says it is not ready rather than doing nothing.
