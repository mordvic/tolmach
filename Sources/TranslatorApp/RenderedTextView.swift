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
    /// A finished правка's change set, or nil. Marks are drawn only over a whole render — the
    /// pane passes nil while a run streams, and `apply` asserts it — because the diff is taken
    /// at the settle and a mark located in a document still arriving would move under the
    /// reader (spec §7.9).
    var changes: ChangeSet? = nil
    /// «Изменения» (deletions spliced in, struck through) against «Результат» (underlines
    /// only). Meaningless without `changes`.
    var showsChangeDetail = false
    /// The change the stepper is standing on, selected and flashed in the view. Not part of the
    /// storage's mode: moving it must not rebuild the document.
    var changeCursor: Int? = nil
    /// A click on a change's mark — moves the model's cursor there. The same shape `onCopy`
    /// already is on this view's siblings; never a reference to the model itself.
    var onChangeSelected: (Int) -> Void = { _ in }
    /// Whether «Вернуть» would do anything for a change, asked of the model before the
    /// popover's button is drawn.
    var canRevertChange: (Int) -> Bool = { _ in false }
    /// «Вернуть» was pressed for a change.
    var onRevertChange: (Int, UndoManager?) -> Void = { _, _ in }

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
        textView.contentFont = font
        textView.onChangeSelected = onChangeSelected
        textView.canRevertChange = canRevertChange
        textView.onRevertChange = onRevertChange
        context.coordinator.apply(text: text, font: font, rendersMarkup: rendersMarkup,
                                  isStreaming: isStreaming, changes: changes,
                                  showsChangeDetail: showsChangeDetail, to: textView)
        context.coordinator.select(change: changeCursor, in: textView)
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
            /// Both halves of the marks are in the mode, so a new change set or a flip of
            /// «Результат | Изменения» rebuilds the storage: the «Изменения» document has
            /// characters the «Результат» one does not, and an incremental edit between the
            /// two would be a second diff nobody asked for.
            let changes: ChangeSet?
            let showsChangeDetail: Bool
        }
        /// The change last selected through `select(change:in:)`, so a `body` re-evaluation
        /// that passes the same cursor does not re-select and re-flash it on every token.
        private var selectedChange: Int?

        func apply(text: String, font: ContentFont, rendersMarkup: Bool, isStreaming: Bool,
                   changes: ChangeSet? = nil, showsChangeDetail: Bool = false,
                   to textView: CodeBlockTextView) {
            // The pane's promise, checked where it would be broken: a change set is a fact about
            // a *finished* text, and `TranslationPane` passes one only when `state == .finished`.
            assert(changes == nil || !isStreaming,
                   "change marks over a streaming text would be located in a moving document")
            let config = font.markdownConfig
            let wanted = Mode(font: font, rendersMarkup: rendersMarkup,
                              isStreaming: isStreaming, changes: changes,
                              showsChangeDetail: showsChangeDetail)
            if mode != wanted {
                mode = wanted
                reset(textView)
            }

            // «Исходник», and the finished document: one whole render. The finished document
            // goes this way because the last block of a document that does not end in a blank
            // line is never *settled* — nothing may follow it — so the incremental path alone
            // would leave the tail of every completed translation unrendered.
            guard rendersMarkup, isStreaming else {
                // `plainRendering` and not `plain`: the raw view needs block ranges for the marks
                // to be located in, and it is byte-identical to `plain` otherwise.
                var rendering = rendersMarkup
                    ? MarkdownToAttributed.rendering(of: text, config: config)
                    : MarkdownToAttributed.plainRendering(of: text, config: config)
                if let changes, !isStreaming {
                    rendering = ChangeMarks.apply(changes, to: rendering, resultMarkdown: text,
                                                  detail: showsChangeDetail ? .changes : .result,
                                                  config: config)
                }
                textView.textStorage?.setAttributedString(rendering.attributed)
                textView.codeRegions = rendering.codeRegions
                // Not `isStreaming`'s condition again: `changes` is already nil while
                // streaming (the pane's own gate, `apply`'s assert), so this is `changes`
                // verbatim — the popover's own card is read straight from it.
                textView.changeSet = changes
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
            // The streaming path this reset serves never carries marks (`apply`'s assert), and
            // a rebuilt storage's popover, if one was open, points at a document that is gone.
            textView.changeSet = nil
            // A rebuilt storage has no selection worth keeping, and the next `select` must
            // land on the change again rather than believing it already did.
            selectedChange = nil
        }

        /// Put the selection on change `index` and point at it, once per change of cursor.
        ///
        /// The selection moves so VoiceOver reads the change in its sentence, and
        /// `showFindIndicator(for:)` is AppKit's own way of pointing at a range — the bubble
        /// «Найти» draws — so nothing here invents a highlight of its own. Whether that bubble
        /// reads well over an underline is `docs/reference/OPEN-ITEMS.md`'s to answer.
        /// `nil` clears nothing: the reader's own selection is theirs, and the cursor going
        /// away (a new run) comes with a `reset` anyway.
        func select(change index: Int?, in textView: CodeBlockTextView) {
            guard index != selectedChange else { return }
            selectedChange = index
            guard let index, let range = Self.range(ofChange: index, in: textView) else { return }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }

        /// Where change `index` was drawn — the storage is the record, read back through
        /// `ChangeMarks.changeKey`, so this cannot disagree with what is on screen. Nil for a
        /// change the locator left unmarked (spec §«Step 2», «nothing is guessed»).
        static func range(ofChange index: Int, in textView: NSTextView) -> NSRange? {
            guard let storage = textView.textStorage, storage.length > 0 else { return nil }
            var found: NSRange?
            storage.enumerateAttribute(ChangeMarks.changeKey,
                                       in: NSRange(location: 0, length: storage.length),
                                       options: []) { value, range, stop in
                guard let value = value as? Int, value == index else { return }
                found = range
                stop.pointee = true
            }
            return found
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

    /// The finished правка's own change set, set by `RenderedTextView.Coordinator` alongside
    /// `codeRegions` — the popover reads a change's «было»/«стало» straight from here, keyed by
    /// the same index `ChangeMarks.changeKey` marks the storage with, so it cannot disagree
    /// with what is underlined. Nil (перевод, a run in flight, «Изменений нет») closes whatever
    /// popover was open: a rebuilt storage's marks describe a document this view no longer
    /// shows.
    var changeSet: ChangeSet? {
        didSet { closeChangePopover() }
    }
    /// «Шрифт текста» — the popover's text keeps this font's *family* at the system caption
    /// size, never its own size (`docs/adr/0008`; `ChangeCardView`'s doc comment carries why).
    var contentFont: ContentFont = .default
    /// A click landed on change `index`'s mark — the window's stepper and the popover agree on
    /// the same cursor because both read it. Never a reference to the model: this view and
    /// `MarkupKit` know nothing about `TranslationViewModel`, only this closure, the same shape
    /// `onCopy` already is elsewhere in this app.
    var onChangeSelected: ((Int) -> Void)?
    /// Whether «Вернуть» would do anything for change `index`, asked before the button is even
    /// drawn — never guessed from inside this view, which has no way to run
    /// `ChangeMarks.revertEdit` against the *plain* result (its own storage may be a rendering).
    var canRevertChange: ((Int) -> Bool)?
    /// «Вернуть» was pressed for change `index`, alongside this view's own `undoManager` — the
    /// text view is where AppKit gives a non-editable, selectable view its lazily-created undo
    /// manager (`NSResponder.undoManager`, overridden by `NSTextView`), and handing it over here
    /// is simpler than threading it through several SwiftUI layers to a caller that has no
    /// other reason to know a text view exists. Fire-and-forget: a successful revert changes
    /// the model's `changes`, which flows back down as a new `changeSet`/storage and closes
    /// this popover through the `didSet` above — there is nothing here for this view to undo
    /// on its own account.
    var onRevertChange: ((Int, UndoManager?) -> Void)?

    private var changePopover: NSPopover?
    private var scrollBoundsObserver: NSObjectProtocol?

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

    /// One code block's header: its button, its label if the fence named a language, and the
    /// rect both are placed from. One value rather than two arrays looked up by range.
    private struct CodeCard {
        let range: NSRange
        let button: CodeCopyButton
        let label: CodeLanguageLabel?
        var frame: NSRect?
    }
    private var cards: [CodeCard] = []

    /// Nothing. A read-only view has no use for a drop, and since this view hosts the исходник
    /// pane's rendered mode too (2026-09-02), a file dropped on it must reach the pane's own
    /// drop destination rather than a text view that would refuse it — the same reason
    /// `SourceTextView` limits its own registration to strings.
    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    // MARK: - «Было → стало» on click

    /// The change whose marked range contains `point`, read straight from the storage's own
    /// `ChangeMarks.changeKey` attribute — so this can never disagree with what is underlined.
    /// Exposed rather than kept behind `mouseDown(with:)`: a real drag-selection gesture is not
    /// something this environment can simulate (`docs/reference/TESTING.md`), so a test drives
    /// this — and `reportClick(at:)` below — directly instead of a synthetic `NSEvent` pair.
    ///
    /// **Not `NSTextView.characterIndex(for:)` — measured unreliable off a real, on-screen
    /// window.** A test built exactly this view (no window, then a real one, both) and it
    /// answered `storage.length` — one past the last character, so `< storage.length` always
    /// failed — for every point tried, on either window. `NSLayoutManager.characterIndex(for:
    /// in:fractionOfDistanceBetweenInsertionPoints:)` answers correctly in both: it is the
    /// lower-level call the convenience method is presumably built on, so this calls it
    /// directly rather than depend on whatever the convenience method needs that a test
    /// process does not reliably have. `docs/reference/PLATFORM-TRAPS.md` carries the finding.
    func changeIndex(at point: NSPoint) -> Int? {
        guard let storage = textStorage, storage.length > 0,
              let layoutManager, let textContainer else { return nil }
        // The subtraction `characterIndex(for:)` itself is documented to perform before
        // calling into the layout manager — `point` arrives in this view's own coordinates,
        // and the container's are offset from them by exactly this inset.
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x,
                                     y: point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return nil }
        return storage.attribute(ChangeMarks.changeKey, at: index, effectiveRange: nil) as? Int
    }

    /// A click (not a drag) landed at `point`: move the model's cursor to the change there and
    /// open the popover over it. Nothing happens off a point with no mark, or with no change
    /// set to read a card from.
    func reportClick(at point: NSPoint) {
        guard let index = changeIndex(at: point), let changeSet, index < changeSet.changes.count
        else { return }
        onChangeSelected?(index)
        presentChangePopover(for: index, change: changeSet.changes[index])
    }

    /// **Only a plain click opens the popover — a drag must still select text.** AppKit's own
    /// `mouseDown(with:)` runs a blocking tracking loop for a text view's drag-selection, so it
    /// has already returned by the time this reads `selectedRange()`: a plain click leaves a
    /// zero-length caret where the mouse went down, and a drag leaves a real selection. Reading
    /// the *post-drag* selection is therefore the only reliable discriminator — a flag set from
    /// `mouseDragged(with:)` would work too, but this needs nothing this view does not already
    /// have, and it is what a test can drive without a synthetic drag.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        reportClick(at: point)
    }

    /// The popover's own gate: a change `canRevertChange` refuses (or that has none set) draws
    /// «Вернуть» disabled with a reason, never a button that fails silently when pressed.
    private func presentChangePopover(for index: Int, change: TextChange) {
        // `NSPopover.show(relativeTo:of:preferredEdge:)` throws `NSInvalidArgumentException`
        // for a positioning view with no window (measured: a scratch view built for a test,
        // with no window at all) — so a click reported against this view before it has one
        // opens nothing rather than crash, which a real click can never do in the running app
        // (nothing is clickable before it is on screen) but a test driving `reportClick(at:)`
        // directly can (`ChangeClickTests`).
        guard window != nil else { return }
        guard let range = RenderedTextView.Coordinator.range(ofChange: index, in: self),
              let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y

        let canRevert = canRevertChange?(index) ?? false
        let content = ChangeCardView(
            card: .of(change), typeface: contentFont.typeface,
            revertUnavailableReason: canRevert
                ? nil : "Это изменение нельзя восстановить автоматически",
            onRevert: { [weak self] in
                guard let self else { return }
                self.onRevertChange?(index, self.undoManager)
            })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: content)
        changePopover = popover
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        observeScrolling()
    }

    /// **Measured, `Scripts/popover-anchor.swift`: a `.transient` popover neither repositions
    /// nor auto-closes when its anchor scrolls — not even for a real, posted `scrollWheel`
    /// event.** So this view closes it itself the moment the scroll view under it moves, rather
    /// than trust the behaviour to do a job it was measured not to do.
    /// `docs/reference/PLATFORM-TRAPS.md` carries the finding.
    private func observeScrolling() {
        if let scrollBoundsObserver { NotificationCenter.default.removeObserver(scrollBoundsObserver) }
        guard let clipView = enclosingScrollView?.contentView else { return }
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this runs on the main thread, but the closure's own
            // type is `nonisolated` — the compiler has no way to know that from the API
            // signature — so the hop is stated rather than assumed away.
            Task { @MainActor in self?.closeChangePopover() }
        }
    }

    private func closeChangePopover() {
        changePopover?.close()
        changePopover = nil
        if let scrollBoundsObserver { NotificationCenter.default.removeObserver(scrollBoundsObserver) }
        scrollBoundsObserver = nil
    }

    override func layout() {
        super.layout()
        positionButtons()
    }

    /// «Скопировать код» in the context menu, for the same block the pointer is over.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        guard let card = cards.first(where: { $0.frame?.contains(point) ?? false })
        else { return menu }
        let item = NSMenuItem(title: "Скопировать код",
                              action: #selector(copyCodeBlock(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = card.button.source
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
        for card in cards {
            card.button.removeFromSuperview()
            card.label?.removeFromSuperview()
        }
        cards = codeRegions.map { region in
            let button = CodeCopyButton(title: "Скопировать", target: self,
                                        action: #selector(copyCodeBlock(_:)))
            button.source = region.source
            button.range = region.range
            button.bezelStyle = .roundRect
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            addSubview(button)
            // A label only for a fence that named a language; a bare fence gets a header with
            // the button alone rather than a label saying nothing.
            let label = region.language.map { language in
                let label = CodeLanguageLabel(labelWithString: language)
                label.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                         weight: .regular)
                label.textColor = .secondaryLabelColor
                addSubview(label)
                return label
            }
            return CodeCard(range: region.range, button: button, label: label, frame: nil)
        }
        positionButtons()
    }

    /// Placement from the layout manager's own rect for the block's glyphs. Nothing here
    /// guesses at line heights: the design's measurement is that
    /// `boundingRect(forGlyphRange:in:)` answers exact rects even headless, so the button is
    /// pinned to the code rather than to a font metric.
    private func positionButtons() {
        guard let layoutManager, let textContainer else { return }
        let header = MarkdownToAttributed.codeCardHeaderHeight
        for index in cards.indices {
            let button = cards[index].button
            let glyphs = layoutManager.glyphRange(forCharacterRange: cards[index].range,
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
            cards[index].frame = rect
            button.blockFrame = rect
            button.sizeToFit()
            let size = button.frame.size
            // In the card's header — the room the text block leaves above the first line of
            // code — at the right edge but inside it, because a button hanging past the edge
            // would be clipped by the scroll view at narrow pane widths. The header is
            // `codeCardHeaderHeight` tall; the button sits vertically centred in it.
            button.setFrameOrigin(NSPoint(x: max(rect.maxX - size.width - 6, rect.minX),
                                          y: rect.minY - header + (header - size.height) / 2))
            if let label = cards[index].label {
                label.sizeToFit()
                // Same header, left edge, a little in from the border.
                label.setFrameOrigin(NSPoint(x: rect.minX + 2,
                                             y: rect.minY - header + (header - label.frame.height) / 2))
            }
        }
    }
}

/// The language a fence named, over the block that named it. A type of its own so a test can
/// find the labels among the subviews the way it finds the buttons.
final class CodeLanguageLabel: NSTextField {}

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
