# Document-terms review (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user correct the документный глоссарий before the translation that uses it, in all three paths, without ever leaving a run suspended forever.

**Architecture:** One optional `async throws` hook on `Translator.translate`, called once between the term-list call and the per-часть loop. The app bridges it to a human with `DocumentTermsRequest`, a type whose entire job is guaranteeing exactly one resume. The surface is one sheet on the main window; the ⌥⌘T path escalates to that window rather than editing text fields inside a `.nonactivatingPanel`.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, SwiftUI/AppKit, Swift Testing, macOS 14 floor. No external dependencies.

**Spec:** `docs/superpowers/specs/2026-08-07-batch-translation-design.md`, §3.1–3.4, §3.6, §6.

**Depends on Phase 1** (`docs/superpowers/plans/2026-08-07-batch-translation-queue.md`): `FileQueueModel`, `AppSettings.reviewDocumentTerms` and `TranslationProgress` already exist. Do not start this plan until that one is merged and green.

## Global Constraints

Identical to Phase 1's — reproduced here because a task's implementer sees only their own plan.

- **Zero warnings.** `swift build --build-tests` must stay at zero warnings; CI fails on any.
- **Swift language mode `.v6` on every target**, macOS 14 floor.
- **No new dependencies.** Foundation, NaturalLanguage, SwiftUI, AppKit, Observation, ApplicationServices, CoreGraphics, CoreText, ImageIO, Carbon, os, Swift Testing.
- **`TranslationCore` may not import `os`, AppKit or SwiftUI.**
- **Nothing derived from the user's text may be logged** — not a term, not a translation, not a file name.
- **All user-facing strings are Russian**, «guillemets», «ё», no backticks in `Text(String)`.
- **Tests use Swift Testing**, names are sentences. `UserDefaults` tests use `InMemoryDefaults`.
- **Comments carry *why* and the measurement**; «measured» and «load-bearing» mean an observation was made.
- **Commit messages:** conventional, scoped — `feat(core):`, `feat(app):`, `docs(app):`.
- **UI is verified by hand.** Never describe UI behaviour that was not observed.

---

### Task 1: The review hook

§3.1–3.3 and §3.6. The hook itself is small; the tests are the task, and the one that matters most is the one proving nothing changed for callers who pass nothing.

**Files:**
- Modify: `Sources/TranslationCore/Translator.swift`
- Test: `Tests/TranslationCoreTests/TranslatorTests.swift`

**Interfaces:**
- Consumes: `TranslationProgress` (Phase 1), `GlossaryEntry`, `Glossary.relevantEntries(for:)`.
- Produces: `public struct DocumentTermsDraft: Sendable` with `documentEntries: [GlossaryEntry]`, `userEntries: [GlossaryEntry]`, `chunkCount: Int`; a new parameter `reviewDocumentTerms: (@Sendable (DocumentTermsDraft) async throws -> [GlossaryEntry])? = nil`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslationCoreTests/TranslatorTests.swift`:

```swift
@Test func theReviewHookSeesTheParsedTermsAndTheirPartCount() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс\nserver => сервер",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)
    let box = DraftBox()

    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral,
        userGlossary: Glossary(entries: [GlossaryEntry(term: "server", doNotTranslate: true)]),
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { draft in box.record(draft); return draft.documentEntries })

    #expect(box.count == 1)   // once per run, never once per часть
    let draft = try #require(box.value)
    #expect(draft.documentEntries.contains { $0.term.lowercased() == "resource" })
    // The user's own entry travels alongside, because the review shows a «откуда»
    // column and cannot tell the two apart without being told.
    #expect(draft.userEntries.map(\.term) == ["server"])
    #expect(draft.chunkCount == outcome.chunks.count)
}

@Test func editsMadeInTheReviewReachThePrompt() async throws {
    let fake = FakeLLMClient(responses: [
        "resource => ресурс",
        "перевод один", "перевод два", "перевод три", "перевод четыре",
    ])
    let translator = Translator(client: fake)

    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { _ in
            [GlossaryEntry(term: "resource", translations: ["ru": "объект"])]
        })

    // The whole point: what the user typed is what the model is told, for every часть.
    let chunkPrompts = fake.receivedMessages.dropFirst()   // drop the term-list call
    #expect(chunkPrompts.allSatisfy { messages in
        messages.contains { $0.content.contains("объект") }
    })
    #expect(!chunkPrompts.contains { messages in
        messages.contains { $0.content.contains("ресурс") }
    })
    #expect(outcome.documentGlossary.first?.translations["ru"] == "объект")
}

@Test func refusingTheReviewCancelsTheRunRatherThanFailingIt() async throws {
    let fake = FakeLLMClient(responses: ["resource => ресурс", "не должно быть запрошено"])
    let translator = Translator(client: fake)

    await #expect(throws: CancellationError.self) {
        _ = try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            reviewDocumentTerms: { _ in throw CancellationError() })
    }
    // One call made — the term list — and not a single часть requested afterwards.
    #expect(fake.receivedMessages.count == 1)
}

private struct ReviewExploded: Error {}

@Test func anErrorFromTheReviewFailsTheRunRatherThanBeingSwallowed() async throws {
    let fake = FakeLLMClient(responses: ["resource => ресурс", "не должно быть запрошено"])
    let translator = Translator(client: fake)

    await #expect(throws: ReviewExploded.self) {
        _ = try await translator.translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            reviewDocumentTerms: { _ in throw ReviewExploded() })
    }
}

@Test func aSingleChunkRunNeverAsksForAReview() async throws {
    let fake = FakeLLMClient(responses: ["Привет, мир."])
    let translator = Translator(client: fake)
    let box = DraftBox()

    _ = try await translator.translate(
        text: "Hello, world.", target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 900,
        reviewDocumentTerms: { draft in box.record(draft); return draft.documentEntries })

    // No документный глоссарий is built here, so there is nothing to review and a
    // table of nothing would read as a failure.
    #expect(box.count == 0)
}

@Test func aFailedTermListCallSkipsTheReviewInsteadOfShowingAnEmptyTable() async throws {
    let fake = FakeLLMClient(
        responses: ["ignored", "перевод один", "перевод два", "перевод три", "перевод четыре"],
        errors: [FakeTermListFailure()])
    let translator = Translator(client: fake)
    let box = DraftBox()

    let outcome = try await translator.translate(
        text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
        options: ChatOptions(model: "test"), maxChunkCharacters: 200,
        reviewDocumentTerms: { draft in box.record(draft); return draft.documentEntries })

    #expect(box.count == 0)
    // Still swallowed and still recorded — the app is what has to stop being silent
    // about it when the user asked for a gate. See §6.6.
    #expect(outcome.documentGlossaryFailure != nil)
}

@Test func aHookThatChangesNothingChangesNothing() async throws {
    // The pinning test. Two runs of the same input, one with no hook and one with a
    // hook that returns its draft untouched, must agree on everything observable.
    // Comparing the two runs rather than against literals is what makes this survive a
    // change to the fixture: a literal would have to be regenerated and would then pin
    // whatever the code did that day.
    func run(withHook: Bool) async throws -> TranslationOutcome {
        let fake = FakeLLMClient(responses: [
            "resource => ресурс\nserver => сервер",
            "перевод один", "перевод два", "перевод три", "перевод четыре",
        ])
        return try await Translator(client: fake).translate(
            text: multiChunkText, target: .ru, tone: .neutral, userGlossary: nil,
            options: ChatOptions(model: "test"), maxChunkCharacters: 200,
            reviewDocumentTerms: withHook ? { $0.documentEntries } : nil)
    }

    let without = try await run(withHook: false)
    let with = try await run(withHook: true)

    #expect(without.final == with.final)
    #expect(without.translatedChunks == with.translatedChunks)
    #expect(without.chunks.map(\.text) == with.chunks.map(\.text))
    #expect(without.documentGlossary == with.documentGlossary)
    #expect(without.checks == with.checks)
    #expect(without.markupDiffs == with.markupDiffs)
    #expect(without.detectedSource == with.detectedSource)
}

/// See `ProgressBox` for why a lock and not a bare array: the hook is `@Sendable`.
private final class DraftBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DocumentTermsDraft] = []
    func record(_ draft: DocumentTermsDraft) { lock.lock(); storage.append(draft); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    var value: DocumentTermsDraft? { lock.lock(); defer { lock.unlock() }; return storage.first }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter theReviewHookSeesTheParsedTermsAndTheirPartCount`
Expected: compile failure — `DocumentTermsDraft` is not defined.

- [ ] **Step 3: Add the type**

In `Sources/TranslationCore/Translator.swift`, beside `TranslationProgress`:

```swift
/// What a human is shown before the translation that will use it.
///
/// Carries the user's own matching entries as well as the model's, because the review
/// draws a «откуда» column and cannot distinguish the two sources by looking at a
/// `GlossaryEntry`. The user's are context only: `GlossaryMerge.merge(user:document:)`
/// lets a user entry win over a document one, so an edit to a user row would be
/// discarded by the very next thing the engine does.
public struct DocumentTermsDraft: Sendable {
    /// The term-list call's result, parsed. This is what the review edits.
    public let documentEntries: [GlossaryEntry]
    /// `Glossary.relevantEntries(for:)` — the user's entries that occur in this text.
    public let userEntries: [GlossaryEntry]
    /// How many части these terms will be held constant across. The review says this
    /// number out loud, so it comes from the engine that planned them.
    public let chunkCount: Int

    public init(documentEntries: [GlossaryEntry], userEntries: [GlossaryEntry], chunkCount: Int) {
        self.documentEntries = documentEntries
        self.userEntries = userEntries
        self.chunkCount = chunkCount
    }
}
```

- [ ] **Step 4: Add the parameter and call it**

Add to `translate`'s signature, after `onProgress`:

```swift
        reviewDocumentTerms: (@Sendable (DocumentTermsDraft) async throws -> [GlossaryEntry])? = nil
```

Inside the document-glossary block, **after** `documentEntries = DocumentGlossary.parse(...)` and inside the same `do`, before the `catch`es:

```swift
                    // The review point. The term-list stream has finished and no
                    // per-часть request has been issued, so nothing is in flight while
                    // this waits for a human — which is what makes an unbounded
                    // suspension safe here and nowhere else in this function.
                    //
                    // Skipped when there is nothing to review: an empty table reads as
                    // a failure, and the terms-empty case is already covered by the
                    // enclosing `if !terms.isEmpty`.
                    if let reviewDocumentTerms, !documentEntries.isEmpty {
                        let draft = DocumentTermsDraft(
                            documentEntries: documentEntries,
                            userEntries: userGlossary?.relevantEntries(for: text) ?? [],
                            chunkCount: chunks.count)
                        documentEntries = try await reviewDocumentTerms(draft)
                        // A refusal arrives as `CancellationError` and is re-thrown by
                        // the existing `catch let cancellation as CancellationError`
                        // below, so it reaches the caller as a cancellation and not as
                        // a failed enhancement.
                        try Task.checkCancellation()
                    }
```

**This must not be swallowed by the existing `catch`.** The block below turns any non-cancellation error into an empty glossary and a recorded `documentGlossaryFailure` — correct for a failed *model* call, wrong for a hook the app supplied. Restructure so the review's throw escapes: put the review after the `do`/`catch` that owns the network call, guarded on `!documentEntries.isEmpty`, rather than inside it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TranslationCoreTests`
Expected: PASS — the new tests plus every pre-existing one, unchanged, since the parameter defaults to `nil`.

- [ ] **Step 6: Verify zero warnings and commit**

```bash
swift build --build-tests 2>&1 | grep -i warning   # expect no output
git add Sources/TranslationCore/Translator.swift Tests/TranslationCoreTests/TranslatorTests.swift
git commit -m "feat(core): a review point between the term list and the части

Called once, between DocumentGlossary.parse and the per-часть loop — the only
instant where the term-list stream has finished and no часть request has been
issued, so nothing is in flight while it waits for a human.

Refusal is CancellationError, reusing the contract the engine already has rather
than adding a second refusal path. An error from the hook fails the run: the hook
belongs to the app, and the app does not get to invent engine failure modes
quietly, which is why it sits outside the catch that swallows a failed term call.

Defaulted to nil, and a test pins that a hook returning its draft untouched
produces the same run as no hook at all."
```

---

### Task 2: `DocumentTermsRequest` — exactly one resume

§3.4. The whole task exists because the failure it prevents is invisible: not a crash, not an error, a run suspended forever.

**Files:**
- Create: `Sources/TranslatorApp/DocumentTermsRequest.swift`
- Test: `Tests/TranslatorAppTests/DocumentTermsRequestTests.swift`

**Interfaces:**
- Consumes: `DocumentTermsDraft`.
- Produces: `@MainActor final class DocumentTermsRequest` — `init(draft:)`, `var draft: DocumentTermsDraft`, `var entries: [GlossaryEntry]` (editable), `func answer() async throws -> [GlossaryEntry]`, `func proceed()`, `func cancel()`, `var suppressForRun: Bool`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TranslatorAppTests/DocumentTermsRequestTests.swift`:

```swift
import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

@MainActor
private func makeRequest() -> DocumentTermsRequest {
    DocumentTermsRequest(draft: DocumentTermsDraft(
        documentEntries: [GlossaryEntry(term: "resource", translations: ["ru": "ресурс"])],
        userEntries: [],
        chunkCount: 7))
}

@MainActor @Test func proceedingHandsBackWhateverTheUserEdited() async throws {
    let request = makeRequest()
    let waiting = Task { try await request.answer() }
    request.entries = [GlossaryEntry(term: "resource", translations: ["ru": "объект"])]
    request.proceed()

    let answer = try await waiting.value
    #expect(answer.first?.translations["ru"] == "объект")
}

@MainActor @Test func cancellingThrowsCancellationRatherThanReturningNothing() async {
    let request = makeRequest()
    let waiting = Task { try await request.answer() }
    request.cancel()

    await #expect(throws: CancellationError.self) { try await waiting.value }
}

@MainActor @Test func aSecondAnswerAfterProceedingIsIgnoredRatherThanCrashing() async throws {
    // A checked continuation resumed twice traps the process. The sheet's button, Esc
    // and an external cancel can all arrive within one run loop turn, so «at most once»
    // has to be a property of this type and not of the callers' discipline.
    let request = makeRequest()
    let waiting = Task { try await request.answer() }
    request.proceed()
    request.cancel()
    request.proceed()

    _ = try await waiting.value   // must not trap
}

@MainActor @Test func aSecondAnswerAfterCancellingIsIgnoredRatherThanCrashing() async {
    let request = makeRequest()
    let waiting = Task { try await request.answer() }
    request.cancel()
    request.proceed()
    request.cancel()

    await #expect(throws: CancellationError.self) { try await waiting.value }
}

@MainActor @Test func ananswerThatArrivedBeforeAnyoneWaitedIsNotLost() async throws {
    // The queue can cancel a run before the sheet's `answer()` has even been reached.
    // Without this, the continuation is created after the decision and nobody ever
    // resumes it — the exact hang this type exists to make impossible.
    let request = makeRequest()
    request.cancel()

    await #expect(throws: CancellationError.self) { try await request.answer() }
}

@MainActor @Test func suppressingForTheRunIsCarriedOnTheRequestAndDefaultsOff() {
    let request = makeRequest()
    #expect(!request.suppressForRun)
    request.suppressForRun = true
    #expect(request.suppressForRun)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DocumentTermsRequestTests`
Expected: compile failure — `DocumentTermsRequest` is not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/TranslatorApp/DocumentTermsRequest.swift`:

```swift
// Sources/TranslatorApp/DocumentTermsRequest.swift
import Foundation
import Observation
import TranslationCore

/// One question put to the user — «are these the right terms?» — and the guarantee that
/// it is answered exactly once.
///
/// **This type exists for a failure that has no symptom.** The engine's review hook is
/// `async`; the answer comes from a human on the main actor; and cancellation arrives
/// from somewhere else entirely — ⌘., the toolbar's «Отмена», the queue being cleared,
/// the window closing. A checked continuation nobody resumes is not a crash and not an
/// error: it is a run suspended forever, and `Task.checkCancellation()` cannot reach it
/// because it is not running. A continuation resumed *twice* is the opposite failure and
/// traps the process.
///
/// This is the same shape as the trap CLAUDE.md records for `AsyncThrowingStream` —
/// cancellation *finishes* instead of throwing, so «not resumed» looks like nothing
/// happening — and that one already cost this project a truncated document reported as
/// a success. So «exactly once» is a property of this type, checked by tests that drive
/// all four orders, rather than something every call site is trusted to arrange.
@Observable
@MainActor
final class DocumentTermsRequest {
    let draft: DocumentTermsDraft
    /// What the sheet edits. Seeded from the draft's document entries; the user's own
    /// entries are not here because they are not editable — see `DocumentTermsDraft`.
    var entries: [GlossaryEntry]
    /// «Больше не спрашивать в этом прогоне». Lives on the request rather than in
    /// settings because it is a statement about this sitting, not a preference: the
    /// queue reads it after the sheet closes and forgets it when the run ends.
    var suppressForRun = false

    private enum Outcome { case proceed([GlossaryEntry]), cancel }
    /// Set the moment a decision is made, whether or not anyone is waiting yet. A queue
    /// can cancel before `answer()` is reached, and without this the continuation would
    /// be created after the decision and never resumed.
    private var decided: Outcome?
    private var continuation: CheckedContinuation<[GlossaryEntry], Error>?

    init(draft: DocumentTermsDraft) {
        self.draft = draft
        self.entries = draft.documentEntries
    }

    /// The engine's side. Suspends until someone decides.
    func answer() async throws -> [GlossaryEntry] {
        if let decided { return try Self.result(of: decided) }
        return try await withCheckedThrowingContinuation { continuation in
            // Re-checked inside, because a decision can land between the check above
            // and this closure running.
            if let decided {
                continuation.resume(with: Result { try Self.result(of: decided) })
            } else {
                self.continuation = continuation
            }
        }
    }

    func proceed() { finish(.proceed(entries)) }

    func cancel() { finish(.cancel) }

    private func finish(_ outcome: Outcome) {
        // Every call after the first is a no-op, deliberately and silently. The sheet's
        // button, Esc and an external cancel can all arrive within one run loop turn,
        // and the second of them must not trap the process.
        guard decided == nil else { return }
        decided = outcome
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: Result { try Self.result(of: outcome) })
    }

    private static func result(of outcome: Outcome) throws -> [GlossaryEntry] {
        switch outcome {
        case .proceed(let entries): return entries
        // `CancellationError` and not a bespoke type: the engine already treats it as
        // «abort this run», so a refusal travels the path cancellation already has.
        case .cancel: throw CancellationError()
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DocumentTermsRequestTests`
Expected: PASS, 6 tests. If `aSecondAnswerAfterProceedingIsIgnoredRatherThanCrashing` traps rather than fails, the guard is missing — a trap is the defect, not a flaky test.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/DocumentTermsRequest.swift Tests/TranslatorAppTests/DocumentTermsRequestTests.swift
git commit -m "feat(app): DocumentTermsRequest — exactly one resume, guaranteed

The failure this prevents has no symptom: a checked continuation nobody resumes is
not a crash and not an error, it is a run suspended forever that
Task.checkCancellation() cannot reach because it is not running. Resumed twice, it
traps the process instead.

Cancellation arrives from outside the sheet — ⌘., the toolbar, the queue, the
window closing — so «exactly once» is a property of this type, driven by tests
through all four orders, including a decision made before anyone waits."
```

---

### Task 3: The sheet

§6.2, §6.3, §6.4, §6.5.

**Files:**
- Create: `Sources/TranslatorApp/DocumentTermsView.swift`
- Test: `Tests/TranslatorAppTests/DocumentTermsViewTests.swift`

**Interfaces:**
- Consumes: `DocumentTermsRequest`, `GlossaryStore`, `Language`.
- Produces: `struct DocumentTermsView: View`; `enum DocumentTermsRow { case user(GlossaryEntry), document(Int) }`; `DocumentTermsView.rows(for:)` as a static, testable function.

- [ ] **Step 1: Write the failing test**

Create `Tests/TranslatorAppTests/DocumentTermsViewTests.swift`:

```swift
import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

private func draft(document: [GlossaryEntry], user: [GlossaryEntry]) -> DocumentTermsDraft {
    DocumentTermsDraft(documentEntries: document, userEntries: user, chunkCount: 7)
}

@Test func theUsersOwnTermsComeFirstAndAreNotEditable() {
    let rows = DocumentTermsView.rows(for: draft(
        document: [GlossaryEntry(term: "profile", translations: ["ru": "профиль"])],
        user: [GlossaryEntry(term: "StructureDefinition", doNotTranslate: true)]))

    // Read-only first, because they are context for the editable ones below.
    guard case let .user(entry) = rows.first else { Issue.record("expected a user row first"); return }
    #expect(entry.term == "StructureDefinition")
    guard case .document = rows.last else { Issue.record("expected a document row last"); return }
}

@Test func aDocumentTermThatTheUserGlossaryAlreadyCoversIsNotOfferedTwice() {
    // GlossaryMerge lets the user's entry win, so an editable duplicate would accept a
    // change the very next line of the engine discards.
    let rows = DocumentTermsView.rows(for: draft(
        document: [GlossaryEntry(term: "profile", translations: ["ru": "профиль"]),
                   GlossaryEntry(term: "Profile", translations: ["ru": "анкета"])],
        user: [GlossaryEntry(term: "PROFILE", doNotTranslate: true)]))

    #expect(rows.count == 1)
    guard case .user = rows.first else { Issue.record("expected only the user's row"); return }
}

@Test func theHeadlineNamesBothNumbersTheUserNeeds() {
    let d = draft(document: Array(repeating: GlossaryEntry(term: "x"), count: 12), user: [])
    #expect(DocumentTermsView.headline(for: d) == "Термины документа — 12")
    #expect(DocumentTermsView.explanation(for: d)
            == "Они переведены один раз и будут одинаковы во всех 7 частях. "
             + "Исправьте то, что переведено не так, — перевод ещё не начался.")
}

@Test func theSourceColumnNamesWhereEachRowCameFrom() {
    #expect(DocumentTermsView.origin(.user(GlossaryEntry(term: "x"))) == "глоссарий")
    #expect(DocumentTermsView.origin(.document(0)) == "документ")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DocumentTermsViewTests`
Expected: compile failure — `DocumentTermsView` is not defined.

- [ ] **Step 3: Write the view**

Create `Sources/TranslatorApp/DocumentTermsView.swift`. The four static functions above hold every decision; the `body` is a `Form` that renders them.

```swift
// Sources/TranslatorApp/DocumentTermsView.swift
import SwiftUI
import TranslationCore

/// One row of the review: either the user's own entry, shown for context, or an index
/// into the request's editable entries.
///
/// An index and not a copy for the document case, because the field writes through a
/// binding into `DocumentTermsRequest.entries` and a copied entry would edit a value
/// nobody reads.
enum DocumentTermsRow: Equatable {
    case user(GlossaryEntry)
    case document(Int)
}

/// «Термины документа» — the документный глоссарий, before the translation that uses it.
struct DocumentTermsView: View {
    @Bindable var request: DocumentTermsRequest
    let target: Language
    /// Non-nil only in a queue run, which is the only place «больше не спрашивать»
    /// means anything.
    let showsSuppress: Bool
    let onAddToGlossary: () -> Void

    static func headline(for draft: DocumentTermsDraft) -> String {
        "Термины документа — \(draft.documentEntries.count)"
    }

    static func explanation(for draft: DocumentTermsDraft) -> String {
        "Они переведены один раз и будут одинаковы во всех \(draft.chunkCount) "
            + "\(RussianCopy.plural(draft.chunkCount, "части", "частях", "частях")). "
            + "Исправьте то, что переведено не так, — перевод ещё не начался."
    }

    static func origin(_ row: DocumentTermsRow) -> String {
        switch row {
        case .user: "глоссарий"
        case .document: "документ"
        }
    }

    /// The user's entries first, then the model's — and a model entry whose term the
    /// user's glossary already covers is dropped rather than shown twice.
    ///
    /// `GlossaryMerge.merge(user:document:)` lets the user's entry win, so an editable
    /// duplicate would take a change that the engine discards on the very next line.
    /// Compared case-insensitively, because `merge` does.
    static func rows(for draft: DocumentTermsDraft) -> [DocumentTermsRow] {
        let covered = Set(draft.userEntries.map { $0.term.lowercased() })
        return draft.userEntries.map { DocumentTermsRow.user($0) }
            + draft.documentEntries.enumerated()
                .filter { !covered.contains($0.element.term.lowercased()) }
                .map { DocumentTermsRow.document($0.offset) }
    }

    var body: some View { /* Form over `Self.rows(for: request.draft)`; see below. */ }
}
```

The `body` renders, in order:

1. `Text(Self.headline(for: request.draft))` in `.headline`, `Text(Self.explanation(for: request.draft))` in `.caption`/`.secondary`.
2. A header row — «термин», «перевод», «откуда» — then one row per `Self.rows(for:)`. A `.user` row's «перевод» is `Text(entry.doNotTranslate ? "не переводить" : entry.requiredTranslation(for: target) ?? "")` in `.secondary`; a `.document(index)` row's is a `TextField` bound to `request.entries[index].translations[target.rawValue]`.
3. If `showsSuppress`, `Toggle("Больше не спрашивать в этом прогоне", isOn: $request.suppressForRun)`.
4. A footer: `Button("Добавить в пользовательский глоссарий", action: onAddToGlossary).buttonStyle(.link)`, a `Spacer`, and one primary `Button("Перевести") { request.proceed() }.keyboardShortcut(.defaultAction)`.

**One button, not the drawing's two.** «Переводить без правок» beside «Перевести» is indistinguishable from it before any edit and silently discards work after one. Esc — `.keyboardShortcut(.cancelAction)` on a hidden cancel, or the sheet's own dismissal — calls `request.cancel()`, and that is the whole escape.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DocumentTermsViewTests`
Expected: PASS, 4 tests.

`RussianCopy.plural` is already `static` and internal (`RussianCopy.swift:64`), so `explanation` can call it directly — checked, not assumed.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp/DocumentTermsView.swift Tests/TranslatorAppTests/DocumentTermsViewTests.swift
git commit -m "feat(app): the «Термины документа» sheet

Every decision is a static function so it can be tested without rendering: which
rows exist, in what order, and what the two sentences say.

A model term the user's glossary already covers is dropped rather than shown as a
second editable row — GlossaryMerge lets the user's entry win, so editing the
duplicate would take a change the engine discards on the next line.

One primary button, not the drawing's two: «Переводить без правок» beside
«Перевести» is indistinguishable before any edit and silently discards work after
one. Esc is the escape and it cancels the run."
```

---

### Task 4: Wiring the three paths

§6.1 and §6.6.

**Files:**
- Modify: `Sources/TranslatorApp/TranslationViewModel.swift`
- Modify: `Sources/TranslatorApp/FileQueueModel.swift`
- Modify: `Sources/TranslatorApp/MainWindowView.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift`
- Modify: `Sources/TranslatorApp/SettingsFilesView.swift`
- Test: `Tests/TranslatorAppTests/TranslationViewModelTests.swift`, `FileQueueModelTests.swift`

**Interfaces:**
- Produces: `TranslationViewModel.pendingTermsRequest: DocumentTermsRequest?`, `FileQueueModel.pendingTermsRequest: DocumentTermsRequest?`, `TranslationViewModel.documentTermsUnavailable: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslatorAppTests/TranslationViewModelTests.swift`:

```swift
/// Never `GlossaryStore()`: its default is `GlossaryStore.defaultURL`, the developer's
/// real ~/Library/Application Support/LocalTranslator/glossary.json. A suite that reads
/// a person's own file is the failure `InMemoryDefaults` exists to prevent, one
/// directory over.
private func scratchGlossary() -> GlossaryStore {
    GlossaryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("glossary-\(UUID().uuidString).json"))
}

@MainActor @Test func theTermsGateIsSkippedEntirelyWhenTheSettingIsOff() async {
    let client = ScriptedClient(replies: ["resource => ресурс", "перевод"])
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "gate-off"))
    #expect(!settings.reviewDocumentTerms)
    let model = TranslationViewModel(translator: Translator(client: client),
                                     settings: settings, glossary: scratchGlossary(),
                                     pasteboard: NSPasteboard(name: .init("gate-off")))
    model.sourceText = String(repeating: "The resource is published. ", count: 60)

    await model.translate()

    #expect(model.pendingTermsRequest == nil)
    #expect(model.state == .finished)
}

@MainActor @Test func cancellingTheSheetLeavesTheRunInterruptedAndNotWedged() async {
    let client = ScriptedClient(replies: ["resource => ресурс", "перевод"])
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "gate-cancel"))
    settings.reviewDocumentTerms = true
    let model = TranslationViewModel(translator: Translator(client: client),
                                     settings: settings, glossary: scratchGlossary(),
                                     pasteboard: NSPasteboard(name: .init("gate-cancel")))
    model.sourceText = String(repeating: "The resource is published. ", count: 60)

    let run = Task { await model.translate() }
    while model.pendingTermsRequest == nil { await Task.yield() }
    model.pendingTermsRequest?.cancel()
    await run.value

    #expect(model.state == .interrupted)
    // The sheet must go away with the run that raised it, or the window keeps a modal
    // over a translation that is already over.
    #expect(model.pendingTermsRequest == nil)
}

@MainActor @Test func aFailedTermListStopsBeingSilentOnceTheUserAskedForTheGate() async {
    let client = ScriptedClient(replies: ["", "перевод"], failCallAtIndex: 0)
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "gate-term-failure"))
    settings.reviewDocumentTerms = true
    let model = TranslationViewModel(translator: Translator(client: client),
                                     settings: settings, glossary: scratchGlossary(),
                                     pasteboard: NSPasteboard(name: .init("gate-term-failure")))
    model.sourceText = String(repeating: "The resource is published. ", count: 60)

    await model.translate()

    // The user waited for a gate that never opened; staying quiet about it would let
    // the run's terminology differ from what they were promised, invisibly.
    #expect(model.documentTermsUnavailable)
    #expect(model.state == .finished)
}
```

`ScriptedClient` may need a `failCallAtIndex:` parameter — add it in the same shape `FakeLLMClient.errors` already uses, rather than inventing a third mechanism.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter theTermsGateIsSkippedEntirelyWhenTheSettingIsOff`
Expected: compile failure — no member `pendingTermsRequest`.

- [ ] **Step 3: Wire `TranslationViewModel`**

Add the two properties and pass the hook only when the setting is on:

```swift
    /// The sheet the window is showing, or nil. Cleared in the same `defer` that ends
    /// the run, so a cancelled or failed run cannot leave a modal over a window that
    /// has already finished.
    private(set) var pendingTermsRequest: DocumentTermsRequest?
    /// The user asked for the gate and it could not be prepared. Reset at the top of
    /// every run, beside the other per-run state.
    private(set) var documentTermsUnavailable = false
```

In `translate()`, build the hook as:

```swift
        // Only when asked for. A nil hook is byte-for-byte the behaviour that shipped,
        // which is what the engine's pinning test guarantees.
        let review: (@Sendable (DocumentTermsDraft) async throws -> [GlossaryEntry])? =
            settings.reviewDocumentTerms
            ? { [weak self] draft in
                  guard let self else { throw CancellationError() }
                  return try await self.askAboutTerms(draft)
              }
            : nil
```

with

```swift
    private func askAboutTerms(_ draft: DocumentTermsDraft) async throws -> [GlossaryEntry] {
        let request = DocumentTermsRequest(draft: draft)
        pendingTermsRequest = request
        // The request resumes exactly once whichever way this ends, so the `defer` is
        // about the *sheet*, not about the continuation — clearing it here is what
        // stops a cancelled run leaving a modal on screen.
        defer { pendingTermsRequest = nil }
        return try await request.answer()
    }
```

and `documentTermsUnavailable` set after the run from
`settings.reviewDocumentTerms && result.documentGlossaryFailure != nil`.

`cancel()` gains `pendingTermsRequest?.cancel()` before `task?.cancel()`, so ⌘. reaches a run that is waiting on a human rather than on the network.

- [ ] **Step 4: Wire `FileQueueModel`**

The same shape, plus §6.4: after each sheet closes, if `request.suppressForRun` was ticked, set a private `suppressTermsForThisRun = true` that makes the hook return `draft.documentEntries` without ever showing a sheet. Reset it at the top of `run()`, because it is a statement about this sitting.

`cancel()` gains `pendingTermsRequest?.cancel()` for the same reason.

- [ ] **Step 5: Present the sheet and wire the escalation**

`MainWindowView` gains one `.sheet(item:)` fed by whichever of the two models has a pending request. For the ⌥⌘T path, `HotkeyCoordinator`'s panel model raises its request, and `TranslatorApp` observes it: open the main window if closed, bring it forward with the same cooperative activation `activateThisApp()` already uses, and present the sheet there.

Do not build a second sheet for the panel. One surface, three raisers.

- [ ] **Step 6: Enable the toggle**

In `SettingsFilesView`, remove the `.disabled(true)` Phase 1 put on «Показывать перед переводом», and add beneath it: «Работает везде, где перевод длиннее одной части, — и в окне, и по сочетанию клавиш. Для выделения по клавише окно выйдет на передний план.»

That sentence is not decoration: it is the only warning a user gets that ⌥⌘T may raise a window, and §7.3 ships the toggle off precisely because that is a surprise.

- [ ] **Step 7: Run everything and commit**

```bash
swift test
swift build --build-tests 2>&1 | grep -i warning
```

```bash
git add Sources/TranslatorApp Tests/TranslatorAppTests
git commit -m "feat(app): the terms gate in all three paths

One sheet, three raisers. The hook is passed only when the setting is on, so with
it off the engine takes the nil path its pinning test covers.

The ⌥⌘T path escalates to the main window rather than editing text fields inside
a .nonactivatingPanel, which is unverified territory and the rarest of the three
routes — see the spec, §6.1. A queue asks once if «больше не спрашивать» is
ticked, because thirteen files would otherwise mean thirteen sheets in exactly
the scenario the gate was designed for.

cancel() now reaches a run waiting on a human, not only one waiting on the
network, and the sheet is cleared with the run that raised it."
```

---

### Task 5: «Добавить в пользовательский глоссарий»

§6.5's second half.

**Files:**
- Modify: `Sources/TranslatorApp/DocumentTermsView.swift`, `MainWindowView.swift`
- Test: `Tests/TranslatorAppTests/GlossaryStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func promotingDocumentTermsAddsTheEditedFormAndNotTheModelsOriginal() throws {
    let store = GlossaryStore(url: scratchGlossaryURL())
    try store.load()
    let added = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "profile", translations: ["ru": "профиль"])],
        to: store.glossary)
    #expect(added.contains { $0.term == "profile" && $0.translations["ru"] == "профиль" })
}

@Test func promotingATermTheGlossaryAlreadyHasLeavesTheUsersOwnVersionAlone() throws {
    let store = GlossaryStore(url: scratchGlossaryURL())
    try store.load()
    let existing = Glossary(entries: [GlossaryEntry(term: "profile", doNotTranslate: true)])
    let added = GlossaryPromotion.entries(
        adding: [GlossaryEntry(term: "Profile", translations: ["ru": "анкета"])],
        to: existing)
    // The user's own entry is the authority; promoting must not quietly retranslate it.
    #expect(added.count == 1)
    #expect(added[0].doNotTranslate)
}
```

Adjust `GlossaryStore`'s initialiser and the scratch-URL helper to whatever `GlossaryStoreTests` already uses — do not invent a second fixture.

- [ ] **Step 2–4: Implement `GlossaryPromotion.entries(adding:to:)`, run the tests, and wire the button**

The button calls it, writes the result into `GlossaryStore`, and saves through the same three-error handling `MainWindowView.mute` already has — `saveBeforeLoad`, `fileChangedOnDisk`, everything else — reusing those exact sentences rather than writing new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranslatorApp Tests/TranslatorAppTests
git commit -m "feat(app): promote reviewed terms into the user's glossary

A term the glossary already has is left alone: the user's entry is the authority
and promoting must not quietly retranslate it. Saving reuses MainWindowView.mute's
three failure sentences verbatim — two spellings of one failure is how they drift."
```

---

### Task 6: Documentation

- [ ] **Step 1: `CLAUDE.md`**

The pipeline description gains the review point and the fact that a hook may suspend the engine there — with the reason it is safe only there. The «Cancellation must be checked explicitly» paragraph gains the continuation trap as its third instance. `AppSettings.reviewDocumentTerms` stops being «read by nothing».

- [ ] **Step 2: `docs/PLATFORM-TRAPS.md`**

Add the continuation trap under a «suspending on a human» heading, pointing at `DocumentTermsRequest.swift`, and add the *unrun* probe from spec §9.3 — editable text fields in a `.nonactivatingPanel` — recorded as the reason the escalation exists rather than as a gap.

- [ ] **Step 3: `docs/OPEN-ITEMS.md`**

Add spec §11's terms-sheet rows: the table at 12 rows, an editable «перевод» cell, Esc cancelling the run, and the ⌥⌘T escalation bringing the window forward from another app.

- [ ] **Step 4: Spec status**

Change the design document's `Status:` line to `implemented`, and add the standard note that where it and the code disagree the code is right.

- [ ] **Step 5: Run everything and commit**

```bash
swift test
git add CLAUDE.md docs/
git commit -m "docs: the document-terms review

The continuation trap joins the cancellation paragraph as its third instance, and
PLATFORM-TRAPS records the probe that was deliberately not run — editable fields
in a nonactivating panel — as the reason the ⌥⌘T path escalates instead."
```

---

## Self-review

**Spec coverage.** §3.1 → Task 1 Step 4. §3.2 → Task 1 Step 3. §3.3 → Task 1. §3.4 → Task 2. §3.6 → Task 1's `aHookThatChangesNothingChangesNothing`. §6.1 → Task 4 Step 5. §6.2 → Task 3. §6.3 → Task 3 Step 3. §6.4 → Task 4 Step 4. §6.5 → Task 3 (`rows`) and Task 5 (promotion). §6.6 → Task 4. §9.3 → Task 6 Step 2, recorded as deliberately not run. §11 → Task 6 Step 3.

**Type consistency.** `DocumentTermsDraft`, `DocumentTermsRequest`, `DocumentTermsRow`, `DocumentTermsView`, `pendingTermsRequest`, `documentTermsUnavailable`, `suppressForRun` are spelled identically everywhere they appear. `CancellationError` is the refusal in Task 1, Task 2 and Task 4 — one contract, three places.

**Placeholder scan.** No "TBD" and no "handle errors appropriately". Three steps deliberately describe rather than show code — Task 3's `body`, Task 4 Step 5's sheet presentation and Task 5 Step 2–4 — because each is a SwiftUI layout whose correctness cannot be established from here anyway, and pinning a layout in a plan that a human must then look at would be false precision. Every decision *inside* them is a tested static function.

**One thing this plan asks the implementer to check rather than assume:** `ScriptedClient` may need a failure mechanism (Task 4 Step 1), and the step says what to do. `RussianCopy.plural`'s visibility was a second such caveat and has been resolved by reading the file — it is `static` and internal (`RussianCopy.swift:64`).

**Known and deliberately left for a later pass:** `documentTermsUnavailable` (§6.6) is wired for `TranslationViewModel` only. The queue path can hit the same case — the user turned the gate on, the term-list call failed, no sheet appears — and says nothing about it. It is one property and one row on `FileQueueModel`, and it is called out here rather than folded in silently so that skipping it stays a choice.

**Risk to watch.** Task 1 Step 4's restructuring is the sharpest edit in either phase: the review must sit *outside* the `catch` that swallows a failed term-list call, or a hook that throws would be silently converted into an empty glossary and the run would continue. `anErrorFromTheReviewFailsTheRunRatherThanBeingSwallowed` is the test that catches it, and it should be run before and after the restructure rather than only after.
