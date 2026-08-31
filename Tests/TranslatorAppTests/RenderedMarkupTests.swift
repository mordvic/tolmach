// Tests/TranslatorAppTests/RenderedMarkupTests.swift
import AppKit
import Foundation
import MarkupKit
import Testing
import TextCapture
@testable import TranslationCore
@testable import TranslatorApp

/// Never `.general`: these write for real, and the user's clipboard is not the suite's to
/// spend. A uniquely named board is also the only shape `NSPasteboard` is safe in
/// concurrently — see `GeneralPasteboard`'s own doc comment.
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.markup.\(UUID().uuidString)"))
}

// MARK: - The setting

@Test func theRenderedMarkupSettingDefaultsToOnAndSurvivesAReload() {
    let defaults = InMemoryDefaults(prefix: "markup")
    // Default true: the pane used to show `# Заголовок` as its own characters, and rendering
    // is the behaviour this phase ships.
    #expect(AppSettings(defaults: defaults).showsRenderedMarkup)
    AppSettings(defaults: defaults).showsRenderedMarkup = false
    // A second instance over the same store, so what is asserted is the *stored* value and not
    // a property this object happens to remember.
    #expect(AppSettings(defaults: defaults).showsRenderedMarkup == false)
    #expect(defaults.object(forKey: "showsRenderedMarkup") as? Bool == false)
    AppSettings(defaults: defaults).showsRenderedMarkup = true
    #expect(AppSettings(defaults: defaults).showsRenderedMarkup)
}

@Test func theRenderedMarkupSettingIsObservable() {
    // The accessor pattern this file's whole class follows: no stored property, so
    // `@Observable`'s synthesis does not apply and `access`/`withMutation` are called by hand.
    // Without them a toggle in the pane's header would change the stored value and redraw
    // nothing.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "markup-obs"))
    // A class box rather than a captured `var`: the `onChange` closure is `@Sendable`, so a
    // mutable capture is a Swift 6 error.
    final class Flag: @unchecked Sendable { var raised = false }
    let observed = Flag()
    withObservationTracking { _ = settings.showsRenderedMarkup } onChange: { observed.raised = true }
    settings.showsRenderedMarkup = false
    #expect(observed.raised)
}

// MARK: - What the pane decides to draw and to copy

@Test func aPlainProseTranslationOffersNoToggleAndCopiesPlainOnly() {
    let text = "Это обычный перевод без разметки. Цена 5 * 3 = 15."
    let rendering = PaneRendering.of(text, showsRenderedMarkup: true)
    #expect(!rendering.hasMarkup)
    #expect(!rendering.showsRendered)
    // «a plain-prose translation never arrives in Word wearing a font this app chose»
    #expect(rendering.rtf(of: text, font: .default) == nil)
}

@Test func markupCopiesRichOnlyWhileTheRenderedModeIsShowing() {
    let text = "# Заголовок\n\nАбзац с **жирным**.\n"
    let rendered = PaneRendering.of(text, showsRenderedMarkup: true)
    #expect(rendered.hasMarkup)
    #expect(rendered.showsRendered)
    #expect(rendered.rtf(of: text, font: .default) != nil)
    // «Исходник» is showing the Markdown itself, so a rich flavour would describe something
    // other than what is on screen.
    let source = PaneRendering.of(text, showsRenderedMarkup: false)
    #expect(source.hasMarkup)
    #expect(!source.showsRendered)
    #expect(source.rtf(of: text, font: .default) == nil)
}

// MARK: - Two flavours, one write

@MainActor
@Test func copyingRenderedMarkupPutsBothTheMarkdownAndTheRTFOnOneBoard() async {
    let board = scratchPasteboard()
    let text = "# Заголовок\n\nАбзац с **жирным**.\n"
    let rtf = PaneRendering.of(text, showsRenderedMarkup: true).rtf(of: text, font: .default)
    await GeneralPasteboard.write(text, rtf: rtf, to: board)
    // The plain flavour is the Markdown bytes, unchanged from what the app always copied.
    #expect(board.string(forType: .string) == text)
    // …and the rich one is beside it rather than instead of it. Both, from one write: a second
    // `write` would have called `clearContents()` again and thrown the first flavour away.
    guard let data = board.data(forType: .rtf) else {
        Issue.record("no rtf flavour on the board"); return
    }
    let attributed = NSAttributedString(rtf: data, documentAttributes: nil)
    #expect(attributed?.string.contains("Заголовок") == true)
    // The markers are gone from the rich flavour, which is what makes it rich rather than a
    // second copy of the same characters.
    #expect(attributed?.string.contains("**") == false)
}

@MainActor
@Test func aPlainCopyLeavesNoRichFlavourBehindOnTheBoard() async {
    let board = scratchPasteboard()
    // Rich first, then plain — the order that catches a `write` which forgot to clear.
    await GeneralPasteboard.write("# Заголовок\n", rtf: Data("{\\rtf1 x}".utf8), to: board)
    #expect(board.data(forType: .rtf) != nil)
    await GeneralPasteboard.write("обычный текст", rtf: Data?.none, to: board)
    #expect(board.string(forType: .string) == "обычный текст")
    #expect(board.data(forType: .rtf) == nil)
}

@MainActor
@Test func theWindowsCopyStillWritesThePlainTextItAlwaysDid() async {
    // The one-argument `write` is what `HotkeyCoordinator.copyResult()` and the queue's copy
    // still call. It must behave exactly as before the rich flavour existed, empty guard
    // included: `clearContents()` with nothing to put back destroys what the user had copied.
    let board = scratchPasteboard()
    await GeneralPasteboard.write("уже скопировано", to: board)
    await GeneralPasteboard.write("", to: board)
    #expect(board.string(forType: .string) == "уже скопировано")
    #expect(board.data(forType: .rtf) == nil)
}

// MARK: - Streaming

/// A text view of the shape `RenderedTextView.makeNSView` builds — TextKit 1, because
/// `NSTextTable` lives nowhere else.
@MainActor
private func scratchTextView() -> CodeBlockTextView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: 400,
                                                 height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    return CodeBlockTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                             textContainer: container)
}

@MainActor
@Test func streamingNeverRedrawsABlockItHasAlreadyDrawnAsItself() {
    let document = """
    # Заголовок

    Абзац с **жирным**.

    - пункт один
    - пункт два

    ```swift
    let x = 1
    ```

    Последний абзац.
    """
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    let config = ContentFont.default.markdownConfig
    var previouslySettled = ""
    // Character by character, which is finer than the engine's tokens and therefore strictly
    // harder: every intermediate state a stream can be in is visited.
    for length in 0...document.count {
        let arrived = String(document.prefix(length))
        coordinator.apply(text: arrived, font: .default, rendersMarkup: true,
                          isStreaming: true, to: view)
        let (blocks, tail) = MarkdownBlockScanner.settledPrefix(of: arrived)
        let settled = MarkdownToAttributed
            .rendering(blocks: blocks, in: arrived, config: config).attributed.string
        // **The incremental path must produce what a whole recompute would.** The coordinator
        // replaces only the tail region of the storage, so a wrong region — an off-by-one in
        // `settledLength`, a `tailLength` not updated — would leave the document duplicated or
        // truncated here rather than merely mis-styled.
        #expect(view.textStorage?.string == settled + String(arrived[tail]),
                "at \(length) characters the storage is not the settled prefix plus the tail")
        // …and what was settled a token ago is still settled, byte for byte. A block redrawn
        // as something else — a paragraph becoming a heading, a run-together paragraph
        // becoming a table — breaks this, and that is what `settledPrefix` exists to prevent.
        #expect(settled.hasPrefix(previouslySettled),
                "at \(length) characters an already-drawn block changed")
        previouslySettled = settled
    }
    // And at the end, everything that has settled is rendered rather than left as characters.
    coordinator.apply(text: document, font: .default, rendersMarkup: true, isStreaming: true,
                      to: view)
    let drawn = view.textStorage?.string ?? ""
    #expect(!drawn.contains("# Заголовок"))
    #expect(!drawn.contains("**жирным**"))
    // The unsettled last paragraph is still its own characters, which is the honest state for
    // a block whose shape is not yet decided — it carries no markers to eat.
    #expect(drawn.contains("Последний абзац."))
}

@MainActor
@Test func aFinishedRunRendersTheWholeDocumentIncludingItsLastBlock() {
    // A document with no trailing blank line: its last block can never *settle*, so the
    // streaming path alone would leave it as plain characters for ever. The pane renders whole
    // whenever no run is in flight, which is why `isStreaming` is a parameter and not a guess.
    let document = "# Заголовок\n\nПоследний абзац."
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: document, font: .default, rendersMarkup: true, isStreaming: false,
                      to: view)
    let drawn = view.textStorage?.string ?? ""
    #expect(drawn.contains("Заголовок"))
    #expect(!drawn.contains("#"))
    #expect(drawn.contains("Последний абзац."))
}

@MainActor
@Test func theSourceModeShowsTheDocumentsOwnCharacters() {
    let document = "# Заголовок\n\nАбзац с **жирным**.\n"
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: document, font: .default, rendersMarkup: false, isStreaming: false,
                      to: view)
    // Byte for byte: «Исходник» is today's pane in a text view, not a re-serialisation.
    #expect(view.textStorage?.string == document)
    #expect(view.codeRegions.isEmpty)
}

@MainActor
@Test func switchingModesRebuildsRatherThanAppendingToWhatWasAlreadyDrawn() {
    let document = "# Заголовок\n\nАбзац.\n\n"
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: document, font: .default, rendersMarkup: true, isStreaming: true,
                      to: view)
    coordinator.apply(text: document, font: .default, rendersMarkup: false, isStreaming: true,
                      to: view)
    // Not «the rendered document followed by the source»: a mode change invalidates everything
    // already in the storage, and the state that tracks what was drawn has to reset with it.
    #expect(view.textStorage?.string == document)
}

@MainActor
@Test func aRunStartingOverAPreviousResultReplacesItRatherThanPrependingToIt() {
    // Reachable from «Ещё вариант»: the previous translation is still on screen when the next
    // run's first tokens arrive. The incremental path replaces the tail *region*, which after
    // a reset is a zero-length range at the front — so a reset that forgot to empty the
    // storage put the new document in front of the old one instead of over it.
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: "# Первый\n\nСтарый абзац.\n", font: .default,
                      rendersMarkup: true, isStreaming: false, to: view)
    #expect(view.textStorage?.string.contains("Старый абзац.") == true)
    coordinator.apply(text: "# Второй\n\nНовый", font: .default, rendersMarkup: true,
                      isStreaming: true, to: view)
    let drawn = view.textStorage?.string ?? ""
    #expect(!drawn.contains("Старый абзац."))
    #expect(!drawn.contains("Первый"))
    #expect(drawn.contains("Второй"))
}

@MainActor
@Test func aCodeBlockKeepsItsSourceBytesForTheOverlayToCopy() {
    let document = "Текст\n\n```swift\nlet x = 1\n```\n\nЕщё.\n"
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: document, font: .default, rendersMarkup: true, isStreaming: false,
                      to: view)
    #expect(view.codeRegions.count == 1)
    #expect(view.codeRegions.first?.source == "let x = 1")
    // The region points at those bytes *inside the storage*, which is what the button's
    // placement is measured from — an off-by-one here would put the button over the paragraph.
    guard let region = view.codeRegions.first, let storage = view.textStorage else { return }
    #expect((storage.string as NSString).substring(with: region.range) == "let x = 1")
}

@MainActor
@Test func aCodeBlockThatArrivesMidStreamIsFoundOnceRatherThanTwice() {
    // The regions travel with the settled prefix and are *appended* to, so an update that
    // re-rendered the whole document into the same array would count every block twice.
    let document = "```\nкод\n```\n\nАбзац.\n\n"
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    for length in 0...document.count {
        coordinator.apply(text: String(document.prefix(length)), font: .default,
                          rendersMarkup: true, isStreaming: true, to: view)
    }
    #expect(view.codeRegions.count == 1)
    #expect(view.codeRegions.first?.source == "код")
}
