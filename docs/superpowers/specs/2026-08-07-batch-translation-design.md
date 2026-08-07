# Batch file translation and the document-terms review — design

Date: 2026-08-07
Status: awaiting approval

## Status of this document

This is the pre-implementation design for v2's third surface: a queue of files translated one
after another from the main window, a review of the документный глоссарий before the translation
that uses it, and the settings tab both need. Once the code exists, **the code is the authority
on behaviour and this document is the authority on why**.

A claim marked **measured** restates an observation already recorded in the code or in `docs/`;
the citation says where. A claim marked **unverified** is a platform behaviour this environment
cannot establish — §9 lists the probe that settles it. Everything else is intent.

The source is a Claude Design document (`Толмач UI.dc.html`, turn 2, options `2a`/`2b`/`2c`).
Turn 1 of that document is a recreation of the shipping v1 and is not part of this work. §12
lists every place this design deliberately departs from the drawing, with the reason.

---

## 1. Vocabulary

`CONTEXT.md` owns the app's words and gains these. One word per concept, no synonyms.

| Word | Means | Never |
|---|---|---|
| **часть** | one chunk of one file | «фрагмент» (already ruled out, `RussianCopy.swift:90`) |
| **задание** | one file in the queue, with its state | «задача», «работа» |
| **очередь** | the whole list of заданий | «пакет», «партия» |
| «Файлы» | the queue mode, the settings tab | «Пакетный» — §12.6 |

The user-facing noun for the feature is **«Файлы»** everywhere it is a label. «Пакетный перевод»
survives only in prose (a section caption), never as a control's name.

---

## 2. What this does not touch

`Chunker`, `LineScanner`, `ChunkPlan.assembled`, `MarkupSkeleton`, `PromptBuilder`,
`ResponseCleaner`, `GlossaryVerifier` — unchanged. `PanelSizer`, `PanelPlacement`,
`PanelController`, `TranslationPanel` — unchanged. Scene order, `LSUIElement`, the menu, the
capture path, `HotkeyCoordinator`'s measured ordering inside a press — unchanged.

`Translator.translate` gains two parameters, both with defaults that reproduce today's behaviour
byte for byte (§3.5). `translate-cli` and `acceptance` pass neither and are not edited.

One existing view is refactored, and only because a second consumer appears: `TranslationPane`
stops taking a `TranslationViewModel` and takes the values it renders (§5.3).

---

## 3. The engine (`TranslationCore`)

### 3.1 Where the review point is

`Translator.translate` today runs: detect → plan → *[if >1 часть and the source language is
recognised]* extract terms → one term-list call → `DocumentGlossary.parse` → per-часть
translation calls. The review point is the single instant between `parse` and the loop.

It is the only correct place, and the reason is not aesthetic: at that instant the term-list
stream has finished and no per-часть request has been issued, so **no HTTP request is in
flight** while the app waits for a human. Any earlier and there is nothing to show; any later
and the terms have already reached a prompt.

### 3.2 The draft handed out

```swift
public struct DocumentTermsDraft: Sendable {
    /// What the term-list call produced. This is what the user edits.
    public let documentEntries: [GlossaryEntry]
    /// The user-glossary entries that occur in this text — `Glossary.relevantEntries(for:)`.
    /// Shown for context and never edited here; see §6.5.
    public let userEntries: [GlossaryEntry]
    /// How many части these terms will be held constant across. The review says this out
    /// loud («будут одинаковы во всех 7 частях»), so it must come from the engine that
    /// planned them rather than from a second `Chunker.plan` at the call site.
    public let chunkCount: Int
}
```

### 3.3 The hook

```swift
reviewDocumentTerms: (@Sendable (DocumentTermsDraft) async throws -> [GlossaryEntry])? = nil
```

Called **at most once per `translate` call**, and only where the документный глоссарий is built
today — more than one часть, a recognised source language, a non-empty extracted term list. Two
cases deliberately do not call it:

- **The term list came back empty.** There is nothing to review, and a table of nothing reads as
  a failure.
- **The term-list call failed.** Today that failure is swallowed and recorded in
  `TranslationOutcome.documentGlossaryFailure`; that stays. What must change is the app's
  silence about it — see §6.6.

The returned array replaces `documentEntries` wholesale. Returning the draft unchanged is
"proceed"; **throwing `CancellationError` is "abort the run"**, which reuses the contract the
engine already has rather than adding a second refusal path. Any other error thrown by the hook
propagates as a failure of the run — the hook belongs to the app and the app does not get to
invent new engine failure modes quietly.

### 3.4 The one-resume guarantee — the trap this design exists to avoid

The hook is `async` inside a `Sendable` struct; the decision is made by a human on the main
actor. The bridge is a checked continuation, and **cancellation arrives from outside the hook**:
⌘., the toolbar's «Отмена», or the queue being cleared. A continuation that nobody resumes is
not a crash and not an error — it is a run suspended forever, unreachable by
`Task.checkCancellation()` because it is not running.

This is the same shape as the trap CLAUDE.md already records for `AsyncThrowingStream`:
cancellation *finishes* rather than throwing, so anything that is merely "not resumed" looks
like nothing happening. It cost this project its truncated-document-as-success defect once.

So the bridge is a named type in `TranslatorApp`, not a closure written at the call site:

```swift
@MainActor final class DocumentTermsRequest {
    // Resumed exactly once, by whichever of these happens first:
    //   proceed(with:) — the user pressed «Перевести»
    //   cancel()       — Esc, ⨯, ⌘., the queue was cancelled, the window closed
    // Every later call is a no-op. A test drives all four orders.
}
```

The requirement is stated here because it is a property of the engine's contract; the type lives
in the app because the engine may not know what a sheet is.

### 3.5 Progress

```swift
public struct TranslationProgress: Sendable {
    public let partsDone: Int
    public let partsTotal: Int
    /// How many document terms this run is holding constant. Zero when there is no
    /// документный глоссарий for this text.
    public let documentTermCount: Int
}

onProgress: @Sendable (TranslationProgress) -> Void = { _ in }
```

A struct rather than `(Int, Int)` because the queue row says «Перевожу часть 4 из 7 · 12 терминов
документа», and with the review toggle off there is no other moment the app could learn the third
number before the run ends.

Fired after each часть completes, plus once before the first with `partsDone == 0`, so a queue row
can show «часть 0 из 7» rather than an empty bar between the term call and the first token.

### 3.6 What is unchanged, and how that is pinned

With `reviewDocumentTerms == nil` and `onProgress` defaulted, `translate` must produce
byte-identical output for identical input. This is not asserted by reading the diff: a test
translates a fixed multi-часть document through `FakeLLMClient` and compares `final`, `chunks`,
`translatedChunks`, `documentGlossary`, `checks` and `markupDiffs` against pinned values, and the
same test runs again with a hook that returns its draft untouched.

---

## 4. The queue (`TranslatorApp`)

### 4.1 What a drop is accepted

`QueueDrop`, a pure type beside `DroppedDocument` and following its shape: the rules are
checkable, and a rule written inside a view modifier can only be read.

Same extension list as `DroppedDocument.readableExtensions` (`txt`, `text`, `md`, `markdown`),
same UTF-8-or-nothing, same refusal-by-`false` so the system springs the item back.

**A mixed drop is refused whole.** Ten `.md` files and one `.pdf` is a refusal, not ten
translations — the identical reasoning `SourcePane` already applies to a multiple selection:
taking the acceptable ones is a guess about which of them was meant.

**The per-file ceiling is 2 MB here, not 256 KB.** `DroppedDocument.maximumBytes` is justified by
a sentence about what a person waits for **at a window** — «about 290 requests to the model, far
past anything a person waits for at a window» (`DroppedDocument.swift`). The queue is the surface
where waiting *is* the arrangement: it has a progress bar, a per-file state and a cancel button.
Carrying the number across while discarding the reasoning that produced it is exactly what
CLAUDE.md's «measured is a contract» rule forbids. 2 MB is about 2300 model calls for an ASCII
source at the default 900-character часть — long, visible, and interruptible. The number is a
choice, not a measurement, and its comment must say so.

`DroppedDocument`'s own 256 KB is untouched: the text pane still has no progress and no cancel
per-file, so its reasoning still holds.

### 4.2 A задание

```swift
struct FileJob: Identifiable {
    let id: UUID
    let url: URL
    let text: String        // read at drop time
    let partsTotal: Int     // Chunker.plan at drop time — see below
    var state: State
    var result: JobResult?
    var saveProblem: String?

    enum State: Equatable {
        case queued
        case running(TranslationProgress)
        case finished
        case interrupted           // cancelled mid-run; partial text kept
        case failed(String)
    }
}
```

**The text is read at drop time**, not at run time, so a file edited or deleted between the drop
and its turn cannot change a задание half-way. **`partsTotal` is computed at drop time too**,
because the queued row promises «4 части» before anything runs — but `Chunker.plan` is a line
split plus a `String.count` per block plus sentence enumeration over oversized blocks, and twenty
2 MB files is not main-actor work. Reading and planning happen off the main actor; the задание
arrives in the model complete.

`JobResult` holds `final`, `checks`, `markupDiffs`, `elapsedMS` and `savedTo: URL?` — **not the
whole `TranslationOutcome`**. An outcome carries `chunks` and `translatedChunks` as well, i.e.
roughly three copies of the document; retaining that for twenty finished 2 MB files is ~120 MB of
nothing anyone will read. The reduced result is everything the right pane and the warnings need.

### 4.3 Running the queue

`FileQueueModel` — `@Observable`, `@MainActor`, owning `[FileJob]` and the selection.

It is **not** an extension of `TranslationViewModel`. One run per model, with a per-instance
re-entrancy guard, is the rule that keeps the window and the panel from overwriting each other
(CLAUDE.md, and `AdoptionRefusal`'s whole existence); a queue inside a view model that also serves
a text pane would put two runs behind one guard.

Files are translated **one at a time**. Ollama holds one model in memory and `keep_alive` is
load-bearing (**measured**: cold load ~2000 ms against ~155 ms warm, CLAUDE.md); concurrent files
would multiply requests against one server without multiplying throughput.

- **Start** is «Перевести», never the drop. A drop that immediately started minutes of work would
  make a mis-aimed drag expensive, and the drawing does not say the queue self-starts (§12.3).
- **«Отмена»** cancels the running задание only. It becomes `.interrupted`, keeping whatever text
  arrived; every `.queued` задание stays queued. «Перевести» resumes from the first задание that
  is not `.finished` — which deliberately includes `.interrupted` and `.failed` ones, so resuming
  retries what did not work rather than skipping past it.
- **`stopOnWarnings`** on: after a задание finishes with markup diffs or missing terms, nothing
  else starts. **The pause is a property of the queue, not of the задание** — the file itself is
  `.finished` and is still written, because it finished; the pause is for a human to look, not a
  rollback. `FileQueueModel.pausedAfterWarnings` holds it and «Перевести» clears it. Modelling it
  as a sixth `FileJob.State` would make one file's outcome and the queue's willingness to
  continue the same value, and they are not: dismissing the pause must not restate the задание.
- The model used is `settings.batchModel` (§7.2), the tone and languages come from the same
  toolbar controls the text mode uses, and `temperature`/`keepAlive`/`chunkSize` are the app-wide
  ones.

### 4.4 Naming the output

`OutputNaming`, pure and tested: `techdoc-en.md` → `techdoc-en.ru.md` — the target language's
code inserted before the extension. A file with no extension gets the code appended.

**An existing file is never overwritten.** A taken name gets a number: `techdoc-en.ru 2.md`,
then `3`, and so on. The check-then-write is inherently racy against another process and the
write uses `Data.WriteOptions.withoutOverwriting` so the race loses safely and retries rather
than destroying a file.

### 4.5 Writing it, and the permission this needs — **unverified**

`saveNextToSource` on (the default) writes each translation beside its source as it finishes.

The app is not sandboxed — `Scripts/make-app-bundle.sh` signs and does nothing else — but that
removes only one of the two barriers. On macOS 14 a non-sandboxed app still meets TCC for
`~/Documents`, `~/Desktop` and `~/Downloads`, and a drag grants the right to **read** what was
dragged, not the right to place a sibling next to it. Whether the first write raises a prompt,
succeeds silently, or fails with `NSCocoaErrorDomain` 513 is **unverified**, and this document
will not guess it — §9.1 is the probe.

The design is built so the answer does not change the shape: a write that fails for any reason
sets `saveProblem` on that задание and the row offers **«Сохранить как…»**, which runs an
`NSSavePanel`. That is a recovery path rather than an error message, because the save panel
itself confers the write right. With `saveNextToSource` off, nothing is written automatically
and every finished row offers «Сохранить рядом с исходником», one file at a time.

---

## 5. The main window

### 5.1 The mode switch

A small segmented control, «Текст» / «Файлы», in the left pane's header row, replacing the
«Исходник» caption. The drop goes wherever the switch points, so nothing about a drop is guessed.

Two consequences to build in rather than discover:

- **Both pane headers must keep one height.** `PaneHeader` is shared by the two panes and is a
  4-pt-padded caption row; a `.small` segmented control is taller than a caption. The header's
  height is pinned once, for both panes, or the split looks broken. This is the one control this
  implementation adds that the drawing does not have (§12.1), and §8 owes it a pair of eyes.
- **The switch is disabled while the queue runs.** One window, one primary button; letting the
  user switch to «Текст» and press «Перевести» would put two runs behind one toolbar.

### 5.2 The left pane in «Файлы»

Header: «Файлы · 3» and «Добавить…» (an open panel — the drop is not the only way in).
Rows are the задания, in drop order, selectable. Per the drawing:

- running: name, «7 частей», a progress bar, «Перевожу часть 4 из 7 · 12 терминов документа»
- queued: name, «в очереди · 4 части»
- finished: name, «✓ готово за 3 140 мс», «2 предупреждения» and the save link
- a dashed drop target at the bottom: «Перетащите .md, .txt или .markdown»

Empty state: the same drop target, filling the pane, plus the sentence that says «Перевести»
starts the queue.

### 5.3 The right pane

Shows the **selected** задание's translation, streaming if that задание is the running one.
Header: «Перевод · techdoc-en.md». With nothing selected it keeps the existing empty state.

`TranslationPane` therefore stops taking `TranslationViewModel` and takes `title`, `text`,
`isRunning` and `onCopy`. A view that renders four values does not need a class reference to get
them, and the second consumer is what makes that worth changing now rather than later.

### 5.4 The status bar

In «Файлы», `RunStatusBar`'s line reads «Перевожу 2-й файл из 3 — 9 частей из 13» while running,
and the disclosure opens the **selected** задание's warnings through the existing `WarningsView`,
which takes checks and diffs and so needs no change.

### 5.5 The toolbar

Unchanged: the same two language pickers, ⇄, the tone picker, and «Перевести»/«Отмена». ⌘↩ and
⌘. stay in the «Перевод» menu, declared once, exactly as CLAUDE.md requires.

---

## 6. «Термины документа» (`2b`)

### 6.1 One view, one host

`DocumentTermsView`, presented as a `.sheet` on the main window. All three paths use it:

- **files** — the sheet opens over the window the queue is already in;
- **text in the window** — likewise;
- **the ⌥⌘T panel** — the run escalates: the main window is opened if it is closed, comes
  forward, and the sheet opens there. The panel stays on screen behind it holding whatever it
  had; it is not the thing being answered.

The escalation is deliberate and it is the design's largest departure from the drawing (§12.2).
The panel is `.nonactivatingPanel` and deliberately does not activate the app; how a text field
inside it behaves for focus, for a focus ring, for ⌘V through the menu and for Cyrillic input is
**unverified**, and the toggle that reaches this path is off by default, so it is the rarest route
with the highest platform risk. A window that comes forward to ask a question is a Mac idiom; a
half-working editable table beside the cursor is not.

### 6.2 What it shows

Title «Термины документа — 12». Beneath it: «Они переведены один раз и будут одинаковы во всех 7
частях. Исправьте то, что переведено не так, — перевод ещё не начался.» Both numbers come from
`DocumentTermsDraft`.

Three columns — «термин», «перевод», «откуда». «откуда» is «глоссарий» for a `userEntries` row and
«документ» for a `documentEntries` row. The «перевод» cell is an editable field for a document
row and static text for a glossary row; a `doNotTranslate` entry renders «не переводить».

### 6.3 Leaving it

One primary button, **«Перевести»**, which returns the edited entries. Esc and ⨯ cancel the run.

The drawing has a second button, «Переводить без правок», beside it. It is dropped: before any
edit the two are indistinguishable and the user must guess which is which; after an edit the left
one silently discards work with no confirmation. One button and an escape is the same set of
outcomes with none of the ambiguity (§12.4).

### 6.4 A queue asks once, not thirteen times

With the toggle on and thirteen files queued, a per-file gate stops the queue thirteen times —
in precisely the scenario the gate was designed for. In a queue run the sheet carries **«Больше не
спрашивать в этом прогоне»**; ticking it makes every remaining задание proceed with its own
unedited draft. It resets when the queue is next started, because it is a statement about this
sitting, not a preference.

### 6.5 Why glossary rows are read-only

`GlossaryMerge.merge(user:document:)` drops a document entry whose term already exists in the
user glossary — the user's own entry wins. An editable glossary row would therefore accept a
change that the very next line of the engine discards. Editing the user glossary has a place, and
it is its own settings tab.

«Добавить в пользовательский глоссарий» promotes the edited document entries into
`GlossaryStore` and saves. Saving can fail in the two ways `GlossaryStore` already refuses —
never loaded, changed on disk — and it reports them with the wording `MainWindowView.mute`
already uses, because two spellings of one failure is how they drift.

### 6.6 A failed term call may not stay silent here

When the term-list call fails, `Translator` swallows it (an enhancement failing is not the
result), records `documentGlossaryFailure`, and the app logs it. That is right when nobody asked.

It is wrong when `reviewDocumentTerms` is on: the user is waiting for a gate that will never
open, and the run's terminology quietly differs from what they were promised. In that case the
run status bar carries one line — «Термины документа не удалось подготовить, перевод идёт без
них» — with no detail, because the detail is already in the log and is not the user's problem.

---

## 7. Settings — the fourth tab

### 7.1 The tab

A fourth `.tabItem`, **«Файлы»**, `doc.on.doc`, in the same `settingsPane()` 560 × 480 the other
three take. Whether the drawn content fits 480 pt is §8's business; `.formStyle(.grouped)`
installs its own `NSScrollView` (**measured**, CLAUDE.md) so the worst case is a scroll, not a
clip.

### 7.2 The model, and the swap it can cause

The section is «Модель для пакетного перевода», and its first item is not a model name:

> Модель — **«Как для перевода по клавише»** ▾

`AppSettings.batchModel` returns `nil` when unset, and `nil` means «whatever `interactiveModel`
is». This is the one setting in the app with no fixed default, and the reason is a measurement
already in CLAUDE.md: Ollama holds one model, and a cold load is ~2000 ms against ~155 ms warm.
If the batch model defaults to something other than the interactive one, then every ⌥⌘T pressed
during a queue run costs **two** cold loads — one to serve the panel and one to get back to the
queue — and a thirteen-file queue makes that the normal case. Shipping a different default would
build that thrash into the box.

Stored under the key **`"backgroundModel"`**, the key the removed property used. Its removal
comment promises exactly this: «Any value a user already stored stays in `UserDefaults` under
`"backgroundModel"` … and v2 would find it again» (`AppSettings.swift:71`). It does.

When the user picks a model that differs from `interactiveModel`, the section's caption says what
it costs, beneath the drawing's own sentence about quality being worth more here than time to the
first character.

`ModelRole.background` and `ModelPolicy.defaultModel(for: .background)` stay as they are: policy,
still read by nothing, and this setting is deliberately not wired to them — a policy answer of
`gpt-oss:20b` is a recommendation to a user who opens the picker, not a default that changes what
an app does before anyone asks.

### 7.3 New settings

Same hand-written `access(keyPath:)` / `withMutation(keyPath:_:)` shape as every other accessor —
`@Observable` does not synthesise for computed properties.

| Property | Key | Default | Drawn as |
|---|---|---|---|
| `batchModel: String?` | `"backgroundModel"` | `nil` = as `interactiveModel` | «Модель» picker |
| `saveNextToSource: Bool` | `"saveNextToSource"` | `true` | «Рядом с исходником» |
| `stopOnWarnings: Bool` | `"stopOnWarnings"` | `false` | «Останавливаться на предупреждениях» |
| `reviewDocumentTerms: Bool` | `"reviewDocumentTerms"` | **`false`** | «Показывать перед переводом» |

`reviewDocumentTerms` is drawn on in `2c` and ships **off**. The drawing assumed the gate lived in
the batch path only; it reaches all three, including ⌥⌘T, and a default that changes the flagship
interaction for every existing user is not a default a mock can grant.

---

## 8. Copy

New strings belong in `RussianCopy` beside `chunkCount` and `characterCount`, not inline:

- `partProgress(done:total:)` → «Перевожу часть 4 из 7»
- `documentTermCount(_:)` → «12 терминов документа» (`plural`: термин/термина/терминов)
- `queuePosition(index:total:partsDone:partsTotal:)` → «Перевожу 2-й файл из 3 — 9 частей из 13»,
  which needs an ordinal helper the app does not have yet
- `elapsed(_:)` → «готово за 3 140 мс» (the existing `ru_RU` grouping, as `modelSize` uses)
- «в очереди», «Файлы · 3», «Добавить…», «Сохранить рядом с исходником», «Сохранить как…»

Guillemets and «ё» throughout; no backticks in anything rendered by `Text(String)`.

---

## 9. Probes to run — these are not assumptions

### 9.1 Writing beside a dropped file (§4.5)

A throwaway binary in the assembled bundle, signed the same way, that takes a URL dragged from
`~/Documents` and writes a sibling. What is being established: whether TCC prompts, whether a
denial surfaces as an error or as a silent no-op, and what the error is. The result decides
nothing about the shape — the `NSSavePanel` fallback is there either way — but it decides what
`docs/OPEN-ITEMS.md` §2 records as accepted, and whether the first run needs a word of warning
before it writes anything.

### 9.2 The four tabs at 560 × 480 (§7.1)

Assemble the bundle with the fourth tab and look. `.formStyle(.grouped)` scrolls, so this is about
whether it *should* have to.

### 9.3 Not run, and why

Editable text fields in a `.nonactivatingPanel` — the escalation in §6.1 removes the need, and a
probe for a path this design does not take is work for nothing. If the escalation is ever
reconsidered, this probe comes first.

---

## 10. Testing

`docs/TESTING.md`'s rule applies: a test that passes under the defect it names is not a test.

**Pure, in `TranslatorAppTests`.** `OutputNaming` — the code inserted before the extension, no
extension, an occupied name taking a number, a name occupied twice, case. `QueueDrop` — a mixed
drop refused whole, the 2 MB ceiling refusing without reading the bytes, a blank-lines-only file
refused, the extension list.

**`FileQueueModel` against `FakeLLMClient`.** Order; cancel mid-file leaves that задание
`.interrupted` and the rest `.queued`; resume starts from the first unfinished; `stopOnWarnings`
halts after a задание with warnings and not after a clean one; a write failure sets `saveProblem`
and does not fail the задание.

**`DocumentTermsRequest`.** Resumed exactly once under all four orders — proceed, cancel, cancel
after proceed, proceed after cancel — and a cancelled request's `translate` throws
`CancellationError`.

**The engine.** The hook is called once, at the review point, with the parsed entries, the
relevant user entries and the true часть count; edits reach `PromptBuilder`; an empty term list
and a failed term call each skip the hook; a hook that throws `CancellationError` aborts the run
and one that throws anything else fails it; `onProgress` fires `partsTotal + 1` times with a
monotonic `partsDone`. And §3.6's pinning test, which is the one that matters most: `nil` hook,
byte-identical output.

**`AppSettings`** on `InMemoryDefaults` — never a real suite; `batchModel`'s `nil`-means-follow
behaviour and the `"backgroundModel"` key specifically, including a pre-existing stored value
being picked up.

---

## 11. What only a human can check

For `docs/OPEN-ITEMS.md` §1. Every one of these is unobservable from this environment.

- The mode switch in the pane header, and whether both pane headers still read as one row.
- A queue of three files end to end: rows updating, the bar moving, the right pane streaming the
  selected file, the status bar counting files and части.
- «Отмена» mid-file, then «Перевести» resuming at the right file.
- A translation actually appearing beside its source in Finder, under the right name, and the
  numbered name when one is taken.
- The `NSSavePanel` fallback after a refused write.
- The terms sheet: the table at 12 rows, an editable «перевод» cell, Esc cancelling the run, and
  the ⌥⌘T escalation bringing the window forward from another app.
- The fourth settings tab at 560 × 480 (§9.2), and the four tab items not crowding.
- All of the above in dark mode.
- VoiceOver on the queue: a row announcing its file, its state and its progress without re-reading
  on every token.

---

## 12. Deliberate departures from the drawing

1. **A «Текст / Файлы» switch exists.** The drawing shows the queue occupying the left pane with
   no visible way in or out. An implicit mode reached by dropping would retire the shipped, tested
   behaviour that a dropped file fills the editor.
2. **The ⌥⌘T path escalates to the window** instead of showing the table in the panel (§6.1).
3. **«Переводить без правок» is dropped** (§6.3).
4. **Esc and ⨯ cancel the run** from the terms sheet. The drawing has no cancel at all; a modal
   sheet with no way out is a trap.
5. **The queue starts on «Перевести»**, not on the drop (§4.3).
6. **The settings tab is «Файлы», not «Пакетный».** Its neighbours are «Основные», «Модели»,
   «Глоссарий» — nouns. «Пакетный» is an adjective with nothing to modify.
7. **The batch model has no fixed default** and its picker's first entry is «Как для перевода по
   клавише» (§7.2). The drawing shows `aya-expanse:8b`, i.e. the interactive model, which is what
   this produces out of the box.
8. **«Показывать перед переводом» ships off** (§7.3).
9. **«Больше не спрашивать в этом прогоне»** is added to the sheet in a queue run (§6.4).
10. **The per-file ceiling is 2 MB** (§4.1). The drawing says nothing about size.
11. The drop hint omits `.text`, which `DroppedDocument` accepts. Kept as drawn — four extensions
    in a hint is already the point at which nobody reads it — and `QueueDrop` still accepts it.

---

## 13. Phasing

One spec, two phases, with a checkpoint between them. They are independent: neither compiles
against the other's types.

**Phase 1 — the queue.** §3.5 (progress — the queue row cannot say «Перевожу часть 4 из 7»
without it), §4, §5, §7, §8, and the parts of §10 that cover them. Delivers `2a` and `2c` with
`reviewDocumentTerms` present in settings but not yet consulted.

**Phase 2 — the gate.** §3.1–3.4, §3.6, §6, and their tests. Delivers `2b` and wires the toggle.

The engine split between the phases is deliberate: `onProgress` is a callback that cannot
suspend and cannot fail, so it carries none of §3.4's continuation risk and does not need the
gate's machinery to land.

Phase 1 alone is shippable. Phase 2 alone is not, because §6.4 needs a queue to suppress within.

---

## 14. Out of scope

Concurrent file translation. Translating a folder recursively. Any format but UTF-8 text.
Re-translating a finished задание in place. A queue that survives a relaunch. The Chinese and
Japanese term-extraction gap (spec §11a) — the gate makes it visible, since those languages
produce an empty term list and so no sheet, but fixing extraction is its own work.
