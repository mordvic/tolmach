import Testing
import AppKit
import Foundation
import SwiftUI
@testable import MarkupKit
@testable import TranslatorApp
@testable import TranslationCore

// MARK: - When the panel renders at all

/// The panel's whole Phase 4 condition, in the four directions it can be wrong.
///
/// Each `#expect` below dies under a different mutation of the rule, which is why they are
/// separate lines rather than one `&&`: dropping the `state != .running` clause makes the first
/// pass and the second fail, dropping `awaitingRun` makes the third pass, dropping the setting
/// makes the fourth, and dropping the `hasMarkup` scan makes the fifth. Watched, one at a time.
@Test func theReplyIsDrawnAsADocumentOnlyOnceTheRunHasEndedAndOnlyIfThereIsMarkup() {
    let markup = """
        ## Заголовок

        | a | b |
        |---|---|
        | 1 | 2 |
        """
    let prose = "Обычная проза, где 5 * 3 = 15 и файл a_b_c.txt ничего не размечают."

    // Streaming: plain characters, byte for byte what the panel did before Phase 4. The design's
    // own reason (§7) is that a reflowing layout at 300–560 pt is worse to watch than raw `**`.
    #expect(PanelView.rendersFinalReply(state: .running, awaitingRun: false, text: markup,
                                        showsRenderedMarkup: true) == false)
    // Settled, with markup, and the user has not asked for «Исходник».
    #expect(PanelView.rendersFinalReply(state: .finished, awaitingRun: false, text: markup,
                                        showsRenderedMarkup: true))
    // A press whose run has not started yet: the panel is measured against the invisible
    // reservation while still showing the *previous* run's text. Rendering there would put a
    // document and that reservation in one `ZStack` and size the panel against both.
    #expect(PanelView.rendersFinalReply(state: .finished, awaitingRun: true, text: markup,
                                        showsRenderedMarkup: true) == false)
    // «Исходник».
    #expect(PanelView.rendersFinalReply(state: .finished, awaitingRun: false, text: markup,
                                        showsRenderedMarkup: false) == false)
    // Nothing to render: the panel must measure and draw exactly as it always did.
    #expect(PanelView.rendersFinalReply(state: .finished, awaitingRun: false, text: prose,
                                        showsRenderedMarkup: true) == false)
}

/// «The run has ended» is wider than `.finished`, and the two states that make it wider are the
/// ones a reader is most likely to be looking at output in.
///
/// An interrupted run's partial output is kept on purpose (spec 8), and a failed run keeps the
/// previous translation on screen with the failure underneath. In both, nothing more is coming to
/// reflow — so there is no reason to leave a document showing as its own source code. A rule
/// written as `state == .finished` passes the test above and fails here.
@Test func aRunThatWasInterruptedOrFailedHasStillEndedAsFarAsTheRenderingGoes() {
    let markup = "## Заголовок\n\nабзац."
    #expect(PanelView.rendersFinalReply(state: .interrupted, awaitingRun: false, text: markup,
                                        showsRenderedMarkup: true))
    #expect(PanelView.rendersFinalReply(state: .failed("Ollama не запущена"), awaitingRun: false,
                                        text: markup, showsRenderedMarkup: true))
    // And `.idle` with nothing shown is not a run that ended — but it is `hasMarkup` that says
    // so, not the state, which is the honest reason and is worth pinning as such.
    #expect(PanelView.rendersFinalReply(state: .idle, awaitingRun: false, text: "",
                                        showsRenderedMarkup: true) == false)
}

// MARK: - The measurement §11.4 sent a probe after

/// The document `Scripts/panel-rendered-measure.swift` measures, byte for byte.
///
/// Duplicated rather than shared, because the probe is a standalone `swiftc` script that links
/// the package's object files and cannot import this test target. **If this string is edited, the
/// probe's copy and its recorded numbers go stale together** — the numbers below are what that
/// script printed, and re-taking them means running it.
private let probeDocument = """
    ## Отчёт о совместимости

    Ниже — сводка по трём движкам и один пример вызова. Абзац нарочно длинный, чтобы на \
    узкой панели он переносился на несколько строк, а на широкой — на меньшее их число.

    | Движок | Порт | Потоковая выдача | Таблицы |
    |---|---:|:---:|---|
    | Ollama | 11434 | да | да |
    | LM Studio | 1234 | да | да |
    | MLX | — | нет | нет |

    ```swift
    let outcome = try await translator.translate(source: text, to: .russian)
    print(outcome.timeToFirstTokenMS ?? 0)
    ```

    - первый пункт списка
    - второй пункт списка
    - третий пункт списка
    """

/// The numbers the panel's whole rendered presentation rests on, at the three widths §11.4 named.
///
/// `PanelController` sizes the panel from a **detached** `NSHostingController`, and an
/// `NSViewRepresentable` with no `sizeThatFits` answers that host `fittingSize` 0 × 0 and
/// `sizeThatFits(in:)` `greatestFiniteMagnitude` — measured, `Scripts/panel-rendered-measure.swift`
/// §1. `PanelSizer.measured` tests `isFinite && > 0` and `greatestFiniteMagnitude` passes both, so
/// every rendered panel would have opened at 0.6 × the screen and scrolling, for a one-line reply
/// as much as for a page. This pins the answer that replaces it.
///
/// **Tolerance rather than equality, and the probe is why the tolerance is small.** Ten
/// consecutive reads on one host and a fresh host answered the identical `CGFloat` — spread
/// 0.0000 — so nothing here is flaky and equality would hold today. ±2 pt is for the one thing
/// this repo cannot pin: these are sums of system-font metrics, and a font revision may move a
/// line height by a fraction with nothing in this codebase changing. A drift larger than a
/// fraction is a real change and should fail.
@MainActor
@Test func theRenderedReplyMeasuresTheHeightsTheProbeTookAtEachPanelWidth() {
    let rendering = MarkdownToAttributed.rendering(of: probeDocument,
                                                   config: MarkdownFontConfig(baseSize: 13))
    // 300 is `PanelSizer.minWidth`, 560 is `maxWidth`, 430 is between them — the three widths
    // §11.4 asked for.
    // 419 / 355 / 339 when the probe ran (2026-08-31); **+27 at every width since 2026-09-02**,
    // re-measured through this same function when the code block became a card (spec #72,
    // step 5): the card's 24 pt header room plus its margins, less the paragraph spacing the
    // tinted paragraph used to carry. The same shift at all three widths is what says the
    // card, and not a wrap, is what moved — the probe script's own figures predate the card.
    // And 491 / 395 / 379 since the typography pass the same day (spec #72 follow-up): the
    // table gained a header fill, wider cell padding and a bottom margin, the quote a bar. The
    // larger move at 300 pt is the padding — narrower columns wrap one more cell there.
    let expected: [(width: CGFloat, height: CGFloat)] = [(300, 491), (430, 395), (560, 379)]
    for (width, height) in expected {
        let measured = RenderedReplyView.measuredSize(of: rendering.attributed, width: width)
        #expect(abs(measured.height - height) <= 2,
                "at \(width) pt expected ≈\(height), measured \(measured.height)")
        // The width is the proposal, handed straight back: this view wraps to what it is given
        // and never asks for more, which is what keeps the panel's frozen width frozen.
        #expect(measured.width == width)
    }
    // Narrower is taller, which no single width can say. A `sizeThatFits` that ignored the
    // proposal and answered one constant would satisfy every assertion above and fail this.
    let heights = expected.map {
        RenderedReplyView.measuredSize(of: rendering.attributed, width: $0.width).height
    }
    #expect(heights[0] > heights[1])
    #expect(heights[1] > heights[2])
}

/// An unspecified proposal must answer the document's *own* width, and that is load-bearing
/// rather than tidy.
///
/// `fittingSize` — the first of `PanelController.measure`'s two passes — is where the panel's
/// ideal width comes from, and it proposes nothing. Measured, `Scripts/panel-rendered-measure.swift`
/// §2: this document's natural width is 1155 pt, the longest unwrapped line, which `PanelSizer`
/// clamps to `maxWidth` 560. The first draft of the probe answered a constant 300 there, and the
/// consequence is exactly what this test exists to prevent: every rendered reply asks for
/// `minWidth`, and a wide document can only ever reach 560 if the plain streamed text had
/// already taken the panel there.
@MainActor
@Test func anUnspecifiedProposalIsAnsweredWithTheDocumentsOwnUnwrappedWidth() {
    let rendering = MarkdownToAttributed.rendering(of: probeDocument,
                                                   config: MarkdownFontConfig(baseSize: 13))
    let natural = RenderedReplyView.measuredSize(of: rendering.attributed, width: nil)
    #expect(abs(natural.width - 1155) <= 4, "natural width measured \(natural.width)")
    // Wider than any width the panel can be, which is the property `PanelSizer` acts on — and a
    // statement that survives a font revision moving the exact figure.
    #expect(natural.width > PanelSizer.maxWidth)
    // Not the greedy answer either. `greatestFiniteMagnitude` is what a scroll view and a
    // missing `sizeThatFits` both give, and it is finite, so a sizer cannot tell it from a
    // measurement.
    #expect(natural.width < CGFloat.greatestFiniteMagnitude)
    #expect(natural.height > 0)
}

/// The measurement and the layout have to agree, or the panel is sized for a document it then
/// draws differently.
///
/// `measuredSize` deliberately builds a *throwaway* text-layout stack rather than asking the
/// installed view, so that measuring cannot re-lay-out text a reader is looking at. That only
/// works if the throwaway stack is configured the way the real one is — the probe's §3 measured
/// them agreeing to the point at all three widths (419 / 355 / 339), and the two things that make
/// them agree are the container's `lineFragmentPadding` and the inset arithmetic. A programmatic
/// container comes up with 5.0 of padding and the panel overrides it to 0, which is worth a whole
/// line at 300 pt — the same document measures 467 / 371 / 355 at the pane's geometry. This
/// re-takes that agreement against the view the app actually installs.
@MainActor
@Test func theThrowawayMeasurementAgreesWithWhatThePanelsTextViewLaysOut() {
    let rendering = MarkdownToAttributed.rendering(of: probeDocument,
                                                   config: MarkdownFontConfig(baseSize: 13))
    let live = PanelReplyTextView(textKit1Inset: RenderedReplyView.inset,
                                  lineFragmentPadding: RenderedReplyView.lineFragmentPadding)
    live.textStorage?.setAttributedString(rendering.attributed)
    guard let container = live.textContainer, let layout = live.layoutManager else {
        Issue.record("the panel's reply view came up without a TextKit 1 stack")
        return
    }
    // The default a container brings, and the reason the panel sets it to 0: 5 pt of indent the
    // plain streamed text does not have would shift every line sideways at the swap.
    #expect(NSTextContainer(size: .zero).lineFragmentPadding == 5)
    #expect(container.lineFragmentPadding == 0)

    for width in [CGFloat(300), 430, 560] {
        live.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        container.size = CGSize(width: width - RenderedReplyView.inset.width * 2,
                                height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let laidOut = ceil(layout.usedRect(for: container).height)
            + RenderedReplyView.inset.height * 2
        let measured = RenderedReplyView.measuredSize(of: rendering.attributed, width: width)
        #expect(abs(measured.height - laidOut) < 0.5,
                "at \(width) pt the measurement says \(measured.height) and the view lays out \(laidOut)")
    }
}

// MARK: - The swap, through the real panel

/// A client that is never asked for anything — the same stand-in `TranslationPanelTests` uses,
/// and for the same reason: what is measured here is geometry, and a run would only add delay.
private final class MuteClient: LLMClient, @unchecked Sendable {
    func chat(messages: [ChatMessage],
              options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private func replyModel(showing translated: String) -> TranslationViewModel {
    let model = TranslationViewModel(
        translator: Translator(client: MuteClient()),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "panel-render")),
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-render-\(UUID().uuidString).json")))
    model.translatedText = translated
    return model
}

/// A holder so the builder can read the controller it is being built for — the controller does
/// not exist yet when its own content closure is written. `PanelHost` does this by capturing the
/// app's `panel` property; a test has to say it out loud.
@MainActor
private final class ControllerBox {
    var controller: PanelController?
    /// What the flag was every time the *installed* variant was built, in order. The installed
    /// host is the one the controller only rebuilds on purpose — the detached one is reassigned
    /// on every measuring pass — so this is where a stale build shows up.
    var installedBuilds: [Bool] = []
}

/// A controller over the **real** `PanelView`, whose `rendersFinalReply` comes from the
/// controller exactly as the app's does.
@MainActor
private func renderingPanelContent(_ model: TranslationViewModel,
                                   _ box: ControllerBox) -> (PanelContentVariant) -> AnyView {
    { variant in
        let renders = box.controller?.rendersFinalReply ?? false
        if case .installed = variant { box.installedBuilds.append(renders) }
        return AnyView(PanelView(model: model, selection: .text("исходный текст"),
                                 adoptionRefusal: nil,
                                 rendersFinalReply: renders,
                                 scrolls: variant.scrolls, fillsPanel: variant.fillsPanel))
    }
}

/// The property the design asks for at the swap: **the panel does not come in under the
/// reader** — and the rule that holds it is `PanelSizer`'s height being monotonic *outside* the
/// settle, which is why `PanelController.setRendersFinalReply` asks for a non-settling fit.
///
/// A rendered document is usually taller than its own source — headings scale by 1.6, tables gain
/// borders and cell padding, code blocks gain spacing — but not always: the markers disappear, and
/// a table row that wrapped to two lines as raw `| a | b |` text can come back as one. So the
/// direction has to be decided rather than assumed.
///
/// **Asserted against the sizer and not against a real frame, and that is a measurement about
/// this test rather than a preference.** `theSettleIsTheOneFitAllowedToMakeThePanelSmaller`
/// already records why: the settle is the one resize `PanelController` animates, so it goes
/// through `panel.animator()` and is not on the frame yet when the next line runs. Written at
/// panel level first — a panel opened on a long reply, the reply then shortened, then the swap —
/// this test **passed** with the swap's `applyFit()` mutated to `applyFit(settling: true)`. The
/// shrink was real and simply invisible to a synchronous read. The controller's half of the claim
/// is pinned by `theSwapAsksForANewFitAtOnceRatherThanAnimatingLikeASettle` below, where the
/// immediate `setFrame` a non-settling fit performs *is* the observable difference.
@Test func theRenderedSwapCannotPullThePanelInUnderTheReader() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    // What the streamed plain text won, and the width the settle has just frozen.
    let previous = CGSize(width: 560, height: 300)

    let shorter = PanelSizer.fit(ideal: CGSize(width: 560, height: 180), frozenWidth: 560,
                                 previous: previous, screen: screen, userSized: false)
    #expect(shorter.size.height == 300)
    #expect(shorter.size.width == 560)

    // Taller is taken, which is the common case and is what the swap is for.
    let taller = PanelSizer.fit(ideal: CGSize(width: 560, height: 420), frozenWidth: 560,
                                previous: previous, screen: screen, userSized: false)
    #expect(taller.size.height == 420)
}

/// …and the swap really does re-measure, at once.
///
/// Two mutations die here, which is why the *growth* direction is the one asserted through a real
/// panel. A `setRendersFinalReply` that rebuilt the installed view and never called `applyFit`
/// leaves the frame where it was. One that asked for `applyFit(settling: true)` instead goes
/// through `panel.animator()`, so the new frame is not there when the next line reads it — the
/// same asynchrony that makes the test above a sizer test. Both were run; both fail this.
@MainActor
@Test func theSwapAsksForANewFitAtOnceRatherThanAnimatingLikeASettle() {
    let box = ControllerBox()
    let model = replyModel(showing: "## Заголовок")
    let controller = PanelController(content: renderingPanelContent(model, box))
    box.controller = controller
    controller.show(at: CGPoint(x: 400, y: 600))
    defer { controller.hide() }

    let short = controller.panel.frame.height
    model.translatedText = "## Заголовок\n\n"
        + String(repeating: "Длинная строка перевода с разметкой. ", count: 40)
    controller.setRendersFinalReply(true)

    #expect(controller.panel.frame.height > short)
}

/// A presentation begins on plain characters, whatever the last one ended on.
///
/// One controller lives for the life of the process and one press's rendered reply must not be
/// the next press's starting state — the same rule `frozenWidth`, `userSized` and `scrolls` are
/// all reset by `show(at:)` for. Without the reset the next press opens measuring a document that
/// is no longer there, and `PanelView` draws one from a half-arrived stream.
@MainActor
@Test func aFreshPresentationStartsOnPlainCharactersAgain() {
    let box = ControllerBox()
    let model = replyModel(showing: "## Заголовок\n\nабзац.")
    let controller = PanelController(content: renderingPanelContent(model, box))
    box.controller = controller
    controller.show(at: CGPoint(x: 400, y: 600))
    controller.setRendersFinalReply(true)
    #expect(controller.rendersFinalReply)
    controller.hide()

    controller.show(at: CGPoint(x: 400, y: 600))
    defer { controller.hide() }
    #expect(controller.rendersFinalReply == false)
    // **And the installed content is rebuilt to match, which the flag alone does not say.**
    // This half is a defect found by writing it: the reset used to lean on `setScrolling(false)`
    // to do the rebuild, and that method returns early when `scrolls` is already false — which it
    // is, on every presentation that never reached the height ceiling. So the flag read false
    // while the installed host went on drawing the previous press's document, and
    // `setRendersFinalReply(false)` at the next run's start returned early from its own guard
    // because the controller already agreed with itself. Nothing would have put it right for the
    // rest of that presentation.
    #expect(box.installedBuilds.last == false)
}

// MARK: - The two keys the panel owns

/// **A selectable text view inside the panel takes first responder, and the panel's two keys are
/// handled on the window.**
///
/// Until Phase 4 the panel's content had no view that takes first responder at all — «the panel
/// is a readout, not a form», at `TranslationPanel.cancelOperation(_:)` — which is why ⏎ and Esc
/// reached the window's handlers. A non-editable `NSTextView` answers ⏎ with `insertNewline(_:)`,
/// which does nothing *and* does not pass the key on, so «скопировать и закрыть» would have gone
/// quiet the moment the reader clicked into their translation. `PanelReplyTextView` forwards the
/// three the panel decides about; deleting the override fails this.
@MainActor
@Test func theRenderedReplyHandsEnterAndEscapeBackToThePanel() {
    let controller = PanelController { _ in AnyView(Text("перевод")) }
    var escapes = 0
    var enters = 0
    controller.onEscape = { escapes += 1 }
    controller.onEnter = { enters += 1 }
    controller.show(at: CGPoint(x: 300, y: 300))
    defer { controller.hide() }

    let reply = PanelReplyTextView(textKit1Inset: RenderedReplyView.inset,
                                   lineFragmentPadding: RenderedReplyView.lineFragmentPadding)
    reply.textStorage?.setAttributedString(NSAttributedString(string: "перевод"))
    controller.panel.contentView?.addSubview(reply)
    // **First responder, and that is the whole test.** Written without this line it passed with
    // the override deleted: a text view that is *not* first responder answers `super.keyDown`
    // by walking the responder chain up to the window, which happens to do the right thing.
    // First responder is the state a reader's click puts it in, and there `NSTextView.keyDown`
    // runs `interpretKeyEvents` instead, which turns ⏎ into `insertNewline(_:)` — a no-op that
    // also does not pass the key on.
    #expect(controller.panel.makeFirstResponder(reply),
            "the text view has to be first responder for this to be the real case")

    reply.keyDown(with: panelKey(36, "\r"))
    #expect(enters == 1)
    reply.keyDown(with: panelKey(76, "\u{3}"))
    #expect(enters == 2)
    reply.keyDown(with: panelKey(53, "\u{1b}"))
    #expect(escapes == 1)
}

/// …and forwards only those, which is the reason for hosting a text view in the first place.
///
/// ⌘C on the selection, ⌘A over the document and the arrow keys through it all have to stay with
/// the text view; a forward that took every key would give the panel a document it cannot select
/// out of. Only the negative half is checkable here — that these keys do not reach the panel's
/// own two handlers — and that is said rather than implied: what ⌘C actually puts on a pasteboard
/// is `GeneralPasteboard`'s business and is tested there.
@MainActor
@Test func everyOtherKeyStaysWithTheTextViewItWasTypedInto() {
    let controller = PanelController { _ in AnyView(Text("перевод")) }
    var escapes = 0
    var enters = 0
    controller.onEscape = { escapes += 1 }
    controller.onEnter = { enters += 1 }
    controller.show(at: CGPoint(x: 300, y: 300))
    defer { controller.hide() }

    let reply = PanelReplyTextView(textKit1Inset: RenderedReplyView.inset,
                                   lineFragmentPadding: RenderedReplyView.lineFragmentPadding)
    reply.textStorage?.setAttributedString(NSAttributedString(string: "перевод"))
    controller.panel.contentView?.addSubview(reply)
    // The same state as the test above, for the same reason: it is the one a reader's click
    // produces, and the one in which `keyDown` is the text view's own to interpret.
    #expect(controller.panel.makeFirstResponder(reply))

    reply.keyDown(with: panelKey(8, "c", modifiers: .command))
    reply.keyDown(with: panelKey(0, "a", modifiers: .command))
    reply.keyDown(with: panelKey(125, "\u{f701}"))
    #expect(enters == 0)
    #expect(escapes == 0)
}

private func panelKey(_ keyCode: UInt16, _ characters: String,
                      modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                     windowNumber: 0, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false,
                     keyCode: keyCode)!
}

// MARK: - What «Скопировать» carries

/// The panel's copy rule: two flavours only while the rendered document is what the reader is
/// looking at.
///
/// The markup-and-setting half is `PaneRendering`'s, delegated rather than restated so the panel
/// and the window's pane cannot copy different things out of one translation. What is the panel's
/// own is the first line: «Скопировать» is enabled from the first token so an interrupted run's
/// output is not stranded, and a copy taken mid-stream must be plain — nothing half-arrived leaves
/// this app wearing a font it chose.
@Test func thePanelCopiesRichlyOnlyWhileItIsShowingTheRenderedDocument() {
    let markup = "## Заголовок\n\n**жирный** абзац."
    let prose = "Обычная проза без всякой разметки."

    // Mid-stream: the reply is characters, so the copy is characters.
    #expect(PanelView.richFlavour(text: markup, rendersFinalReply: false,
                                  showsRenderedMarkup: true, font: .default) == nil)
    // Showing the document: RTF beside the Markdown. Checked by signature rather than by length,
    // because the length is a serialiser's business and would pin the wrong thing.
    let rich = PanelView.richFlavour(text: markup, rendersFinalReply: true,
                                     showsRenderedMarkup: true, font: .default)
    #expect(rich != nil)
    if let rich {
        #expect(String(decoding: rich.prefix(5), as: UTF8.self) == "{\\rtf")
    }
    // «Исходник» — the reader is looking at raw Markdown, so that is all that is copied.
    #expect(PanelView.richFlavour(text: markup, rendersFinalReply: true,
                                  showsRenderedMarkup: false, font: .default) == nil)
    // No markup: a plain-prose translation never arrives in Word wearing a font this app chose.
    #expect(PanelView.richFlavour(text: prose, rendersFinalReply: true,
                                  showsRenderedMarkup: true, font: .default) == nil)
}

