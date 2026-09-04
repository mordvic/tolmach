import AppKit
import Testing
import MarkupKit
import TranslationCore
@testable import TranslatorApp

/// Draws the rendered pane into two PNGs — light and dark — so a person (or an agent reading
/// images) can judge the typography without launching the app.
///
/// **Not a test, and off unless asked for.** It writes files, which a test must not do
/// unasked, and its outcome is a judgement, not an assertion. Run it as:
///
///     RENDER_PREVIEW=/tmp/preview swift test --filter renderPreview
///     RENDER_PREVIEW=/tmp/preview RENDER_PREVIEW_MARKDOWN=corpus/markup-en.md swift test --filter renderPreview
///
/// The default document is `previewDocument` below, which carries one of every block form
/// the renderer draws. `docs/reference/OPEN-ITEMS.md`'s «by eye» rows for the rendered pane are
/// what this exists to shorten: the 2026-09-02 typography pass (header fill, rules between
/// rows, the quote's bar, the inline-code spill) was seen and fixed from these images.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["RENDER_PREVIEW"] != nil))
func renderPreview() throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: environment["RENDER_PREVIEW"] ?? ".")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let markdown = try environment["RENDER_PREVIEW_MARKDOWN"]
        .map { try String(contentsOfFile: $0, encoding: .utf8) } ?? previewDocument
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let view = CodeBlockTextView(textKit1Inset: NSSize(width: 3, height: 8))
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 10)
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: 10_000, height: 100_000)
        let coordinator = RenderedTextView.Coordinator()
        coordinator.apply(text: markdown, font: .default, rendersMarkup: true, isStreaming: false,
                          to: view)
        guard let layout = view.layoutManager, let container = view.textContainer else {
            Issue.record("the view is not in TextKit 1"); return
        }
        layout.ensureLayout(for: container)
        view.frame = NSRect(x: 0, y: 0, width: 620,
                            height: ceil(layout.usedRect(for: container).height) + 16)
        view.layout()
        view.drawsBackground = true
        view.backgroundColor = appearance == .aqua ? .white : NSColor(calibratedWhite: 0.12, alpha: 1)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("no bitmap for \(name)"); return
        }
        view.appearance?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("no png for \(name)"); return
        }
        try png.write(to: directory.appendingPathComponent("preview-\(name).png"))
    }
}

private let previewDocument = """
    # Что предлагается

    Объединить девять репозиториев, составляющих продукт Profile, в один монорепозиторий.

    | Папка | Исходный репозиторий | Ветка (Trunk) |
    | --- | --- | --- |
    | /nova | profile-nova | main |
    | /server | profile-server | main |
    | /tests/profile | profile-tests | main |

    Каждая часть изменений попадает в один коммит, а номера версий, которые мы передаём между \
    репозиториями, исчезают. `profile-k8s-tests` исключён: он тестирует инфраструктуру.

    **Вне рамок предложения:** календарь релизов и *цепочка согласований*.

    ## Проверка кода

    ```bash
    swift build --build-tests
    swift test --filter TranslationCoreTests
    ```

    - первый пункт списка
    - второй пункт с `кодом`
      - вложенный

    1. раз
    2. два

    > Цитата: никогда не пропускайте второй шаг.

    ---

    Последний абзац, см. [сайт](https://example.org).
    """

/// The правка marks, drawn so a person can judge them — the look measurement protocol item 7
/// of the change-marks spec asks for, beside the contrast figures `Scripts/accent-contrast.swift`
/// prints. Same contract as `renderPreview`: off unless asked for, writes files, judges nothing.
///
///     RENDER_PREVIEW_CHANGES=/tmp/preview swift test --filter renderChangesPreview
///
/// Eight images: «Результат» and «Изменения», at 13 and 22 pt, light and dark. The fixture puts
/// a link beside a corrected word on purpose — the two underlines are what the 1.49:1 figure in
/// that script is about — and carries one change of every kind the locator handles: a word in a
/// paragraph, a word in a list item, a cell in a table, a paragraph rewritten past the threshold.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["RENDER_PREVIEW_CHANGES"] != nil))
func renderChangesPreview() throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_PREVIEW_CHANGES"] ?? ".")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = """
        # Отчет за август

        Добрый день, Анна! Высылаю вам отчет за август, посмотрите пожалуйста до пятницы. \
        Подробности на [сайте](https://example.org), коментарии внизу.

        - Север: план выполнен.
        - Юг: отставание на 4%, смотрите таблицу.

        | Регион | Итог |
        | --- | --- |
        | Север | выполнен |
        | Юг | отстование |

        Если что то будет непонятно то пишите, я на связи.
        """
    let result = """
        # Отчёт за август

        Добрый день, Анна! Высылаю вам отчёт за август, посмотрите, пожалуйста, до пятницы. \
        Подробности на [сайте](https://example.org), комментарии внизу.

        - Север: план выполнен.
        - Юг: отставание на 4 %, смотрите таблицу.

        | Регион | Итог |
        | --- | --- |
        | Север | выполнен |
        | Юг | отставание |

        Если возникнут вопросы, напишите мне, я на связи.
        """
    let changes = TextDiff.changes(source: source, result: result)
    for size in [CGFloat(13), 22] {
        for detail in [false, true] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = CodeBlockTextView(textKit1Inset: NSSize(width: 3, height: 8))
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 0, y: 0, width: 560, height: 10)
                view.isVerticallyResizable = true
                view.minSize = .zero
                view.maxSize = NSSize(width: 10_000, height: 100_000)
                let coordinator = RenderedTextView.Coordinator()
                coordinator.apply(text: result, font: ContentFont(typeface: .system, size: size),
                                  rendersMarkup: true, isStreaming: false, changes: changes,
                                  showsChangeDetail: detail, to: view)
                guard let layout = view.layoutManager, let container = view.textContainer else {
                    Issue.record("the view is not in TextKit 1"); return
                }
                layout.ensureLayout(for: container)
                view.frame = NSRect(x: 0, y: 0, width: 560,
                                    height: ceil(layout.usedRect(for: container).height) + 16)
                view.layout()
                view.drawsBackground = true
                view.backgroundColor = appearance == .aqua ? .white : NSColor(calibratedWhite: 0.12, alpha: 1)
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    Issue.record("no bitmap"); return
                }
                view.appearance?.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    Issue.record("no png"); return
                }
                let file = "changes-\(detail ? "detail" : "result")-\(Int(size))pt-\(name).png"
                try png.write(to: directory.appendingPathComponent(file))
            }
        }
    }
}

/// The two cosmetic questions §6.2's last paragraph and §14 phase 4 left to a look: whether a
/// code card should wrap by word (today) or by character. Not a test either — same contract as
/// the two above: writes files, off unless asked for, and the outcome is a judgement made by
/// reading the PNGs, not an assertion.
///
///     RENDER_PREVIEW_CODE=/tmp/preview swift test --filter renderCodePreview
///
/// Twelve images: three code blocks (a shell command with long flags, a JSON line, a comment
/// carrying a URL beside a signature with underscored parameter names) at 560 and 300 pt, word-
/// and char-wrapped, light and dark. `.byCharWrapping` is applied to a **copy** of the
/// rendering's paragraph style, scoped to the code regions alone — never to
/// `MarkdownToAttributed` itself, because the decision in the design (§11 item 6) is made by
/// looking first and the source changes once, after, with the reason written beside it.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["RENDER_PREVIEW_CODE"] != nil))
func renderCodePreview() throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_PREVIEW_CODE"] ?? ".")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = MarkdownFontConfig.default
    let rendering = MarkdownToAttributed.rendering(of: codePreviewDocument, config: config)
    for (mode, byChar) in [("word", false), ("char", true)] {
        let attributed = NSMutableAttributedString(attributedString: rendering.attributed)
        if byChar {
            for region in rendering.codeRegions {
                attributed.enumerateAttribute(.paragraphStyle, in: region.range,
                                              options: []) { value, range, _ in
                    guard let style = (value as? NSParagraphStyle)?
                        .mutableCopy() as? NSMutableParagraphStyle else { return }
                    style.lineBreakMode = .byCharWrapping
                    attributed.addAttribute(.paragraphStyle, value: style, range: range)
                }
            }
        }
        for width in [CGFloat(560), 300] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = CodeBlockTextView(textKit1Inset: NSSize(width: 3, height: 8))
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 0, y: 0, width: width, height: 10)
                view.isVerticallyResizable = true
                view.minSize = .zero
                view.maxSize = NSSize(width: 10_000, height: 100_000)
                view.textStorage?.setAttributedString(attributed)
                view.codeRegions = rendering.codeRegions
                guard let layout = view.layoutManager, let container = view.textContainer else {
                    Issue.record("the view is not in TextKit 1"); return
                }
                layout.ensureLayout(for: container)
                view.frame = NSRect(x: 0, y: 0, width: width,
                                    height: ceil(layout.usedRect(for: container).height) + 16)
                view.layout()
                view.drawsBackground = true
                view.backgroundColor = appearance == .aqua ? .white : NSColor(calibratedWhite: 0.12, alpha: 1)
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    Issue.record("no bitmap"); return
                }
                view.appearance?.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    Issue.record("no png"); return
                }
                let file = "code-\(mode)-\(Int(width))pt-\(name).png"
                try png.write(to: directory.appendingPathComponent(file))
            }
        }
    }
}

private let codePreviewDocument = """
    # Длинные строки в коде

    Команда с длинными флагами:

    ```bash
    swift build --build-tests --disable-sandbox --destination generic/platform=macOS --extremely-long-additional-flag-name
    ```

    Строка JSON:

    ```json
    {"engine_identifier": "ollama-loopback-http-client", "keep_alive_duration_seconds": 1800, "quiet_thinking_enabled": true}
    ```

    Комментарий со ссылкой и сигнатура с подчёркиваниями в именах:

    ```swift
    // See https://developer.apple.com/documentation/appkit/nstextcontainer/widthtrackstextview for the trap this avoids
    func chatOptions(model modelIdentifierWithNamespace: String, quietThinkingLevelOverride: ThinkingLevel?) -> ChatOptions
    ```
    """

/// Question 2 of phase 4: does a realistic four-column table stay legible at the panel's own
/// floor, or does it need the panel to grow past it? Drawn through the panel's own measuring
/// path — `RenderedReplyView.measuredSize` for the height a real fit would ask for, then the
/// same attributed string in a `CodeBlockTextView` at that height — so what is judged is what
/// `PanelController.measure` would actually produce, not a stand-in geometry.
///
///     RENDER_PREVIEW_TABLE=/tmp/preview swift test --filter renderTablePreview
///
/// Six images: 300, 430 and 560 pt, light and dark. Header and cell text are realistic lengths
/// («Регион», «Итог за август», «Ответственный», «Комментарий»), because a table of single
/// words never shows what a narrow column does to a sentence.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["RENDER_PREVIEW_TABLE"] != nil))
func renderTablePreview() throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_PREVIEW_TABLE"] ?? ".")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = MarkdownFontConfig.default
    let rendering = MarkdownToAttributed.rendering(of: tablePreviewDocument, config: config)
    for width in [CGFloat(300), 430, 560] {
        let size = RenderedReplyView.measuredSize(of: rendering.attributed, width: width)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = CodeBlockTextView(textKit1Inset: RenderedReplyView.inset,
                                        lineFragmentPadding: RenderedReplyView.lineFragmentPadding)
            view.appearance = NSAppearance(named: appearance)
            view.isVerticallyResizable = false
            view.isHorizontallyResizable = false
            view.textStorage?.setAttributedString(rendering.attributed)
            view.codeRegions = rendering.codeRegions
            view.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
            view.layout()
            view.drawsBackground = true
            view.backgroundColor = appearance == .aqua ? .white : NSColor(calibratedWhite: 0.12, alpha: 1)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                Issue.record("no bitmap"); return
            }
            view.appearance?.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            guard let png = rep.representation(using: .png, properties: [:]) else {
                Issue.record("no png"); return
            }
            let file = "table-\(Int(width))pt-\(name).png"
            try png.write(to: directory.appendingPathComponent(file))
        }
    }
}

private let tablePreviewDocument = """
    | Регион | Итог за август | Ответственный | Комментарий |
    | --- | --- | --- | --- |
    | Северо-Запад | 128 400 ₽, план перевыполнен | Иванова А. С. | Рост за счёт нового клиента, нужно согласовать бюджет на сентябрь |
    | Юг | 94 200 ₽, отставание 6 % | Петров Д. Н. | Задержка поставки повлияла на закрытие месяца, ждём документы от логистики |
    | Урал | 61 000 ₽, план выполнен | Сидоров К. В. | Без замечаний |
    """
