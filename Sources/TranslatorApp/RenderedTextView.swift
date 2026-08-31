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
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = CodeBlockTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        // Selectable, which is the whole reason this is a text view: the selection runs across
        // the entire document, headings, tables and code included.
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
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
        textView.textContainerInset = NSSize(width: 3, height: 8)
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.linkTextAttributes = linkAttributes

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

/// The text view, plus the one affordance the design asks of it: «Скопировать» over a code
/// block.
///
/// The button is an overlay positioned from `layoutManager.boundingRect(forGlyphRange:in:)`
/// and shown on hover, per the design. It is a **subview of the text view** rather than of the
/// scroll view, so it scrolls with the code it belongs to and needs no scroll observation.
/// A context-menu item is wired to the same action beside it, because a hover affordance
/// cannot be verified in this environment and a right-click can: `docs/reference/OPEN-ITEMS.md`
/// §11.2 of the design is the eyes this needs, and until then there is a route that does not
/// depend on the button being where the measurement says.
final class CodeBlockTextView: NSTextView {
    /// Set by `RenderedTextView.Coordinator` whenever the storage changes. Ranges are into the
    /// current storage; `source` is the block's own bytes.
    var codeRegions: [MarkdownToAttributed.CodeRegion] = [] {
        didSet { rebuildButtons() }
    }

    private var buttons: [CodeCopyButton] = []
    private var hoverTracking: NSTrackingArea?

    override func layout() {
        super.layout()
        positionButtons()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        for button in buttons {
            button.isHidden = !(button.blockFrame?.insetBy(dx: -4, dy: -4).contains(point)
                ?? false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        for button in buttons { button.isHidden = true }
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
        buttons = codeRegions.map { region in
            let button = CodeCopyButton(title: "Скопировать", target: self,
                                        action: #selector(copyCodeBlock(_:)))
            button.source = region.source
            button.range = region.range
            button.bezelStyle = .roundRect
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.isHidden = true
            addSubview(button)
            return button
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
            // Top-right of the block, inside it: a button hanging past the right edge would be
            // clipped by the scroll view at narrow pane widths.
            button.setFrameOrigin(NSPoint(x: max(rect.maxX - size.width - 4, rect.minX),
                                          y: rect.minY + 2))
        }
    }
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
