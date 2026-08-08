# Local Translator — design v1

Date: 2026-07-24, revised 2026-07-25
Status: approved for implementation
Prototype the document's measurements were taken on: `prototype-translation-engine/`
(not present in this repository — see section 11)

The 2026-07-25 revision records the results of the second experiment: the документный глоссарий
(document glossary) was confirmed and refined (section 4.4), the two-pass mode was cut from v1
(section 4.8), and the markup check moved to sequence alignment (section 4.7).

## Status of this document

**This is the pre-implementation design of 2026-07-24. It was written before the code existed.**
It records what was intended and the measurements the intent rests on, not what was built.

**Where this document and the code disagree, the code is right.** The code carries the
measurements; this carries the intent. Corrections made on 2026-07-29 after reading the spec
against the code are marked inline as **Corrected 2026-07-29**; the superseded claim is stated
rather than deleted, so the reason for the change stays visible.

Sections known to be superseded, and where the truth now lives:

- **Section 3** — the module list. `Package.swift` is the roster of targets.
- **Section 3.3** — the `TextCapture` roster. The directory listing of `Sources/TextCapture/`
  is the roster.
- **Section 4.9** — time-to-first-token semantics, and the granularity of streaming.
  `TranslationOutcome.timeToFirstTokenMS` and `Translator.streamChunkTranslation` in
  `Sources/TranslationCore/Translator.swift` are the authority.
- **Section 11** — the prototype is gone. See that section.

## 1. What this is

A macOS translator running entirely on local LLMs through Ollama. Text never leaves the machine.

Three interaction surfaces, of which **two ship in v1**:

1. **A global hotkey** — select text in any application, press a key combination, get a floating
   panel with the translation.
2. **A main window** — two fields, language, tone and model selection, a translate button.
3. **Batch file translation** — deferred to v2, see section 12.

Target languages: RU, EN, DE, FR, ES, PT, IT, ZH, JA — all equal.

Target content: technical documentation containing code, business correspondence, long texts and
articles.

## 2. What v1 does not have

Deliberately out of scope, to keep the work within one implementation plan:

- batch file translation (v2);
- translation history;
- OCR and translation of text on screen;
- speech recognition and synthesis;
- localisation formats (JSON/YAML/`.strings`) with placeholders;
- cross-device sync, an iOS version;
- auto-update, App Store distribution;
- a built-in model benchmark (v2, see section 12).

## 3. Architecture

The key principle: the translation domain logic knows nothing about Ollama and nothing about
SwiftUI. The prototype confirmed the seam holds.

> **Corrected 2026-07-29.** This section said "five modules, each a target in Swift Package
> Manager" and named `AppSettings` as one of them. There is no `AppSettings` target: it is
> `Sources/TranslatorApp/AppSettings.swift`. **`Package.swift` is the target list** — read it
> there rather than here, because a restated list is exactly what drifted. The subsections below
> stay because each carries reasoning that the manifest does not; where a subsection names a
> target that does not exist, it is corrected in place.

### 3.1 `OllamaKit`

A thin HTTP client against `http://127.0.0.1:11434`. Implements the `LLMClient` protocol declared
in `TranslationCore`.

Endpoints: `/api/tags` (installed models), `/api/chat` with NDJSON streaming, `/api/pull` with
progress, `/api/ps` (which models are resident).

Two mandatory rules, derived empirically:

- the `message.thinking` field in a response is read and **discarded**;
- the `think` parameter in a request is **never sent**. Verified on `qwen3:30b`: `"think": false`
  does not disable reasoning, it moves it out of `message.thinking` and into `message.content`,
  from where it lands directly in the translated text.

Ollama reports durations in nanoseconds — the client converts them to milliseconds at the
boundary.

### 3.2 `TranslationCore`

The domain core. Depends only on the `LLMClient` protocol, so it is fully testable with a fake
client and no running Ollama.

Contents:

| Component | Responsibility |
|---|---|
| `LanguageDetector` | Detects the source language via `NLLanguageRecognizer` |
| `Chunker` | Splits long text; a fenced code block is atomic |
| `TermExtractor` | Collects recurring terms from the source |
| `DocumentGlossary` | The document's temporary glossary, built from the extracted terms |
| `Glossary` / `GlossaryEntry` | The user glossary and its filtering by occurrence |
| `LemmaMatcher` | Compares word forms by lemma via `NLTagger` |
| `GlossaryVerifier` | Checks that the glossary was honoured in the result |
| `PromptBuilder` | Assembles system and user messages, including the term-list prompt |
| `ResponseCleaner` | Strips preambles and removes a spurious code-fence wrapper |
| `MarkupSkeleton` | Structural comparison of source and translation markup |
| `ModelPolicy` | Rules for choosing a model per execution path |
| `Translator` | Orchestrates all of the above |

### 3.3 `TextCapture`

All macOS-specific text capture. Split into its own module because it is the most fragile and
least testable part of the system — it needs to be kept away from the logic.

> **Corrected 2026-07-29.** This section listed `HotkeyManager`, `SelectionReader`,
> `PermissionsGate`. The actual contents of `Sources/TextCapture/` are `GeneralPasteboard.swift`,
> `HotkeyCombo.swift`, `HotkeyManager.swift`, `PasteboardSnapshot.swift`, `PermissionsGate.swift`,
> `SelectionReader.swift`. The directory listing is the roster; the two additions the design did
> not anticipate are the hotkey value type (`HotkeyCombo`) and the whole-pasteboard snapshot that
> the ⌘C fallback of section 6 requires.

### 3.4 `AppSettings`

Settings and their storage. Scalars live in `UserDefaults`. The пользовательский глоссарий (user
glossary) is a separate JSON file at
`~/Library/Application Support/LocalTranslator/glossary.json`, so it can be edited by hand and
kept in git.

> **Corrected 2026-07-29.** This is not a target. It is `Sources/TranslatorApp/AppSettings.swift`
> (the scalars) plus `Sources/TranslatorApp/GlossaryStore.swift` (the JSON file). Everything the
> section says about the storage split still holds.

### 3.5 `TranslatorApp`

The SwiftUI shell: `MenuBarExtra`, the floating panel, the main window, the settings scene.

### 3.6 Data flow on a hotkey press

```
HotkeyManager → SelectionReader → LanguageDetector → ModelPolicy
    → Translator (Chunker → TermExtractor → PromptBuilder → LLMClient)
    → ResponseCleaner → MarkupSkeleton + GlossaryVerifier → floating panel
```

> **Corrected 2026-07-29.** Two things about this sketch. The order inside `Translator` was
> written `TermExtractor → Chunker`; the code chunks first and extracts terms only when there is
> more than one чанк, so the arrow is `Chunker → TermExtractor` (see `Translator.translate`).
> And the whole left-hand sequence is owned by `HotkeyCoordinator` in `TranslatorApp`, which also
> decides the ordering of panel hide/capture/show — that ordering is measured, not preferred, and
> its reasoning lives in `Sources/TranslatorApp/HotkeyCoordinator.swift`.

Language detection uses the native `NLLanguageRecognizer` rather than the LLM: it is instant,
free, and does not occupy the model.

## 4. The translation engine

### 4.1 The prompt

The system message carries hard rules: output **only** the translation, with no preamble;
preserve the structure (line breaks, blank lines, list markers, heading levels); do not translate
the contents of fenced code blocks or inline code; do not touch URLs, email addresses, file paths,
CLI flags or identifiers; keep numbers, units and dates; follow the selected тон (tone).

Post-processing is mandatory and is not replaced by the prompt. `ResponseCleaner` strips preambles
of the form «Here is the translation:», «Вот перевод:» and removes a code-fence wrapper if the
model wrapped the entire reply in one.

### 4.2 Tone

Five modes: `neutral`, `formal`, `casual`, `technical`, `literal`. Each is a separate instruction
in the system prompt. The default is configurable; the factory value is `neutral`.

### 4.3 Chunking

Text is cut on paragraph boundaries. A fenced code block is an **atomic unit**: it is never cut,
even when it exceeds the target chunk size. Cut it, and the model receives an unclosed fence and
reliably "repairs" it by translating the code.

A paragraph that exceeds the budget on its own is cut on sentence boundaries.

The default chunk size is 900 characters, configurable in the advanced settings.

### 4.4 Terminological consistency

Passing the previous translated paragraph as context **does not solve the problem** — verified on
two models of different classes, both of which produced «местные языковые модели» in the first
чанк and «локальный перевод» in the fifth on the same text. The mechanism was replaced.

When there is more than one чанк, a preparatory pass runs before translation:

1. `TermExtractor` collects candidates from the source via `NLTagger`: individual nouns and
   adjectives, plus noun phrases two to three words long. A candidate enters the list if it occurs
   at least twice and is not a stop word. Frequencies are compared by lemma, so different
   inflected forms count as one term. The list is sorted by descending frequency and truncated to
   20 entries.
2. A single short request to the model translates that list and nothing else. The model must
   return every line in the form `source term => translation`, echoing the term verbatim.
3. The result becomes the документный глоссарий (document glossary) and is injected into the
   prompt of **every** чанк alongside the пользовательский глоссарий.

On conflict, the user glossary wins.

**Document terms are injected whole, without filtering by occurrence.** This is what distinguishes
them from the user glossary and is the reason the mechanism works: the terms were extracted from
this very document and capped at twenty, so none of them is irrelevant, whereas filtering by
surface form would lose a term in exactly those чанки where it stands in a different case — that
is, exactly where consistency is needed.

**Matching is by the echoed term, not by line position.** Positional matching admits a silent
shift: one missing line in the reply corrupts every term after it, and the error is forced into
every чанк. Parsing by term means an unrecognised line simply yields no entry.

The preparatory pass is skipped in two cases: there is only one чанк, or the source language was
not recognised — parsing text with a foreign language's morphology yields garbage terms.
Translation proceeds normally in both cases.

The mechanism is confirmed by measurement (see section 11): end-to-end term consistency rose from
64–68% to 88% across two runs.

Known limitation: a term translated out of context can be wrong — the measurement produced one
bad entry out of eleven. Supplying the list with context does not fix it, because the cause is the
term's isolation, not a shortage of information. The mitigation is to show the документный
глоссарий to the user (section 7.3), so a bad entry is visible.

### 4.5 The user glossary

An entry: `{term, doNotTranslate, translations: [language code: string]}`.

**Only relevant** entries are injected into the prompt — those whose term occurs in the чанк's
text. The mechanism is verified: on German, 5 of 5 injected terms were honoured.

### 4.6 Glossary verification

Substring comparison is unsuitable for inflected languages: the model correctly translated
`implementation guide` as «руководств**а** по реализации» in the genitive, and the check looked for
«руководство по реализации» and reported a violation.

`LemmaMatcher` reduces both the expected form and the translated text to a sequence of lemmas via
`NLTagger` and compares those.

The check has **three** outcomes:

- **honoured** — a lemma match was found;
- **not found** — no match; a warning is shown;
- **cannot be verified** — lemmatisation is unavailable for the target language, or the term is
  multi-word and spread across the sentence; no warning is shown.

A warning never blocks the result. Beside it sits an «игнорировать этот термин» action, which
excludes the entry from the check permanently.

The caution is deliberate: a check that falsely cries violation on a correct translation is worse
than no check at all — people stop believing it on the second day.

### 4.7 Markup integrity checking

Checking by substring presence is too weak: it missed three distinct defects out of the three that
occurred — a bare URL turned into a markdown link, a broken blockquote, and a paragraph shattered
into four lines by trailing spaces.

`MarkupSkeleton` reduces source and translation to a sequence of structural tokens and compares the
sequences. The tokens:

- a heading with its level;
- a list marker with its nesting depth;
- a blockquote marker;
- a fenced code block — content hash and language;
- inline code — the exact text;
- a URL — flagged as bare or inside a markdown link;
- граница абзаца (paragraph break) — a blank line between blocks;
- жёсткий перенос строки (hard line break) — two trailing spaces at the end of a line.

The last two tokens are kept separate deliberately: the `gpt-oss` defect was precisely a hard line
break, and it looked like a shattered paragraph.

**Comparison is by sequence alignment (LCS), not positional.** Under positional comparison, losing
one token near the start shifts everything after it, and one defect becomes dozens of warnings.
This is the same failure mode that made the glossary check cautious: a warning you cannot trust is
worse than no warning.

A divergence is shown as a concrete «было → стало» list. Like the glossary, this is a warning, not
a block.

### 4.8 Two-pass mode — cut from v1

Both formulations were tested; both failed.

**Editor** (the original): 1.8× the time, six fixes against two new breakages, including
rephrasing that lost content — «спецификация» became «задание», and the last paragraph shrank.

**Корректор** (proof-reader — the rewritten formulation, forbidden to rephrase and fitted with a
length guard): it removed the destructiveness — the guard accepted both runs, paragraph structure
survived — but overshot in the other direction. For 2× the time it edited a single letter in the
first run and changed nothing in the second, leaving obvious calques untouched in the very same
sentence.

Conclusion: a second pass does not pay for itself in either formulation. The route to quality is a
better model: `gpt-oss:20b` in a single pass fixed six errors of `aya-expanse:8b` that
`aya-expanse:8b`'s own second pass never saw.

Cut from v1 entirely — along with `TwoPassRefiner`, the length guard and the корректор prompt.
A candidate for reconsideration in v2, should a model appear for which a second pass makes sense.

### 4.9 Cancellation and streaming

> **Corrected 2026-07-29.** This section said the model's reply is handed to the consumer
> **per чанк, not per token**. That is no longer what the code does, and the paragraph below
> states the current contract. The *reason* given here survived the change and still governs the
> design: cleaning the reply (section 4.1) can only be decided on a whole first line (a preamble)
> or a whole reply (the fence unwrap), so nothing may be emitted before its shape is settled.

The reply is buffered only until the shape of the чанк's answer is decided, then delivered
incrementally. `Translator.streamChunkTranslation` buffers from the first token and leaves
buffering the moment any of three conditions holds: a `"\n"` appears (the preamble decision is made
on the completed first line), the buffer's normalised length passes the point where it can no
longer be a preamble, or the stream ends. One case never goes incremental: a reply that opens a
fence, because the whole-answer unwrap can only be decided at the end. The invariant that matters
is that `final` and the `onToken` stream agree exactly — чанки are joined with `"\n\n"` in both,
and there is a test pinning it. The trade — a less "live" first fraction of a second in exchange
for a contract the consumer can lean on — is made deliberately.

> **Corrected 2026-07-29.** This section said time-to-first-token is taken from the first **raw**
> token («с первого сырого токена»), so that it would not grow by the generation time of a whole
> чанк. That is the opposite of what the code does, and the number gates the product's hard
> requirement (section 5: TTFT under a second; `Sources/acceptance/main.swift` fails the run at
> 1000 ms). Do not "restore" the raw-token reading.

Time-to-first-token is measured to the first `onToken` call that carried actual чанк content —
the first moment a consumer could have shown the user something. It is deliberately **not** the
first raw token off the wire: a чанк whose whole-answer shape is undecided is buffered until its
first line settles, so timing the wire would measure an event nobody watching `onToken` can ever
observe. The `"\n\n"` чанк separator carries no content and does not count, and the internal
term-list call never reaches `onToken` at all. The value is `nil` when no token was ever emitted,
and that nil *is* the empty-reply signal (see section 11a). The authority is
`TranslationOutcome.timeToFirstTokenMS` in `Sources/TranslationCore/Translator.swift`, whose doc
comment carries the reasoning in full.

The request runs in a `Task`, cancelled when the floating panel closes or «Отмена» is pressed.
**Cancellation is checked explicitly** — `Task.checkCancellation()` before and after every network
call. Without it, `AsyncThrowingStream` *finishes* on cancellation instead of throwing: the loop
would receive a short buffer, keep issuing requests for every remaining чанк, and return a
truncated document as a successful result. Cancellation must surface as `CancellationError`.

One exception to the general degradation rule: a failure of the preparatory call that builds the
документный глоссарий leaves the glossary empty but lets the translation continue — it is an
enhancement, not the result itself. Cancellation does not fall under this exception and is
rethrown.

## 5. Model selection policy

`ModelPolicy` binds execution path to model. The basis is measurements on an M5 Pro / 48 GB, a
710-character EN → DE technical document:

| Model | TTFT (warm) | Total time | Role |
|---|---|---|---|
| `aya-expanse:8b` | 0.55 s | 5.7 s | Интерактивный путь |
| `gemma3n:e4b` | 2.7 s (cold) | 6.9 s | Excluded |
| `gpt-oss:20b` | 7.5–25 s | 28.7 s | Фоновый путь |
| `qwen3:30b` | 78.6 s | 82.4 s | Excluded |

A caveat on the table: `gemma3n:e4b` was measured on a cold load and its warm TTFT was never
measured — it is excluded on quality, not on speed, so finishing the measurement had no point. On
throughput it is comparable to `aya-expanse:8b` (52 against 46 tok/s).

**Интерактивный путь** (the interactive path — hotkey): `aya-expanse:8b`. The requirement is hard
— TTFT under a second.

**Фоновый путь** (the background path — the main window's button): `gpt-oss:20b`. Here tens of
seconds of reasoning is an acceptable price for noticeably better prose.

> **Corrected 2026-07-29.** The фоновый путь is not wired up. `ModelPolicy.defaultModel(for:
> .background)` returns `gpt-oss:20b`, but nothing reads it: `TranslationViewModel` builds its
> `ChatOptions` from `settings.interactiveModel` for both surfaces, so the main window's button
> runs the interactive model too. The split exists in the policy, not in the translation path.
>
> There was also an `AppSettings.backgroundModel` and a picker for it in Settings → «Модели».
> Both were **removed on 2026-07-29**: a stored value nothing reads is a defect the user cannot
> see. The policy above stands and the property returns when batch translation does — v2.

**A blacklist, with the reason shown in settings:**

- `gemma3n:e4b` — corrupts identifiers character by character. It produced
  `` `StructureDefiinition` `` inside inline code, and `Implemenentierungsleitfadens`. For a
  technical-documentation translator this is the worst possible failure: a type name in code broken
  silently.
- `qwen3:30b` — 78 seconds before the first character of translation.

The list is not hard-wired: any installed model can be chosen in settings, but blacklisted entries
are marked with a warning stating the reason. (The reason strings in `ModelPolicy.blacklist` are
English and are what `translate-cli` prints; the app renders the Russian
`RussianCopy.blacklistReasons`, keyed by the same prefixes, and falls back to the English text if
a prefix has no Russian counterpart.)

### 5.1 Model residency

`keep_alive` is load-bearing, not an optimisation: a cold load of `aya-expanse:8b` costs ~2000 ms
against ~155 ms warm. Without it, every hotkey press begins with a two-second pause.

The default is `30m`, configurable. At application launch the interactive path's model is warmed
with a short request; this is disabled by the «прогревать при запуске» setting (on by default).

## 6. Capturing the selected text

Two mechanisms, primary and fallback:

1. **The Accessibility API** — `AXUIElement` with the `kAXSelectedTextAttribute` attribute. Clean,
   and it does not touch the clipboard. But it does not work everywhere: some Electron applications
   and browsers ignore the attribute.
2. **Synthetic `Cmd+C`** — the fallback. Works almost everywhere. Mandatory: save the previous
   clipboard contents before the synthetic press and restore them afterwards, or the application
   silently overwrites the user's clipboard.

Order: Accessibility first, then the synthetic press if the result was empty. If both paths come
back empty, the floating panel shows a «выделите текст» hint.

### 6.1 Permissions

The application needs Accessibility access. `PermissionsGate` checks
`AXIsProcessTrustedWithOptions`, and if access is absent shows an onboarding screen explaining why
it is needed, with a button that opens the relevant System Settings pane.

> **Corrected 2026-07-29.** There is no onboarding screen. `TranslatorApp` is an `LSUIElement`
> app with no window at launch to put one in, so onboarding takes three shapes instead: the
> system's own dialog, raised exactly once at first launch (latched by
> `AppSettings.hasRequestedAccessibility`, so a user who declined is not nagged); the panel's own
> prompt, shown at the moment the user presses the hotkey and nothing happens; and a standing
> indicator in Settings → «Основные». All three name the pane explicitly — «Конфиденциальность и
> безопасность» → «Универсальный доступ» — and offer «Открыть настройки системы». The same
> correction applies to the corresponding row of section 8's table.

Without the permission, translation by key combination does not happen: the combination itself is
registered through Carbon and fires even without access, but both capture paths stay silent
without it. The application exploits this — instead of silence it shows, in the floating panel,
an explanation and a button into System Settings at exactly the moment the user tried to use the
hotkey. The main window remains fully functional.

### 6.2 Hotkey and translation direction

The default combination is `⌥⌘T`, configurable.

The direction is derived automatically from two settings: the **primary language** (factory value:
Russian) and the **working language** (factory value: English). If the detected source language
equals the primary one, translation goes to the working language; otherwise to the primary one.

## 7. The interface

### 7.1 Menu bar

`MenuBarExtra` with an icon. The menu: open the main window, settings, Ollama status (running /
not running / model resident), quit.

### 7.2 The floating panel

An `NSPanel` with the `.nonactivatingPanel` style — critical, or the panel steals focus from the
application the user was selecting text in and breaks their workflow.

It appears next to the cursor. It contains: the detected translation direction, the translated
text rendered as it streams in, glossary and markup-integrity warnings (if any), and «скопировать»
and «открыть в окне» buttons.

`Esc` closes the panel and cancels the request. `Enter` copies the result and closes. The
«копировать автоматически» setting (off by default) puts the result on the clipboard as soon as it
completes.

### 7.3 The main window

Two text fields — source and result. Above them: source language selection (with a «определить
автоматически» entry), target language, and tone. A «Перевести» button that becomes «Отмена» while
running.

> **Corrected 2026-07-29.** The window has no model picker. Its pickers are source language,
> target language and tone; the model is chosen in Settings → «Модели» — and, per the correction
> in section 5, the window runs the interactive model regardless.

Below the result is a warnings block: markup divergences and glossary violations, each with a
«было → стало» explanation.

In the same place, as a collapsed list, is the **документный глоссарий** — the terms the engine
fixed for this text and their translations. This is the mitigation for the known defect from
section 4.4: a term translated out of context can be wrong, and only a human eye can see it. The
list is short (up to twenty rows) and reads in a minute. An entry can be muted by the same
mechanism as a glossary violation.

### 7.4 Settings

Four tabs:

- **«Основные»** — hotkey, primary and working languages, default tone, auto-copy, warm-up on
  launch.
- **«Модели»** — the interactive path's model, the background path's model, `keep_alive`. The list
  comes from `/api/tags`; blacklisted entries are marked with a warning and its reason.
- **«Глоссарий»** — a table of entries with editing, the "do not translate" flag, per-language
  translations, and the list of muted checks. An "open file" button leads to `glossary.json`.
- **«Дополнительно»** — chunk size, temperature.

> **Corrected 2026-07-29.** The fourth tab was named «Продвинутые» here; the shipped tab is
> labelled «Дополнительно». Its contents are as described.

## 8. Error handling

| Situation | Behaviour |
|---|---|
| Ollama not running | A clear message and a «Запустить Ollama» button. The application does not try to start it silently. |
| Model not downloaded | An offer to `pull` it, with progress shown through the `/api/pull` stream. |
| Request timeout or hang | Cancelled after 120 s, with a «Повторить» button. |
| Empty selection | A hint in the floating panel. |
| No Accessibility permission | An explanation and a link into System Settings. (Was: "an onboarding screen" — corrected 2026-07-29, see section 6.1 for the three shapes this actually takes.) |
| Model returned an empty reply | An error message and a «Повторить» button; the previous translation's result is not wiped. |

## 9. Data storage

- Scalar settings — `UserDefaults`.
- The user glossary and the list of muted checks —
  `~/Library/Application Support/LocalTranslator/glossary.json`.
- Translations are not written anywhere: v1 has no history.

## 10. Testing

**Unit tests for `TranslationCore` with a fake `LLMClient`** — the bulk of the suite. Covered:
chunking (above all the atomicity of fenced code), prompt assembly, filtering of the user glossary
by occurrence, lemma comparison and the three check outcomes, preamble stripping, code-fence
unwrapping, construction and LCS comparison of `MarkupSkeleton`, parsing the term list by echoed
term (including a missing and a spurious line), and merging the user and document glossaries.

**An acceptance run** — a separate task in the plan, not in CI. A corpus of texts is run through a
live Ollama and objective metrics are compared against the prototype's recorded baseline.

> **Corrected 2026-07-29.** The harness exists: `swift run acceptance`
> (`Sources/acceptance/main.swift`), run from the package root, over `corpus/` — five files today,
> not the 10–20 the last paragraph of this section anticipates. It compares against the thresholds
> in the table below, which are constants in the harness, not against a file inherited from the
> prototype; the list of already-accepted model behaviours lives in the harness too
> (`isKnownModelBehaviour` and `knownFileLimitations`). It exits 1 on regression.

Thresholds are **measured by input shape**, not as one number for the whole corpus. This
refinement was made after the first run came back red on three counts, none of which was an engine
regression — all three showed the threshold was being applied to something other than what it
describes.

| Check | Threshold | Measured on |
|---|---|---|
| TTFT | under 1000 ms | single-чанк files only — the hotkey shape, which is what the requirement was written for. A multi-чанк document honestly pays for the preparatory glossary call, and its time is printed for information, without an assertion. |
| Markup integrity | zero divergences outside the known list | compared against the list of **measured** model habits. A new divergence is a failure; a known one is printed with a note and stays visible. |
| Term consistency | average over three runs no lower than 80% | three runs of the same input gave 80.6%, 86.1% and 91.7% — a single measurement at the boundary cannot tell signal from noise. The threshold's job is to distinguish a working glossary from one that has fallen back to the 64–68% baseline without it. |

The "zero markup divergences" requirement of the first revision contradicted the prototype's own
measurement, which records that `aya-expanse:8b` rewrites a bare URL as a markdown link. The old
substring-presence check did not see this; the structural one does, and its message is a sign of
the checker working, not of breakage.

The allowance is tied to a file and a token kind rather than added to a global list. A code-block
token carries only a content hash, so permitting hash mismatches in general would also permit the
model to rewrite a command outright; targeting a specific block is impossible too, since
`String.hashValue` is seeded per process and the pair of hashes changes from run to run.

**`OllamaKit` tests on fixtures** — parsing the NDJSON stream, including a response with a
`message.thinking` field that must be discarded, and the final frame with statistics in
nanoseconds.

**A quality run against real models** — a separate scheme, not in CI. A set of 10–20 texts across
three content types is run through a live Ollama; objective metrics (markup integrity, glossary
adherence, TTFT) are checked, and the prose is judged by a human. The prototype already contains a
working basis for this harness.

> **Corrected 2026-07-29.** That basis now lives in `Sources/acceptance/main.swift`; the prototype
> is gone (section 11). The human judgement of prose is still manual and unautomated.

**The interface** — by hand. UI automation does not pay for itself in v1.

## 11. Appendix: where the numbers come from

The measurements were taken on 2026-07-24 and 2026-07-25 on an Apple M5 Pro / 48 GB, macOS 26.5.2,
Ollama 0.31.1, with the `prototype-translation-engine/` prototype. The details and full output
texts are in its README.

> **Corrected 2026-07-29.** The prototype is not in this repository: `prototype-translation-engine/`
> holds nothing but build artefacts, is untracked, and a fresh clone gets an empty directory — its
> README and its full outputs are not recoverable from here.
> These figures are therefore historical: they justify decisions that were really made, but they
> cannot be reproduced from a clone.
> The ones that still gate anything are re-measured by `swift run acceptance` against a live
> Ollama; anything else below stands on the record of the day it was measured and nothing more.

The key facts the design rests on:

1. A warm `aya-expanse:8b` gives TTFT of 330–570 ms and 41–46 tok/s; a cold load costs ~2000 ms
   against ~155 ms warm.
2. Fenced code blocks, inline code and URLs survived every run on both working models with the text
   split into 5 чанков.
3. The terminology break between чанками reproduced identically on `aya-expanse:8b` and
   `gpt-oss:20b` — the model is not at fault, the architecture is.
4. Substring-based glossary checking produced a false positive on the Russian genitive and ran
   clean on German.
5. A second pass in the editor formulation: 12.3 s → 22.3 s, six fixes against two new breakages,
   including lost content. In the корректор formulation: 2× the time, one changed letter in the
   first run and zero changes in the second.
6. Документный глоссарий: end-to-end term consistency 68% → 88% and 64% → 88% across two runs. Of
   eleven recorded terms, one was translated wrongly. Adding context to the term list does not fix
   that error in any of the three formulations tested — the cause is the term's isolation, not a
   shortage of information.
7. `gemma3n:e4b` corrupted an identifier inside inline code.
8. `qwen3:30b` spent 78 s reasoning before the first character; `"think": false` moves the
   reasoning into `message.content` and makes it worse.

## 11a. Known limitations of v1

Measured, not fixed, recorded deliberately. Each is something worth knowing before building on
top.

**The документный глоссарий does not work for Chinese and Japanese sources.** `NLTagger` tags
Japanese words as `OtherWord` — not a single noun or adjective across 114 tokens — and the
three-character minimum term length cuts away almost all Chinese vocabulary. For these languages
the mechanism of section 4.4 silently does nothing: `documentGlossary` comes back empty with no
signal that the language is unsupported for this purpose. The languages are declared equal
(section 1), so this is a gap between promise and implementation, not a deliberate narrowing.
Fixing it requires a separate approach to term extraction for scripts without inflection — work
for v2.

**The model translates human-readable text inside code.** `aya-expanse:8b` returned
`git tag -m "См. CHANGELOG.md"` instead of `"See CHANGELOG.md"`. A block consisting only of flags
and paths was preserved byte for byte — the model understands the rule but treats natural language
as an exception to it. Sharpening the prompt was attempted and changed nothing; the attempt was
deliberately limited to one round, to avoid tuning the wording to a single model.

**Hard line breaks are lost in chunking.** `Chunker` trims trailing whitespace on the last line of
a block, and two trailing spaces in Markdown are precisely a жёсткий перенос строки. The markup
check no longer reports this (it compares against what the model actually received), but the
content really does change. The defect is in `Chunker`, not in the check.

**An empty model reply is now distinguishable.** `timeToFirstTokenMS == nil` means not a single
token ever went out — that nil is the empty-reply signal. Section 8's row is implemented with no
change to the core; the limitation was removed by the edit that made this metric optional.

**Terminology divergence between чанками is invisible to the verifier.** `GlossaryVerifier` checks
the joined document, so a term translated differently in different чанки but present in the
required form at least once is reported as honoured. The per-position check exists only in the
acceptance harness and has not been moved into the core.

## 12. What comes after v1

- **Batch file translation** — the third surface. **Built**, as the file queue in the main
  window; see `docs/superpowers/specs/2026-08-07-batch-translation-design.md`. The claim above
  turned out to be very nearly right: the core took two additions, both defaulted so that
  nothing already calling it changed — `onProgress`, because a queue row cannot say «часть 4 из
  7» without it, and a review hook for the document glossary — which this line called «still
  to come» until it shipped on the same branch that wrote the words.
- **A built-in model benchmark** — moving the prototype's harness into settings, so the blacklist
  is built from measurements on the user's machine rather than hard-wired in code.
- **The second pass** — to be reconsidered if a model appears for which it makes sense. Both
  formulations tested failed on `aya-expanse:8b`.
- **Collecting terms from the prose** — instead of translating a list of terms, extract them from
  already-translated text. This strikes at the root of out-of-context mistranslation, but it brings
  back a privileged first чанк and requires an alignment pass. Justified if bad terms turn out to
  be common in practice.
