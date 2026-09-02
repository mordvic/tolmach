// Sources/TranslatorApp/SourceTextView.swift
import AppKit
import MarkupKit
import SwiftUI
import TextCapture

/// The исходник pane's editor: a hosted `NSTextView` with one behaviour `TextEditor` cannot be
/// given — a paste that reads the pasteboard's rich flavours.
///
/// **Why a hosted view and not `TextEditor`.** A table copied out of a browser is on the
/// pasteboard twice: flat in `public.utf8-plain-text`, one cell per line, and whole in
/// `public.html`. `TextEditor` pastes the plain flavour and nothing else, and it offers no
/// hook to change that — `paste:` is an action on the text view AppKit installs, answered
/// before anything in the SwiftUI hierarchy above it sees the command. Overriding `paste(_:)`
/// on a text view of our own is the documented route.
///
/// **The conversion and the gate are the hotkey's, not a second copy.** `RichMarkdown.markdown`
/// prefers HTML over RTF and accepts a conversion only when it gains a block form the plain
/// flavour lacks; a paste that would gain only bold, or nothing, pastes the plain bytes exactly
/// as before. Two entry points reading the same board through two rules is how a selection
/// would come to «be» a table when pressed and a paragraph when pasted.
///
/// **Synchronous, and that is a deliberate departure from the hotkey's off-actor conversion.**
/// The hotkey shows a panel with a spinner while it converts; a paste has no such surface, and
/// text that appears a quarter-second after ⌘V — with the insertion point possibly moved by a
/// keystroke in between — is worse than a stall of the same length. The design measured the
/// costs (`docs/design/specs/2026-08-31-formatting-design.md` §10): the HTML converter is a
/// hand-written tag scanner and cheap; the RTF path brings AppKit's text system up at 216–262
/// ms cold and ~60 ms warm, and is reached only when there is no HTML flavour at all.
///
/// Not `final` for the same reason `CodeBlockTextView` is not: a subclass may want the paste
/// and a different geometry.
class SourceTextView: NSTextView {
    /// A text view configured for editing the исходник. One constructor, so the geometry the
    /// pane depends on — `lineFragmentPadding` at its default of 5, matched by the placeholder's
    /// leading inset — and the smart-substitution settings are decided in one place.
    static func make() -> SourceTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = SourceTextView(frame: .zero, textContainer: container)
        view.isEditable = true
        view.isSelectable = true
        // Plain, not rich: the исходник is bytes for a model, and a font or a colour riding in
        // with a paste would be state the pane cannot show and the pipeline cannot read.
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.usesFontPanel = false
        // Every automatic substitution off. A translator's source must reach the model as it
        // was typed or pasted: «smart» quotes, dashes and spelling corrections applied to a
        // technical text change the bytes the user asked to translate.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        // Called here rather than left to AppKit: when the framework first registers a text
        // view's drag types is its business (a bare view in no window has registered nothing,
        // measured), and the override below makes every later call answer the same list.
        view.updateDragTypeRegistration()
        return view
    }

    override func paste(_ sender: Any?) {
        pasteRich(from: .general)
    }

    /// Strings only. AppKit registers a text view for every readable type — file URLs among
    /// them — the moment it lands in a window, and re-does so whenever editability changes;
    /// a file dropped on the pane would then be taken by the text view, which inserts the
    /// *path*, before the pane's own drop destination ever saw it. `DroppedDocument` is what
    /// decides what may be read out of a dropped file, so the drop has to reach the pane.
    override func updateDragTypeRegistration() {
        registerForDraggedTypes([.string])
    }

    /// The paste, from a given board — so a test can hand it a board of its own and never
    /// touch the user's clipboard.
    ///
    /// With no plain flavour on the board there is nothing to gate against, and AppKit's own
    /// paste does whatever it does today (a file URL, an image — nothing this pane reads).
    func pasteRich(from board: NSPasteboard) {
        let flavours = GeneralPasteboard.withExclusiveAccess {
            (plain: board.string(forType: .string),
             html: board.data(forType: .html),
             rtf: board.data(forType: .rtf))
        }
        guard let plain = flavours.plain else {
            super.paste(nil)
            return
        }
        let text = RichMarkdown.markdown(html: flavours.html, rtf: flavours.rtf,
                                         improvingOn: plain) ?? plain
        // `insertText(_:replacementRange:)` and not a storage edit: it goes through the undo
        // manager and the delegate, so ⌘Z takes the paste back and the pane's binding hears
        // about it, exactly as a typed character would.
        insertText(text, replacementRange: selectedRange())
    }
}

/// `SourceTextView` in a scroll view, bound to the model's `sourceText`.
///
/// The geometry reproduces what the `TextEditor` it replaced had after the pane's own fixes: 8
/// pt above the first line, as `textContainerInset` rather than SwiftUI padding — an inset is
/// inside the view's hit region, so the strip above the text takes a click without the
/// overlay the padding needed — and the container's default `lineFragmentPadding` of 5, which
/// is the 5 the placeholder is inset by.
struct SourceEditorView: NSViewRepresentable {
    @Binding var text: String
    /// «Шрифт текста», applied to the whole view: the editor is plain text, so one font is the
    /// font of everything in it.
    let font: ContentFont
    /// Incremented by the pane when a click outside the text asks for the caret. Compared, not
    /// read as a flag, so two requests in a row both land.
    let focusRequest: Int

    /// The vertical inset, shared with the placeholder in `SourceEditor`.
    static let topInset: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SourceTextView.make()
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 0, height: Self.topInset)
        textView.font = font.nsFont
        textView.textColor = .labelColor
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
        guard let textView = scrollView.documentView as? SourceTextView else { return }
        context.coordinator.text = $text
        // Only when they differ: the coordinator has just written the view's own string into
        // the binding, and writing it back would move the selection under a typing user.
        if textView.string != text { textView.string = text }
        let wanted = font.nsFont
        if textView.font != wanted { textView.font = wanted }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            textView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focusRequest = 0

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
