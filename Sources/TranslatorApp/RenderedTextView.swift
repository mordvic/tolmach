// Sources/TranslatorApp/RenderedTextView.swift
import AppKit
import MarkupKit
import SwiftUI
import TextCapture
import TranslationCore

/// The перевод pane's text, in a hosted read-only `NSTextView`.
///
/// **TextKit 1, on purpose.** The view is built from an `NSTextStorage` /`NSLayoutManager` /
/// `NSTextContainer` triple rather than by `NSTextView.scrollableTextView()`, because a text
/// view that comes up in TextKit 2 has **no table support at all**: `NSTextTable` and
/// `NSTextTableBlock` live only in the compatibility layer, and `MarkdownToAttributed` draws
/// every table with them. Touching `layoutManager` on a TextKit 2 view is the other way in —
/// it forces the fallback — and constructing the triple says so instead of relying on a side
/// effect. `layoutManager` is also what answers `boundingRect(forGlyphRange:in:)`, which is
/// how the per-code-block button finds its rect (measured to answer exact rects headless,
/// `Scripts/markup-render.swift`).
///
/// A text view and not a `VStack` of `Text`s: a translator's primary interaction with its
/// output is select-and-copy, SwiftUI's `.textSelection` is per-view and cannot be dragged
/// across, and the rich «Скопировать» flavour and the rendering are then the same code rather
/// than two serialisers. `docs/design/specs/2026-08-31-formatting-design.md` §6 has the four
/// measurements behind the choice.
///
/// `SourceEditor` is the in-repo precedent for hosting one of these, and two of its measured
/// facts carry over: `textContainerInset` is `{0, 0}` unless set, and `NSTextContainer`'s
/// `lineFragmentPadding` defaults to 5 — which is why the horizontal inset here is 3 rather
/// than 8, so the text lands where the pane's `Text` used to.
struct RenderedTextView: NSViewRepresentable {
    let text: String
    /// «Шрифт текста». Every rendered run comes from it — `docs/adr/0008`.
    let font: ContentFont
    /// False for «Исходник»: the same string in the same view, no conversion.
    let rendersMarkup: Bool
    /// While a run is streaming the view draws the settled blocks and keeps the unsettled tail
    /// as plain characters, so a block is never redrawn as something else. See
    /// `Coordinator.apply`.
    let isStreaming: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // `{3, 8}` because this view's text has to land where the pane's `Text` used to, and
        // that one carried `.padding(8)`: 8 vertically, and 3 horizontally because the
        // container's own `lineFragmentPadding` already contributes 5. The panel's reply has no
        // padding of its own and therefore takes a different inset — see `RenderedReplyView`.
        let textView = CodeBlockTextView(textKit1Inset: NSSize(width: 3, height: 8))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // **`isVerticallyResizable` alone does not let it grow.** A text view built with
        // `init(frame:textContainer:)` takes its `minSize` and `maxSize` from that frame, so a
        // document taller than the frame is laid out and then clipped, with nothing for the
        // scroll view to scroll. The pair below is the programmatic equivalent of what
        // `scrollableTextView()` sets up — which this does not use, because that factory hands
        // back a TextKit 2 view and `NSTextTable` does not exist there.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeBlockTextView else { return }
        context.coordinator.apply(text: text, font: font, rendersMarkup: rendersMarkup,
                                  isStreaming: isStreaming, to: textView)
    }

    /// What has already been drawn, so a streamed token costs the tail rather than the
    /// document.
    ///
    /// The state is three numbers and a string: the source prefix whose blocks are settled and
    /// already in the storage, how long their rendering is, and how long the plain tail after
    /// it currently is. An update replaces **only** the tail region, which is what makes the
    /// «a drawn block is never redrawn» property visible rather than merely true — measured
    /// cost of an append to `NSTextStorage` is 0.3 ms worst case with layout, against a full
    /// rebuild that re-lays out the whole document on every token.
    @MainActor
    final class Coordinator {
        private var settledSource = ""
        private var settledLength = 0
        private var tailLength = 0
        /// The font and mode the storage was built under. Either changing means everything
        /// already drawn is wrong, so the state resets.
        private var mode: Mode?

        private struct Mode: Equatable {
            let font: ContentFont
            let rendersMarkup: Bool
            let isStreaming: Bool
        }

        func apply(text: String, font: ContentFont, rendersMarkup: Bool, isStreaming: Bool,
                   to textView: CodeBlockTextView) {
            let config = font.markdownConfig
            let wanted = Mode(font: font, rendersMarkup: rendersMarkup,
                              isStreaming: isStreaming)
            if mode != wanted {
                mode = wanted
                reset(textView)
            }

            // «Исходник», and the finished document: one whole render. The finished document
            // goes this way because the last block of a document that does not end in a blank
            // line is never *settled* — nothing may follow it — so the incremental path alone
            // would leave the tail of every completed translation unrendered.
            guard rendersMarkup, isStreaming else {
                let rendering = rendersMarkup
                    ? MarkdownToAttributed.rendering(of: text, config: config)
                    : MarkdownToAttributed.Rendering(
                        attributed: MarkdownToAttributed.plain(text, config: config),
                        codeRegions: [])
                textView.textStorage?.setAttributedString(rendering.attributed)
                textView.codeRegions = rendering.codeRegions
                settledSource = ""
                settledLength = rendering.attributed.length
                tailLength = 0
                return
            }

            // A stream only ever grows. Anything else — a new run, «Ещё вариант», the final
            // assignment differing from what was streamed — starts again rather than
            // guessing which half is stale.
            if !text.hasPrefix(settledSource) { reset(textView) }

            let arriving = String(text.dropFirst(settledSource.count))
            let (blocks, tail) = MarkdownBlockScanner.settledPrefix(of: arriving)
            let newlySettled = MarkdownToAttributed.rendering(blocks: blocks, in: arriving,
                                                              config: config)
            let plainTail = MarkdownToAttributed.plain(String(arriving[tail]), config: config)

            let replacement = NSMutableAttributedString(
                attributedString: newlySettled.attributed)
            replacement.append(plainTail)
            let region = NSRange(location: settledLength, length: tailLength)
            textView.textStorage?.replaceCharacters(in: region, with: replacement)

            textView.codeRegions += newlySettled.codeRegions.map {
                $0.offset(by: settledLength)
            }
            settledSource += String(arriving[..<tail.lowerBound])
            settledLength += newlySettled.attributed.length
            tailLength = plainTail.length
        }

        /// Forget what was drawn **and take it off the screen**.
        ///
        /// Emptying the storage is not tidiness: the incremental path replaces the range
        /// `settledLength..<settledLength+tailLength`, and after a reset that range is
        /// `0..<0` — an *insertion* at the front. Leaving the old document in place therefore
        /// put the new run's first tokens in front of the previous translation instead of
        /// replacing it, which is reachable from «Ещё вариант» (a run starting while the
        /// previous result is still on screen) and from the queue's pane changing selection.
        private func reset(_ textView: CodeBlockTextView) {
            settledSource = ""
            settledLength = 0
            tailLength = 0
            textView.textStorage?.setAttributedString(NSAttributedString())
            textView.codeRegions = []
        }
    }
}

/// The text view, plus the code card's header: the language the fence named and an
/// always-visible «Скопировать», drawn over each code block.
///
/// Both are overlays positioned from `layoutManager.boundingRect(forGlyphRange:in:)`, in the
/// room `MarkdownToAttributed.codeCardHeaderHeight` leaves above the code inside the card's
/// border. They are **subviews of the text view** rather than of the scroll view, so they
/// scroll with the code they belong to and need no scroll observation — and they are views,
/// not characters, so the RTF flavour and a drag-selection copy carry the code alone.
///
/// Always visible, since 2026-09-02 (spec #72, step 5): the first version showed the button on
/// hover, per the design, and the grilling that followed decided against it — a button that
/// appears only under the pointer is a button nobody finds. The context-menu item stays beside
/// it as the route a test can reach and a keyboard user can too.
/// Not `final`: the panel's reply is a subclass with one behaviour of its own — see
/// `PanelReplyTextView`, which forwards ⏎ and Esc to the panel that owns them.
class CodeBlockTextView: NSTextView {
    /// Set by `RenderedTextView.Coordinator` whenever the storage changes. Ranges are into the
    /// current storage; `source` is the block's own bytes.
    var codeRegions: [MarkdownToAttributed.CodeRegion] = [] {
        didSet { rebuildButtons() }
    }

    /// The TextKit 1 triple, built by hand, plus the settings both surfaces share.
    ///
    /// **This construction is the trap, which is why there is one of it.** A text view that
    /// comes up in TextKit 2 has no `NSTextTable` — it exists only in the compatibility layer —
    /// and every table `MarkdownToAttributed` draws is one; building the
    /// `NSTextStorage`/`NSLayoutManager`/`NSTextContainer` triple is what opts in, and says so,
    /// where merely touching `layoutManager` would opt in by side effect. `layoutManager` is
    /// also what answers `boundingRect(forGlyphRange:in:)`, which the per-code-block button is
    /// positioned from. `docs/reference/PLATFORM-TRAPS.md` carries both.
    ///
    /// What the two callers do *not* share is the geometry: the pane wraps this in an
    /// `NSScrollView` and insets it to match a `Text` that had `.padding(8)`, the panel hosts it
    /// bare and inset to nothing. Those differences stay at the call sites.
    ///
    /// - Parameter lineFragmentPadding: nil keeps the container's own default, measured at 5.0
    ///   (`Scripts/panel-rendered-measure.swift` §3). The panel passes 0, because 5 pt of
    ///   indent it cannot see in its plain streamed text would shift every line sideways at the
    ///   swap.
    convenience init(textKit1Inset inset: NSSize, lineFragmentPadding: CGFloat? = nil) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        if let lineFragmentPadding { container.lineFragmentPadding = lineFragmentPadding }
        layout.addTextContainer(container)

        self.init(frame: .zero, textContainer: container)
        isEditable = false
        // Selectable, which is the whole reason this is a text view: the selection runs across
        // the entire document, headings, tables and code included.
        isSelectable = true
        isRichText = true
        drawsBackground = false
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        textContainerInset = inset
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    private var buttons: [CodeCopyButton] = []
    private var labels: [CodeLanguageLabel] = []

    /// Nothing. A read-only view has no use for a drop, and since this view hosts the исходник
    /// pane's rendered mode too (2026-09-02), a file dropped on it must reach the pane's own
    /// drop destination rather than a text view that would refuse it — the same reason
    /// `SourceTextView` limits its own registration to strings.
    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    override func layout() {
        super.layout()
        positionButtons()
    }

    /// «Скопировать код» in the context menu, for the same block the pointer is over.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        guard let button = buttons.first(where: { $0.blockFrame?.contains(point) ?? false })
        else { return menu }
        let item = NSMenuItem(title: "Скопировать код",
                              action: #selector(copyCodeBlock(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = button.source
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc func copyCodeBlock(_ sender: Any?) {
        let source: String?
        switch sender {
        case let button as CodeCopyButton: source = button.source
        case let item as NSMenuItem: source = item.representedObject as? String
        default: source = nil
        }
        guard let source, !source.isEmpty else { return }
        // Through `GeneralPasteboard`, like every other write this app makes: that type's lock
        // is the only thing standing between two threads reading one pasteboard name and an
        // uncaught `NSException` (measured, 10 aborts in 10 runs).
        Task { await GeneralPasteboard.write(source) }
    }

    private func rebuildButtons() {
        for button in buttons { button.removeFromSuperview() }
        for label in labels { label.removeFromSuperview() }
        buttons = codeRegions.map { region in
            let button = CodeCopyButton(title: "Скопировать", target: self,
                                        action: #selector(copyCodeBlock(_:)))
            button.source = region.source
            button.range = region.range
            button.bezelStyle = .roundRect
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            addSubview(button)
            return button
        }
        // One label per block that named a language; an unnamed fence gets a header with the
        // button alone rather than a label saying nothing.
        labels = codeRegions.compactMap { region in
            guard !region.language.isEmpty else { return nil }
            let label = CodeLanguageLabel(labelWithString: region.language)
            label.range = region.range
            label.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                     weight: .regular)
            label.textColor = .secondaryLabelColor
            addSubview(label)
            return label
        }
        positionButtons()
    }

    /// Placement from the layout manager's own rect for the block's glyphs. Nothing here
    /// guesses at line heights: the design's measurement is that
    /// `boundingRect(forGlyphRange:in:)` answers exact rects even headless, so the button is
    /// pinned to the code rather than to a font metric.
    private func positionButtons() {
        guard let layoutManager, let textContainer else { return }
        for button in buttons {
            guard let range = button.range else { button.blockFrame = nil; continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            // **Widened to the container, and that is the placement decision.** The glyph rect
            // is only as wide as the code — measured, `"let x = 1"` at 13 pt comes back 84 pt
            // wide — while what the reader sees as «the code block» is the tinted paragraph
            // running the width of the pane. A button pinned to the glyph rect's right edge
            // therefore lands in the middle of the pane, over nothing, and the hover band
            // would miss every point past the end of the shortest line.
            rect.size.width = max(rect.width, textContainer.size.width - rect.minX)
            button.blockFrame = rect
            button.sizeToFit()
            let size = button.frame.size
            // In the card's header — the room the text block leaves above the first line of
            // code — at the right edge but inside it, because a button hanging past the edge
            // would be clipped by the scroll view at narrow pane widths. The header is
            // `codeCardHeaderHeight` tall; the button sits vertically centred in it.
            let header = MarkdownToAttributed.codeCardHeaderHeight
            button.setFrameOrigin(NSPoint(x: max(rect.maxX - size.width - 6, rect.minX),
                                          y: rect.minY - header + (header - size.height) / 2))
        }
        for label in labels {
            guard let range = label.range,
                  let button = buttons.first(where: { $0.range == range }),
                  let rect = button.blockFrame else { continue }
            label.sizeToFit()
            let header = MarkdownToAttributed.codeCardHeaderHeight
            // Same header, left edge, a little in from the border.
            label.setFrameOrigin(NSPoint(x: rect.minX + 2,
                                         y: rect.minY - header + (header - label.frame.height) / 2))
        }
    }
}

/// The language a fence named, over the block that named it. Remembers its block the way the
/// button does, so the two are positioned from one rect.
final class CodeLanguageLabel: NSTextField {
    var range: NSRange?
}

/// An `NSButton` that remembers which code block it belongs to.
///
/// The source string rather than a `Range<String.Index>`: the index range belongs to the
/// document the rendering was built from, and by the time the button is pressed the pane may
/// be showing the next token of it. The bytes were taken from the block's own range at render
/// time, which is where the «verbatim» promise is kept.
final class CodeCopyButton: NSButton {
    var source: String = ""
    var range: NSRange?
    /// The rect of the code the button copies, in the text view's coordinates — what the hover
    /// test and the context menu both ask about.
    var blockFrame: NSRect?
}
