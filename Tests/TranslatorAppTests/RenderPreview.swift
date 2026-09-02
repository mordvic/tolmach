import AppKit
import Testing
import MarkupKit
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
