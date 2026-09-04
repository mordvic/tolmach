// Sources/TranslatorApp/RenderedReplyView.swift
import AppKit
import MarkupKit
import SwiftUI
import TranslationCore

/// The floating panel's reply, rendered as a document — **the finished one only**.
///
/// The panel does not render while a run streams, and that is a decision with a reason rather
/// than an unfinished half of `RenderedTextView`: the panel exists to answer in under a second
/// at 300–560 pt, where a reflowing layout is worse to watch than raw `**`, and where the
/// reservation `Text` and `PanelSizer`'s monotonic height are tuned against plain characters
/// (`docs/design/specs/2026-08-31-formatting-design.md` §7). So during the stream the panel is
/// byte-for-byte what it was before this file existed, and this view appears once, at the
/// settle. `PanelView.rendersFinalReply(...)` is that condition, in one place.
///
/// **A bare `NSTextView`, with no `NSScrollView` around it — that is the load-bearing
/// difference from `RenderedTextView`.** The pane owns its own scrolling; the panel's
/// `scrollingMiddle` owns the panel's, decided by `PanelSizer` from a measurement, and a scroll
/// view here would answer the whole height proposal back (measured on the real `PanelView`:
/// `PanelContentVariant.scrolls`) and put every rendered panel at 0.6 × the screen.
///
/// **And it implements `sizeThatFits`, which is the trap §11.4 sent a probe after.** The panel's
/// size comes from a *detached* `NSHostingController` (`PanelController.measure`), and an
/// `NSViewRepresentable` with no `sizeThatFits` answers that host with nothing usable. Measured,
/// `Scripts/panel-rendered-measure.swift`: `fittingSize` **0 × 0** and `sizeThatFits(in:)`
/// **`greatestFiniteMagnitude`** at 300, 430 and 560 pt alike — both failures at once, and the
/// second is the quiet one, because `PanelSizer.measured` tests `isFinite && > 0` and
/// `greatestFiniteMagnitude` passes both. Every rendered panel would have opened at the height
/// ceiling, scrolling, for a one-line reply as much as for a page.
struct RenderedReplyView: NSViewRepresentable {
    let text: String
    /// «Шрифт текста». Every rendered run is a multiple of it — `docs/adr/0008`, and
    /// `ContentFont.markdownConfig` is the one bridge that carries it into `MarkupKit`.
    let font: ContentFont
    /// Whether what is shown is drawn from its Markdown (`rendering(of:)`) or as plain
    /// characters (`plainRendering(of:)` — byte-identical to `plain`, plus the block ranges the
    /// marks are located in).
    ///
    /// Decided by the caller, `PanelView.rendersMarkup(text:showsRenderedMarkup:)`, and not
    /// here: it is asked of whichever text «Вид» is showing, and «оригинал» is a different
    /// document from the reply — a plain-prose mail corrected into a table, or the reverse,
    /// would otherwise be drawn by the answer the other text deserved.
    ///
    /// Defaults to true so every call site that predates «Вид» renders exactly what it did.
    var rendersMarkup = true
    /// What the правка changed, marked over the rendering — or nil for a перевод, whose reply
    /// is never diffed against anything.
    var changes: ChangeSet?
    /// «изменения» rather than «результат»: the removed words spliced in, struck through,
    /// before what replaced them. Meaningless without `changes`.
    var showsChangeDetail = false
    /// The text the user selected, when «Вид» is on «оригинал» — drawn **instead of** `text`
    /// and never marked, whatever `changes` says.
    ///
    /// Unmarked by construction rather than by the caller remembering: `TextChange.block` and
    /// `insertedTokens` index the *result*'s blocks and tokens, so applying them to the source
    /// would underline whatever words happened to sit at those offsets. The reader wanting to
    /// see the original is asking what it said before, not where it will be corrected.
    var original: String?

    /// Nothing, and that is not the pane's answer.
    ///
    /// `RenderedTextView` insets by `{3, 8}` because the pane's plain `Text` carried
    /// `.padding(8)` and the text view has to reproduce it. The panel's reply `Text` carries
    /// none — it sits inside the panel's own 14 pt — so the rendered document has to begin on
    /// the same pixel the streamed characters were on, or the swap at the settle shifts every
    /// line sideways under a reader who is already reading. The container's default
    /// `lineFragmentPadding` (measured 5.0) is exactly that shift, which is why it is set to 0
    /// here rather than compensated for.
    static let inset = NSSize(width: 0, height: 0)
    static let lineFragmentPadding: CGFloat = 0

    /// The text on screen: the reply, or the original when «Вид» is on «оригинал».
    private var shown: String { original ?? text }
    /// The marks to apply to it — none over the original, for the reason `original` gives.
    private var marks: ChangeSet? { original == nil ? changes : nil }
    private var detail: ChangeMarks.Detail { showsChangeDetail ? .changes : .result }

    /// The rendering both `updateNSView` and `sizeThatFits` draw their answer from, so the
    /// panel is never sized for one document and shown another.
    private func rendering(_ coordinator: Coordinator) -> MarkdownToAttributed.Rendering {
        coordinator.rendering(of: shown, config: font.markdownConfig,
                              rendersMarkup: rendersMarkup, changes: marks, detail: detail)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PanelReplyTextView {
        let textView = PanelReplyTextView(textKit1Inset: Self.inset,
                                          lineFragmentPadding: Self.lineFragmentPadding)
        // Neither resizable dimension, and no `autoresizingMask`: this view's height is
        // whatever `sizeThatFits` said, and SwiftUI sets the frame. The pane's copy needs the
        // vertical pair because a scroll view sizes its document view from the layout; here the
        // frame *is* the answer, and a text view that also grew itself would fight it.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        return textView
    }

    func updateNSView(_ textView: PanelReplyTextView, context: Context) {
        let rendering = rendering(context.coordinator)
        // Assigned unconditionally rather than diffed: this view is installed at the settle and
        // updated only when «Вид» moves, which is a whole new document either way — «изменения»
        // holds characters «результат» does not, and «оригинал» is another text entirely. The
        // `Rendering` behind it is memoised for the *measuring* host's sake, which asks for the
        // same content several times per fit.
        textView.textStorage?.setAttributedString(rendering.attributed)
        textView.codeRegions = rendering.codeRegions
    }

    /// What the detached measuring host is answered with, and therefore what the panel's height
    /// is.
    ///
    /// Measured through a *throwaway* triple (`measuredSize`) and never through `nsView`'s own
    /// layout manager: the measuring host and the installed one are two different views of the
    /// same content, and a measurement that re-laid out the installed one would move the text a
    /// reader is looking at in order to ask a question about it.
    ///
    /// An unspecified, infinite or zero proposal all mean «what is your natural size», and
    /// answering the document's own unwrapped width there is load-bearing: `fittingSize` is
    /// where the panel's *ideal width* comes from, so a constant would make every rendered
    /// reply ask for `PanelSizer.minWidth` and a wide document could only ever reach 560 pt if
    /// the plain streamed text had already taken it there. Measured on the §11.4 document:
    /// 1155 pt natural, which `PanelSizer` clamps to `maxWidth` — the same shape a `Text` gives
    /// (274 for a word, 6929 for a paragraph).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelReplyTextView,
                      context: Context) -> CGSize? {
        // The *marked* rendering, deliberately: the underlines cost no height but the deletions
        // «изменения» splices in are characters, and a panel measured against «результат» while
        // showing «изменения» would put the tail of every changed paragraph past its own frame.
        let rendering = rendering(context.coordinator)
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return Self.measuredSize(of: rendering.attributed, width: nil)
        }
        return Self.measuredSize(of: rendering.attributed, width: width)
    }

    /// The size the reply needs at a given width, or its natural size for `width == nil`.
    ///
    /// Internal rather than private so a test can pin the three widths §11.4 named against the
    /// probe's numbers. It builds its own text-layout stack every call, which is what makes it
    /// answerable without a view and side-effect free — and what makes it *agree* with the view:
    /// measured, the throwaway answers 419 / 355 / 339 pt at 300 / 430 / 560 for the §11.4
    /// document and a live `NSTextView` lays the same document out at 419 / 355 / 339.
    static func measuredSize(of attributed: NSAttributedString, width: CGFloat?) -> CGSize {
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // `width` is the width of *this view*, so the container gets it less the insets on both
        // sides — which are zero here, spelled out rather than dropped so that changing
        // `inset` cannot silently stop the measurement matching the layout.
        let containerWidth = width.map { max($0 - inset.width * 2, 1) }
            ?? CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(
            size: CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = lineFragmentPadding
        layout.addTextContainer(container)
        // Without this, `usedRect` answers whatever has been laid out so far — which for a
        // freshly built stack is nothing.
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: (width ?? (ceil(used.width) + inset.width * 2)),
                      height: ceil(used.height) + inset.height * 2)
    }

    /// One rendering per (text, font, «Вид») tuple, held for the several `sizeThatFits` calls a
    /// single fit makes.
    ///
    /// `PanelController.measure` asks twice per fit — `fittingSize`, then `sizeThatFits(in:)` at
    /// the chosen width — and SwiftUI probes a layout more often than that. Converting the
    /// document each time would put a full Markdown parse plus an `NSAttributedString` build on
    /// each of them; the panel's own text is short, but «Открыть в окне» and «Ещё вариант» make
    /// no promise about that, and the memo costs one comparison.
    ///
    /// **The key is the whole tuple, and each part of it earns its place.** The marks are a
    /// second pass over the storage and «Изменения» is a *different document* from «Результат»
    /// — it has the removed words in it — so a key of (text, font) alone would answer the
    /// question the panel is asking now with the answer it gave before «Вид» moved, and the
    /// panel would be measured for one view while drawing the other.
    @MainActor
    final class Coordinator {
        private struct Key: Equatable {
            let text: String
            let config: MarkdownFontConfig
            let rendersMarkup: Bool
            let changes: ChangeSet?
            let detail: ChangeMarks.Detail
        }

        private var key: Key?
        private var cached: MarkdownToAttributed.Rendering?

        func rendering(of text: String, config: MarkdownFontConfig, rendersMarkup: Bool,
                       changes: ChangeSet?,
                       detail: ChangeMarks.Detail) -> MarkdownToAttributed.Rendering {
            let wanted = Key(text: text, config: config, rendersMarkup: rendersMarkup,
                             changes: changes, detail: detail)
            if key == wanted, let cached { return cached }
            // The same two lines the pane's coordinator runs, and deliberately the same order:
            // `plainRendering` and not `plain`, because prose still needs the block ranges the
            // marks are located in, and `ChangeMarks.apply` over whichever of the two came out,
            // so one change set marks a document and a plain reply alike.
            var made = rendersMarkup
                ? MarkdownToAttributed.rendering(of: text, config: config)
                : MarkdownToAttributed.plainRendering(of: text, config: config)
            if let changes {
                made = ChangeMarks.apply(changes, to: made, resultMarkdown: text,
                                         detail: detail, config: config)
            }
            key = wanted
            cached = made
            return made
        }
    }
}

/// The panel's reply text view: everything `CodeBlockTextView` does, plus giving ⏎ and Esc back
/// to the panel.
///
/// **The panel's two keys are handled on the window, and a first responder inside it intercepts
/// them.** `TranslationPanel.keyDown` is what makes ⏎ «скопировать и закрыть» and
/// `cancelOperation(_:)` is what makes Esc «закрыть и отменить» — both reached because, until
/// this view existed, the panel's content had no view that takes first responder at all («the
/// panel is a readout, not a form», at that override). A selectable `NSTextView` does take it, on
/// the reader's first click, and from then on the keys are its own to interpret.
///
/// **The two keys need two different routes, which is measured rather than symmetrical.** ⏎ never
/// gets as far as a command: `NSTextView.keyDown` runs `interpretKeyEvents`, which turns it into
/// `insertNewline(_:)` — a no-op on a non-editable view that also does not pass the key on — so it
/// is forwarded from `keyDown` before that happens. Esc *does* become a command,
/// `cancelOperation(_:)`, and AppKit sends that to the **first responder**, i.e. to this view and
/// not to the panel; forwarding it from `keyDown` instead was tried and does not work, because the
/// panel's own `keyDown` then hands it to `super` and AppKit dispatches the resulting command back
/// down to this view again. So Esc is handed on from the command, where AppKit puts it.
///
/// Everything else is deliberately *not* forwarded, and that is the win of hosting a text view
/// here: ⌘C copies the selection, ⌘A selects the document, the arrow keys move through it. ⌘⇧↩
/// and ⌘. are SwiftUI `keyboardShortcut`s, which are dispatched through `performKeyEquivalent`
/// before any `keyDown` and so never reach this method — except when their button is disabled,
/// where SwiftUI declines the equivalent and the event arrives here; ⌘⇧↩ is forwarded for that
/// case, and the panel swallows it exactly as it does today.
final class PanelReplyTextView: CodeBlockTextView {
    override func keyDown(with event: NSEvent) {
        // Return (36) and the numeric pad's Enter (76), bare or ⌘⇧ — spelled the way
        // `TranslationPanel.keyDown` spells them, because a forward that disagreed with the
        // handler about which events matter would be a second, wrong copy of the rule. Esc is
        // **not** here; see `cancelOperation(_:)` below and the note above.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, modifiers.isEmpty || modifiers == [.command, .shift],
              let window else {
            super.keyDown(with: event)
            return
        }
        window.keyDown(with: event)
    }

    /// Esc, handed to the panel that owns it.
    ///
    /// `TranslationPanel.cancelOperation(_:)` is «закрыть и отменить», and it used to be reached
    /// because the window itself was the first responder. It no longer is whenever the reader has
    /// clicked into their translation, and AppKit sends this command to the first responder — so
    /// without this line Esc stops closing the panel the moment the text is touched, which is the
    /// one dismissal a user reaches for without thinking.
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }
}
