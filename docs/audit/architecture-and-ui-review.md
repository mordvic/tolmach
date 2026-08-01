# Архитектурный и UI-аудит

> **Статус: волны 1 и 2 выполнены.** Волна 1 — ветка `wave1/observability-and-swift6`
> (PR #9), волна 2 — `wave2/mac-idioms` поверх неё. Ни одна не слита.
>
> Закрыты **A1, A2, A3, A4, A6, A7/M1, M2, M5** (волна 1) и **U1/M3, U2, U3/M4, U5/M6, U8**
> (волна 2) — плюс два дефекта, найденных уже в ходе работ и в отчёт не входивших
> (см. «Что нашлось при исправлении» ниже). Остальные находки не тронуты. Проверено:
> холодная `swift build --build-tests` — 0 ошибок, 0 предупреждений; `swift test` — 354 теста
> зелены в 3 прогонах из 3; `-strict-concurrency=complete` — 0 предупреждений; сквозной прогон
> `translate-cli` против живой Ollama; локализация проверена на **собранном бандле**
> (`preferredLocalizations` стал `["ru"]`), печать подписи цела.
>
> **Одна поправка к самому отчёту по волне 2.** В U3 рекомендовалось убрать пустое меню «Вид»
> через `CommandGroup(replacing: .sidebar) { }`. Измерено: это **не работает** — группа
> опустошается, но меню остаётся заголовком без пунктов, то есть становится хуже. Пришлось
> добавить `pruneEmptyMenus()` на AppKit. Заодно замерено, что меню полностью построено уже к
> первому запуску `.task`, так что обрезка не нуждается в задержке, и что она не откатывается.
>
> **Что нашлось при исправлении** (обоих в отчёте не было — их выявил сам переход на `.v6`):
>
> 1. **Рантайм-ловушка в `WarningsView`.** Замыкание внутри computed property на `View`
>    наследует `@MainActor`; Swift 5 это не проверяет, Swift 6 проверяет **во время
>    выполнения** и падает с `signal code 5`. Сборка при этом чистая. Детерминированно 3/3
>    против 0/3 на `main`. Умирали ровно те два теста, что передают непустой `checks` —
>    пустая коллекция прячет дефект полностью, потому что замыкание не запускается.
>    Разбор — в шапке [WarningsViewTests.swift](../../Tests/TranslatorAppTests/WarningsViewTests.swift).
> 2. **Утверждение аудита про `qwen3:30b` и таймаут — снято измерением.** Я записал в
>    `OPEN-ITEMS` вопрос «стримится ли reasoning», а затем измерил его против живой Ollama:
>    258 кадров, первый `thinking` на 2.12 с, первый `content` на 7.12 с, **максимальный
>    разрыв между кадрами 62 мс**. Тишины нет — рассуждающая модель таймаут не задевает.
>    Долг из `OPEN-ITEMS` удалён, цифры перенесены в комментарий к
>    [`OllamaClient.Timeout`](../../Sources/OllamaKit/OllamaClient.swift).
>
> Ниже — исходный отчёт в том виде, в каком он был написан до правок.

---

Внешний read-only аудит «Толмача». Ни один файл исходников не изменён.

Документ написан по-русски, в отличие от остальных `docs/` — он адресован владельцу
проекта, а не является частью кодовой документации. Идентификаторы, имена API и пути
оставлены как есть.

**Окружение, в котором взяты все измерения** (`sw_vers`, `xcodebuild -version`, `swift --version`):

| | |
|---|---|
| macOS | 26.6 (25G72) |
| Xcode | 26.6 (17F113) |
| Swift toolchain | 6.3.3, target `arm64-apple-macosx26.0` |
| Планка проекта | macOS 14.0, `swift-tools-version: 6.0`, `.swiftLanguageMode(.v5)` ×11 |
| Код | 50 файлов / 6881 строк в `Sources`, 38 / 5847 в `Tests`, 347 `@Test` |
| Дата | 2026-08-01, `main` @ `c25328f` |

**Что было запущено** (с разрешения владельца, обе сборки — в изолированные
`--scratch-path`, рабочий `.build` не тронут):

| Прогон | Результат |
|---|---|
| `swift build --build-tests`, холодная | **0 warnings**, 9.32 s — правило «zero warnings» держится |
| `swift build --build-tests -Xswiftc -strict-concurrency=complete`, холодная | 8 предупреждений (6 в `Sources`, 2 в `Tests`), 0 ошибок, сборка проходит |

Кроме этого написаны **четыре пробника вне репозитория** (в scratchpad), чтобы превратить
догадки в измерения: меню SwiftUI для этой конфигурации сцен, локализация меню под тремя
конфигурациями бандла, наличие рекомендуемых accessibility-API на планке macOS 14, и
безопасность добавления `ru.lproj`. Их результаты помечены как «измерение» в колонке
«источник».

---

## 1. Executive summary

- **Слоевая граница реальна, а не декларативна.** `TranslationCore` не импортирует ничего,
  кроме Foundation и NaturalLanguage; `TextCapture` не зависит даже от `TranslationCore`;
  инверсия через `LLMClient`. Views нигде не ходят напрямую в сеть или на диск. Это
  подтверждено манифестом и построчным чтением, а не заявлено.
- **Проект уже почти готов к Swift 6.** Строгая конкурентность даёт **шесть** мест в
  `Sources` — все в двух файлах `TextCapture` и в двух вызовах вокруг `NSPasteboard`. Это
  один рабочий день, а не миграция.
- **Единственная критическая дыра в эксплуатации — полное отсутствие логирования.** Ноль
  `os.Logger` во всём `Sources`, при четырёх намеренно проглатываемых отказах. У
  menu-bar-приложения, живущего сутками, нет ни одного способа рассказать, что у
  пользователя пошло не так.
- **Меню приложения существует и оно английское.** Измерено: SwiftUI ставит полное главное
  меню (`Правка` с ⌘C/⌘V/⌘Z, `Настройки… ⌘,`), но бандл не объявляет ни одной локализации,
  поэтому даже на русской системе меню остаётся английским. Починка — два ключа в
  `Info.plist`, проверено экспериментально.
- **Комментарий в `TranslatorApp.swift:466` опровергнут измерением**: «нет меню приложения,
  поэтому стандартного ⌘, не существует» — меню есть, ⌘, в нём есть. По правилам самого
  `CLAUDE.md` это не мелочь: «measured» здесь контракт.
- **Ни одной `.commands` во всём приложении.** Ни «Перевести», ни «Открыть окно», ни
  «Показать панель» не попадают в меню; меню `View` установлено и **пусто**.
- **Accessibility — самое слабое место UI.** Четыре явные метки на 4421 строку интерфейса.
  Reduce Motion учтён, **Reduce Transparency — нет**, хотя API доступен на планке macOS 14
  (проверено компиляцией).
- **Ollama-клиент множится**: комментарий в `TranslatorApp.swift:27` обосновывает шаринг
  клиента тем, чтобы не поднимать вторую `URLSession`, а приложение поднимает **три** при
  старте и ещё по одной на каждую загрузку модели.
- **Безопасность чистая по всем осям, которые здесь применимы**: секретов нет, keychain не
  используется (нечего хранить), единственный сетевой адрес — `127.0.0.1:11434`, ATS не
  мешает эмпирически. Entitlements нет вовсе — и для приложения, которое постит `CGEvent` и
  читает Accessibility, это правильно, но нигде не записано как решение.
- **Качество комментариев и тестов выше отраслевой нормы настолько, что это меняет характер
  аудита.** `docs/OPEN-ITEMS.md` уже содержит бо́льшую часть того, что обычный ревью назвал
  бы находками. Ниже я явно отделяю новое от уже известного — повторять известное было бы
  шумом.

---

## 2. Таблица находок

Severity: **Critical** — ломает пользователя или данные; **High** — реальный дефект или
блокирующий риск; **Medium** — заметный, но обходимый; **Low** — мелочь или корректность
документации. Пункты, помеченные **[стиль]**, — предпочтения, а не дефекты; они отделены в
§3 и в таблицу не входят.

### 2.1 Архитектура

| ID | Область | Severity | Место | Проблема | Рекомендация | Источник |
|---|---|---|---|---|---|---|
| A1 | Concurrency | High | [GeneralPasteboard.swift:63](../../Sources/TextCapture/GeneralPasteboard.swift#L63), [TranslationViewModel.swift:74](../../Sources/TranslatorApp/TranslationViewModel.swift#L74), [HotkeyCoordinator.swift:220](../../Sources/TranslatorApp/HotkeyCoordinator.swift#L220) | `NSPasteboard` не `Sendable`, а `write(_:to:)` передаёт его в `Task.detached`. Три предупреждения `#SendingRisksDataRace` / `#SendingClosureRisksDataRace`, в Swift 6 — ошибки | Обернуть доску в `struct UncheckedBoard: @unchecked Sendable { let board: NSPasteboard }` внутри `GeneralPasteboard` — сериализация уже обеспечена `NSLock`, так что `@unchecked` здесь честен и обоснование уже написано в докстринге типа | измерение (strict-concurrency сборка) |
| A2 | Concurrency | High | [HotkeyManager.swift:39-40](../../Sources/TextCapture/HotkeyManager.swift#L39) | `deinit` — nonisolated, а `EventHotKeyRef?`/`EventHandlerRef?` (`OpaquePointer`) не `Sendable`. В Swift 6 — ошибка | Объявить оба поля `nonisolated(unsafe) private var`. Комментарий в самом `deinit` («Carbon-вызовы thread-agnostic») уже является требуемым обоснованием | измерение |
| A3 | Concurrency | High | [PermissionsGate.swift:17](../../Sources/TextCapture/PermissionsGate.swift#L17) | `kAXTrustedCheckOptionPrompt` импортируется как глобальный `var` → «not concurrency-safe» | Снять значение один раз в `nonisolated(unsafe) private static let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String` | измерение |
| A4 | Наблюдаемость | High | весь `Sources` | **Ноль** `os.Logger`/`OSLog`. `print` есть только в `acceptance`. При этом четыре пути глушат ошибку намеренно: отказ `coordinator.start` ([TranslatorApp.swift:169](../../Sources/TranslatorApp/TranslatorApp.swift#L169)), отказ `warmUp()` ([:368](../../Sources/TranslatorApp/TranslatorApp.swift#L368)), отказ документного глоссария ([Translator.swift:225](../../Sources/TranslationCore/Translator.swift#L225)), `try? JSONEncoder` ([AppSettings.swift:159](../../Sources/TranslatorApp/AppSettings.swift#L159)). Каждый оправдан по отдельности; вместе они дают приложение, о сбоях которого нельзя узнать ничего | Ввести `Logger(subsystem: "com.mordvic.localtranslator", category: …)` и логировать именно эти четыре точки на уровне `.error`/`.notice`. Пользовательское поведение не меняется — меняется возможность диагностики по `log show --predicate 'subsystem == …'` | измерение (grep по `Sources`) |
| A5 | Сеть/IO | Medium | [OllamaStatusModel.swift:59](../../Sources/TranslatorApp/OllamaStatusModel.swift#L59), [ModelsViewModel.swift:50](../../Sources/TranslatorApp/ModelsViewModel.swift#L50), против [TranslatorApp.swift:27](../../Sources/TranslatorApp/TranslatorApp.swift#L27) | Комментарий обосновывает шаринг `OllamaClient` тем, что он «держит `URLSession`» и второй поднимать не надо. Фактически при старте создаются **три** (`TranslatorApp`, дефолтный `LiveOllamaProbe` в `OllamaStatusModel`, ещё один в `ModelsViewModel`), и `puller` по умолчанию конструирует `OllamaClient()` **на каждую** загрузку модели | Прокинуть один `OllamaClient` через дефолты `TranslatorApp.init` в оба view-model'а, как уже сделано для `Translator`. Либо снять обоснование из комментария — сейчас оно описывает не то, что происходит | чтение кода + grep |
| A6 | Сеть/IO | Medium | [OllamaClient.swift:33](../../Sources/OllamaKit/OllamaClient.swift#L33) | `timeoutIntervalForRequest = 120` на всех вызовах, включая интерактивный перевод по хоткею, чья заявленная цель — TTFT < 1 с. Собственные комментарии проекта ([TranslatorApp.swift:157](../../Sources/TranslatorApp/TranslatorApp.swift#L157), [:205](../../Sources/TranslatorApp/TranslatorApp.swift#L205)) трактуют эти 120 с как опасность — но только для порядка запуска, не для пользовательского пути | Разделить конфигурации: короткий таймаут для `chat` интерактивной роли, длинный — для `pull`. Сейчас зависшая Ollama держит панель две минуты, и единственный выход — «Отмена» | чтение кода |
| A7 | Build | Medium | [Package.swift:8-24](../../Package.swift#L8) | `.swiftLanguageMode(.v5)` на всех 11 таргетах при тулчейне 6.3.3. [Translator.swift:41-46](../../Sources/TranslationCore/Translator.swift#L41) уже документирует потребителя, который без этого не собрался бы | После A1–A3 переключить на `.v6`. Проверено: с `-strict-concurrency=complete` сборка проходит с 8 предупреждениями и **нулём ошибок**, то есть путь до `.v6` короткий | измерение |
| A8 | Security | Medium | нет файла `*.entitlements`; [make-app-bundle.sh](../../Scripts/make-app-bundle.sh) | Ни App Sandbox, ни Hardened Runtime, ни `--options runtime`. Для приложения, которое постит `CGEvent` через `.cghidEventTap` и читает системный AX, это **правильно** — песочница их запретит, — но нигде не записано как решение с причиной | Добавить ADR (в `docs/adr/` уже семь) «почему нет sandbox и hardened runtime». Иначе следующий человек попробует «привести к best practice» и сломает захват | чтение |
| A9 | Тестируемость | Low | [ModelsViewModel.swift:50](../../Sources/TranslatorApp/ModelsViewModel.swift#L50) | `puller` по умолчанию конструирует клиента внутри замыкания — единственная зависимость в приложении, которая создаётся не в `init` и потому не подменяется одним аргументом | Свести к `probe`-подобной инъекции. Тесты уже подменяют её, так что это косметика DI, не дыра | чтение |
| A10 | Security | — | весь репозиторий | **Находок нет.** Ни секретов (grep по `git ls-files`), ни keychain (нечего хранить), единственный сетевой хост — `http://127.0.0.1:11434` ([OllamaClient.swift:25](../../Sources/OllamaKit/OllamaClient.swift#L25)). ATS исключения не нужны и не заявлены — loopback работает эмпирически (проект гоняет `acceptance` против живой Ollama) | — | измерение (grep) |

### 2.2 UI / UX

| ID | Область | Severity | Место | Проблема | Рекомендация | Источник |
|---|---|---|---|---|---|---|
| U1 | Локализация | High | [Info.plist](../../Sources/TranslatorApp/Info.plist) | Бандл не объявляет ни одной локализации, поэтому `Bundle.main.preferredLocalizations == ["en"]`. Главное меню, которое SwiftUI ставит, остаётся английским **даже на русской системе** — измерено принудительным `-AppleLanguages '(ru)'`: `Edit / Copy / Paste / Quit`. Это же — причина, по которой [SettingsModelsView.swift:192](../../Sources/TranslatorApp/SettingsModelsView.swift#L192) и [RussianCopy.swift:189](../../Sources/TranslatorApp/RussianCopy.swift#L189) вынуждены прибивать `Locale(identifier: "ru_RU")` руками | Добавить в `Info.plist` `CFBundleDevelopmentRegion` = `ru` и положить пустой `Contents/Resources/ru.lproj/`. **Проверено на том же бинарнике**: меню становится «Правка / Скопировать / Вставить / Завершить», а `preferredLocalizations` — `["ru"]`. `make-app-bundle.sh` должен класть `ru.lproj` **до** `codesign` — по той же причине, что и иконку (комментарий про печать подписи в скрипте) | измерение (пробник, 3 конфигурации) |
| U2 | Корректность документации | Medium | [TranslatorApp.swift:466-467](../../Sources/TranslatorApp/TranslatorApp.swift#L466) | Комментарий: «There is no application menu in an `LSUIElement` app, so the standard ⌘, does not exist». Измерено на копии этой же конфигурации сцен: меню приложения **есть** в `NSApp.mainMenu` и несёт `Settings…` с ⌘,. Вывод (использовать `SettingsLink`) остаётся верным, посылка — нет | Переписать обоснование. По `CLAUDE.md` («„measured“ — контракт, а не выразительное средство») ложная посылка в комментарии дороже отсутствующего комментария | измерение |
| U3 | Mac-идиомы | Medium | весь `Sources` (grep: ноль `commands`/`CommandGroup`/`CommandMenu`) | Ни одной команды меню. «Перевести» ⌘↩ и «Отмена» ⌘. живут только как `.keyboardShortcut` на кнопках тулбара — работают, но недоступны для обнаружения и не существуют, когда окно закрыто. Меню `View` установлено системой и **пусто** | Добавить `.commands { }` к сцене `Window`: `CommandMenu("Перевод")` с «Перевести» / «Отмена» / «Поменять языки местами» / «Скопировать перевод», `CommandGroup(replacing: .help)` с чем-то осмысленным, и `CommandGroup(replacing: .sidebar) { }` чтобы убрать пустой `View`. Ключевые эквиваленты и так диспатчатся через `NSApp.mainMenu`, так что это чистое приобретение | context7 `/websites/developer_apple_swiftui` → `building-and-customizing-the-menu-bar-with-swiftui`; наличие пустого `View` — измерение |
| U4 | Accessibility | High | 4 метки на 4421 строку: [TranslatorApp.swift:98](../../Sources/TranslatorApp/TranslatorApp.swift#L98), [PanelView.swift:135](../../Sources/TranslatorApp/PanelView.swift#L135), [RunStatusBar.swift:35](../../Sources/TranslatorApp/RunStatusBar.swift#L35), [HotkeyRecorder.swift:90-93](../../Sources/TranslatorApp/HotkeyRecorder.swift#L90) | Панель не сообщает VoiceOver ни направления перевода, ни того, что перевод завершился. Уже зафиксировано в `docs/OPEN-ITEMS.md` §2 как «известно и принято» | **Перевести из «принято» в «запланировано».** Минимум: `accessibilityLabel` на `Text(model.translatedText)`, `accessibilityAddTraits(.updatesFrequently)` на неё же во время стрима, и объявление результата на `settling`. Это не большая работа, а панель — главная поверхность продукта | чтение + `OPEN-ITEMS.md` §2 |
| U5 | Accessibility | Medium | [PanelView.swift:64](../../Sources/TranslatorApp/PanelView.swift#L64), [SourcePane.swift:89](../../Sources/TranslatorApp/SourcePane.swift#L89), [RunStatusBar.swift:69](../../Sources/TranslatorApp/RunStatusBar.swift#L69) | Reduce Motion учтён ([TranslationPanel.swift:420](../../Sources/TranslatorApp/TranslationPanel.swift#L420)), **Reduce Transparency — нет**. `.regularMaterial` и `.quaternary.opacity(0.25)` рисуются одинаково при включённом «Уменьшение прозрачности» | Проверено компиляцией на планке macOS 14, что доступны и `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency`, и `@Environment(\.accessibilityReduceTransparency)`. Подменять `.regularMaterial` на непрозрачный `Color(nsColor: .windowBackgroundColor)` при включённом флаге. Симметрично уже сделанному для Reduce Motion | измерение (компиляционный пробник) |
| U6 | Layout | Medium | [SettingsPane.swift:18](../../Sources/TranslatorApp/SettingsPane.swift#L18) | `.frame(width: 560, height: 480)` — жёсткая рамка без `ScrollView`. Содержимое, которое не влезло, обрезается, а не прокручивается. `OPEN-ITEMS.md` §1 фиксирует, что две панели набрали секции **после** того, как высота была зафиксирована, и что это никто не смотрел | `.frame(minWidth: 560, idealHeight: 480)` + `ScrollView` внутри модификатора. Но: рамка существует ровно затем, чтобы окно не прыгало при переключении вкладок ([SettingsPane.swift:6-8](../../Sources/TranslatorApp/SettingsPane.swift#L6)) — минимальная ширина/высота этот инвариант сохраняет, обрезку убирает | чтение + `OPEN-ITEMS.md` §1 |
| U7 | Mac-идиомы | Medium | весь `Sources` (grep: ноль `onDrop`/`dropDestination`/`draggable`/`contextMenu`) | Окно переводчика не принимает перетащенный `.txt`/`.md`; в панели исходника нет контекстного меню; приложение не предоставляет ни одной **Service** — хотя это хрестоматийный кандидат («Перевести Толмачом» в меню «Службы» любого приложения), а подменю `Services` в `NSApp.mainMenu` уже стоит (измерено) | Порядок по отдаче: (1) `.dropDestination(for: URL.self)` на `SourcePane`; (2) `NSServices` в `Info.plist` + `NSPerformService`-провайдер — это буквально второй способ входа в продукт, дешевле, чем кажется; (3) `.contextMenu` на обеих панелях | измерение (grep + пробник меню) |
| U8 | Accessibility | Low | [PanelView.swift:299-304](../../Sources/TranslatorApp/PanelView.swift#L299) | Статус в панели («прерван» / «ошибка») различается **только цветом** — `.orange` против `.red`, без глифа. В остальных местах цвет всегда дублируется SF Symbol'ом ([SettingsGeneralView.swift:42/45](../../Sources/TranslatorApp/SettingsGeneralView.swift#L42), [SettingsModelsView.swift:34](../../Sources/TranslatorApp/SettingsModelsView.swift#L34)), так что это единственное исключение | Добавить иконку в `statusLine`, как в `SettingsNote`. Заодно закрывает Differentiate Without Color | чтение |
| U9 | State restoration | Low | нет `defaultSize`/`windowResizability`/`defaultPosition`/`restorationBehavior` | `Window` — синглтонная сцена, размер и позицию AppKit сохраняет сам; содержимое (`sourceText`) не восстанавливается | Для переводчика невосстановление текста скорее правильно. Отмечено ради полноты; действий не требует | grep |
| U10 | Localization/RTL | — | — | **Не находка.** RTL неприменим: `Language` перечисляет ru/en/de/fr/es/pt/it/zh/ja — ни одного RTL-языка. Отсутствие `.xcstrings` — зафиксированное решение `CLAUDE.md`, а не упущение | — | чтение |
| U11 | Layout | — | [PanelView.swift:168](../../Sources/TranslatorApp/PanelView.swift#L168), [:200](../../Sources/TranslatorApp/PanelView.swift#L200), [:268](../../Sources/TranslatorApp/PanelView.swift#L268), [:290](../../Sources/TranslatorApp/PanelView.swift#L290), [SettingsGeneralView.swift:57](../../Sources/TranslatorApp/SettingsGeneralView.swift#L57), [RunStatusBar.swift:101](../../Sources/TranslatorApp/RunStatusBar.swift#L101) | **Положительная находка.** Устойчивость к длинному тексту проработана лучше нормы: каждый `fixedSize(horizontal: false, vertical: true)` снабжён измеренным примером обрезки, которую он предотвращает | Не трогать | чтение |

### 2.3 Что аудит проверил и **не** нашёл дефекта

Записано отдельно, потому что ошибочная «модернизация» этих мест обошлась бы дороже, чем
их отсутствие в отчёте.

| Что | Вердикт | Источник |
|---|---|---|
| `HSplitView` вместо `NavigationSplitView` ([MainWindowView.swift:30](../../Sources/TranslatorApp/MainWindowView.swift#L30)) | **Корректно.** `HSplitView` — macOS 10.15+, не deprecated. `NavigationSplitView` предназначен для колоночной *навигации* (sidebar → detail); это окно — двухпанельный редактор, а не навигация | context7 `/websites/developer_apple_swiftui` → `hsplitview`, `bringing-robust-navigation-structure-to-your-swiftui-app` |
| ⌘C/⌘V/⌘Z/⌘A в `TextEditor` панели исходника | **Работают.** SwiftUI ставит полное меню `Edit` с `undo:`/`cut:`/`copy:`/`paste:`/`selectAll:` для этой конфигурации сцен, и ключевые эквиваленты диспатчатся через `NSApp.mainMenu` независимо от видимости меню-бара | измерение (пробник меню) |
| `@Observable` + ручные `access`/`withMutation` в `AppSettings` | **Корректно и необходимо.** Свойства вычисляемые над `UserDefaults`, синтез `@Observable` к ним не применяется. Альтернатива `@ObservationIgnored @AppStorage` потеряла бы главное свойство — подхват значения, изменённого `defaults write` | чтение + context7 `/avdlee/swiftui-agent-skill` → `state-management.md` |
| Два `TranslationViewModel` | **Корректно**, ADR 0004 + [HotkeyCoordinator.swift:38-43](../../Sources/TranslatorApp/HotkeyCoordinator.swift#L38) | чтение |
| Отсутствие retry/backoff | **Корректно** для локального сервера: «Повторить» на панели и в статус-баре — это и есть retry, инициированный пользователем | чтение |
| Секреты, keychain, ATS | Чисто (см. A10) | измерение |
| Файлы > 400 строк | Только два: [TranslatorApp.swift](../../Sources/TranslatorApp/TranslatorApp.swift) (515) и [TranslationPanel.swift](../../Sources/TranslatorApp/TranslationPanel.swift) (522). Оба когезивны — сцена целиком и панель целиком; God-object'ов нет | измерение |
| Дублирование логики | Не найдено. Пути копирования сведены в `GeneralPasteboard.write`; счёт предупреждений — в единственном `WarningsView.warningCount`, который читает и `RunStatusBar.summary` | чтение |

---

## 3. Стилевые предпочтения (не дефекты)

Отделено по просьбе заказчика. Ничего из этого я не рекомендую менять без отдельного решения.

- **Liquid Glass не принят.** Все API (`glassEffect`, `GlassEffectContainer`) требуют
  платформы 26+, планка — 14. Руководство, на которое ссылается context7, прямо говорит не
  переводить существующий UI на Liquid Glass без явного запроса. Панель уже использует
  `.regularMaterial`, что и есть документированный fallback. Источник: context7
  `/avdlee/swiftui-agent-skill` → `references/liquid-glass.md`.
- **Плотность комментариев.** Отношение комментариев к коду в `TranslatorApp` заметно выше
  обычного. Это осознанная политика `CLAUDE.md`, и она окупается: половина находок этого
  аудита найдена *потому что* комментарий называл измерение, которое можно перепроверить.
- **`AnyView` в `PanelController`** ([TranslationPanel.swift:237](../../Sources/TranslatorApp/TranslationPanel.swift#L237)) —
  стирание типа стоит производительности, но здесь нужно два разных билда одного контента;
  дженерик-параметр протащить через `NSHostingController` в две переменные не выйдет без
  большего усложнения.
- **Отсутствие CI.** Зафиксировано в `OPEN-ITEMS.md` §2 с причиной (`acceptance` требует
  живой Ollama). Замечу лишь, что `swift test` и `swift build --build-tests` *полностью
  офлайновы* — 0 warnings, 9 секунд, — и их одних хватило бы на GitHub Actions, не трогая
  `acceptance`.
- **`prototype-translation-engine/`** содержит только `.build/` и `.swiftpm/` — исходники
  удалены, остался игнорируемый мусор, из-за чего `git status` выглядит чистым. Косметика.

---

## 4. Модернизация: старый паттерн → текущий

| # | Из | В | Effort | Blast radius | Блокеры |
|---|---|---|---|---|---|
| M1 | `.swiftLanguageMode(.v5)` ×11 | `.v6` | **M** | Все 11 таргетов `Package.swift`; поведение не меняется | Сначала A1–A3. Измерено: 8 предупреждений, 0 ошибок — то есть после трёх правок остаются 2 в тестах |
| M2 | `NSPasteboard` в `Task.detached` | `@unchecked Sendable`-обёртка внутри `GeneralPasteboard` | **S** | `TextCapture/GeneralPasteboard.swift` + 2 вызова; `PasteboardSnapshot` не трогается | нет |
| M3 | нет локализации бандла | `CFBundleDevelopmentRegion=ru` + `ru.lproj/` | **S** | `Info.plist`, `Scripts/make-app-bundle.sh` (класть до `codesign`). **Проверено измерением: пустой `ru.lproj/Localizable.strings` не ломает русские литералы** — `NSLocalizedString`/`String(localized:)` возвращают ключ как есть, включая строку с `%` | нет |
| M4 | нет `.commands` | `CommandMenu("Перевод")` + `CommandGroup(replacing: .sidebar) { }` | **S** | `TranslatorApp.swift`, сцена `Window`. Риск: `CommandGroup(replacing:)` может задеть порядок меню — проверяется тем же пробником | нет |
| M5 | нет логирования | `os.Logger` на 4 глушащих пути | **M** | Сквозное, но чисто аддитивное — ни одна ветка поведения не меняется | нет |
| M6 | нет Reduce Transparency | `@Environment(\.accessibilityReduceTransparency)` | **S** | `PanelView`, `SourcePane`, `RunStatusBar`. API проверен компиляцией на планке 14 | нет |
| M7 | `.frame(width:height:)` в настройках | `.frame(minWidth:idealHeight:)` + `ScrollView` | **S** | `SettingsPane.swift` + 3 панели. **Риск регрессии**: рамка существует, чтобы окно не прыгало между вкладками — нужен ручной прогон всех трёх вкладок | нет |
| M8 | `withObservationTracking` с саморевзводом ([TranslatorApp.swift:233](../../Sources/TranslatorApp/TranslatorApp.swift#L233)) | `Observations` (AsyncSequence) | **S** | Одна функция | **Заблокировано**: `Observations` — macOS 26, планка 14. Комментарий в коде это уже знает и называет верно |
| M9 | порядок сцен как load-bearing инвариант | `Scene.defaultLaunchBehavior(.suppressed)` на `Window` | **S** | Снимает самое хрупкое ограничение всего app-слоя | **Заблокировано**: macOS 15+. Комментарий в коде это уже знает |
| M10 | нет Services / drag & drop | `NSServices` + `.dropDestination` | **L** | Новая поверхность входа: `Info.plist`, провайдер сервиса, `SourcePane`. Требует своего дизайна и ручной проверки | нет, но это фича, а не миграция |
| M11 | нет CI | GitHub Actions на `swift build --build-tests` + `swift test` | **S** | Новый файл, кода не касается. `acceptance` остаётся вне CI, как и записано | нет |

Оценки: **S** — до половины дня, **M** — 1–2 дня, **L** — неделя и своё проектирование.

---

## 5. Приоритетная дорожная карта

### Волна 1 — «сделать сбои видимыми» (≈ 2–3 дня)

Всё, что стоит между вами и способностью узнать, что у пользователя не работает.

1. **A4 / M5 — `os.Logger` на четыре глушащих пути.** Первым, потому что все остальные
   находки диагностируются легче, когда это есть. Сейчас отказ регистрации хоткея — то
   есть полная потеря единственного входа в продукт — не оставляет ни единого следа.
2. **A1–A3 / M1–M2 — шесть мест strict concurrency, затем `.v6`.** Ровно шесть, все
   локальные, компилятор их уже перечислил. Чем дольше это откладывается, тем дороже: любой
   новый код пишется под `.v5` и накапливает долг.
3. **A6 — таймаут интерактивного пути.** Дешёвая правка с прямым пользовательским эффектом:
   зависшая Ollama сейчас держит панель две минуты.

### Волна 2 — «сделать приложение маковским» (≈ 3–4 дня)

Здесь лежит наибольшая отдача на единицу усилий во всём отчёте.

4. **U1 / M3 — локализация бандла.** Два ключа, проверенный эффект: меню перестаёт быть
   английским островом в русском приложении. Побочно снимает необходимость прибивать
   `ru_RU` руками в двух местах.
5. **U3 / M4 — `.commands`.** Пустое меню `View` уходит, «Перевести» и «Отмена» становятся
   обнаружимыми и продолжают работать при закрытом окне.
6. **U2 — исправить опровергнутый комментарий.** Пять минут, но по правилам самого проекта
   это обязательный долг: измерение опровергло посылку.
7. **U5 / M6 + U8 — Reduce Transparency и иконка в статусе панели.** Симметрично уже
   сделанному для Reduce Motion.

### Волна 3 — «поднять потолок» (по решению)

8. **U4 — accessibility панели.** Крупнейший оставшийся разрыв. Требует ручной проверки
   VoiceOver, которую всё равно должен делать человек, — поэтому в третьей волне, а не
   раньше.
9. **U6 / M7 — прокрутка в настройках.** Требует ручного прогона трёх вкладок; связан с
   пунктом `OPEN-ITEMS.md` §1, который и так ждёт человека.
10. **A5 — свести `URLSession` к одной.** Либо снять обоснование из комментария.
11. **M11 — офлайновый CI.** Дёшево и защищает правило «zero warnings», которое сейчас
    держится только на дисциплине.
12. **U7 / M10 — Services и drag & drop.** Продуктовое решение, не техдолг.

**Явно не рекомендуется:** переход на Liquid Glass, замена `HSplitView`, поднятие планки до
macOS 15/26 ради M8–M9. Планка macOS 14 — осознанное ограничение; M8 и M9 стоит держать как
записанный выигрыш на день, когда планка поднимется по другой причине.

---

## 6. Не проверено / требует обсуждения

Помечено честно: ни одно из этого не является установленным дефектом и ни одно не
установлено как безопасное.

1. **Показывает ли `LSUIElement`-приложение свой меню-бар вообще.** Измерено, что меню
   *установлено* в `NSApp.mainMenu` и что его ключевые эквиваленты работают. **Не** измерено,
   рисуется ли оно на экране при активации — этого окружение увидеть не может. От ответа
   зависит severity U1 и U3: если меню никогда не видно, U1 — это про `preferredLocalizations`
   и форматирование чисел (реально, но мельче), а U3 — про обнаружимость (тоже мельче).
   **Это первый вопрос, который стоит закрыть человеку у экрана.**
2. **Пробник меню воспроизводит конфигурацию сцен, а не сам бандл.** `MenuBarExtra` →
   `Window` → `Settings`, `LSUIElement`-эквивалентная `.accessory`-политика. Совпадение с
   реальным `LocalTranslator.app` вероятно, но не проверено.
3. **context7 отдаёт документацию Liquid Glass в формулировках iOS 26.** macOS-специфика
   (панели, toolbar, `NSGlassEffectView`) не выгружалась. Для рекомендации «не принимать» это
   несущественно, для обратного решения — понадобится.
4. **Рантайм-семантика `@Environment(\.accessibilityReduceTransparency)` на macOS.**
   Компилируется на планке 14 (измерено); что она следует именно системному тумблеру
   «Уменьшение прозрачности», а не чему-то ещё, — не перекрёстно проверено с
   `NSWorkspace.accessibilityDisplayShouldReduceTransparency`. Оба флага на этой машине
   вернули `false`, то есть различить их сейчас нельзя.
5. **Весь `docs/OPEN-ITEMS.md` §1** — тридцать с лишним пунктов, ждущих человека у экрана.
   Аудит их не дублирует и не закрывает. Отмечу лишь, что пункт про **возможный цикл
   `.task { await launch() }`** (`OPEN-ITEMS.md` §1, Task 13) — единственный в списке, чья
   реализация была бы не косметической: повторный `launch()` перерегистрирует хоткей и
   заново ждёт `warmUp()`. Он проверяется одной строкой лога (A4/M5) — ещё один довод
   ставить логирование первым.
6. **Порог `maxHeightFraction = 0.6`** ([PanelSizer.swift:25](../../Sources/TranslatorApp/PanelSizer.swift#L25))
   и ширины 300–560 pt — выведены из измерений на конкретных дисплеях. На внешнем 4K или
   вертикальном мониторе поведение не измерялось никем.
7. **Открытый вопрос из `OPEN-ITEMS.md` §3 про `NSMouseInRect`** для выбора экрана
   ([TranslationPanel.swift:324](../../Sources/TranslatorApp/TranslationPanel.swift#L324)) —
   подтверждаю как реальный, подтвердить сам не могу: нужна многомониторная конфигурация.
8. **Стоит ли вообще принимать U7 (Services).** Это расширение продукта, а не устранение
   долга. Решение владельца; техническая цена низкая, а вторая точка входа для переводчика —
   аргумент сильный.
