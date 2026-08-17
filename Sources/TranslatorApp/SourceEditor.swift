// Sources/TranslatorApp/SourceEditor.swift
//
// Named for `SourceEditor` since the window's left half became two modes. `PaneHeader`
// lives here rather than in a file of its own because both panes use it and it was already
// shared before the split; `SourceFooter` is private to the editor.
import SwiftUI

/// The window's left half in «Текст»: what the user typed.
///
/// Header-less on purpose. The window draws one header for both of its left-hand modes —
/// «Текст» and «Файлы» share the row that holds the switch — so a header here would be a
/// second one under it.
struct SourceEditor: View {
    @Bindable var model: TranslationViewModel
    /// «Шрифт текста» — the one the user chose, or the system's if they never opened the
    /// setting. Passed in rather than read from `AppSettings` here, like the four values
    /// `TranslationPane` takes: this pane renders a model and a font, and a view that needs no
    /// settings object should not acquire one.
    ///
    /// Measured before it was wired: the font does reach the hosted `NSTextView` —
    /// `.SFNS-Regular 22.0`, `.AppleSystemUIFontMonospaced-Regular 22.0` and `.NewYork-Regular
    /// 22.0` for the three faces at 22 pt (`Scripts/content-font.swift`, section 5). `TextEditor`
    /// exposes no font of its own, so had it not, there would have been no route to one.
    var font: ContentFont = .default
    /// So a click in the pane's top margin can still put the caret in the editor. See the
    /// `contentShape` on the stack below.
    @FocusState private var editorFocused: Bool

    /// The drawing's 8 pt top margin for this pane, applied to the editor **and** to the
    /// placeholder from one place. Two copies of it is exactly how the caret and the grey
    /// text came to sit 8 pt apart.
    private static let textTopInset: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.sourceText)
                    .font(font.font)
                    .scrollContentBackground(.hidden)
                    // **The editor's own top margin, and the reason the caret used to look
                    // misplaced.** Asked of the text view on the running bundle:
                    // `textContainerInset` is `{0, 0}` and `textContainerOrigin` is `{0, 0}`,
                    // so text begins hard against the top edge of the pane; the caret's own
                    // rect came back at exactly the text view's top, at x = 5. The 5 is
                    // `lineFragmentPadding`, which `NSTextContainer` defaults to and which is
                    // why the placeholder's leading inset below is 5 and not 8.
                    //
                    // Vertically there was nothing, so the placeholder's 8 pt put the grey
                    // text a whole 8 pt below the caret that was supposed to sit in front of
                    // it. Padding the editor rather than un-padding the placeholder, because
                    // the drawing gives this pane `padding: 8px 5px` — the margin is wanted,
                    // it was simply being applied to the wrong one of the two.
                    .padding(.top, Self.textTopInset)
                    .focused($editorFocused)
                // A placeholder and not a first line of grey text in the editor itself:
                // anything in the binding is text the user would have to delete, and would
                // be translated if they did not.
                if model.sourceText.isEmpty {
                    Text("Вставьте или наберите текст")
                        // The editor's font, not the system's: the placeholder stands where the
                        // first line of text will, and the two used to be pinned together by
                        // both saying `.body`. A placeholder left behind at 13 pt would sit at a
                        // different baseline from the caret in front of it — the same defect the
                        // 8 pt inset above was written to fix, arriving through the font instead.
                        .font(font.font).foregroundStyle(.tertiary)
                        // The same constant the editor is padded by, so the two cannot drift.
                        // The 5 is `lineFragmentPadding`, measured, not chosen.
                        .padding(.top, Self.textTopInset).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            // **The margin above is padding, and padding is outside its child's hit region.**
            // The editor's own frame moves down by those 8 pt, the stack has no background and
            // the placeholder refuses hits, so the top strip of the pane landed on nothing: a
            // click there neither focused the editor nor placed a caret, and the user had to
            // aim lower.
            //
            // The gesture covers **the strip and nothing else**. Hung on the stack, as it
            // first was, its hit region covered the `TextEditor` too — and if SwiftUI resolves
            // an ancestor tap before the hosted `NSTextView`'s own mouse handling, every click
            // in the pane would only set focus: no caret placed mid-paragraph, no click-drag
            // selection, editing a pasted source reduced to appending. Which way that
            // resolves is exactly the kind of AppKit routing this project refuses to assert
            // from memory, so the fix is to not depend on the answer.
            //
            // Padding and not an inset inside the editor because there is no way to ask for
            // one: `TextEditor`'s `textContainerInset` is `{0, 0}` and not exposed, and
            // `.contentMargins` does not reach its text — measured, in all three spellings,
            // each leaving the caret flush with the top while the frame stayed full height.
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: Self.textTopInset)
                    .contentShape(Rectangle())
                    .onTapGesture { editorFocused = true }
            }
            .overlay(alignment: .bottomTrailing) { SourceFooter(model: model).padding(6) }
        }
        .frame(minWidth: 280)
        // A translator window that cannot take a dropped file is a translator window that
        // makes the user open the file elsewhere, select all, copy, and paste. What may be
        // dropped and what is read out of it is `DroppedDocument`; this closure only decides
        // *when*.
        //
        // Refusing returns false, which is the whole error-reporting mechanism: the system
        // springs the item back to where it was dragged from. Two things are refused here on
        // top of whatever `DroppedDocument` refuses — a drop while a run is in flight, which
        // would swap the source out from under a translation already streaming into the pane
        // beside it, and a multiple selection, because taking «the first of five» silently is
        // a guess about which one was meant.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.state != .running, urls.count == 1,
                  let text = DroppedDocument.text(of: urls[0])
            else { return false }
            model.sourceText = text
            // Everything derived from the previous run goes with the text it described, the
            // same pairing `translate()` and `swapLanguages()` maintain: an outcome that
            // outlives its source renders the old run's markup diffs and glossary checks
            // under a document that is no longer there.
            model.translatedText = ""
            model.outcome = nil
            model.state = .idle
            return true
        }
    }
}

/// A `View` of its own rather than a computed property, and that is the whole point of the
/// type.
///
/// `MainWindowView` reads `model.translatedText`, so every streamed token invalidates its
/// body and everything inlined in it. `expectedChunkCount` runs `Chunker.plan` in full — a
/// line split, a `String.count` per block, and `enumerateSubstrings(options: .bySentences)`
/// over oversized ones — and was measured at 2 evaluations per token, for a value whose only
/// inputs cannot change while a run is streaming.
///
/// As a separate view value holding a single class reference, SwiftUI compares the re-created
/// value against the previous one, finds the reference identical, and skips its body.
/// Observation then re-runs it only when `sourceText` itself changes. The character count is
/// here for the same protection, not for tidiness.
///
/// This carries forward a measurement `ChunkHint` in `MainWindowView.swift` recorded — 2
/// evaluations of `expectedChunkCount` per streamed token, for a value whose only inputs are
/// `sourceText` and `settings.chunkSize` and so cannot change while a run is streaming. That
/// type was deleted when the window was rebuilt around this pane, and this doc comment is the
/// only place the reasoning still lives, which is why the inputs are named here: without them
/// the claim that they cannot change mid-run is not checkable from the comment.
private struct SourceFooter: View {
    let model: TranslationViewModel

    var body: some View {
        // Read once each. An earlier version read `expectedChunkCount` twice — once for the
        // test and once for the label — and so paid for chunking twice on every pass.
        let characters = model.sourceText.count
        let chunks = model.expectedChunkCount
        HStack(spacing: 6) {
            if characters > 0 {
                Text(RussianCopy.characterCount(characters))
            }
            if chunks > 1 {
                Text("·")
                Text(RussianCopy.chunkCount(chunks))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// One row, one title, one action. Shared by both panes so they cannot drift apart.
struct PaneHeader<Action: View>: View {
    /// Optional because the left pane's header is a mode switch rather than a caption,
    /// while the right pane's is still a caption. One type, two contents.
    let title: String?
    @ViewBuilder var action: () -> Action

    /// Both panes' headers are pinned to this, and that is the point of the constant.
    /// The row used to size itself from a caption plus 4 pt of padding; the left one now
    /// holds a `.small` segmented control, which is taller. Two headers a few points
    /// apart put a visible step in the divider between the panes.
    ///
    /// The number is **not** measured — nothing in this environment can see a screen. It
    /// is the smallest value that should fit a `.small` segmented control with the
    /// padding this row already had, and `docs/reference/OPEN-ITEMS.md` carries it as owed to a
    /// pair of eyes.
    static var height: CGFloat { 28 }

    var body: some View {
        HStack {
            // The spacer belongs to the *title*, and only to it: it is what pushes the
            // action to the trailing edge. With no title — the left pane's header, which is
            // a mode switch — two equally flexible spacers split the free width between
            // them and the switch floated a quarter of the way in, instead of sitting where
            // the caption it replaced used to be.
            if let title {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            action().font(.caption)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(.quaternary.opacity(0.25))
        Divider()
    }
}
