import Testing
import Foundation
@testable import TranslatorApp
@testable import TranslationCore
import OllamaKit

@Test func everyToneHasANonEmptyRussianName() {
    for tone in Tone.allCases {
        #expect(!tone.russianName.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(tone.rawValue) has no Russian name")
    }
}

@Test func toneNamesAreDistinct() {
    let names = Tone.allCases.map(\.russianName)
    #expect(Set(names).count == Tone.allCases.count)
}

/// The picker sits in a Russian UI, so `Text($0.rawValue)` — «neutral», «formal» — is the
/// bug this guards against. Latin letters anywhere in a tone name mean the raw value, or
/// part of it, leaked into the label.
@Test func toneNamesContainNoLatinLetters() {
    let latin = CharacterSet(charactersIn: "a"..."z").union(CharacterSet(charactersIn: "A"..."Z"))
    for tone in Tone.allCases {
        #expect(tone.russianName.rangeOfCharacter(from: latin) == nil,
                "\(tone.rawValue) → «\(tone.russianName)» contains Latin letters")
    }
}

@Test func everyLanguageHasANonEmptyRussianName() {
    for language in Language.allCases {
        #expect(!language.russianName.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(language.rawValue) has no Russian name")
    }
}

@Test func languageNamesAreDistinct() {
    let names = Language.allCases.map(\.russianName)
    #expect(Set(names).count == Language.allCases.count)
}

/// `Language.englishName` exists for the *prompt* — the model is told "translate into
/// German" — and reaching for it in a picker is the easy mistake, since it is the only
/// name the type ships. Latin letters in a label mean `englishName`, or the raw code,
/// leaked onto a Russian screen.
@Test func languageNamesContainNoLatinLetters() {
    let latin = CharacterSet(charactersIn: "a"..."z").union(CharacterSet(charactersIn: "A"..."Z"))
    for language in Language.allCases {
        #expect(language.russianName.rangeOfCharacter(from: latin) == nil,
                "\(language.rawValue) → «\(language.russianName)» contains Latin letters")
    }
}

/// Language names are written lowercase in running Russian text, unlike English, and the
/// pickers put them in a sentence-shaped list. Capitalising them is the transliteration
/// of an English habit, so it is worth pinning rather than trusting to review.
@Test func languageNamesAreLowercase() {
    for language in Language.allCases {
        let first = language.russianName.first
        #expect(first?.isUppercase == false,
                "\(language.rawValue) → «\(language.russianName)» starts with a capital")
    }
}

/// Russian picks one of three forms from the last two digits, and 11-14 are the trap: they
/// end in 1-4 but take the same form as 5-20. The whole 11-14 span is listed rather than
/// just its ends, because the branch is a range test and an off-by-one at either edge
/// would still satisfy 11 and 14 alone.
///
/// 0 and 100 are here because they are the two counts whose last digit is 0 — the branch
/// no other case in this list reaches — and because the helper's doc comment names them.
@Test(arguments: [
    (0, "0 частей"),
    (1, "1 часть"),
    (2, "2 части"),
    (4, "4 части"),
    (5, "5 частей"),
    (11, "11 частей"),
    (12, "12 частей"),
    (13, "13 частей"),
    (14, "14 частей"),
    (21, "21 часть"),
    (22, "22 части"),
    (25, "25 частей"),
    (100, "100 частей"),
    (101, "101 часть"),
    (111, "111 частей"),
])
func chunkCountUsesTheRightPluralForm(count: Int, expected: String) {
    #expect(RussianCopy.chunkCount(count) == expected)
}

/// The helper documents itself as general over sign — the magnitude picks the form. A
/// chunk count is never negative, so nothing in the app exercises this; the assertion is
/// what stops the doc comment and the code drifting apart.
@Test(arguments: [
    (1, "часть"),
    (2, "части"),
    (4, "части"),
    (5, "частей"),
    (11, "частей"),
    (13, "частей"),
    (21, "часть"),
    (22, "части"),
    (100, "частей"),
])
func negativeCountsTakeTheSameFormAsTheirMagnitude(magnitude: Int, expected: String) {
    #expect(RussianCopy.plural(-magnitude, "часть", "части", "частей") == expected)
    // Paired with the positive twin in the same test, so the claim under scrutiny is
    // "sign does not matter" rather than two independent tables that could both be wrong.
    #expect(RussianCopy.plural(magnitude, "часть", "части", "частей") == expected)
}

/// `abs(Int.min)` traps, which is why the helper takes `% 100` *before* `abs`. Reordering
/// those two operations turns a hint into a crash, and this is the only thing that would
/// notice.
@Test func extremeCountsDoNotTrap() {
    // Int.min ends in …08 and Int.max in …07; both land in the "many" branch.
    #expect(RussianCopy.plural(Int.min, "один", "два", "много") == "много")
    #expect(RussianCopy.plural(Int.max, "один", "два", "много") == "много")
}

@Test func pluralHelperIsNotTiedToOneNoun() {
    #expect(RussianCopy.plural(1, "термин", "термина", "терминов") == "термин")
    #expect(RussianCopy.plural(13, "термин", "термина", "терминов") == "терминов")
    #expect(RussianCopy.plural(22, "термин", "термина", "терминов") == "термина")
}

@Test func theCharacterCountAgreesWithRussianGrammar() {
    // Through `plural`, like the chunk count, because the number comes from the user's
    // typing and every form is reachable within a sentence of it.
    #expect(RussianCopy.characterCount(1) == "1 символ")
    #expect(RussianCopy.characterCount(2) == "2 символа")
    #expect(RussianCopy.characterCount(5) == "5 символов")
    #expect(RussianCopy.characterCount(11) == "11 символов")
    #expect(RussianCopy.characterCount(21) == "21 символ")
    #expect(RussianCopy.characterCount(0) == "0 символов")
}

// MARK: - Direction

/// The panel's header. Both halves are `russianName`, so the two assertions that would
/// merely restate `russianName` are left to the tests above; what is pinned here is the
/// arrow, the order of the operands, and — the part that is a decision rather than a
/// format — that an undetected source is *stated* instead of silently dropped.
@Test func theDirectionLineNamesBothLanguagesInRussian() {
    #expect(RussianCopy.direction(from: .en, to: .ru) == "английский → русский")
    #expect(RussianCopy.direction(from: nil, to: .ru) == "язык не определён → русский")
}

// MARK: - Blacklist reasons

/// The engine decides *whether* a model is blacklisted and the app decides *what to say*,
/// which is two tables that can drift. `ModelPolicy` is engine-side and `translate-cli`
/// prints its English; a prefix added there without Russian here would show the user
/// «Port: corrupts identifiers character-by-character…» in a Russian pane. This is the only
/// thing that would notice.
@Test func everyBlacklistedPrefixHasRussianCopy() {
    for prefix in ModelPolicy.blacklist.keys {
        #expect(RussianCopy.blacklistReasons[prefix] != nil,
                "ModelPolicy.blacklist has no Russian counterpart for «\(prefix)»; add one to RussianCopy.blacklistReasons")
    }
}

/// Documenting the fallback by exercising it rather than by comment: a prefix the engine
/// blacklists and this layer has no Russian for still warns, in English. A warning in the
/// wrong language is worse than Russian and far better than silence — silence would let a
/// model that mangles identifiers look approved.
@Test func aMissingTranslationFallsBackToTheEnglishReasonNotToSilence() {
    let reason = RussianCopy.blacklistReason(for: "gemma3n:e4b", russian: [:])
    #expect(reason == ModelPolicy.blacklistReason(for: "gemma3n:e4b"))
    #expect(reason != nil)
    // A model the engine does not blacklist stays unmarked whatever the table holds.
    #expect(RussianCopy.blacklistReason(for: "aya-expanse:8b", russian: [:]) == nil)
}

@Test func blacklistReasonsAreKeyedByPrefixLikeTheEngines() {
    // `blacklistReason(for:)` must agree with `ModelPolicy` on *which* models are marked,
    // for every tag, and only disagree on the language of the answer.
    for name in ["gemma3n", "gemma3n:e4b", "gemma3n:e2b", "qwen3:30b", "qwen3:30b-a3b",
                 "aya-expanse:8b", "qwen3:8b", "gpt-oss:20b"] {
        #expect((RussianCopy.blacklistReason(for: name) == nil)
                == (ModelPolicy.blacklistReason(for: name) == nil),
                "«\(name)» is marked by one layer and not the other")
    }
}

// MARK: - Pull statuses

/// Ollama's `/api/pull` stream carries English status lines, and putting them straight into
/// `pullStatus` would show «verifying sha256 digest» in a Russian pane. Strings taken from
/// ollama v0.31.1's own source (`server/images.go`, `server/download.go`) — the running
/// server here — plus the wording the published API docs still show.
@Test(arguments: [
    ("pulling manifest", "Получаю манифест…"),
    ("pulling model", "Загружаю модель…"),
    ("pulling 65f986688a01", "Загружаю файлы модели…"),
    // Only a real digest takes the layer caption. A future "pulling …" wording must reach
    // the raw-string fallback instead of being mislabelled as a layer download — that is
    // the one status family the fallback would otherwise not protect.
    ("pulling from mirror", "pulling from mirror"),
    ("verifying sha256 digest", "Проверяю контрольную сумму…"),
    ("writing manifest", "Записываю манифест…"),
    ("removing unused layers", "Убираю неиспользуемые слои…"),
    ("removing any unused layers", "Убираю неиспользуемые слои…"),
    ("success", "Готово."),
])
func pullStatusesAreShownInRussian(raw: String, expected: String) {
    #expect(RussianCopy.pullStatus(raw) == expected)
}

/// Ollama has renamed these before — v0.31.1 emits «removing unused layers» where the
/// published docs still say «removing any unused layers» — so an unrecognised line must
/// reach the user as-is. Swallowing it would leave the pane captionless with no clue why.
@Test func anUnrecognisedPullStatusIsShownRatherThanSwallowed() {
    #expect(RussianCopy.pullStatus("recomputing the flux capacitor") == "recomputing the flux capacitor")
    #expect(RussianCopy.pullStatus("") == "")
}

// MARK: - OllamaError → Russian

/// `TranslationViewModel.message(for:)` casts to `OllamaErrorBridge`; without the
/// conformance the cast fails and the user gets `errorDescription`'s English
/// («Ollama is not reachable on 127.0.0.1:11434»).
@MainActor
@Test func everyOllamaErrorCaseReachesTheUserInRussian() {
    let cases: [OllamaError] = [.notRunning, .httpStatus(503, "upstream"), .decoding("bad shape")]
    for error in cases {
        let message = TranslationViewModel.message(for: error)
        #expect(message != error.errorDescription,
                "\(error) still surfaces OllamaKit's English: \(message)")
        #expect(message.rangeOfCharacter(from: CharacterSet(charactersIn: "а"..."я")) != nil,
                "\(error) produced no Russian: \(message)")
    }
}

@MainActor
@Test func theHttpStatusCodeSurvivesTheTranslation() {
    // The code is the one piece of the message that helps diagnose anything.
    #expect(TranslationViewModel.message(for: OllamaError.httpStatus(503, "upstream")).contains("503"))
}

// MARK: - Model size

@Test func aModelSizeIsWrittenInRussianNotation() {
    // Comma for the decimal separator, and the locale pinned rather than taken from the
    // system: every string in this app is Russian and there is no localisation to switch,
    // so on a machine set to en_US the default format would put «4.8 ГБ» in a Russian
    // sentence next to «4,8» elsewhere.
    #expect(RussianCopy.modelSize(5_100_273_664) == "4,8 ГБ")
    #expect(RussianCopy.modelSize(0) == "0,0 ГБ")
}

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
    // Same ru_RU formatting modelSize is pinned to, so the two do not disagree about what
    // a number looks like in this app. ru_RU groups with U+00A0, not a plain space.
    #expect(RussianCopy.finishedIn(milliseconds: 3140) == "готово за 3\u{00A0}140 мс")
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
