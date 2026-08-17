# Code Protection by Construction + Style Unblock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fenced code never reaches the model (pass-through chunks), inline code is restored from source bytes after the reply, and the правка styles are unblocked by removing the voice/register contradiction — every claim proven by a live measurement.

**Architecture:** All engine changes live in `TranslationCore` (`Chunker`, `Translator`, `MarkupSkeleton`, `Proofreading`, `PromptBuilder`); the app layer changes two guard conditions in `TranslationViewModel`; the acceptance harness migrates one classification. Measurements reuse the existing acceptance harness and the правка scratchpad runner.

**Tech Stack:** Swift 6 / SwiftPM, Swift Testing (`@Test`, `#expect`), live Ollama at `http://127.0.0.1:11434` (`aya-expanse:8b`).

**Spec:** `docs/design/specs/2026-08-10-code-protection-and-styles-design.md` — read §2 (Part A) before Tasks 1–5, §3 (Part B) before Tasks 6–8.

## Global Constraints

- Branch: `worktree-proofreading` (worktree at `.claude/worktrees/proofreading`); run all commands from that worktree root.
- Zero warnings: `swift build --build-tests` must print none (grep `warning:` — plain `-i warning` also matches the filenames `WarningsView*.swift`).
- `swift test` passes fully offline; no offline test touches the network.
- `swift run acceptance` runs from the worktree root, needs live Ollama, takes minutes — 10-minute timeout, never abort it.
- `docs/BASELINE.md` and `docs/OPEN-ITEMS.md` §5 are append-only records.
- Comments carry *why* + the measurement; «measured»/«load-bearing» is a contract.
- The правка corpus/runner live ONLY in the session scratchpad, never in the repo. Scratchpad root (referred to as `$SCRATCH` below — substitute the literal path):
  `/private/tmp/claude-501/-Users-dmitriy-Documents-Projects-local-translator/529d224b-873c-437a-b0cb-eb2afe8fb11f/scratchpad`
- Tests: Swift Testing, sentence-style names; never restate the assembly formula — call `ChunkPlan.assembled(from:)`; `InMemoryDefaults` for `UserDefaults`.
- Commit messages: conventional, scoped; end every commit message with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01Na6nWHn61E2vGWZUP6Bra7`

---

### Task 1: `Chunk.passthrough` — fenced blocks never merge

**Files:**
- Modify: `Sources/TranslationCore/Chunker.swift` (the `Chunk` struct ~line 4–27; the pieces→chunks merge loop ~line 126–170)
- Modify: `Sources/TranslationCore/Translator.swift:632` (one argument)
- Test: `Tests/TranslationCoreTests/ChunkerTests.swift`, `Tests/TranslationCoreTests/TranslatorTests.swift:142`

**Interfaces:**
- Produces: `Chunk.passthrough: Bool` — REPLACES `containsCodeFence` (the property is renamed and its meaning narrows: `true` exactly when the chunk IS a fenced block, standing alone). Tasks 2 and 4 consume `chunk.passthrough`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslationCoreTests/ChunkerTests.swift`:

```swift
@Test func aFencedBlockBecomesItsOwnPassthroughChunkAndNeverMerges() {
    // Today this document packs into ONE chunk (both separators are exactly one blank
    // line, total under budget). The spec's §2.1 changes that deliberately: the fence
    // stands alone and never reaches the model.
    let text = "Пролог.\n\n```swift\nlet x = 1\n```\n\nЭпилог."
    let plan = Chunker.plan(text, maxCharacters: 900)
    #expect(plan.chunks.count == 3)
    #expect(plan.chunks.map(\.passthrough) == [false, true, false])
    #expect(plan.chunks[1].text == "```swift\nlet x = 1\n```")
    // The byte-lossless invariant survives the new boundaries.
    #expect(plan.assembled(from: plan.chunks.map(\.text)) == text)
}
```

- [ ] **Step 2: Run it — expect a compile failure**

Run: `swift test --filter aFencedBlockBecomesItsOwnPassthroughChunkAndNeverMerges`
Expected: FAIL to compile (`passthrough` does not exist). That is the failing state for a renamed property.

- [ ] **Step 3: Implement**

In `Chunk`, replace `public let containsCodeFence: Bool` with:

```swift
/// True exactly when this chunk IS a fenced code block, standing alone. A passthrough
/// chunk never reaches the model: `Translator` copies its bytes verbatim (spec §2.1 —
/// protection by construction, DeepL/LanguageTool precedent). Replaces
/// `containsCodeFence`, whose only load-bearing consumer was the fence-unwrap
/// suppression — moot now that a model-bound chunk cannot contain a fence.
public let passthrough: Bool
```

In the merge loop, a `fencedCode` piece flushes whatever is open, forms its own chunk, and flushes again — it merges with nothing in either direction (rename `currentHasFence` to `currentIsPassthrough`):

```swift
for piece in pieces {
    precondition(!piece.text.isEmpty, "Chunker: a piece must carry content")
    if piece.kind == .fencedCode {
        // Never merged, in either direction (spec §2.1): the model must not see it,
        // and prose after it must not inherit its chunk.
        flush()
        currentSeparator = piece.separatorBefore
        current = piece.text
        currentIsPassthrough = true
        flush()
    } else if !current.isEmpty, LineScanner.isExactlyOneBlankLine(piece.separatorBefore),
              current.count + piece.separatorBefore.count + piece.text.count <= maxCharacters {
        current += piece.separatorBefore + piece.text
    } else {
        flush()
        currentSeparator = piece.separatorBefore
        current = piece.text
        currentIsPassthrough = false
    }
}
```

(The `|| piece.kind == .fencedCode` accumulation disappears with the branch; `flush()` writes `passthrough: currentIsPassthrough` and resets it to `false`.)

In `Translator.swift:632`, `allowFenceUnwrap: !chunk.containsCodeFence` becomes `allowFenceUnwrap: true` with the comment updated in place:

```swift
// Unconditional since pass-through chunks: a model-bound chunk cannot contain a
// fence (Chunker isolates fenced blocks, spec §2.1), so a fence opening the reply
// is always the model's own wrapper.
```

- [ ] **Step 4: Migrate the existing pins — their meaning changes, say so**

`ChunkerTests.swift:21,39,58` and `TranslatorTests.swift:142` read `containsCodeFence`. Rename to `passthrough` AND re-check each test's expectations against the new chunking: any test that pinned «a fence merged with prose across one blank line» now pins the opposite (more chunks). Update expected chunk counts/texts to the new behaviour — the assembled-bytes invariant in those tests must keep passing untouched. If a test's whole point was the accumulation through merges, rewrite its name and body to pin isolation instead.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS — including Step 1's test and every migrated pin.

- [ ] **Step 6: Zero warnings, commit**

Run: `swift build --build-tests 2>&1 | grep "warning:" || echo CLEAN` → `CLEAN`

```bash
git add Sources/TranslationCore/Chunker.swift Sources/TranslationCore/Translator.swift Tests/TranslationCoreTests/ChunkerTests.swift Tests/TranslationCoreTests/TranslatorTests.swift
git commit -m "feat(core): fenced blocks become standalone passthrough chunks"
```

---

### Task 2: `Translator` skips the model for pass-through chunks; `modelChunkCount`

**Files:**
- Modify: `Sources/TranslationCore/Translator.swift` — the `translate` per-chunk loop, the `proofread` per-chunk loop (~line 437–489), the glossary trigger (~line 220), both `TranslationOutcome` constructions
- Modify: `Sources/TranslationCore/TranslationOutcome.swift` (or wherever `TranslationOutcome` is declared — find with `grep -rn "struct TranslationOutcome" Sources/`)
- Test: `Tests/TranslationCoreTests/TranslatorTests.swift`, `Tests/TranslationCoreTests/ProofreaderTests.swift`

**Interfaces:**
- Consumes: `Chunk.passthrough` (Task 1).
- Produces: `TranslationOutcome.modelChunkCount: Int` — the number of chunks that were model-bound. Task 3 (view model) and Task 5 (acceptance) consume it. All other outcome fields keep their meaning; `translatedChunks` stays aligned index-for-index with `chunks` (a pass-through entry is the source bytes).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslationCoreTests/TranslatorTests.swift` (follow the file's existing harness shape — `FakeLLMClient(responses:)`, `Translator(client:)`, `ChatOptions(model: "fake")`):

```swift
@Test func aPassthroughChunkNeverReachesTheModelAndItsBytesArriveVerbatim() async throws {
    let source = "Пролог.\n\n```swift\nlet зц = 1 // нарочно с опечаткой\n```\n\nЭпилог."
    let fake = FakeLLMClient(responses: ["Prologue.", "Epilogue."])
    let translator = Translator(client: fake)
    var streamed = ""
    let outcome = try await translator.translate(
        text: source, target: .en, tone: .neutral,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: { streamed += $0 })
    // The strong pin (docs/TESTING.md shape): not merely «two calls», but «no message
    // ever sent to the model contains the fenced bytes» — a call-count pin alone
    // survives the defect «called, with the wrong chunk».
    for messages in fake.receivedMessages {
        for message in messages {
            #expect(!message.content.contains("let зц = 1"))
        }
    }
    #expect(fake.receivedMessages.count == 2)
    #expect(outcome.final.contains("```swift\nlet зц = 1 // нарочно с опечаткой\n```"))
    #expect(streamed == outcome.final)
    #expect(outcome.modelChunkCount == 2)
}

@Test func anAllCodeDocumentSucceedsWithoutAModelCallAndNilTTFT() async throws {
    let source = "```sh\nls -la\n```"
    let fake = FakeLLMClient(responses: [])
    let translator = Translator(client: fake)
    var streamed = ""
    let outcome = try await translator.translate(
        text: source, target: .ru, tone: .neutral,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: { streamed += $0 })
    #expect(fake.receivedMessages.isEmpty)
    #expect(outcome.final == source)
    #expect(streamed == source)
    #expect(outcome.modelChunkCount == 0)
    #expect(outcome.timeToFirstTokenMS == nil)   // nil keeps meaning «no model emission»
    #expect(outcome.stats.isEmpty)
}

@Test func aDocumentGlossaryIsNeverAttemptedBelowTwoModelBoundChunks() async throws {
    // Fence + one paragraph = 2 chunks but only 1 model-bound: no term-list call may
    // fire (Translator.swift:220 counted raw chunks before; spec §2.1 renegotiates).
    let source = "```sh\nls\n```\n\nParagraph about the listing command and its flags."
    let fake = FakeLLMClient(responses: ["Абзац про команду вывода списка."])
    let translator = Translator(client: fake)
    let outcome = try await translator.translate(
        text: source, target: .ru, tone: .neutral,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900)
    #expect(fake.receivedMessages.count == 1)   // per-chunk call only, no term-list call
    #expect(outcome.documentGlossaryAttempted == false)
    #expect(outcome.modelChunkCount == 1)
}
```

Append the правка twin to `Tests/TranslationCoreTests/ProofreaderTests.swift` (same harness shape as its neighbours):

```swift
@Test func proofreadPassesFencedChunksThroughAndCountsModelChunks() async throws {
    let source = "Текст с ошибкой.\n\n```py\nprint('helo')\n```"
    let fake = FakeLLMClient(responses: ["Текст без ошибки."])
    let translator = Translator(client: fake)
    var streamed = ""
    let outcome = try await translator.proofread(
        text: source, level: .errorsOnly,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: { streamed += $0 })
    for messages in fake.receivedMessages {
        for message in messages { #expect(!message.content.contains("print('helo')")) }
    }
    #expect(outcome.final.contains("```py\nprint('helo')\n```"))
    #expect(streamed == outcome.final)
    #expect(outcome.modelChunkCount == 1)
}
```

Adapt the exact `translate(...)` argument labels to the real signature (read it first — `grep -n "public func translate" Sources/TranslationCore/Translator.swift`); the assertions are the requirement, the labels follow the code.

- [ ] **Step 2: Run — expect compile failure on `modelChunkCount`**

Run: `swift test --filter aPassthroughChunkNeverReachesTheModel`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

1. `TranslationOutcome` gains the field (doc comment included) and its memberwise init gains the parameter:

```swift
/// How many chunks were model-bound. Pass-through (fenced-code) chunks are excluded.
/// Zero means the whole document was code: a trivially successful run in which
/// `timeToFirstTokenMS` is nil WITHOUT meaning «empty reply» — consumers must check
/// this count before reading that nil as a failure (spec §2.1, the renegotiated
/// contract; `TranslationViewModel` is the consumer that got this wrong first).
public let modelChunkCount: Int
```

2. In **both** per-chunk loops (`translate` and `proofread`), before building messages:

```swift
if chunk.passthrough {
    // Protection by construction (spec §2.1): the bytes go straight through — no
    // request, no cleaner, no restore. The separator still precedes them, and
    // progress still counts the part.
    try Task.checkCancellation()
    if !chunk.separatorBefore.isEmpty { onToken(chunk.separatorBefore) }
    onToken(chunk.text)
    translatedChunks.append(chunk.text)   // (correctedChunks in proofread)
    onProgress(...)                        // same progress call as the model path
    continue
}
```

Mind the existing separator emission: the model path already emits `chunk.separatorBefore` — make sure the pass-through branch does not double-emit it (place the branch so each chunk's separator is emitted exactly once; follow the loop's current structure).

3. The glossary trigger (`Translator.swift:220`): `if chunks.count > 1` becomes

```swift
let modelChunks = chunks.filter { !$0.passthrough }
if modelChunks.count > 1, let source = detected {
```

(and any use of `chunks.count` inside that block for the same purpose follows).

4. Both `TranslationOutcome(...)` constructions pass `modelChunkCount: chunks.count { !$0.passthrough }` — spelled `chunks.lazy.filter { !$0.passthrough }.count` or a local `modelChunks.count`. The compiler then finds every other construction site (tests included) — update each, passing the honest count for fabricated outcomes.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Zero warnings, commit**

Run: `swift build --build-tests 2>&1 | grep "warning:" || echo CLEAN` → `CLEAN`

```bash
git add Sources/TranslationCore/ Tests/TranslationCoreTests/
git commit -m "feat(core): passthrough chunks skip the model; outcomes carry modelChunkCount"
```

---

### Task 3: The view model's two renegotiated guards

**Files:**
- Modify: `Sources/TranslatorApp/TranslationViewModel.swift:502` (the empty-reply guard) and `:267` (the «Ещё вариант» availability)
- Test: `Tests/TranslatorAppTests/TranslationViewModelTests.swift`

**Interfaces:**
- Consumes: `TranslationOutcome.modelChunkCount` (Task 2).
- Produces: nothing new — two conditions change meaning.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslatorAppTests/TranslationViewModelTests.swift`, following the file's existing harness (the fake, settings via `InMemoryDefaults`, `@MainActor` where its neighbours are):

```swift
@MainActor @Test func anAllCodeDocumentFinishesAsSuccessNotEmptyReply() async {
    // nil TTFT used to be the empty-reply signal; with pass-through chunks an
    // all-code document has nil TTFT AND a correct result (spec §2.1).
    let (model, _) = makeModel(responses: [])   // adapt to the file's harness helper
    model.sourceText = "```sh\nls -la\n```"
    await model.run()
    #expect(model.state == .finished)
    #expect(model.translatedText == "```sh\nls -la\n```")
}

@MainActor @Test func anotherVariantIsNotOfferedWhenNothingWentToTheModel() async {
    let (model, _) = makeModel(responses: [])
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsAndStyle
    model.sourceText = "```sh\nls\n```"
    await model.run()
    #expect(model.state == .finished)
    #expect(model.offersAnotherVariant == false)   // adapt the property name to :267's
}
```

Before writing, read the harness helpers at the top of the test file and the real property name at `TranslationViewModel.swift:267`; the assertions are the requirement.

- [ ] **Step 2: Run — expect FAIL**

Run: `swift test --filter anAllCodeDocumentFinishesAsSuccessNotEmptyReply`
Expected: FAIL — today the nil TTFT trips «Модель вернула пустой ответ» and state is `.failed`.

- [ ] **Step 3: Implement**

At `:502`, the guard becomes:

```swift
// nil TTFT means «empty reply» only when something was actually model-bound: an
// all-code document legitimately finishes with nil TTFT and modelChunkCount == 0
// (spec §2.1, the renegotiated contract — pass-through chunks made the old reading
// fail a successful run).
guard result.modelChunkCount == 0 || result.timeToFirstTokenMS != nil else {
    state = .failed("Модель вернула пустой ответ. Попробуйте ещё раз.")
    ...
}
```

At `:267`, append the gate:

```swift
&& (outcome?.modelChunkCount ?? 0) > 0
```

with a one-line comment: «re-running an identity is not a variant (spec §2.1)».

- [ ] **Step 4: Run the full suite; zero warnings; commit**

Run: `swift test` → PASS; `swift build --build-tests 2>&1 | grep "warning:" || echo CLEAN` → `CLEAN`

```bash
git add Sources/TranslatorApp/TranslationViewModel.swift Tests/TranslatorAppTests/TranslationViewModelTests.swift
git commit -m "fix(app): all-code runs finish as success; Ещё вариант needs a model-bound chunk"
```

---

### Task 4: Inline-code positional restore

**Files:**
- Modify: `Sources/TranslationCore/MarkupSkeleton.swift` (~line 199 — extract the backtick scan)
- Create: `Sources/TranslationCore/InlineCodeRestorer.swift`
- Modify: `Sources/TranslationCore/Translator.swift` (`streamChunkReply`, ~line 560–645)
- Test: `Tests/TranslationCoreTests/InlineCodeRestorerTests.swift` (new), `Tests/TranslationCoreTests/TranslatorTests.swift`

**Interfaces:**
- Consumes: `Chunk.passthrough` (Task 1) — restore concerns model-bound chunks only.
- Produces:
  - `MarkupSkeleton.inlineCodeSpans(in line: String) -> [(range: NSRange, content: String)]` — the ONE backtick-pairing scan; `inlineTokens` calls it, so restore and diff share the definition literally.
  - `InlineCodeRestorer.restore(reply: String, source: String) -> String` — chunk-level: equal span counts → N-th reply span content replaced by N-th source span content; any mismatch → reply returned untouched.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TranslationCoreTests/InlineCodeRestorerTests.swift`:

```swift
import Foundation
import Testing
@testable import TranslationCore

@Test func anEditedSpanIsRestoredToTheSourceBytes() {
    let source = "Выполните комманду `git comit --amend` и живите."
    let reply  = "Выполните команду `git commit --amend` и живите."
    #expect(InlineCodeRestorer.restore(reply: reply, source: source)
            == "Выполните команду `git comit --amend` и живите.")
}

@Test func anAddedSpanRestoresNothingBecauseAlignmentIsUnknowable() {
    // The model wrapped a word in backticks. Greedy N↔N would inject source content
    // into the wrong span — worse than no restore (spec §2.2, the equal-count gate).
    let source = "Run `npm instal` first."
    let reply  = "Run `npm` `install` first."
    #expect(InlineCodeRestorer.restore(reply: reply, source: source) == reply)
}

@Test func aLoneBacktickIsNotASpanInSourceOrReply() {
    // Parity is per line and unterminated openers emit nothing — the shared
    // definition (MarkupSkeleton.inlineCodeSpans), not a new regex.
    let source = "Don't use ` alone. Use `git status` here."
    let reply  = "Do not use ` alone. Use `git status!` here."
    // Source spans: [" alone. Use "]? — no: the FIRST backtick opens, the second
    // closes, so span 1 is " alone. Use " and "git status" sits outside. Whatever
    // the shared scan says, restore must follow it exactly — this test pins the
    // two agreeing, not a particular reading:
    let sourceSpans = source.split(separator: "\n", omittingEmptySubsequences: false)
        .flatMap { MarkupSkeleton.inlineCodeSpans(in: String($0)) }.map(\.content)
    let replySpans = reply.split(separator: "\n", omittingEmptySubsequences: false)
        .flatMap { MarkupSkeleton.inlineCodeSpans(in: String($0)) }.map(\.content)
    let restored = InlineCodeRestorer.restore(reply: reply, source: source)
    if sourceSpans.count == replySpans.count {
        let restoredSpans = restored.split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { MarkupSkeleton.inlineCodeSpans(in: String($0)) }.map(\.content)
        #expect(restoredSpans == sourceSpans)
    } else {
        #expect(restored == reply)
    }
}

@Test func multiLineRepliesRestoreAcrossLinesInDocumentOrder() {
    let source = "Первый `a b` спан.\nВторой `c d` спан."
    let reply  = "Первый `A-B` спан.\nВторой `C-D` спан."
    #expect(InlineCodeRestorer.restore(reply: reply, source: source)
            == "Первый `a b` спан.\nВторой `c d` спан.")
}
```

- [ ] **Step 2: Run — expect compile failure**

Run: `swift test --filter anEditedSpanIsRestoredToTheSourceBytes`
Expected: FAIL to compile (`InlineCodeRestorer`, `inlineCodeSpans` do not exist).

- [ ] **Step 3: Extract the shared scan in `MarkupSkeleton`**

The backtick loop inside `inlineTokens` (~line 231–247) moves into:

```swift
/// The one definition of an inline code span — shared by the skeleton diff and
/// `InlineCodeRestorer`, so the two can never disagree about what a span is
/// (spec §2.2). Per line: parity pairs backticks left to right; an unterminated
/// opener emits nothing; an empty pair (``) emits nothing but consumes both.
/// NSRange coordinates are UTF-16, matching the rest of `inlineTokens`.
static func inlineCodeSpans(in line: String) -> [(range: NSRange, content: String)] {
    let ns = line as NSString
    var spans: [(NSRange, String)] = []
    var openAt: Int? = nil
    for index in 0..<ns.length where ns.character(at: index) == 0x60 {
        if let start = openAt {
            if index > start + 1 {
                let content = NSRange(location: start + 1, length: index - start - 1)
                spans.append((content, ns.substring(with: content)))
            }
            openAt = nil
        } else {
            openAt = index
        }
    }
    return spans.map { (range: $0.0, content: $0.1) }
}
```

`inlineTokens` then calls it: `for span in inlineCodeSpans(in: line) { found.append((span.range.location - 1, .inlineCode(span.content))) }` — **the token's sort position was the opening backtick** (`start`), so subtract 1 from `range.location` (the content starts one past the backtick). Run the whole suite after this extraction alone — the existing `MarkupSkeletonTests` must pass byte-identically before anything else builds on the scan.

- [ ] **Step 4: Implement `InlineCodeRestorer`**

Create `Sources/TranslationCore/InlineCodeRestorer.swift`:

```swift
// Sources/TranslationCore/InlineCodeRestorer.swift
import Foundation

/// Restores inline-code span contents from the source after a model reply — the inline
/// half of «protection by construction» (spec §2.2; the fenced half is pass-through
/// chunks in `Chunker`). Restore fires only when the reply's span count equals the
/// source's: the measured failure mode is exactly the equal-count case (delimiters
/// kept, content edited — 3/3 on every failing calibration file), and under any
/// mismatch a positional alignment could inject source bytes into the wrong span,
/// which is worse than no restore. Span definition: `MarkupSkeleton.inlineCodeSpans`,
/// per line, shared with the skeleton diff.
enum InlineCodeRestorer {
    static func restore(reply: String, source: String) -> String {
        let sourceSpans = spans(of: source)
        guard !sourceSpans.isEmpty else { return reply }
        let replyLines = reply.components(separatedBy: "\n")
        let replySpanCount = replyLines.reduce(0) {
            $0 + MarkupSkeleton.inlineCodeSpans(in: $1).count
        }
        guard replySpanCount == sourceSpans.count else { return reply }
        var next = 0
        var rebuilt: [String] = []
        rebuilt.reserveCapacity(replyLines.count)
        for line in replyLines {
            let lineSpans = MarkupSkeleton.inlineCodeSpans(in: line)
            guard !lineSpans.isEmpty else { rebuilt.append(line); continue }
            let ns = NSMutableString(string: line)
            // Right-to-left, so the earlier spans' NSRanges stay valid while later
            // ones are replaced; `next + offset` pairs this line's spans with the
            // source's, in document order.
            for (offset, span) in lineSpans.enumerated().reversed() {
                ns.replaceCharacters(in: span.range, with: sourceSpans[next + offset])
            }
            next += lineSpans.count
            rebuilt.append(ns as String)
        }
        return rebuilt.joined(separator: "\n")
    }

    private static func spans(of text: String) -> [String] {
        text.components(separatedBy: "\n")
            .flatMap { MarkupSkeleton.inlineCodeSpans(in: $0) }
            .map(\.content)
    }
}
```

Newline note: chunks can contain CRLF (CRLF documents) — splitting on `"\n"` leaves the
`"\r"` glued to the previous line's tail, where no backtick scan is harmed and the join
restores it byte-for-byte; do not crash on it, no special-casing required.

- [ ] **Step 5: Run the restorer tests**

Run: `swift test --filter InlineCodeRestorerTests`
Expected: PASS, all four.

- [ ] **Step 6: Wire restore into `streamChunkReply` — buffer-whole when the source has spans**

In `Translator.streamChunkReply` (the mode decision at the top): compute once

```swift
let sourceSpanCount = chunk.text.components(separatedBy: "\n")
    .reduce(0) { $0 + MarkupSkeleton.inlineCodeSpans(in: $1).count }
```

When `sourceSpanCount > 0`, force the **buffered** path for the whole reply (never switch to `.incremental` — same shape as the fence-unwrap deferral), and at the end apply, in this order (spec §2.2: clean → restore → emit):

```swift
let cleaned = ResponseCleaner.clean(buffer, allowFenceUnwrap: true,
    allowMarkerUnwrap: ...).text          // existing arguments unchanged
let restored = InlineCodeRestorer.restore(reply: cleaned, source: chunk.text)
emit(restored)
return collected
```

with the why-comment:

```swift
// A chunk whose source carries inline code is buffered whole: the equal-count
// restore gate is decidable only on the complete reply, and emitted bytes cannot
// be recalled — so incremental emission would break «final and the stream agree
// byte-for-byte». Bounded by the chunk budget; measured trade, spec §2.2.
```

- [ ] **Step 7: The end-to-end pin**

Append to `Tests/TranslationCoreTests/TranslatorTests.swift`:

```swift
@Test func anInlineSpanEditedByTheModelIsRestoredInFinalAndStreamAlike() async throws {
    let source = "Выполните комманду `git comit --amend` сейчас."
    let fake = FakeLLMClient(responses: ["Выполните команду `git commit --amend` сейчас."])
    let translator = Translator(client: fake)
    var streamed = ""
    let outcome = try await translator.proofread(
        text: source, level: .errorsOnly,
        options: ChatOptions(model: "fake"), maxChunkCharacters: 900,
        onToken: { streamed += $0 })
    #expect(outcome.final == "Выполните команду `git comit --amend` сейчас.")
    #expect(streamed == outcome.final)
}
```

- [ ] **Step 8: Full suite, warnings, commit**

Run: `swift test` → PASS; warnings grep → `CLEAN`

```bash
git add Sources/TranslationCore/ Tests/TranslationCoreTests/
git commit -m "feat(core): inline code restored from source bytes under the equal-count gate"
```

---

### Task 5: Acceptance — model-bound classification, the live run, the re-based entry

**Files:**
- Modify: `Sources/acceptance/main.swift:79,160,180,190` (every `chunks.count` classification site)
- Modify: `docs/BASELINE.md` (append one entry)

**Interfaces:**
- Consumes: `TranslationOutcome.modelChunkCount` (Task 2).

- [ ] **Step 1: Migrate the classification**

At each of the four sites, the question being asked is «did this run pay per-chunk model calls / a term-list call?» — replace `outcome.chunks.count` with `outcome.modelChunkCount` where the logic gates TTFT (single-model-chunk files gate TTFT) and adherence (multi-model-chunk files measure it); keep `chunks.count` only where the printed line reports raw structure, and print both when they differ (`"3 chunks (2 model-bound)"` — so the entry records the re-basing per file). Build: `swift build` → clean.

- [ ] **Step 2: The live run, twice**

Confirm the model: `curl -s --max-time 3 http://127.0.0.1:11434/api/tags | grep -o 'aya-expanse:8b'`.
Run `swift run acceptance` twice (10-minute timeout each); the second run is the record. Expected: `ACCEPTED`; the known-limitation «translated commit message inside a code block» should be **absent** — that absence is the headline.

- [ ] **Step 3: Append the re-based entry**

Append to `docs/BASELINE.md`, following its entry format, headed:

```markdown
## 2026-08-10 — after pass-through chunks and inline restore (re-basing)

Part A of specs/2026-08-10-code-protection-and-styles-design.md changed the chunking of
every code-bearing file, so adherence is computed over a different chunk set and files
may have changed single-/multi-chunk class — percent-to-percent comparison with the
entries above is qualitative; the 80 % floor is absolute. Files that changed class:
<list from the run output, e.g. «snippet-en: 1 chunk → 2 chunks (1 model-bound), leaves
the TTFT-gated class» — from the actual printout>.
<the harness's printed lines, verbatim>
```

If a gate fails (adherence < 80 %, TTFT ≥ 1000 ms on a single-model-chunk file, or a NEW
markup-diff shape): stop, append the FAILED entry anyway, and report — do not revert
engine tasks on your own; the failure analysis is the controller's.

- [ ] **Step 4: Commit**

```bash
git add Sources/acceptance/main.swift docs/BASELINE.md
git commit -m "feat(acceptance): classify by model-bound chunks; re-based entry after Part A"
```

---

### Task 6: Правка corpus run №1 — Part A verification + style-matrix baseline

**Files:**
- Create (scratchpad only): `$SCRATCH/proofread-corpus/12-style-probe-formal-ru.txt`
- Modify (scratchpad only): `$SCRATCH/proofread-runner/main.swift`
- No repo changes in this task (records land in Task 8).

**Interfaces:**
- Consumes: the corpus and runner from the prompt-improvement pass. If `$SCRATCH/proofread-corpus/` or the runner are missing, rebuild them: the 11 texts are recorded verbatim in `docs/OPEN-ITEMS.md` §5, the runner code in `docs/design/plans/2026-08-10-prompt-improvement.md` Task 4 (use its Task 4 report's compile fix: add `-module-name TranslationCore`).
- Produces: `$SCRATCH/proofread-out-partA/` and `$SCRATCH/proofread-out-matrix-baseline/` + logs, consumed by Tasks 7–8.

- [ ] **Step 1: The new probe text**

Write `$SCRATCH/proofread-corpus/12-style-probe-formal-ru.txt` (no seeded errors; a stiff formal notice — the register gap «дружеский» must close):

```
Уважаемые коллеги! Настоящим уведомляем вас о необходимости предоставить отчётные материалы в срок до пятницы. При наличии вопросов надлежит обращаться к руководителю подразделения.
```

- [ ] **Step 2: Extend the runner's matrix**

In `$SCRATCH/proofread-runner/main.swift`, replace the per-file dispatch so the matrix follows spec §3.2 (each style probed where it has a gap to close; file 11 keeps business/professional; file 12 gets friendly; file 02 additionally runs plain; file 07 additionally runs friendly as the EN spot-check):

```swift
for file in files {
    let name = file.deletingPathExtension().lastPathComponent
    let text = try String(contentsOf: file, encoding: .utf8)
    if name.hasPrefix("11-style-probe") {
        for style in [RewriteStyle.original, .business, .professional] {
            await run(name, text, level: .errorsAndStyle, style: style,
                      tag: "errorsAndStyle-\(style.rawValue)", runs: 3)
        }
    } else if name.hasPrefix("12-style-probe") {
        for style in [RewriteStyle.original, .friendly] {
            await run(name, text, level: .errorsAndStyle, style: style,
                      tag: "errorsAndStyle-\(style.rawValue)", runs: 3)
        }
    } else {
        await run(name, text, level: .errorsOnly, style: .original, tag: "errorsOnly", runs: 3)
        if name.hasPrefix("02-") {
            await run(name, text, level: .errorsAndStyle, style: .plain,
                      tag: "errorsAndStyle-plain", runs: 3)
        }
        if name.hasPrefix("07-") {
            await run(name, text, level: .errorsAndStyle, style: .friendly,
                      tag: "errorsAndStyle-friendly", runs: 3)
        }
    }
}
```

(`.original` runs on 11 and 12 give the no-style reference output each probe is compared against.)

- [ ] **Step 3: Recompile and run**

```bash
swiftc -O -module-name TranslationCore -o $SCRATCH/proofread-runner/pp \
  Sources/TranslationCore/*.swift Sources/OllamaKit/*.swift \
  $SCRATCH/proofread-runner/main.swift
$SCRATCH/proofread-runner/pp $SCRATCH/proofread-corpus $SCRATCH/proofread-out-matrix-baseline \
  | tee $SCRATCH/proofread-matrix-baseline.log
```

(10-minute timeout; ~60 live calls.) The errorsOnly outputs double as the **Part A verification**: for files 03, 04, 08, 09 the log's `codeIntact` must read `true` 3/3 — fenced files (04, 09) by pass-through, inline files (03, 08) by restore. For files 01–10, compare errorsOnly outputs against the previous baseline (`$SCRATCH/proofread-out-baseline/` if present; otherwise the counts recorded in OPEN-ITEMS §5): no previously-passing text may regress.

- [ ] **Step 4: Read the style outputs and write the interim verdict**

For each probe (11-business, 11-professional, 12-friendly, 02-plain, 07-friendly): diff the style output against the same file's `.original` output — does the register shift, does meaning survive? Write the per-probe counts into `$SCRATCH/matrix-baseline-verdict.md` (this is Task 8's raw material; no repo write yet). Honest counting: «shifted 2/3» means 2 of 3 runs.

- [ ] **Step 5: No commit** — scratchpad-only task; state the verification results in the report.

---

### Task 7: The voice/register contradiction fix

**Files:**
- Modify: `Sources/TranslationCore/Proofreading.swift` (the `errorsAndStyle` case), `Sources/TranslationCore/PromptBuilder.swift` (`proofreadSystemPrompt`)
- Test: `Tests/TranslationCoreTests/ProofreadPromptTests.swift`, `Tests/TranslationCoreTests/ProofreadingModesTests.swift`

**Interfaces:**
- Produces: `ProofreadingLevel.instruction(styleGovernsVoice: Bool) -> String`; the parameterless `instruction` keeps today's wording for both cases (existing pins keep meaning what they said).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslationCoreTests/ProofreadPromptTests.swift`:

```swift
@Test func aNamedStyleDropsVoiceFromTheLevelInstruction() {
    // «Preserve the voice» and «rewrite the register» were mutually exclusive; the
    // model resolved the conflict by doing nothing (spec §3.1, measured 3/3 no-ops).
    let withStyle = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsAndStyle, style: .friendly)
    #expect(!withStyle.contains("voice"))
    #expect(withStyle.contains("Preserve the author's meaning and overall structure."))
    let original = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsAndStyle, style: .original)
    #expect(original.contains("meaning, voice, and overall structure"))
    let errorsOnly = PromptBuilder.proofreadSystemPrompt(language: .ru, level: .errorsOnly, style: .friendly)
    #expect(errorsOnly.contains("only where an error was corrected"))   // untouched
}
```

- [ ] **Step 2: Run — expect FAIL** (`swift test --filter aNamedStyleDropsVoiceFromTheLevelInstruction`)

- [ ] **Step 3: Implement**

`ProofreadingLevel` gains:

```swift
/// The style-aware variant. When a named style accompanies this level, «voice»
/// leaves the preservation list — the style owns the voice, and keeping both
/// instructions produced measured 3/3 no-ops on «дружеский» and «простой»
/// (spec §3.1; docs/OPEN-ITEMS.md §5). `errorsOnly` ignores the flag: no style
/// ever accompanies it.
public func instruction(styleGovernsVoice: Bool) -> String {
    guard self == .errorsAndStyle, styleGovernsVoice else { return instruction }
    return "Fix spelling, punctuation, and grammatical errors, and also smooth awkward phrasing: "
        + "remove bureaucratic constructions, needless repetition, and clumsy word order. "
        + "Preserve the author's meaning and overall structure."
}
```

In `PromptBuilder.proofreadSystemPrompt`, the level line becomes:

```swift
let styleGovernsVoice = level.allowsRewriteStyle && style.instruction != nil
lines.append("- \(level.instruction(styleGovernsVoice: styleGovernsVoice))")
```

(the style line's own append stays as it is).

- [ ] **Step 4: Full suite, warnings, commit**

`swift test` → PASS; warnings grep → `CLEAN`

```bash
git add Sources/TranslationCore/Proofreading.swift Sources/TranslationCore/PromptBuilder.swift Tests/TranslationCoreTests/
git commit -m "feat(core): a named style owns the voice — the level instruction stops defending it"
```

---

### Task 8: Правка corpus run №2 — the matrix after the fix, and the records

**Files:**
- Modify: `docs/OPEN-ITEMS.md` (§5 — append a dated follow-up subsection; §1 — close the escalation)

**Interfaces:**
- Consumes: Task 6's outputs (`$SCRATCH/proofread-out-matrix-baseline/`, `$SCRATCH/matrix-baseline-verdict.md`) and Task 7's prompt fix.

- [ ] **Step 1: Recompile and re-run the matrix**

Same commands as Task 6 Step 3, output dir `$SCRATCH/proofread-out-matrix-after`, log `proofread-matrix-after.log`. The errorsOnly files re-run too — §3.1 does not touch `errorsOnly`, so any movement there is noise to investigate before recording.

- [ ] **Step 2: Judge each probe against its Task 6 twin**

Per probe: register shifted (majority of 3)? meaning preserved? Compare with the baseline matrix — the question is «did §3.1 move a style that was dead». A style still dead under the correct probe AND the resolved contradiction is recorded as an honest model limitation.

- [ ] **Step 3: The records**

Append to `docs/OPEN-ITEMS.md` §5 a dated subsection:

```markdown
### Part A verification and the style matrix (2026-08-10, follow-up)

Engine: pass-through chunks + inline restore (specs/2026-08-10-code-protection-and-styles-design.md).
- codeIntact: <03/04/08/09 counts, expected 3/3 each — the headline this design exists for>
- errorsOnly non-regression: <per-file counts vs the §5 baseline>
- Style matrix, before §3.1 (correct probes, old prompt): <per-probe counts>
- Style matrix, after §3.1: <per-probe counts>
- Verdict per style: <works / dead under both — honest>
- New probe text 12 (verbatim): <the text>
```

Close the §1 escalation entry: replace its «rests with a human» tail with the outcome — fenced protection is moot by construction, inline is restored by code, pointer to the subsection above. If codeIntact is NOT 3/3 anywhere, the record says exactly what failed and §1 stays open with the updated facts instead.

- [ ] **Step 4: Commit**

```bash
git add docs/OPEN-ITEMS.md
git commit -m "docs: Part A verification and the style matrix, before and after the voice fix"
```

---

### Task 9: Bounded model benchmark

**Files:**
- Modify: `docs/OPEN-ITEMS.md` (append to the Task 8 subsection)
- Scratchpad: reuse the runner with a model argument.

- [ ] **Step 1: Parameterise the runner's model**

In `$SCRATCH/proofread-runner/main.swift`, read the model from `CommandLine.arguments[3]` (default `"aya-expanse:8b"`), pass it into `ChatOptions(model:)`. Recompile.

- [ ] **Step 2: Run per candidate**

For `gpt-oss:20b` (required; reasoning-prone — `OllamaKit` discards `message.thinking` by standing rule, its TTFT carries that cost and the record must say so) and, time permitting, `qwen3:8b`:

```bash
$SCRATCH/proofread-runner/pp $SCRATCH/proofread-corpus $SCRATCH/proofread-out-bench-<model> <model> \
  | tee $SCRATCH/proofread-bench-<model>.log
```

(One matrix + errorsOnly pass, 3 runs per text; note wall-clock per call from the log timestamps as the warm-TTFT proxy. Expect the first call per model to pay a cold load — exclude it from timing notes.)

- [ ] **Step 3: Record**

Append to the OPEN-ITEMS §5 subsection: per model — errorsOnly pass counts, style-shift counts, codeIntact (should be 3/3 regardless of model — the guarantee is structural now; if it is not, that is a restorer bug, stop and report), and the timing caveat. Purpose line verbatim: «facts for a future model-policy decision about правка; no policy change here». Commit:

```bash
git add docs/OPEN-ITEMS.md
git commit -m "docs: правка model benchmark — facts, no policy change"
```

---

### Task 10: Documentation and the final sweep

**Files:**
- Modify: `CLAUDE.md` (the pipeline section), `docs/design/specs/2026-07-24-local-translator-design.md` §11a
- Verify: everything.

- [ ] **Step 1: CLAUDE.md**

In the pipeline section's fact list, add one bullet (place it after the packing-rule bullet):

```markdown
- **The model never sees fenced code, and inline code is restored by construction.**
  A fenced block is its own pass-through chunk (`Chunk.passthrough`) — emitted from
  source bytes with no model call, on both routes; inline spans are restored
  positionally from the source under an equal-count gate, on the cleaned reply, and a
  span-bearing chunk buffers whole so `final` and the stream stay byte-identical.
  `TranslationOutcome.modelChunkCount` is what «multi-chunk» means now — the
  document-glossary trigger, the empty-reply ending and the acceptance classification
  all count model-bound chunks. See
  docs/design/specs/2026-08-10-code-protection-and-styles-design.md.
```

- [ ] **Step 2: §11a**

In `docs/design/specs/2026-07-24-local-translator-design.md` §11a, the entry «The model translates human-readable text inside code» (extended 2026-08-10 with the правка counts) gains its closing sentences: fenced blocks are now structurally out of the model's reach (pass-through chunks) and inline spans are restored from source bytes under the equal-count gate — the limitation survives only for a reply that changes the number of inline spans, which the skeleton diff reports. Date the addition.

- [ ] **Step 3: Final sweep**

Run: `swift test` (expect PASS, ~2.1–2.6 s), `swift build --build-tests 2>&1 | grep "warning:" || echo CLEAN` (expect `CLEAN`), `swift test --filter DocumentationTests` (the CLAUDE.md edit must not break it). Confirm: BASELINE has the re-based entry; OPEN-ITEMS §5 has the follow-up + benchmark and §1 is closed; `git log --oneline` shows one commit per task (Tasks 6 has none — scratchpad-only, by design).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/design/specs/2026-07-24-local-translator-design.md
git commit -m "docs: record protection-by-construction as pipeline fact and close §11a's code entry"
```

---

## Self-review notes

- Spec coverage: §1a is process context (no task); §2.1 → Tasks 1–3 + 5; §2.2 → Task 4; §3.1 → Task 7; §3.2 → Tasks 6 + 8; §4.1 → Task 5; §4.2 → Tasks 6/8; §4.3 → Task 9; §6 test shapes distributed into their owning tasks; §7 → Task 10 (+ records in 5/8/9).
- Task 4's Step 4 carries the complete restorer implementation (running index, per-line right-to-left replacement); the tests in Steps 1 and 7 are the contract it must satisfy.
- Ordering: Task 6 runs the matrix BASELINE after Part A but before Task 7's prompt fix — that isolates §3.1 as the only variable between the two matrix runs, per spec §3.2.
- Type consistency: `Chunk.passthrough` (1) → consumed in 2/4/5; `modelChunkCount` (2) → consumed in 3/5; `inlineCodeSpans` (4) is the only span definition; `instruction(styleGovernsVoice:)` (7) matches the call in `PromptBuilder`.
