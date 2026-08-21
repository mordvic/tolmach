# Domain language

The concepts this project is built out of, each with the **Russian term** that names it, the
type that implements it, and the words not to use for it.

The headwords stay Russian on purpose. The product's interface is Russian, its design spec was
written in Russian, and this glossary's job is to keep one concept from acquiring three names
across the UI, the docs and the code. Translating the headwords would leave the file describing
concepts nobody writes down that way.

`_Avoid_` lists are not style preferences. Each entry is a word that was used for the concept at
some point and caused a real ambiguity.

---

## Glossaries

**Пользовательский глоссарий** — *user glossary*
Terms set by a person, in force for every translation. Injected into a chunk's prompt
selectively: only entries whose term occurs in that chunk. See `docs/adr/0001` for why this one
is filtered and the next is not.
→ `Glossary`, `GlossaryEntry`, `GlossaryStore`
_Avoid_: глоссарий (unqualified), словарь

**Документный глоссарий** — *document glossary*
Terms extracted from the document being translated and translated once, before the main
translation, so every part of it renders them the same way. Lives for one translation only, and
is injected whole, without filtering.
→ `DocumentGlossary`, `TermExtractor`
_Avoid_: временный словарь, автоглоссарий, кэш терминов

**Дрейф терминологии** — *terminology drift*
The same term rendered differently in different parts of one document. The failure the document
glossary exists to prevent; worth about twenty points of adherence.
→ measured by `Sources/acceptance/main.swift`
_Avoid_: несогласованность, рассинхрон, разъезд

---

## Translation

**Чанк** — *chunk*
A piece of text translated by one request to the model. A fenced code block goes into a chunk
whole and is never cut.
→ `Chunker`, `Chunk`
_Avoid_: фрагмент, кусок, блок, сегмент
_On screen_: **часть**. This is the one headword whose interface wording differs from the
code's, and it is a deliberate exception rather than drift. «Чанк» is a transliteration that
means nothing to someone translating a document, and every alternative the `_Avoid_` list
rules out is ruled out for good reason — so the interface names the *effect* instead: the
source pane says «3 части», and the setting that governs the size is called «Длина одного
запроса к модели» and never names the unit at all. Code, docs and this file keep «чанк».

**Задание** — *job*
One file in the queue, together with its state and whatever came back for it.
→ `FileJob`, `FileQueueModel`
_Avoid_: задача, работа, элемент
_On screen_: named by its own filename, never by the word — a row says «techdoc-en.md», not
«задание 1». The word exists so the code has one name for the thing; the interface has the
file's own.

**Очередь** — *queue*
The whole list of заданий, translated one after another. Started by «Перевести» and never by a
drop.
→ `FileQueueModel`
_Avoid_: пакет, партия, список файлов
_On screen_: **Файлы** — the mode switch, the pane header and the settings tab all use that one
word, because «пакетный» is an adjective with nothing to modify in a row of nouns. «Пакетный
перевод» survives in prose, as a section caption, and never as a control's name.

**Корректор** — *corrector*
A second pass that fixes only outright errors from the first. It may not rephrase, shorten or
restructure — which is what distinguishes it from an editor, which is what the second pass was
originally going to be. **Cut from v1** after measurement; see §4.8 of the design spec.
_Avoid_: редактор, ревьюер, вычитка

**Тон** — *tone*
The register a person chose for the translation.
→ `Tone`, and `Tone.russianName` for the label
_Avoid_: стиль, манера

---

## Движок

**Движок** — *engine*
The local server the app sends its requests to: Ollama or LM Studio. Chosen in «Модели» →
«Движок», stored in `AppSettings.engine`, and read by `EngineRouter` on every call — so the
choice takes effect on the next request rather than at the next launch. Only the *port* is
configurable; the host is `127.0.0.1` in the code and nowhere else.
→ `ModelEngine`, `EngineRouter`, `AppSettings.engine`, `EngineStatus`
_Avoid_: бэкенд, провайдер, API; **сервер** — that is the process the движок runs, and «сервер
не запущен» is about the process while «движок» is about the choice
_On screen_: the engine's own name, untranslated — «Ollama», «LM Studio» — because both are
proper nouns and «Оллама» is a spelling nobody else uses. The word «движок» appears as the
section and picker label only.

## Execution paths

**Интерактивный путь** — *interactive path*
Translation by hotkey, where time to the first character matters more than prose quality.
→ `AppSettings.interactiveModel`, `ModelRole.interactive`
_Avoid_: быстрый режим, режим хоткея

**Сочетание клавиш для перевода / сочетание клавиш для правки** — *the перевод / правка shortcut*
Two system-wide combinations, ⌥⌘T and ⌥⌘R out of the box, each opening the panel already
performing its own operation — a press never inherits the operation the previous panel's switch
was left on. Set separately in «Основные» → «Сочетания клавиш», and they must differ: the
recorder refuses a duplicate at the keystroke, because Carbon would refuse it afterwards and the
pane would then show a shortcut the app does not answer to.
→ `AppSettings.hotkey`, `AppSettings.proofreadHotkey`, `HotkeyCoordinator.handlePress(operation:)`
_Avoid_: хоткей (in the interface — the settings section is «Сочетания клавиш»), горячая клавиша,
шорткат

**Панель** — *the panel*
The floating readout either shortcut opens next to the pointer: it shows the result and nothing
else, sizes itself to its own content, and never takes the application into the foreground. The
app has a real dropdown menu as well — the one under the status-bar item — which is why calling
this one «выпадающее меню» has to be avoided rather than merely discouraged: both exist.
→ `TranslationPanel`, `PanelView`, `PanelController`, `PanelSizer`
_Avoid_: выпадающее меню (that is the menu-bar menu), всплывающее окно, попап, окошко

**Фоновый путь** — *background path*
Translation by button or in batch, where prose quality matters more than speed. **Built** — the
file queue and the document-terms review gate both ship. `AppSettings.batchModel` selects the
queue's model in Settings → «Файлы» and defaults to «the same one the hotkey uses»: one model
lives in Ollama's memory, so two different ones make every ⌥⌘T during a queue run pay two cold
loads. `ModelRole.background` stays what it always was — a recommendation in `ModelPolicy`, read
by nothing.
→ `ModelRole.background`, `ModelPolicy.defaultModel(for: .background)`
_Avoid_: медленный режим, качественный режим

**Рассуждение** — *reasoning, thinking*
What a model emits before its answer — into `message.thinking` on Ollama, into the
`reasoning.delta` events on LM Studio. The app reads it and throws it away on both, so its
only effect here is delay — which is why «Отключать рассуждение модели» is on by default.
**How the app asks for silence differs by движок, and the safe direction is inverted**: on
Ollama nothing may *enable* it (`ThinkRequest` has no «on» case), while on LM Studio `off`
itself is refused by a model that cannot be silenced, so the value sent is chosen from what
that model says it accepts.
→ `ThinkRequest`, `ModelPolicy.thinkRequest`, `AppSettings.quietThinking`,
`ReasoningChoice`, `LMStudioModel.reasoningOptions`
_Avoid_: размышление, мышление, thinking

**Длина рассуждения** — *reasoning length*
How long a `gpt-oss` trace may run before the answer starts: «Кратко» / «Средне» /
«Подробно». Only `gpt-oss` has this control, because it is the one family that
ignores being switched off.
→ `ThinkRequest.Level`, `AppSettings.gptOssThinkingLevel`
_Avoid_: глубина, степень — that word belongs to правка; уровень

---

## Markup

**Целостность разметки** — *markup integrity*
Everything the model must not touch surviving the translation: document structure, code, links.
→ `MarkupSkeleton`, `MarkupDiff`
_Avoid_: валидность, корректность вёрстки

**Граница абзаца** — *paragraph break*
The blank line separating blocks of text.
→ `MarkupToken.paragraphBreak`
_Avoid_: перенос, разрыв

**Жёсткий перенос строки** — *hard line break*
A break inside a paragraph, written as two trailing spaces. A separate concept from a paragraph
break because this is the one models destroy, and the damage looks like a paragraph falling
apart.
→ `MarkupToken.hardLineBreak`
_Avoid_: перенос, новая строка

---

## Language

**Опознанный язык исходника** — *recognised source language*
A source language that was detected *and* is in the supported list. The document glossary is
built only for a recognised source; translation itself works from an unrecognised one.
→ `LanguageDetector.detect` returning non-nil
_Avoid_: исходный язык (without saying whether it was recognised)

---

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

---

## Вид

**Шрифт текста** — *content font*
The typeface and size the *user's own text* is drawn in: the исходник, the перевод, and the text
in the панели. Deliberately not the interface's — подписи, кнопки, предупреждения and the tables
keep the system's size, and that boundary is the whole of the concept.
→ `ContentFont`, `ContentTypeface`, `AppSettings.contentFont`
_On screen_: two controls, «Шрифт» and «Размер». The word «начертание» is not used for the first
of them: in Russian typography it names bold or italic *within* a family, and what is chosen here
is the family.
_Avoid_: начертание, кегль, шрифт интерфейса, масштаб

---

## A note on writing

Documentation and commit messages are English; the application's UI strings are Russian. When
an English sentence needs one of these concepts, use the English gloss and put the Russian term
beside it on first use — that is what the rest of the documentation does.

Russian UI labels for domain enums live in `Sources/TranslatorApp/RussianCopy.swift`, exhaustive
with no `default:`, so a new case fails to compile rather than silently rendering nothing.
