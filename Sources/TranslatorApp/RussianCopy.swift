// Sources/TranslatorApp/RussianCopy.swift
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
        case .zh: "китайский (упрощённый)"
        case .ja: "японский"
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

    /// "3 фрагмента" — the hint the main window shows over the source pane when the text
    /// will be translated in more than one piece.
    static func chunkCount(_ count: Int) -> String {
        "\(count) \(plural(count, "фрагмент", "фрагмента", "фрагментов"))"
    }

    /// "12 символов" — the source pane's own character count, next to `chunkCount` in its
    /// footer.
    static func characterCount(_ count: Int) -> String {
        "\(count) " + plural(count, "символ", "символа", "символов")
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
}
