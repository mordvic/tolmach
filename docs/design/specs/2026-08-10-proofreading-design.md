# Proofreading and style rewriting («Правка») — design

Date: 2026-08-10
Status: designed, not implemented

## Status of this document

This is the pre-implementation design for the app's second operation: correcting a text in
its own language — spelling, punctuation, grammar, and optionally style — instead of
translating it. Once the code exists, **the code is the authority on behaviour and this
document is the authority on why**.

A claim marked **measured** restates an observation already recorded in the code or in
`docs/`; the citation says where. Claims about other products in §3 cite their sources and
were gathered on 2026-08-10; products change. Everything else is intent.

---

## 1. Vocabulary

`CONTEXT.md` owns the app's words and gains these. One word per concept, no synonyms.

| Word | Means | Never |
|---|---|---|
| **правка** | the operation: correct a text in its own language | «корректура», «редактура», «улучшение» |
| **степень** | how freely wording may change: «только ошибки» / «ошибки и стиль» | «уровень», «глубина» |
| **стиль** | the target register a rewrite aims at | «тон» (that word belongs to translation's `Tone`) |
| «Перевод \| Правка» | the operation switch, in the window toolbar and in the panel | — |
| «Исправить» | the primary action's title while правка is selected | «Проверить», «Улучшить» |
| «Ещё вариант» | re-run the same правка for a different rendering | «Повторить» (that is the *failure* retry) |

## 2. What the user gets

- **Two surfaces**: the main window (an operation switch in the toolbar) and the ⌥⌘T panel
  (a switch inside the panel; the hotkey itself always starts with перевод). The file queue
  and `translate-cli` deliberately stay translation-only in this iteration.
- **Степень** — two values:
  - «только ошибки»: spelling, punctuation, obvious grammar; wording untouched, minimal diff.
  - «ошибки и стиль»: the above plus awkward phrasing, bureaucratese, repetition — the
    author's voice and meaning preserved.
- **Стиль** — a target register for rewriting, meaningful only under «ошибки и стиль»:
  «как в оригинале» (default) / «дружеский» / «деловой» / «профессиональный» /
  «простой и ясный». Under «только ошибки» the style control is **disabled**, not silently
  ignored (§3, DeepL/Apple precedent).
- The result is the corrected text, streamed like a translation. No change highlighting in
  this iteration (§10.1).
- «Ещё вариант» on a finished правка re-runs the same input for a different rendering —
  offered only when the finished run's степень was «ошибки и стиль»: under «только ошибки»
  the promise is a deterministic minimal diff, and "another variant" of that promise is a
  contradiction (product review, 2026-08-10).
- The output language is the input language, always. Detection failing does not block the
  run; the prompt then forbids translating instead of naming the language.

## 3. What other products do, and what was taken

Surveyed 2026-08-10: Apple Intelligence Writing Tools, DeepL Write, Grammarly, LanguageTool,
QuillBot, Wordtune, Notion AI, Microsoft Copilot (Teams/Word). Full notes are in the design
conversation; the load-bearing findings:

- **Every product separates correction depth from tone.** Apple: `Proofread` vs `Rewrite` +
  tone buttons; DeepL: `Corrections only` checkbox vs style/tone selectors; Notion:
  `Fix spelling & grammar` vs `Improve writing`; Teams Copilot: `Rewrite` vs `Adjust`.
  Our «степень» × «стиль» pair matches the industry taxonomy exactly.
  (apple: support.apple.com/guide/mac-help/mchldcd6c260/mac; deepl:
  developers.deepl.com/docs/translate/controlling-writing-style-and-tone; microsoft:
  support.microsoft.com/en-us/office/53315d9c-93be-45ab-9004-2f8205725cc7)
- **No product defaults to a tone.** DeepL «None set», QuillBot `Standard`, LanguageTool
  `General`. Hence «как в оригинале» is the style default, and «только ошибки» is the
  degree default — the safer default for a tool that touches someone's finished text.
- **Contradictions are removed constructively, not by ignoring input.** Apple makes tone
  inapplicable to Proofread by construction; DeepL disables styles under `Corrections only`
  and says so. Hence the disabled style control.
- **«деловой» and «профессиональный» read as synonyms in one list** — at DeepL they live on
  *different axes* (`Business` = genre, `Confident`/`Diplomatic` = sound). We keep both but
  disambiguate with descriptions, DeepL-style: «деловой — письма, официальная переписка»,
  «профессиональный — документация, отчёты, рабочий тон без канцелярита». The descriptions
  render in the toolbar (`.help`) **and** beside the settings pickers.
- **Length (`shorter`/`longer`) is always its own axis** and never mixed into tone lists —
  we have no length axis, and if one is ever added it must be a third control (§10.2).
- **Multiple renderings are the core gesture of rewriting** (Wordtune always offers
  variants; Word Auto Rewrite has `Regenerate`). Hence «Ещё вариант» — cheap for us because
  `temperature` 0.2 already varies output and the re-run machinery exists.
- **DeepL supports no styles for Russian at all** — there is no prior art to copy for the
  prompt wording; the style instructions in §4 are ours to calibrate, and the acceptance
  harness is where that calibration would eventually live.

## 4. Engine — `TranslationCore`

The hard rule stands: translation logic knows nothing about Ollama or SwiftUI. Правка is a
second route through the same pipeline, not a second pipeline.

### 4.1 `ProofreadingLevel` and `RewriteStyle`

Two new enums beside `Tone`, same shape (`String, CaseIterable, Sendable`, an English
`instruction` for the prompt):

- `ProofreadingLevel`: `errorsOnly`, `errorsAndStyle`.
- `RewriteStyle`: `original`, `friendly`, `business`, `professional`, `plain`.
  «Как в оригинале» is a **case**, not the absence of a value — exactly as `Tone.neutral`
  is a case. `nil` is thereby reserved for what it means everywhere else in this app:
  «no override, follow the setting». Spelling «как в оригинале» as `nil` instead would
  force a double optional onto the toolbar override and the setting. `.original`
  contributes no instruction to the prompt.

The style is honoured only under `.errorsAndStyle`. `PromptBuilder` enforces this (a style
passed with `.errorsOnly` never reaches the prompt) and a test pins it; the app additionally
disables the control so the user cannot express the combination.

### 4.2 `PromptBuilder`

`proofreadMessages(text:language:level:style:)` returns the same two-message shape as
translation. The system prompt:

- Role: a meticulous copy editor, not a translator.
- **«Never translate. The corrected text must be in the same language as the original.»**
  When `language` is known it is named twice — «The text is in Russian» and «must be in
  Russian» — because the single most damaging failure of this feature is a model that
  helpfully translates.
- The structure and protection rules — preserve line breaks/list markers/blockquotes/heading
  levels; never touch fenced or inline code; never touch URLs, emails, paths, CLI flags,
  identifiers; keep numbers, units and dates — are **the same lines the translation prompt
  uses, extracted into one shared private constant** so the two prompts cannot drift. The
  translation prompt's wording changes for nobody in this work; the extraction is
  wording-neutral.
- The level instruction, then the style instruction when one applies.

No glossary block, ever: правка has no target language for `translations[target]` to key
on, and «leave untranslated» is vacuous when nothing is translated.

The user prompt mirrors translation's `<text>` markers: «Correct the text between the
markers.»

### 4.3 `Translator.proofread`

```
proofread(text:level:style:source:options:maxChunkCharacters:onToken:onProgress:)
    async throws -> TranslationOutcome
```

The route: detect (unless `source` is given) → `Chunker.plan` → per-chunk calls → clean →
`MarkupSkeleton.diff` → assemble via `ChunkPlan.assembled(from:)`. **No** glossary stages:
no `TermExtractor`, no term-list call, no review hook, no user glossary, no
`GlossaryVerifier`.

The dangerous machinery is shared, not copied. `streamChunkTranslation` — the buffering
until the reply's shape settles, the fence path, the preamble decision, the `emit` that
stamps `firstTokenAt` — moves out of `translate`'s body into a private helper used by both
routes, along with the separator forwarding and the trailing-separator emission. The
contract «`final` and the `onToken` stream agree exactly» then holds for правка by
construction, and the existing pinning tests keep holding for перевод because the behaviour
is the same code. `Task.checkCancellation()` sits before and after every network call on
the new route exactly as on the old one — `AsyncThrowingStream` finishes silently on
cancellation (measured; see `Translator.translate`'s comments).

**It returns `TranslationOutcome`, not a new type.** The glossary fields come back honest
and empty (`documentGlossary: []`, `checks: []`, `documentGlossaryFailure: nil`,
`documentGlossaryAttempted: false`), `detectedSource` is the text's own language (nil when
undetected), `timeToFirstTokenMS` keeps its nil-means-empty-reply contract, `stats` covers
the per-chunk calls. Reason: every consumer — `outcome` on the view model, `WarningsView`,
`RunStatusBar`, `adopt(from:)` — speaks this type, and a parallel `ProofreadOutcome` would
duplicate each of them to carry fields that are honestly empty. The cost is that a reader
of `TranslationOutcome` must know правка fills some fields with vacuous values; the field
docs gain one line each saying so.

## 5. View model — `TranslationViewModel`

- New app-layer enum `TextOperation`: `.translate`, `.proofread`. Russian labels
  («Перевод», «Правка») live in `RussianCopy`, exhaustive, no `default:`.
- The model gains `operation: TextOperation = .translate`,
  `proofreadingLevelOverride: ProofreadingLevel?` and `rewriteStyleOverride: RewriteStyle?`
  — plain optionals resolved against the settings at run start
  (`?? settings.defaultProofreadingLevel`, `?? settings.defaultRewriteStyle`), exactly the
  `toneOverride` shape. No double optional exists because «как в оригинале» is a case
  (§4.1).
- The entry point becomes `run()`, dispatching on `operation`: the translate branch is
  today's `translate()` unchanged; the proofread branch resolves level and style and calls
  `translator.proofread`. Everything around the branch is shared and untouched: the
  re-entrancy guard, the `AsyncStream` consumer and its `await consumer.value` barrier,
  spec 8 (the previous result survives until the first real token), the
  empty-reply/`CancellationError`/failure endings and their Russian messages.
- `resolvedOperation: TextOperation?` and `resolvedProofreadingLevel: ProofreadingLevel?`
  (nil for a translation) are assigned beside `resolvedTarget` and `outcome`, and
  cleared with them — the same pairing rule those two already obey, for the same reason: a
  header or warning must never describe another operation's result. For правка,
  `resolvedTarget` stays nil (there is no target) and the header line comes from
  `RussianCopy.proofreadHeader(language:)` — «правка · русский», or «правка» alone when the
  language went undetected.
- Each instance carries its own `operation`; the window and the panel stay independent, as
  their models already are.
- `adopt(from:)` moves `resolvedOperation` and `resolvedProofreadingLevel` with the rest of
  the five-value unit it already moves — the panel can hand a правка to the window like it
  hands a translation, and the window's «Ещё вариант» then answers about the adopted run.

## 6. The window

- The toolbar, in «Текст» mode only, gains the operation switch «Перевод | Правка»
  (segmented, like the mode switch on the left pane). «Файлы» has no operation: the queue
  is translation-only.
- While «Правка» is selected: «Из», ⇄, «В» and «Тон» are **hidden** (not disabled — they
  answer questions правка does not ask), replaced by two menus in the same `directionMenu`
  chrome: «Степень» and «Стиль». «Стиль» is disabled while степень is «только ошибки»
  (§3). Each style row carries its `.help` description. The toolbar sheds more controls
  than it gains, so the 700 pt minimum is safe — verify against `Scripts/toolbar-fit.swift`
  rather than assume, per that script's purpose.
- `PrimaryAction` gains `startTitle: String` — «Перевести» or «Исправить» — read by the
  toolbar button and the «Перевод» menu item both, so the two cannot disagree. ⌘↩ and ⌘.
  keep flowing through `PrimaryAction` and need no new declarations. `canStart`, `cancel`,
  `canCopy`, `canClear`, `canSwap` are unchanged in shape; `canSwap` is `false` under
  правка (nothing to swap).
- `TranslationPane`'s title follows the operation in «Текст»: «Правка» instead of
  «Перевод».
- «Ещё вариант» appears in the pane header beside «Скопировать» when
  `resolvedProofreadingLevel == .errorsAndStyle && state == .finished` (§2's rule: never
  under «только ошибки»), and calls `run()` again on the unchanged source. Spec 8 already
  makes that safe: the previous rendering stays until the new one's first token.
- `operation` lives on the view model, not in `MainWindowView` `@State`, for the same
  reason `mode` lives in `TranslatorApp`: the «Перевод» menu must read it, and the app owns
  the models.

## 7. Settings

«Основные», beside «Тон по умолчанию»:

- «Степень правки» — `ProofreadingLevel`, default `errorsOnly`, key `"proofreadingLevel"`.
- «Стиль правки» — `RewriteStyle`, default `.original` («как в оригинале»), key
  `"rewriteStyle"`, stored as the raw value exactly as `defaultTone` is. The picker shows
  the same per-style descriptions as the toolbar (§3): a caption under the picker, not a
  tooltip, because settings are where a user chooses deliberately.
- Both accessors follow the `AppSettings` shape: read/write `UserDefaults` directly,
  `access(keyPath:)`/`withMutation(keyPath:_:)` by hand.
- The settings pane also disables «Стиль правки» while «Степень правки» is «только
  ошибки», mirroring the toolbar rule — one rule, stated once as a computed property both
  surfaces read (`RewriteStyleAvailability` or similar), pinned by a test.

## 8. The panel

> **Corrected 2026-08-15.** The first bullet below no longer describes the code, and neither
> does the «the panel gets no pickers» one. There are two shortcuts now — ⌥⌘T перевод and
> ⌥⌘R правка by default — each carrying its own operation into the same press, and the panel
> has the степень/стиль controls this section predicted as «the expected first ask». Those
> controls write the settings rather than per-run overrides, so «правка in the panel uses the
> settings defaults» still holds — the user can now change those defaults from the panel. See
> `docs/design/specs/2026-08-15-proofread-hotkey-design.md`. Everything else in this
> section — the switch, `switchOperation(to:)`'s refusal to read a new selection, «Ещё
> вариант», `autoCopy` — is unchanged.

- A press of ⌥⌘T behaves exactly as today: capture → перевод. The panel gains the
  «Перевод | Правка» switch in its pinned chrome (by the header). The panel stays a
  readout: the switch only calls a new callback, and `HotkeyCoordinator` decides.
- `HotkeyCoordinator.switchOperation(to:)`: guarded on a captured `.text` selection and
  `panelModel.state != .running` (the `retry()` guards), sets `panelModel.operation` and
  re-runs the **already captured** selection through `runTranslation()`. It never reads a
  new selection — the user's selection may be long gone, and silently operating on
  something else would be worse than a control that does nothing (the `retry()` reasoning,
  verbatim).
- Every new press resets `panelModel.operation = .translate` before running: the hotkey is
  predictable, the switch is per-presentation.
- Правка in the panel uses the settings defaults for степень and стиль; the panel gets no
  pickers. `autoCopy` applies to a finished правка exactly as to a translation — it is the
  same `runTranslation()` path.
- **A deliberate consequence, stated so nobody reads it as a defect:** with factory
  settings (степень «только ошибки», §7), правка in the panel is purely error correction
  and «Ещё вариант» never appears there — style rewriting is reachable from the panel only
  after the user changes the default in settings, and with its own pickers only in the
  window. That is the safe-default trade (§3) accepted knowingly; if panel-правка earns
  traction, per-panel степень/стиль controls are the expected first ask (product review,
  second pass, 2026-08-10).
- «Ещё вариант» appears in the panel's pinned button row under the same condition as in
  the window (степень of the finished run was «ошибки и стиль») and calls the
  coordinator's re-run.
- The switch and the button add fixed-height chrome to `PanelView`; the measuring copy
  picks them up automatically because it renders the same view. No `PanelSizer` rule
  changes. If the panel opens visibly short during implementation, the reservation path in
  `PanelView` is where to look first (measured behaviours; see `docs/reference/PLATFORM-TRAPS.md`).

## 9. Errors, edges, and what does not change

- Empty reply, cancellation, dead Ollama: same endings, same Russian copy — the shared
  `run()` machinery is what decides, and it does not fork.
- Undetected language (a tenth language): правка proceeds; the prompt omits the language
  name and keeps the translation ban. `detectedSource` stays nil and the header says
  «правка» alone.
- The interactive model (`aya-expanse:8b` by default) serves правка: both surfaces are
  interactive and TTFT < 1 s binds them equally. `ModelPolicy` is untouched; no new role.
- The file queue, `translate-cli`, the acceptance harness, `GlossaryStore`, the terms
  review — untouched. Правка never raises the terms sheet because it never builds a
  glossary.
- Nothing derived from the user's text is logged, on either route — the standing rule.

## 10. Deliberately deferred (with the precedent that argues for each)

1. **Change highlighting with explanations — the designated first fast-follow.** Apple's
   Proofread underlines each fix and explains it; that underlining is a *trust* mechanism,
   not decoration, and «только ошибки» without it asks the user to take a minimal diff on
   faith. Deferred on effort (structured output is a separate quality investigation for a
   local 8b model), but deliberately first in this list: when правка ships and holds, this
   is the next piece of it, ahead of anything else here (product review, 2026-08-10).
2. **A length axis («короче / длиннее»).** Teams `Make it: concise/longer`, QuillBot
   `Expand/Shorten`, Notion. Always a separate axis in the wild; would be a third control
   here, added only if wanted after the feature lands.
3. **A free-form instruction** (Apple «Describe your change»). A different class of
   feature — arbitrary prompt engineering over someone's text — with different quality
   risks.
4. **Multiple simultaneous variants** (Wordtune). Costs N× generation on local hardware;
   «Ещё вариант» is the cheap 80%.
5. **Writing the result back into the other application.** Apple replaces inline; for us
   that would be synthetic paste via Accessibility into a foreign window — fragile,
   dangerous to the user's text, and against the panel's readout-plus-explicit-copy model.

## 11. Testing

Offline, Swift Testing, `FakeLLMClient`, `InMemoryDefaults` — the standing rules, plus
`docs/reference/TESTING.md`'s shapes (particularly: no test may restate the assembly formula; call
`ChunkPlan.assembled(from:)`).

- **Prompt**: the level instruction reaches the system prompt; the style instruction
  reaches it only when the level is `.errorsAndStyle` *and* a style is set; the language is
  named when known and the translation ban is present always; no glossary block appears
  even when entries exist.
- **Engine**: exactly one model call per chunk and zero term-list calls (the fake counts);
  `final` equals `plan.assembled(from:)` of the cleaned chunks; the stream reconstructs
  `final` byte for byte; cancellation surfaces as `CancellationError` before and after
  calls; an all-empty reply yields `timeToFirstTokenMS == nil`; the outcome's glossary
  fields are empty and `documentGlossaryAttempted` is false.
- **View model**: `run()` under `.proofread` sends the proofread prompt (the fake inspects
  messages); spec 8 holds on the правка path; `resolvedOperation` is assigned with
  `outcome` and moved by `adopt(from:)`.
- **PrimaryAction**: `startTitle` follows the operation; the файлы mode never exposes
  правка.
- **Coordinator**: `switchOperation` re-runs the captured selection and reads no new one; a
  press resets the operation to `.translate`; `autoCopy` fires on a finished правка.
- **Availability rule**: the style-disabled-under-errors-only property, as a value both the
  toolbar and the settings pane read.
- **Settings**: defaults and storage round-trips for both keys; an unreadable stored value
  falls back to the default, as every enum-backed setting here does.
- **RussianCopy**: labels exhaustive; `proofreadHeader` with and without a language.

### 11.1 The manual quality gate (live model, before merge)

The offline suite proves the prompt is assembled right and says nothing about whether the
pinned interactive model can actually proofread — it is pinned for translation TTFT
(`ModelPolicy`), and its editing quality in any language is unmeasured. Two failures the
offline tests structurally cannot catch: the model **translating** despite the ban, and the
model **paraphrasing under «только ошибки»**, which breaks the minimal-diff promise that
mode is named for.

So the feature does not merge on green tests alone. Before merge, a manual corpus run
against the live default model (`aya-expanse:8b`):

- ~10 short texts — Russian and English, mixed — each seeded with known spelling,
  punctuation and grammar errors, at least one containing inline code and one a fenced
  block.
- Pass criteria, per text: the output language equals the input language, every seeded
  error is fixed or at minimum untouched-but-not-worsened, code/URLs/identifiers are byte
  identical, and under «только ошибки» the wording outside the seeded errors is unchanged
  (eyeball diff — this gate is exactly the manual check the deferred highlighting will one
  day automate).
- Each rewrite style run once on one text, checked for register shift without meaning
  drift.
- The corpus and the observed results are recorded in `docs/reference/OPEN-ITEMS.md` (a manual check
  owed to a human — that file's stated purpose) or, if the corpus proves worth keeping, as
  a new acceptance-harness task later. If the model fails the gate, the feature waits on
  prompt calibration or a model decision — it does not ship on the strength of the offline
  suite.

## 12. Documentation updates shipped with the code

- `CLAUDE.md`: the pipeline section gains the proofread route (one paragraph: shared
  machinery, no glossary stages, returns `TranslationOutcome` with empty glossary fields).
- `CONTEXT.md`: the §1 vocabulary.
- `docs/reference/TESTING.md` and `docs/reference/PLATFORM-TRAPS.md`: only if implementation uncovers a new
  shape or trap; nothing is expected.
