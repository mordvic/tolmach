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

## Execution paths

**Интерактивный путь** — *interactive path*
Translation by hotkey, where time to the first character matters more than prose quality.
→ `AppSettings.interactiveModel`, `ModelRole.interactive`
_Avoid_: быстрый режим, режим хоткея

**Фоновый путь** — *background path*
Translation by button or in batch, where prose quality matters more than speed. **The queue is
built.** `AppSettings.batchModel` selects its model and defaults to «the same one the hotkey
uses» — one model lives in Ollama's memory, so two different ones make every ⌥⌘T during a queue
run pay two cold loads. What is still v2 is the document-terms review gate. The settings control that
used to imply otherwise was removed.
→ `ModelRole.background`, `ModelPolicy.defaultModel(for: .background)`
_Avoid_: медленный режим, качественный режим

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

## A note on writing

Documentation and commit messages are English; the application's UI strings are Russian. When
an English sentence needs one of these concepts, use the English gloss and put the Russian term
beside it on first use — that is what the rest of the documentation does.

Russian UI labels for domain enums live in `Sources/TranslatorApp/RussianCopy.swift`, exhaustive
with no `default:`, so a new case fails to compile rather than silently rendering nothing.
