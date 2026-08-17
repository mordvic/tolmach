# Batch translation — the file queue (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate a queue of dropped text files one after another from the main window, writing each translation beside its source, with a fourth settings tab that governs it.

**Architecture:** One new engine callback (`onProgress`, non-suspending, cannot fail) plus four new pure types and one `@Observable @MainActor` runner in `TranslatorApp`. The main window gains a «Текст / Файлы» mode switch in the left pane header; the right pane and the status bar render whichever mode is showing. Nothing in `Chunker`, `PanelSizer`, `HotkeyCoordinator` or the capture path is touched.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, SwiftUI/AppKit, Swift Testing, macOS 14 floor. No external dependencies.

**Spec:** `docs/design/specs/2026-08-07-batch-translation-design.md`. Section references below (§4.1, §7.2 …) point into it.

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

What the queue accepts (§4.1). The interesting decisions are that a mixed drop is *kept* with its refusals named, and the 2 MB ceiling that deliberately differs from `DroppedDocument`'s 256 KB.

**Files:**
- Create: `Sources/TranslatorApp/QueueDrop.swift`
- Test: `Tests/TranslatorAppTests/QueueDropTests.swift`

**Interfaces:**
- Consumes: `DroppedDocument.readableExtensions`.
- Produces: `enum QueueDrop` with `static let maximumBytes: Int`, `struct QueueDrop.Item { let url: URL; let text: String? }`, and `static func accept(_ urls: [URL]) -> [Item]?` — an item's `nil` text means that file could not be read; a `nil` return means nothing in the drop was readable and the whole drop is refused.

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

@Test func aMixedDropKeepsWhatItCanReadAndNamesWhatItCannot() throws {
    // The queue has a slot per file and no ambiguity about intent — the user means all
    // of them — so there is nothing to guess. A spring-back is legible feedback for one
    // file and a riddle for ten: everything returns and nothing says which was refused.
    let scratch = Scratch()
    let good = scratch.file("a.md", "text")
    let bad = scratch.file("b.pdf", "text")
    let accepted = try #require(QueueDrop.accept([good, bad]))

    #expect(accepted.map(\.url) == [good, bad])
    #expect(accepted[0].text == "text")
    #expect(accepted[1].text == nil)   // becomes a visible .unreadable row
}

@Test func aDropWithNothingReadableInItIsRefusedWhole() throws {
    // Only here does the spring-back stay the right answer: there is no row worth
    // making, and eleven refused rows would be a mess rather than an explanation.
    let scratch = Scratch()
    #expect(QueueDrop.accept([scratch.file("a.pdf", "x"), scratch.file("b.key", "y")]) == nil)
}

@Test func aFileOverTheCeilingIsRefusedWithoutBeingRead() throws {
    let scratch = Scratch()
    let huge = scratch.file("huge.md", bytes: QueueDrop.maximumBytes + 1)
    let readable = scratch.file("ok.md", "text")
    let accepted = try #require(QueueDrop.accept([huge, readable]))
    #expect(accepted[0].text == nil)
}

@Test func theCeilingHereIsHigherThanTheTextPanesOnPurpose() {
    // DroppedDocument's 256 KB is justified by what a person waits for *at a window*.
    // The queue has a progress bar, a per-file state and a cancel button, so that
    // reasoning does not carry across — see the spec, §4.1.
    #expect(QueueDrop.maximumBytes > DroppedDocument.maximumBytes)
    #expect(QueueDrop.maximumBytes == 2 * 1024 * 1024)
}

@Test func aFileOfBlankLinesIsNotReadableEitherAndSaysSo() throws {
    let scratch = Scratch()
    let blank = scratch.file("blank.md", "\n\n   \n")
    let readable = scratch.file("ok.md", "text")
    let accepted = try #require(QueueDrop.accept([blank, readable]))
    #expect(accepted[0].text == nil)
}

@Test func anEmptyDropIsRefusedRatherThanAcceptedAsAnEmptyQueue() {
    #expect(QueueDrop.accept([]) == nil)
}

@Test func aFileThatIsNotUTF8IsNotReadable() throws {
    let scratch = Scratch()
    let url = scratch.directory.appendingPathComponent("latin1.md")
    try Data([0xFF, 0xFE, 0xFD]).write(to: url)
    let readable = scratch.file("ok.md", "text")
    let accepted = try #require(QueueDrop.accept([url, readable]))
    #expect(accepted[0].text == nil)
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

    /// One dropped file. A `nil` `text` means it could not be read, and the queue shows
    /// it as an `.unreadable` row rather than discarding it.
    struct Item: Equatable {
        let url: URL
        let text: String?
    }

    /// Everything this drop contributes to the queue, or `nil` if none of it is readable
    /// and the drop should be refused outright.
    ///
    /// **A mixed drop is accepted and its refusals are named.** Ten `.md` files and one
    /// `.pdf` yields eleven items, one of them textless. An earlier version refused the
    /// whole drop on `SourcePane`'s rule that «taking the acceptable ones is a guess
    /// about which was meant» — but that rule is about *one slot and many candidates*,
    /// and a queue has a slot per file and no ambiguity at all. What the transplant cost
    /// is the part that decided it: `dropDestination`'s `Bool` is the entire error
    /// channel here, and a spring-back is legible feedback for one file and a riddle for
    /// ten — everything returns and nothing says which one was the problem.
    ///
    /// `nil` is still `false` at the call site, and still the whole channel, for the one
    /// case where a row would explain nothing: a drop with nothing readable in it.
    static func accept(_ urls: [URL]) -> [Item]? {
        guard !urls.isEmpty else { return nil }
        let items = urls.map { Item(url: $0, text: readable($0)) }
        guard items.contains(where: { $0.text != nil }) else { return nil }
        return items
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

Same extensions, same UTF-8-or-nothing and same blank-file rule as DroppedDocument.
A mixed drop is kept and its refusals are named: SourcePane's «taking the acceptable
ones is a guess about which was meant» is about one slot and many candidates, and a
queue has a slot per file and no ambiguity. What the transplant would have cost is
the deciding part — dropDestination's Bool is the whole error channel, and a
spring-back is legible for one file and a riddle for ten. The drop is refused
outright only when nothing in it is readable.

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
                // `set(nil,)` and not `removeObject(forKey:)`, and the difference is not
                // stylistic. `InMemoryDefaults` — the only defaults these tests are
                // allowed to touch — overrides exactly three methods: `object`, `set`
                // and `string` (`InMemoryDefaults.swift:46-48`). `removeObject` would
                // fall through to the superclass and empty the throwaway backing suite
                // while the in-memory dictionary kept the value, so clearing this
                // setting would appear to do nothing under test and work in production.
                // Assigning `nil` through the overridden `set` removes the key from that
                // dictionary, which is the same effect through the door that is open.
                let stored = (newValue?.isEmpty == false) ? newValue : nil
                defaults.set(stored, forKey: "backgroundModel")
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
}

@Test func thereIsNoPartLineOnceEveryPartIsDone() {
    // The engine's last report arrives with partsDone == partsTotal, a moment before the
    // задание becomes .finished. Clamping it to «часть 7 из 7» would put a sentence about
    // work in progress under a file that has none left; nil lets the row show nothing.
    #expect(RussianCopy.partProgress(done: 7, total: 7) == nil)
    #expect(RussianCopy.partProgress(done: 1, total: 1) == nil)
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
    /// "Перевожу часть 4 из 7" — the running queue row — or nil when there is no next
    /// часть to name.
    ///
    /// Takes `done` and names `done + 1`, because the row is about the часть the user is
    /// *waiting for*, not the ones behind it, and the progress bar beside it is filled
    /// from the same `done`.
    ///
    /// Optional rather than clamped. The engine's final report arrives with
    /// `done == total`, a moment before the задание becomes `.finished`; clamping it
    /// would render «часть 7 из 7» — a sentence claiming work in progress under a file
    /// that has none left. Nil lets the row simply stop saying anything.
    static func partProgress(done: Int, total: Int) -> String? {
        guard done < total else { return nil }
        return "Перевожу часть \(done + 1) из \(total)"
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
    /// Formatted exactly the way `modelSize` does it — `.formatted(.number.locale(…))`
    /// against a pinned `ru_RU` (`RussianCopy.swift:190`) — and deliberately not through
    /// a `NumberFormatter` of its own. Two mechanisms for one convention is how two
    /// numbers side by side in this app come to be spelled two ways, which is the whole
    /// reason these functions live in one file. Pinned to the locale rather than the
    /// user's, for `modelSize`'s reason: the app is Russian whatever the system is set to.
    static func finishedIn(milliseconds: Int) -> String {
        "готово за \(milliseconds.formatted(.number.locale(Locale(identifier: "ru_RU")))) мс"
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

```

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
                          // A scratch URL, never `GlossaryStore()`. Its default is
                          // `GlossaryStore.defaultURL` — the developer's real
                          // ~/Library/Application Support/LocalTranslator/glossary.json
                          // — and a suite that reads a person's own file is the failure
                          // InMemoryDefaults exists to prevent, one directory over.
                          glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
                              .appendingPathComponent("glossary-\(UUID().uuidString).json")),
                          // Saving is Task 7. Here it always succeeds and reports where.
                          save: { job, _ in .success(job.url.appendingPathExtension("ru")) })
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

@MainActor @Test func aFileThatFailsIsNotRetriedWithinTheSameRun() async {
    // The test that catches a re-scanning loop. `run()` must decide its work list once:
    // a loop that re-asked «what is not finished?» after each задание would find the one
    // it had just marked .failed and translate it again, forever, on the main actor.
    //
    // The client answers every call, so a re-scanning implementation **hangs** rather
    // than failing — which is why the assertion is on the call count and why this fixture
    // does not run out of replies. A test that wedges the suite instead of naming the
    // defect is worse than no test.
    let client = QueueClient(replies: ["", "второй"])
    let model = makeModel(client, prefix: "queue-failure")
    model.add([job("a.md", "first"), job("b.md", "second")])

    await model.run()

    if case .failed = model.jobs[0].state {} else { Issue.record("expected the first file to fail") }
    #expect(model.jobs[1].state == .finished)
    #expect(client.callCount == 2)   // one attempt each, not one-and-forever
}

@MainActor @Test func anUnreadableFileIsShownButNeverTranslated() async {
    let client = QueueClient(replies: ["перевод"])
    let model = makeModel(client, prefix: "queue-unreadable")
    var refused = job("broken.pdf", "")
    refused.state = .unreadable
    model.add([refused, job("b.md", "second")])

    await model.run()

    // It stays on screen naming the file the drop could not take, and the queue neither
    // translates it nor retries it on a later run.
    #expect(model.jobs[0].state == .unreadable)
    #expect(model.jobs[1].state == .finished)
    #expect(client.callCount == 1)
}

@MainActor @Test func theSelectionStaysWhereTheUserPutIt() async {
    // The queue must not follow the running file: a user reading a finished translation
    // would have it pulled out from under them, and the status bar already says which
    // file is running.
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let model = makeModel(client, prefix: "queue-selection")
    model.add([job("a.md", "first"), job("b.md", "second")])
    model.selection = model.jobs[1].id

    await model.run()

    #expect(model.selection == model.jobs[1].id)
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
    /// inside the runner.
    ///
    /// **Returns the URL it wrote**, not just success or failure. An earlier version
    /// returned only a problem and let the runner recompute the destination for its
    /// «saved here» link — which asks the filesystem *after* the write, finds the name
    /// now taken, and answers with the next number. The link would have pointed at a
    /// file that does not exist. Only the writer knows where the bytes went.
    private let save: (FileJob, String) -> Result<URL, String>

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
         save: @escaping (FileJob, String) -> Result<URL, String>) {
        self.translator = translator
        self.settings = settings
        self.glossary = glossary
        self.save = save
    }

    func add(_ new: [FileJob]) {
        jobs.append(contentsOf: new)
        if selection == nil { selection = jobs.first?.id }
    }

    /// Turn a drop into заданиями, planning each readable file off the main actor.
    ///
    /// Planning lives here and not in the view for two reasons. It needs
    /// `settings.chunkSize` — a view using the 900 that happens to be its default would
    /// promise «4 части» to a user who set 500 and then serve them seven — and
    /// `Chunker.plan` is a line split plus a `String.count` per block plus sentence
    /// enumeration over oversized ones, which for twenty 2 MB files is not work to do
    /// while the drop animation is still running.
    ///
    /// The count it stores is an estimate the run supersedes: `chunkSize` can change
    /// between the drop and the turn, so the running row draws from
    /// `TranslationProgress.partsTotal` and only the queued row uses this.
    func add(dropped items: [QueueDrop.Item]) async {
        let chunkSize = settings.chunkSize
        let planned = await Task.detached(priority: .userInitiated) {
            items.map { item -> FileJob in
                guard let text = item.text else {
                    var job = FileJob(url: item.url, text: "", partsTotal: 0)
                    job.state = .unreadable
                    return job
                }
                return FileJob(url: item.url, text: text,
                               partsTotal: Chunker.plan(text, maxCharacters: chunkSize).chunks.count)
            }
        }.value
        add(planned)
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

        // **The work list is decided once, here.** `.interrupted` and `.failed` are in it
        // on purpose — resuming retries what did not work, because a queue that steps
        // over a file it failed to translate reports success for work it never performed
        // — and `.unreadable` is not, because there is nothing to retry.
        //
        // Re-scanning instead of snapshotting is a hang, not a slowdown: `.failed` is not
        // `.finished`, so a loop asking «what is unfinished?» after each задание would
        // find the one it had just failed and translate it again, forever, on the main
        // actor. `aFileThatFailsIsNotRetriedWithinTheSameRun` is the guard.
        let pending = jobs.filter { $0.state != .finished && $0.state != .unreadable }.map(\.id)
        for id in pending {
            // Looked up by id rather than carried as an index: `remove(_:)` is refused
            // while running, but nothing here should depend on that from a distance.
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
            if await translate(at: index) { return }
        }
    }

    func cancel() { current?.cancel() }

    /// - Returns: whether the queue should stop here.
    private func translate(at index: Int) async -> Bool {
        let job = jobs[index]
        // The selection is deliberately **not** moved here. Following the running file
        // would yank a finished translation out from under whoever is reading it, and
        // the status bar already says which file is running.
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
                // The writer says where it wrote. Recomputing the destination here would
                // ask the filesystem *after* the write, find the name taken by that very
                // write, and answer with the next number — a «показать в Finder» link
                // pointing at a file that does not exist.
                switch save(job, outcome.final) {
                case .success(let url):
                    result.savedTo = url
                    jobs[index].saveProblem = nil
                case .failure(let problem):
                    jobs[index].saveProblem = problem
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
- Produces: `enum TranslatedFileWriter` with `static func write(_ text: String, beside source: URL, target: Language) -> Result<URL, String>` — the URL it wrote, or a Russian problem to show. Naming and writing are one call precisely so no caller can recompute the destination after the write and get a different answer.

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

@Test func aTranslationIsWrittenAsUTF8BesideItsSourceAndSaysWhere() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("doc.md")
    try Data("source".utf8).write(to: source)

    let written = try TranslatedFileWriter.write("Привет, мир.", beside: source, target: .ru).get()

    #expect(written.lastPathComponent == "doc.ru.md")
    #expect(try String(contentsOf: written, encoding: .utf8) == "Привет, мир.")
}

@Test func theReturnedURLIsWhereTheBytesWentEvenWhenTheFirstNameWasTaken() throws {
    // The whole reason naming and writing are one call. Asking OutputNaming again after
    // the write finds the name taken by that very write and answers with the next
    // number — a «показать в Finder» link pointing at a file that does not exist.
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("doc.md")
    try Data("source".utf8).write(to: source)
    try Data("занято".utf8).write(to: directory.appendingPathComponent("doc.ru.md"))

    let written = try TranslatedFileWriter.write("новый перевод", beside: source, target: .ru).get()

    #expect(written.lastPathComponent == "doc.ru 2.md")
    #expect(try String(contentsOf: written, encoding: .utf8) == "новый перевод")
    // And the file that was already there is untouched.
    #expect(try String(contentsOf: directory.appendingPathComponent("doc.ru.md"),
                       encoding: .utf8) == "занято")
}

@Test func aRefusedWriteComesBackAsARussianSentenceAndNotAnNSErrorDump() throws {
    let denied = URL(fileURLWithPath: "/System/definitely-not-writable/doc.md")
    guard case let .failure(message) = TranslatedFileWriter.write("текст", beside: denied, target: .ru)
    else { Issue.record("expected the write to be refused"); return }
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
    /// Name it and write it, in one call.
    ///
    /// The two are inseparable on purpose. A caller that named the file, wrote it, and
    /// then asked `OutputNaming` again for its «показать в Finder» link would be asking
    /// *after* the write — the name is taken now, by that very write — and would be told
    /// the next number. Only whoever wrote the bytes knows where they went, so only this
    /// function answers.
    ///
    /// - Returns: the URL written, or a Russian sentence to show the user.
    static func write(_ text: String, beside source: URL, target: Language) -> Result<URL, String> {
        let destination = OutputNaming.destination(
            for: source, target: target,
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        do {
            // `.withoutOverwriting` and not a plain write: `OutputNaming` checks for a
            // free name and this writes, and another process can create the file in
            // between. Losing that race must cost a numbered name, not a document.
            try Data(text.utf8).write(to: destination, options: [.withoutOverwriting])
            return .success(destination)
        } catch {
            // The error's own `localizedDescription` is English and names
            // NSCocoaErrorDomain; neither belongs on a Russian screen. The code is
            // logged for diagnosis and the sentence says what to do instead.
            Log.files.error("could not write a translation: \(error.localizedDescription, privacy: .public)")
            return .failure("Не удалось сохранить перевод рядом с исходником. "
                + "Воспользуйтесь кнопкой «Сохранить как…» — это заодно выдаст приложению право на запись.")
        }
    }
}
```

`.withoutOverwriting` throws when the file exists, so the numbered-name path in the second test is `OutputNaming`'s doing and not this function's — which is exactly the split intended: `OutputNaming` picks a free name, the write option makes losing a race to another process safe.

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
### Task 9: One header height, and the source editor as its own view

Behaviour-preserving groundwork, split out from the queue pane deliberately. `PaneHeader` is shared by both panes and is about to hold a control taller than a caption; `SourcePane` is about to lose its header to the window. Neither change should be visible, and doing them in the same commit as a new pane would leave a regression in the shipped window with no way to tell which half caused it.

**Files:**
- Modify: `Sources/TranslatorApp/SourcePane.swift`
- Modify: `Sources/TranslatorApp/MainWindowView.swift`
- Test: none new; the existing suite must stay green at the same count.

**Interfaces:**
- Produces: `PaneHeader(title: String?, action:)` with `static var height: CGFloat`; `struct SourceEditor: View` — the editor, placeholder, footer and text-file drop, with no header of its own.

- [ ] **Step 1: Give `PaneHeader` an optional title and one pinned height**

In `Sources/TranslatorApp/SourcePane.swift`:

```swift
struct PaneHeader<Action: View>: View {
    /// Optional because the left pane's header is about to be a mode switch rather than
    /// a caption, and the right pane's is still a caption. One type, two contents.
    let title: String?
    @ViewBuilder var action: () -> Action

    /// Both panes' headers are pinned to this, and that is the point of the constant.
    /// The row used to size itself from a caption plus 4 pt of padding; the left one is
    /// about to hold a `.small` segmented control, which is taller. Two headers a few
    /// points apart put a visible step in the divider between the panes.
    ///
    /// The number is not measured — nothing here can see a screen. It is the smallest
    /// value that fits a `.small` segmented control with the padding this row already
    /// had, and `docs/OPEN-ITEMS.md` carries it as owed to a pair of eyes.
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

- [ ] **Step 2: Split `SourcePane` into a header-less editor**

Rename the existing `SourcePane` to `SourceEditor` and delete its `PaneHeader` call and its `onClear` parameter — both move to the window in Task 10. Everything else stays exactly as it is: the `ZStack` placeholder, `SourceFooter`, `.frame(minWidth: 280)` and the whole `.dropDestination` block with its comment.

Keep `PaneHeader` in this file. It is used by both panes and moving it now would make this commit's diff look like a reorganisation rather than the two small changes it is.

- [ ] **Step 3: Keep the window compiling and unchanged**

In `MainWindowView.swift`, wrap the editor in the header the pane used to draw itself, so the rendered result is what it was:

```swift
                VStack(alignment: .leading, spacing: 0) {
                    PaneHeader(title: "Исходник") {
                        Button("Очистить") { model.sourceText = "" }
                            .buttonStyle(.link)
                            .disabled(model.sourceText.isEmpty)
                    }
                    SourceEditor(model: model)
                }
```

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS at exactly the previous count. This task adds no test because it adds no behaviour; a failure here means the split changed something it should not have.

- [ ] **Step 5: Verify zero warnings and commit**

```bash
swift build --build-tests 2>&1 | grep -i warning   # expect no output
git add Sources/TranslatorApp/SourcePane.swift Sources/TranslatorApp/MainWindowView.swift
git commit -m "refactor(app): pin one header height and lift the source header to the window

Groundwork for the mode switch, kept in its own commit because none of it should be
visible. PaneHeader takes an optional title and a fixed height: the left header is
about to hold a small segmented control, which is taller than a caption, and two
headers a few points apart put a step in the divider between the panes.

SourceEditor is the old SourcePane without its header. Behaviour is unchanged and
the suite is green at the same count."
```

---

### Task 10: The queue pane and the «Текст / Файлы» switch

§5.1, §5.2. Views, so almost nothing here is testable from this environment — Task 14 records what is owed to a pair of eyes.

**Files:**
- Create: `Sources/TranslatorApp/FileQueuePane.swift`
- Modify: `Sources/TranslatorApp/MainWindowView.swift`
- Modify: `Sources/TranslatorApp/FileQueueModel.swift`
- Test: `Tests/TranslatorAppTests/FileQueueModelTests.swift` (append)

**Interfaces:**
- Consumes: `FileQueueModel.add(dropped:)`, `QueueDrop.accept(_:)`, `RussianCopy.*`.
- Produces: `struct FileQueuePane: View`, `enum SourceMode: String, CaseIterable`, `FileQueueModel.canChangeMode: Bool`.

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

@MainActor @Test func aDroppedFileIsPlannedWithTheUsersChunkSizeAndNotThe900Default() async {
    // The queued row promises «N частей» before anything runs. Planning with the 900 that
    // happens to be the default would promise four to a user who set 500 and serve seven.
    let client = QueueClient(replies: [])
    let model = makeModel(client, prefix: "queue-chunk-size") { $0.chunkSize = 120 }
    let text = String(repeating: "Одно предложение про ресурс и сервер. ", count: 20)

    await model.add(dropped: [QueueDrop.Item(url: URL(fileURLWithPath: "/tmp/a.md"), text: text)])

    let expected = Chunker.plan(text, maxCharacters: 120).chunks.count
    #expect(expected > 1)                       // the fixture actually exercises the split
    #expect(model.jobs[0].partsTotal == expected)
}

@MainActor @Test func anUnreadableItemBecomesARowRatherThanBeingDropped() async {
    let client = QueueClient(replies: [])
    let model = makeModel(client, prefix: "queue-unreadable-row")

    await model.add(dropped: [
        QueueDrop.Item(url: URL(fileURLWithPath: "/tmp/a.md"), text: "текст"),
        QueueDrop.Item(url: URL(fileURLWithPath: "/tmp/b.pdf"), text: nil),
    ])

    #expect(model.jobs.map(\.state) == [.queued, .unreadable])
    #expect(model.jobs[1].partsTotal == 0)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter theModeSwitchIsLockedWhileTheQueueRuns`
Expected: compile failure — no member `canChangeMode`.

- [ ] **Step 3: Add the rule to the model**

In `Sources/TranslatorApp/FileQueueModel.swift`:

```swift
    /// Whether the window may switch between «Текст» and «Файлы» right now.
    ///
    /// A property of the model and not a condition restated in the view, for
    /// `TranslationViewModel.canSwapLanguages`' reason: the control has to answer before
    /// it is pressed, and a view that re-derived the rule would keep offering a switch
    /// for a case added later. One window has one primary button; switching mid-run
    /// would let «Перевести» start a text translation behind a running queue.
    var canChangeMode: Bool { !isRunning }
```

- [ ] **Step 4: Write the pane**

Create `Sources/TranslatorApp/FileQueuePane.swift`:

```swift
// Sources/TranslatorApp/FileQueuePane.swift
import SwiftUI
import TranslationCore

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if queue.jobs.isEmpty {
                dropTarget
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        Text("Нажмите «Перевести», чтобы начать")
                            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 20)
                    }
            } else {
                List(selection: $queue.selection) {
                    ForEach(queue.jobs) { job in
                        FileQueueRow(job: job).tag(job.id)
                    }
                    .onDelete { offsets in
                        offsets.map { queue.jobs[$0].id }.forEach(queue.remove)
                    }
                }
                .listStyle(.inset)
                dropTarget
            }
        }
        .frame(minWidth: 280)
        // Refusing returns `false`, which springs every item back — the same and only
        // error channel `SourcePane` uses. It happens only when nothing in the drop was
        // readable: a mixed drop is accepted and its refusals become visible rows, so
        // the user learns *which* file could not be taken instead of watching ten fly
        // home with no explanation. See `QueueDrop.accept`.
        .dropDestination(for: URL.self) { urls, _ in
            guard queue.canChangeMode, let items = QueueDrop.accept(urls) else { return false }
            // Reading and planning are the model's, off the main actor; this closure
            // only decides *when*, exactly as `SourcePane`'s does.
            Task { await queue.add(dropped: items) }
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
                ProgressView(value: Double(progress.partsDone),
                             total: Double(max(progress.partsTotal, 1)))
                    .progressViewStyle(.linear)
                if let detail = runningDetail(progress) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
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
        case .unreadable: "не удалось прочитать"
        }
    }

    /// Only the two states that are a complaint are tinted. An earlier version branched
    /// and returned `.secondary` from both arms — a switch that pretended to distinguish
    /// cases it did not.
    private var trailingStyle: Color {
        switch job.state {
        case .failed, .unreadable: .orange
        default: .secondary
        }
    }

    /// Nil once every часть is done — `partProgress` returns nil there rather than
    /// claiming «часть 7 из 7» under a file with no work left.
    private func runningDetail(_ progress: TranslationProgress) -> String? {
        guard let part = RussianCopy.partProgress(done: progress.partsDone,
                                                  total: progress.partsTotal) else { return nil }
        guard progress.documentTermCount > 0 else { return part }
        return "\(part) · \(RussianCopy.documentTermCount(progress.documentTermCount))"
    }
}
```

- [ ] **Step 5: Put the switch in the window**

In `MainWindowView.swift`, add `@State private var mode: SourceMode = .text` and `let queue: FileQueueModel`, and replace the header built in Task 9 Step 3:

```swift
                VStack(alignment: .leading, spacing: 0) {
                    // The switch replaces the «Исходник» caption rather than sitting
                    // above it, so both panes still read as one row of chrome — which is
                    // what Task 9 pinned `PaneHeader.height` for.
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
                        FileQueuePane(queue: queue)
                    }
                }
```

`addFiles` runs an `NSOpenPanel` restricted to `DroppedDocument.readableExtensions`, feeds its result through `QueueDrop.accept` and then `queue.add(dropped:)`, so the panel and the drop cannot come to accept different things.

- [ ] **Step 6: Run the suite and check the build**

Run: `swift test` then `swift build --build-tests 2>&1 | grep -i warning`
Expected: PASS at the previous count plus three; no warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslatorApp/FileQueuePane.swift Sources/TranslatorApp/MainWindowView.swift Sources/TranslatorApp/FileQueueModel.swift Tests/TranslatorAppTests/FileQueueModelTests.swift
git commit -m "feat(app): the file queue pane and the «Текст / Файлы» switch

canChangeMode lives on the model, not in the view: one window has one primary
button, and switching mid-run would let «Перевести» start a text translation
behind a running queue.

The drop closure only decides when; reading and planning are the model's, off the
main actor and with the user's own chunkSize — planning with the 900 that happens
to be its default would promise «4 части» to someone who set 500 and serve seven.

A file the drop could not read is a visible row saying so, not a silent omission."
```

---

### Task 11: The primary action follows the mode

§5.5. The gap this closes was invisible in the spec because the sentence «the toolbar is unchanged» is true of its controls and false of its bindings. Without this task the queue cannot be started or stopped at all.

**Files:**
- Modify: `Sources/TranslatorApp/MainWindowView.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift:124-135`, `154-167`
- Test: `Tests/TranslatorAppTests/FileQueueModelTests.swift` (append)

**Interfaces:**
- Consumes: `FileQueueModel`, `TranslationViewModel`.
- Produces: `struct PrimaryAction` — `isRunning: Bool`, `canStart: Bool`, `start: () async -> Void`, `cancel: () -> Void`; `MainWindowView.primaryAction(for:)`; `FileQueueModel` is constructed in `TranslatorApp` and passed to the window.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor @Test func thePrimaryActionInFilesModeDrivesTheQueueAndNotTheTextModel() async {
    let client = QueueClient(replies: ["один"])
    let queue = makeModel(client, prefix: "primary-files")
    queue.add([job("a.md", "first")])
    let text = TranslationViewModel(translator: Translator(client: QueueClient(replies: [])),
                                    settings: AppSettings(defaults: InMemoryDefaults(prefix: "primary-text")),
                                    glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("g-\(UUID().uuidString).json")),
                                    pasteboard: NSPasteboard(name: .init("primary-files")))

    let action = PrimaryAction.forMode(.files, text: text, queue: queue)
    #expect(action.canStart)
    await action.start()

    #expect(queue.jobs[0].state == .finished)
    #expect(text.state == .idle)   // the text model was never touched
}

@MainActor @Test func thePrimaryActionSaysThereIsNothingToStartWhenTheQueueIsEmpty() {
    let queue = makeModel(QueueClient(replies: []), prefix: "primary-empty")
    let text = TranslationViewModel(translator: Translator(client: QueueClient(replies: [])),
                                    settings: AppSettings(defaults: InMemoryDefaults(prefix: "primary-empty-t")),
                                    glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("g-\(UUID().uuidString).json")),
                                    pasteboard: NSPasteboard(name: .init("primary-empty")))

    // An empty queue and an empty source pane are the same statement to the user: there
    // is nothing to translate. The button says so in both modes rather than only one.
    #expect(!PrimaryAction.forMode(.files, text: text, queue: queue).canStart)
    #expect(!PrimaryAction.forMode(.text, text: text, queue: queue).canStart)
}

@MainActor @Test func cancellingInFilesModeStopsTheQueueAndNotTheTextModel() async {
    let client = QueueClient(replies: ["один", "два"], paced: true)
    let queue = makeModel(client, prefix: "primary-cancel")
    queue.add([job("a.md", "first"), job("b.md", "second")])
    let text = TranslationViewModel(translator: Translator(client: QueueClient(replies: [])),
                                    settings: AppSettings(defaults: InMemoryDefaults(prefix: "primary-cancel-t")),
                                    glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("g-\(UUID().uuidString).json")),
                                    pasteboard: NSPasteboard(name: .init("primary-cancel")))
    let action = PrimaryAction.forMode(.files, text: text, queue: queue)

    let run = Task { await action.start() }
    try? await Task.sleep(for: .milliseconds(10))
    action.cancel()
    await run.value

    #expect(queue.jobs[0].state == .interrupted)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter thePrimaryActionInFilesModeDrivesTheQueueAndNotTheTextModel`
Expected: compile failure — `PrimaryAction` is not defined.

- [ ] **Step 3: Write `PrimaryAction`**

In `Sources/TranslatorApp/MainWindowView.swift` (it is the window's rule and has no other consumer):

```swift
/// What «Перевести» / «Отмена» does right now — one answer, read by three controls.
///
/// The toolbar button, the «Перевод» menu's ⌘↩ and its ⌘. all have to agree about which
/// model they are driving, and in «Файлы» that is not the one they were written against:
/// both menu items call the *text* view model directly. Left alone, «Файлы» would have a
/// button that ran an empty text model and returned, no «Отмена» at all, and two dead
/// keyboard shortcuts.
///
/// A value rather than three copies of a condition, for `canSwapLanguages`' reason: a
/// control has to answer before it is pressed, and three restatements of one rule is
/// three places for a fourth mode to be forgotten.
@MainActor
struct PrimaryAction {
    let isRunning: Bool
    let canStart: Bool
    let start: () async -> Void
    let cancel: () -> Void

    static func forMode(_ mode: SourceMode,
                        text: TranslationViewModel,
                        queue: FileQueueModel) -> PrimaryAction {
        switch mode {
        case .text:
            PrimaryAction(
                isRunning: text.state == .running,
                canStart: !text.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                start: { await text.translate() },
                cancel: { text.cancel() })
        case .files:
            PrimaryAction(
                isRunning: queue.isRunning,
                // Same statement in both modes: there is nothing to translate. An
                // `.unreadable` задание is not something to translate either, so it does
                // not light the button on its own.
                canStart: queue.jobs.contains { $0.state != .finished && $0.state != .unreadable },
                start: { await queue.run() },
                cancel: { queue.cancel() })
        }
    }
}
```

- [ ] **Step 4: Read it from all three controls**

In `MainWindowView.toolbar`, replace the `.primaryAction` item:

```swift
        ToolbarItem(placement: .primaryAction) {
            let action = PrimaryAction.forMode(mode, text: model, queue: queue)
            if action.isRunning {
                Button("Отмена") { action.cancel() }
            } else {
                Button("Перевести") { Task { await action.start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!status.isHealthy || !action.canStart)
            }
        }
```

Neither button declares a keyboard shortcut — that comment stays true and stays where it is.

In `TranslatorApp.swift`'s `CommandMenu("Перевод")`, the two items read the same value. The window owns `mode`, so it publishes the current `PrimaryAction` upward through a small `@Observable` holder the app already has access to, or the app computes it from the same inputs — whichever the implementer finds fits; what must not happen is a third spelling of the rule.

**The ⌘. reasoning must survive.** CLAUDE.md records that the panel's own ⌘. works because a *disabled* menu item declines its key equivalent and the key window's handler gets it. That argument depends on when the item is disabled, and this task changes that condition — the item is now disabled unless the **visible mode** is running. Re-read the comment at `TranslatorApp.swift:154-166` before editing and keep its claim true, or update it and say why.

- [ ] **Step 5: Construct the queue where the other models are constructed**

In `TranslatorApp.swift`, beside `translation`:

```swift
    @State private var queue: FileQueueModel
```

built in `init()` from the same `Translator`, `settings` and `glossary`, with
`save: { job, text in TranslatedFileWriter.write(text, beside: job.url, target: ...) }`,
and passed into `MainWindowView(model:queue:glossary:status:…)`.

Third model, same owner. The app owns the models and the scenes read them — the arrangement the window's and the panel's `TranslationViewModel`s already have, and the reason they are two and not one.

- [ ] **Step 6: Run everything, build the bundle, and look**

```bash
swift test
swift build --build-tests 2>&1 | grep -i warning
./Scripts/make-app-bundle.sh && open build/LocalTranslator.app
```

Press «Перевести» in each mode, press ⌘↩ and ⌘. in each mode, and start a hotkey translation and press ⌘. while the panel has focus and the window is idle. **Record what you actually saw** — none of this is reachable from a test.

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslatorApp/MainWindowView.swift Sources/TranslatorApp/TranslatorApp.swift Tests/TranslatorAppTests/FileQueueModelTests.swift
git commit -m "feat(app): the primary action follows the visible mode

Without this the queue could not be started or stopped: the toolbar button reads
the text model's state and both menu items call it directly, so «Файлы» would have
had a button that ran an empty text model and two dead shortcuts.

One PrimaryAction value read by the toolbar and both menu items, rather than three
restatements of one rule — the same reasoning canSwapLanguages is a property for.

FileQueueModel is constructed in TranslatorApp beside the other two models: the app
owns the models, the scenes read them."
```
---

### Task 12: The right pane and the status bar in «Файлы»

§5.3 and §5.4. The right pane is here rather than in Task 10 because both halves read the *selection*, and wiring them from one place is what stops them disagreeing about which задание is on screen.

**Files:**
- Modify: `Sources/TranslatorApp/RunStatusBar.swift`
- Modify: `Sources/TranslatorApp/WarningsView.swift`
- Modify: `Sources/TranslatorApp/MainWindowView.swift`
- Test: `Tests/TranslatorAppTests/FileQueueModelTests.swift` (append)

**Interfaces:**
- Consumes: `RussianCopy.queuePosition(fileIndex:fileTotal:partsDone:partsTotal:)`, `PrimaryAction` (Task 11).
- Produces: `FileQueueModel.statusLine: String?`, `.selectedResult: JobResult?`, `.selectedTitle: String`, `.selectedText: String`.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor @Test func theRightPaneShowsTheSelectedFileAndNotWhicheverIsStreaming() async {
    // Wiring the pane straight to the running file's stream means selecting a finished
    // задание shows somebody else's document under its name — visible the moment it is
    // wrong, and invisible in any test that only ever selects the running file.
    let client = QueueClient(replies: ["первый перевод", "второй перевод"])
    let model = makeModel(client, prefix: "queue-right-pane")
    model.add([job("a.md", "first"), job("b.md", "second")])
    await model.run()

    model.selection = model.jobs[0].id
    #expect(model.selectedText == "первый перевод")
    #expect(model.selectedTitle == "Перевод · a.md")

    model.selection = model.jobs[1].id
    #expect(model.selectedText == "второй перевод")
    #expect(model.selectedTitle == "Перевод · b.md")
}

@MainActor @Test func theRightPaneFallsBackToTheHeaderWithNothingSelected() {
    let model = makeModel(QueueClient(replies: []), prefix: "queue-right-pane-empty")
    #expect(model.selectedText.isEmpty)
    #expect(model.selectedTitle == "Перевод")
}

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
    var selectedResult: JobResult? { selectedJob?.result }

    private var selectedJob: FileJob? { jobs.first { $0.id == selection } }

    /// «Перевод · techdoc-en.md», or the plain header with nothing selected.
    var selectedTitle: String {
        selectedJob.map { "Перевод · \($0.url.lastPathComponent)" } ?? "Перевод"
    }

    /// What the right pane shows: the live stream when the selected задание is the one
    /// running, its stored result otherwise.
    ///
    /// Selection-driven and not stream-driven, deliberately. Wiring the pane to
    /// `streamingText` alone shows the running file's text under the selected file's
    /// name the moment a user clicks a finished задание while the queue carries on —
    /// which is exactly when they are most likely to click one.
    var selectedText: String {
        guard let job = selectedJob else { return "" }
        if case .running = job.state { return streamingText }
        return job.result?.final ?? ""
    }
```

- [ ] **Step 4: Render both halves**

In `RunStatusBar`, add an optional `queue: FileQueueModel?`. When it is non-nil the row's `line` is `queue.statusLine` and the disclosure opens `WarningsView` built from `queue.selectedResult`.

`WarningsView` currently takes a `TranslationOutcome`. Give it a second initialiser taking `checks` and `markupDiffs` directly, and have the existing one forward to it — **do not duplicate the view**, for `TranslationPane`'s reason.

In `MainWindowView`, the right pane now dispatches on mode like the primary action does:

```swift
                TranslationPane(title: mode == .text ? "Перевод" : queue.selectedTitle,
                                text: mode == .text ? model.translatedText : queue.selectedText,
                                isRunning: PrimaryAction.forMode(mode, text: model, queue: queue).isRunning,
                                onCopy: onCopy)
```

`onCopy` copies what the pane is showing, so it dispatches on mode too — copying the text model's translation while the queue's is on screen is the same defect one layer down.

- [ ] **Step 5: Run the suite and commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/TranslatorApp/FileQueueModel.swift Sources/TranslatorApp/RunStatusBar.swift Sources/TranslatorApp/WarningsView.swift Sources/TranslatorApp/MainWindowView.swift Tests/TranslatorAppTests/FileQueueModelTests.swift
git commit -m "feat(app): the right pane and the status bar follow the selection

The pane shows the selected задание — its stored result when finished, the live
stream when it is the one running. Wiring it to the stream alone puts the running
file's text under the selected file's name the moment someone clicks a finished
one, which is exactly when they will.

Parts are counted across the whole queue rather than within the current file: the
sentence is about how much of the queue is left, and a per-file count beside a
per-queue file count would put two scales in one line.

WarningsView gains an initialiser taking checks and diffs directly, and the
outcome-taking one forwards to it — a second copy of that view is how two
surfaces come to describe one run differently."
```

---

### Task 13: The «Файлы» settings tab

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

### Task 14: Documentation

The repo treats documentation drift as a build failure (`Tests/DocumentationTests`). This task is not optional and not last-minute.

**Files:**
- Modify: `CLAUDE.md`, `CONTEXT.md`, `docs/OPEN-ITEMS.md`
- Modify: `docs/design/specs/2026-07-24-local-translator-design.md` (§12)
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

Add the table from spec §11, verbatim, as a new «Owed by the file queue» block. Add the TCC probe (§9.1) to §2 with whatever the bundle runs in Task 11 Step 6 and Task 13 Step 6 actually established — **and nothing they did not**. `PaneHeader.height`'s 28 pt goes here too: it is a chosen number, not a measured one, and it decides whether the two panes read as one row.

- [ ] **Step 5: Spec §12**

`docs/design/specs/2026-07-24-local-translator-design.md` §12's first bullet stops being future tense and points at the new spec.

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

**Spec coverage.** §3.5 → Task 1. §4.1 → Task 3. §4.2, §4.3 → Task 6 and Task 10 Step 3 (planning at drop). §4.4 → Task 2. §4.5 → Task 7. §5.1, §5.2 → Tasks 9 and 10. §5.3 → Task 8 and Task 12. §5.4 → Task 12. §5.5 → **Task 11.** §7 → Task 13. §8 → Task 5. §9.1 → Task 7 (the fallback) and Task 14 (recording it). §9.2 → Task 13 Step 6. §10 → distributed across every task's tests. §11 → Task 14. §3.1–3.4, §6 → **Phase 2, not this plan.**

**Three gaps found and closed after the first draft.** All three came from reviewing the plan against the source rather than against itself:

- The spec's §13 put `onProgress` in Phase 2 while §5.2's queue row depends on it. Corrected in the spec; Task 1 is the result.
- **§5.5 mapped to no task at all**, because «the toolbar is unchanged» was read as «no work». It is true of the toolbar's controls and false of its bindings: the button reads `model.state` and both menu items call the text view model directly (`MainWindowView.swift:83`, `TranslatorApp.swift:162-166`), so «Файлы» would have shipped with no way to start or stop the queue. Task 11 exists for that, and the spec's §5.5 now says the distinction out loud.
- Task 9 was four deliverables in one — header height, editor extraction, new pane, window restructure — two of which change nothing visible. Split so a regression in the shipped window has one commit to blame.

**Defects fixed after checking the plan's own code against the repository.** Each was written confidently and was wrong:

- `run()` re-scanned for «the first задание that is not `.finished`», which re-finds a задание it has just marked `.failed`: an infinite loop on the main actor, and a test that would have hung rather than failed. The work list is a snapshot now, and `aFileThatFailsIsNotRetriedWithinTheSameRun` asserts a call count so it fails instead of wedging.
- The runner recomputed `OutputNaming.destination` after the write to fill in `savedTo` — asking the filesystem after the name had been taken by that very write, so the «saved here» link pointed at a file that does not exist. Naming and writing are one call now, and the writer returns the URL.
- `batchModel = nil` used `removeObject(forKey:)`, which `InMemoryDefaults` does not override (`InMemoryDefaults.swift:46-48`), so clearing the setting would have appeared to do nothing under test and worked in production. It assigns `nil` through the overridden `set` instead.
- The drop planned части with a literal `900`, ignoring `settings.chunkSize`, and did it on the main actor for up to twenty 2 MB files. Planning moved into `FileQueueModel.add(dropped:)`, off the main actor, with the user's own value.
- `finishedIn` grew a `NumberFormatter` beside `modelSize`'s `.formatted(.number.locale(…))` (`RussianCopy.swift:190`) — two mechanisms for one convention, which the same task's own comment forbids.
- The tests built `GlossaryStore()`, whose default URL is the developer's real glossary (`GlossaryStore.swift:67`). Scratch URLs now.
- `FileQueueRow.trailingStyle` returned `.secondary` from both arms of a `switch` — a branch pretending to distinguish cases it did not.
- `partProgress` clamped to «часть 7 из 7», a sentence claiming work in progress under a file with none left. It returns `nil` there.
- `translate(at:)` moved the selection to each file as it started, pulling a finished translation out from under whoever was reading it.

**Type consistency.** Two names were wrong when first written and were checked against the source rather than left as an instruction to check:

- `GlossaryCheck` has no `isHonoured`. It carries `status: GlossaryStatus`, whose cases are `.satisfied`, `.missing`, `.unverifiable` (`GlossaryVerifier.swift:4-10`). `JobResult.warningCount` counts `.missing` only, and Task 6 now says why `.unverifiable` is excluded.
- `Log` has no `app`. Its categories are `hotkey`, `engine`, `settings` (`Log.swift:46-50`), so Task 7 adds a fourth, `files`, with its reasoning.

Other names were taken from files read while planning: `ModelsViewModel.installedNames` (`ModelsViewModel.swift:29`) for Task 13's picker, `GlossaryStore(url:)` and `.glossary`/`.mutedSet` (`GlossaryStore.swift:67,132-133`), `RussianCopy.plural` and `modelSize` (`RussianCopy.swift:64,187-190`), `GlossaryCheck.status` / `GlossaryStatus` (`GlossaryVerifier.swift:4-10`), `Log`'s three categories (`Log.swift:46-50`), `TranslationViewModel.message(for:)`, `Chunker.plan(_:maxCharacters:)`, `AppSettings.targetLanguage(forDetected:)`, `InMemoryDefaults(prefix:)`.

**Placeholder scan.** No "TBD", no "handle errors appropriately", no "similar to Task N". Every code step carries the code. Three steps are deliberately not code — Task 11 Step 6, Task 13 Step 6 and Task 14 Step 4 — because they are «open the bundle and look» and «write down only what you actually saw», which is what this environment's lack of GUI automation makes them.

**One step left as a judgement rather than a line of code**, and named so it is not mistaken for an oversight: Task 11 Step 4 does not spell out how `MainWindowView`'s `mode` reaches the `CommandMenu` in `TranslatorApp`, because the window owns that state and there are two defensible routes. What it does spell out is the constraint that decides the work: there must not be a third spelling of the rule, and the ⌘. comment at `TranslatorApp.swift:154-166` must still be true afterwards.

**Not in this plan, on purpose.** `reviewDocumentTerms` is stored and drawn but disabled; the engine hook, the continuation guarantee and the terms sheet are Phase 2. Phase 1 is shippable without them: the toggle says it is not ready rather than doing nothing.
