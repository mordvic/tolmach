// Sources/TranslatorApp/RussianCopy.swift
import Foundation
import TranslationCore

extension Tone {
    /// `Tone`'s raw values are English identifiers that belong in the prompt, not on a
    /// Russian screen. The label lives here rather than in TranslationCore because the
    /// core is UI-agnostic, and here rather than inline in a view because the main
    /// window's picker and the settings pane must not drift apart.
    ///
    /// Exhaustive with no `default:` on purpose: a sixth `Tone` case should fail to
    /// compile here instead of quietly showing the user nothing.
    var russianName: String {
        switch self {
        case .neutral: "нейтральный"
        case .formal: "деловой"
        case .casual: "разговорный"
        case .technical: "технический"
        case .literal: "буквальный"
        }
    }
}

extension Language {
    /// `englishName` is prompt material — the model is told "translate into German" — and
    /// the two-letter `rawValue`/`shortCode` is a code, not a word. Neither belongs in a
    /// sentence on a Russian screen, so the settings pickers get their own labels here,
    /// next to `Tone.russianName` and for the same reason.
    ///
    /// Nominative singular and lowercase, the way a language is named in running Russian
    /// text («перевод на немецкий»), not the English habit of capitalising it. All nine
    /// happen to be masculine adjectives, so this form also reads correctly as the direct
    /// object of «переводится на …» in the same-language warning.
    ///
    /// Exhaustive with no `default:` on purpose: a tenth `Language` case should fail to
    /// compile here instead of quietly showing the user nothing.
    var russianName: String {
        switch self {
        case .ru: "русский"
        case .en: "английский"
        case .de: "немецкий"
        case .fr: "французский"
        case .es: "испанский"
        case .pt: "португальский"
        case .it: "итальянский"
        // «китайский», not «китайский (упрощённый)» — and the reason is not the one it was
        // first dropped for. It was dropped because an `NSPopUpButton` is as wide as its
        // widest menu row, so seven characters nobody had chosen set the width of every
        // picker listing languages. The window's two are `Menu`s now (see `MainWindowView`'s
        // toolbar) and a menu's button is as wide as the title it is given, so that argument
        // is gone.
        //
        // What replaced it is narrower and stronger. Measured on the bundle, sweeping the
        // window against `NSToolbar.visibleItems`, the toolbar fits from: 650 pt as it
        // usually stands, 680 pt with the longest names selected on both sides — and 740 pt
        // with this parenthetical chosen once, 810 pt with it chosen twice. The drawing
        // specifies a 700 pt minimum. So the parenthetical is the difference between a window
        // that honours that number and never hides «Перевести», and one that does not.
        //
        // Nothing is lost that the user could act on: `Language` has one Chinese case, so it
        // distinguished this from nothing on offer. What it *said* — which script the model is
        // asked for — is still said where it is load-bearing: `englishName` is «Chinese
        // (Simplified)», and `englishName` is what `PromptBuilder` puts in the prompt. This
        // name is UI only. The drawing specifies the 700; it never shows Chinese at all.
        case .zh: "китайский"
        case .ja: "японский"
        }
    }
}

extension ProofreadingLevel {
    var russianName: String {
        switch self {
        case .errorsOnly: "только ошибки"
        case .errorsAndStyle: "ошибки и стиль"
        // Not «вольная правка» (collides with the operation's own name) and not
        // «свободный стиль» (collides with the neighbouring стиль control — the
        // term-collision rule that already rejected «тон», spec terminology table).
        case .rewrite: "переписать"
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

extension ThinkRequest.Level {
    /// The control these label is «длина рассуждения», not «глубина» and not «степень».
    /// `CONTEXT.md` gives «степень» to правка and lists «глубина» among the words *not* to use
    /// for it — so naming this one «глубина» would have made that avoid-list ambiguous rather
    /// than avoided a collision. «Длина» is what the setting actually governs: how long the
    /// trace runs before the answer starts.
    ///
    /// Exhaustive with no `default:`, for `Tone.russianName`'s reason.
    var russianName: String {
        switch self {
        case .low: "Кратко"
        case .medium: "Средне"
        case .high: "Подробно"
        }
    }
}

enum RussianCopy {
    /// Russian nouns after a number take one of three forms, chosen by the last two
    /// digits of the count:
    ///
    /// - `many` when the last two digits are 11-14 — these end in 1-4 but behave like
    ///   5-20, and are the case a naive last-digit rule gets wrong;
    /// - otherwise `one` when the last digit is 1 (1, 21, 101, 121…);
    /// - otherwise `few` when the last digit is 2-4 (2, 23, 104…);
    /// - otherwise `many` (0, 5-20, 25-30…).
    ///
    /// The count's sign is irrelevant to the grammar, so the magnitude decides. Taking
    /// `% 100` before `abs` keeps `Int.min` from overflowing.
    /// The engine's own name, untranslated: both are proper nouns, and an app that wrote
    /// «Оллама» would be inventing a spelling nobody else uses.
    static func engineName(_ engine: ModelEngine) -> String {
        switch engine {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }

    /// The status line, in one form for every engine.
    ///
    /// «Нет связи с LM Studio» rather than «LM Studio не запущен», and that is a decision about
    /// grammar rather than tone: the previous wording, «Ollama не запущена», agrees with its
    /// subject, so a template would have to inflect for each name it is given — and a template
    /// that inflects is a template that will be wrong for the next name. This form takes the
    /// name in the genitive and needs nothing from it.
    static func engineStatus(_ status: EngineStatus, engineName: String) -> String {
        switch status {
        case .unknown: "Проверяю \(engineName)…"
        case .notAnswering: "Нет связи с \(engineName)"
        case .running(true): "\(engineName) работает, модель в памяти"
        case .running(false): "\(engineName) работает, модель не загружена"
        }
    }

    /// The window's idle line: the engine's state, unless there is a more actionable thing to
    /// say. «Выберите модель» outranks «работает»: a running server the app cannot use yet is
    /// not what the reader needs to know.
    static func idleLine(_ status: EngineStatus, engineName: String, hasModel: Bool) -> String {
        guard hasModel else { return "Модель для перевода не выбрана — «Модели» в настройках." }
        return engineStatus(status, engineName: engineName)
    }

    /// What to say when the engine refuses. Keyed on the machine-readable code rather than on
    /// the server's prose, which is English and free to be rephrased.
    static func lmStudioRefusal(code: String?, message: String) -> String {
        switch code {
        case "model_not_found":
            "LM Studio не знает такой модели. Проверьте «Модель для перевода» в настройках."
        case "invalid_value":
            "LM Studio отклонил параметр запроса: \(message)"
        case "unrecognized_keys":
            "LM Studio отклонил неизвестное поле запроса: \(message)"
        case "internal_error":
            "Внутренняя ошибка LM Studio: \(message)"
        default:
            "LM Studio отклонил запрос: \(message)"
        }
    }

    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let lastTwo = abs(count % 100)
        if (11...14).contains(lastTwo) { return many }
        switch lastTwo % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    /// The panel's header line. An undetected source is stated rather than hidden — the
    /// direction rule sends undetected text to the primary language, and a user who sees a
    /// surprising target deserves to know the detector is why.
    ///
    /// The target is not optional and the source is: `AppSettings.targetLanguage(forDetected:)`
    /// always resolves to *some* language, while `LanguageDetector.detect` is allowed to
    /// give up. Nothing here decides *whether* to show the line — see `PanelView.direction`,
    /// which will not build one out of two halves that came from different runs.
    static func direction(from source: Language?, to target: Language) -> String {
        let left = source.map(\.russianName) ?? "язык не определён"
        return "\(left) → \(target.russianName)"
    }

    /// "3 части" — the hint the main window shows over the source pane when the text will be
    /// translated in more than one request.
    ///
    /// «часть» and not «фрагмент». The concept is `CONTEXT.md`'s «чанк», whose _Avoid_ list
    /// names «фрагмент» outright — and those lists are words that caused a real ambiguity,
    /// not preferences. «Чанк» itself is no better on screen: it is a transliteration that
    /// means nothing to someone translating a document. `CONTEXT.md` now records «часть» as
    /// the one word this concept wears in the interface, so the glossary keeps doing its job
    /// — one concept, one name per audience — instead of being quietly broken.
    static func chunkCount(_ count: Int) -> String {
        "\(count) \(plural(count, "часть", "части", "частей"))"
    }

    /// "12 символов" — the source pane's own character count, next to `chunkCount` in its
    /// footer.
    static func characterCount(_ count: Int) -> String {
        "\(count) " + plural(count, "символ", "символа", "символов")
    }

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

    /// "12 терминов документа" — what a run is holding constant across its части.
    static func documentTermCount(_ count: Int) -> String {
        "\(count) \(plural(count, "термин", "термина", "терминов")) документа"
    }

    /// "в очереди · 4 части" — a задание that has not started.
    static func queuedFile(parts: Int) -> String {
        "в очереди · \(chunkCount(parts))"
    }

    /// "готово за 3 140 мс".
    ///
    /// Formatted the way `modelSize` does it — `.formatted(.number.locale(…))` against a
    /// pinned `ru_RU` — and deliberately not through a `NumberFormatter` of its own. Two
    /// mechanisms for one convention is how two numbers side by side in this app come to
    /// be spelled two ways, which is the whole reason these functions share a file. The
    /// locale is pinned rather than taken from the system for `modelSize`'s reason: the
    /// app is Russian whatever the machine is set to.
    static func finishedIn(milliseconds: Int) -> String {
        "готово за \(milliseconds.formatted(.number.locale(Locale(identifier: "ru_RU")))) мс"
    }

    /// "прервано за 3 140 мс" — a задание the user stopped.
    ///
    /// The time is the machine's, not the reader's: `markInterrupted` subtracts whatever was
    /// spent in the terms sheet, exactly as `totalMS` does on the finished path. Rendered
    /// rather than merely computed — a corrected number nothing shows is bookkeeping
    /// defending a value nobody can see.
    static func interruptedAfter(milliseconds: Int) -> String {
        "прервано за \(milliseconds.formatted(.number.locale(Locale(identifier: "ru_RU")))) мс"
    }

    /// "Перевожу 2-й файл из 3 — 9 частей из 13" — the status bar in «Файлы».
    ///
    /// `fileIndex` is zero-based, matching the array it comes from; the sentence is
    /// one-based, which is why the conversion happens here rather than at the call site
    /// where it would be repeated and eventually be off by one in one of them.
    static func queuePosition(fileIndex: Int, fileTotal: Int,
                              partsDone: Int, partsTotal: Int) -> String {
        "Перевожу \(ordinal(fileIndex + 1)) файл из \(fileTotal) — "
            + "\(partsDone) \(plural(partsDone, "часть", "части", "частей")) из \(partsTotal)"
    }

    /// "2-й" — masculine, to agree with «файл».
    ///
    /// Russian ordinals take one of two written endings after the hyphen depending on the
    /// last letter of the spelled-out form; for the masculine nominative every one of them
    /// is «-й» («первый», «второй», «одиннадцатый»), so this is a suffix and not a table.
    /// Feminine or neuter would need one, and would need its own function.
    static func ordinal(_ number: Int) -> String { "\(number)-й" }

    /// "4 предупреждения" — the count on a finished задание.
    static func warningCount(_ count: Int) -> String {
        "\(count) \(plural(count, "предупреждение", "предупреждения", "предупреждений"))"
    }

    /// «6 изменений» / «1 изменение» / «изменений нет» — how many ranges a правка moved.
    ///
    /// Zero is a sentence and not «0 изменений», because it is the whole answer to a clean
    /// «только ошибки» run: the pane shows a text identical to the source, and «0» beside it
    /// reads as a counter that failed to count. The word is «изменение», never «правка» — that
    /// is the operation's name (`CONTEXT.md`), and «6 правок» under a правка would be the same
    /// word twice meaning two things.
    static func changeCount(_ count: Int) -> String {
        guard count > 0 else { return "изменений нет" }
        return "\(count) \(plural(count, "изменение", "изменения", "изменений"))"
    }

    /// The one sentence for a правка whose diff was not run. Lower-case because it sits after
    /// «Готово за N мс · » in the status bar, like `changeCount`; the panel capitalises it
    /// itself where it stands alone.
    static let changesNotCompared = "изменения не отмечены — текст слишком длинный"

    /// The status bar's word for a правка's change set, in one place: the count, or the reason
    /// there is none, so the window and a test read the same sentence for the same set.
    static func changeSummary(_ changes: ChangeSet) -> String {
        changes.notCompared == nil ? changeCount(changes.count) : changesNotCompared
    }

    /// Keyed by the same model-name prefixes as `ModelPolicy.blacklist`, because the engine
    /// matches by prefix so that every tag of a bad model is covered.
    ///
    /// The reasons live here rather than in `ModelPolicy` for the same reason
    /// `Tone.russianName` does: the engine is UI-agnostic and `translate-cli` prints its
    /// English text on a terminal, while this pane is Russian. Two tables can drift, so
    /// `everyBlacklistedPrefixHasRussianCopy` fails the suite if a prefix is added there
    /// without a translation here.
    ///
    /// Wording follows the measurements in spec §5 — this is evidence the user is being
    /// shown, not a ban, and the model stays selectable.
    static let blacklistReasons: [String: String] = [
        "gemma3n": "Портит идентификаторы посимвольно: выдала «StructureDefiinition» внутри "
            + "инлайн-кода и «Implemenentierungsleitfadens». Для перевода техдокументации это "
            + "худший из отказов — имя типа в коде ломается молча.",
        "qwen3:30b": "78 секунд рассуждений до первого символа перевода. Слишком медленно для "
            + "интерактивной работы.",
    ]

    /// The engine decides *whether* a model is marked; this layer decides *what to say*.
    /// Consulting `ModelPolicy` first is what keeps the two from disagreeing about which
    /// models carry a warning — only the language of the answer differs.
    ///
    /// A marked prefix with no translation falls back to the engine's English rather than
    /// to `nil`: a warning in the wrong language is worse than Russian and far better than
    /// silence, which would leave a model that mangles identifiers looking approved.
    /// `russian` is a parameter so that fallback can be exercised by a test instead of
    /// merely asserted in a comment.
    static func blacklistReason(for model: String,
                                russian: [String: String] = blacklistReasons) -> String? {
        guard let english = ModelPolicy.blacklistReason(for: model) else { return nil }
        for (prefix, reason) in russian where model.hasPrefix(prefix) { return reason }
        return english
    }

    /// Ollama's `/api/pull` stream captions itself in English. Strings taken from the
    /// running server's own source — ollama v0.31.1, `server/images.go` and
    /// `server/download.go` — plus «removing any unused layers», which the published API
    /// docs still show and older servers still send.
    static let pullStatuses: [String: String] = [
        "pulling manifest": "Получаю манифест…",
        "pulling model": "Загружаю модель…",
        "verifying sha256 digest": "Проверяю контрольную сумму…",
        "writing manifest": "Записываю манифест…",
        "removing unused layers": "Убираю неиспользуемые слои…",
        "removing any unused layers": "Убираю неиспользуемые слои…",
        "success": "Готово.",
        // LM Studio's five, beside Ollama's rather than instead of them: this function
        // translates the *server's* own words, and there are two servers now.
        "downloading": "Скачиваю…",
        "paused": "Скачивание приостановлено.",
        "completed": "Готово.",
        "already_downloaded": "Уже установлена.",
        "failed": "Скачать не удалось.",
    ]

    static func pullStatus(_ raw: String) -> String {
        if let known = pullStatuses[raw] { return known }
        // Each layer gets its own line — "pulling " plus twelve hex characters of its
        // digest. The digest names nothing the user can act on and there is one per layer,
        // so they all read the same; the progress bar is what tells them apart. Checked
        // after the exact table, since "pulling manifest" shares the prefix.
        // The remainder must actually look like a digest. A bare `hasPrefix("pulling ")`
        // would swallow any future "pulling …" wording — the one status family whose
        // renaming the raw-string fallback below would otherwise not survive.
        if raw.hasPrefix("pulling ") {
            let digest = raw.dropFirst("pulling ".count)
            if !digest.isEmpty, digest.allSatisfy(\.isHexDigit) { return "Загружаю файлы модели…" }
        }
        // Ollama has renamed these before, so an unrecognised line reaches the user as-is.
        // Swallowing it would leave the pane captionless with no clue why.
        return raw
    }

    /// The Russian for a transport failure already exists on `OllamaErrorBridge`; anything
    /// else has only its English `localizedDescription`, which still beats saying nothing
    /// about why an operation failed.
    static func failureDetail(_ error: Error) -> String {
        (error as? OllamaErrorBridge)?.russianMessage ?? error.localizedDescription
    }

    /// A model's size on disk, in the notation the rest of this app uses.
    ///
    /// Comma for the decimal separator, and the locale pinned rather than taken from the
    /// system: every string in this app is Russian and there is no localisation to switch,
    /// so on a machine set to en_US the default format would put «4.8 ГБ» in a Russian
    /// sentence next to «4,8» elsewhere — the same reasoning as the temperature slider's
    /// pinned locale in this same pane.
    static func modelSize(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return gigabytes.formatted(.number.precision(.fractionLength(1))
            .locale(Locale(identifier: "ru_RU"))) + " ГБ"
    }

    /// What «Оформить не удалось» says under the warnings. «Обработан», not «переведён»:
    /// the same pass runs before правка.
    static func formattingNotice(_ notice: FormattingNotice) -> String {
        switch notice {
        case .tooLong:
            "Текст длиннее одного запроса к модели, поэтому оформлен не был — обработан как есть."
        case .rejected(.empty):
            "Модель ничего не вернула на запрос об оформлении — текст обработан как есть."
        case .rejected(.wordsChanged):
            "Модель изменила слова, а не только разметку — результат отброшен, текст обработан как есть."
        case .rejected(.unevenTable):
            "В собранной таблице строки разной длины — результат отброшен, текст обработан как есть."
        case let .failed(message):
            "Запрос об оформлении не удался (\(message)) — текст обработан как есть."
        }
    }

    /// The panel's and the window's header line for правка: there is no direction to
    /// draw, so the line names the operation and the language it worked in. The language
    /// is omitted rather than replaced by «язык не определён» — правка ran fine without
    /// it, unlike translation, where the detector picked the target (spec §5).
    static func proofreadHeader(language: Language?) -> String {
        language.map { "правка · \($0.russianName)" } ?? "правка"
    }
}
