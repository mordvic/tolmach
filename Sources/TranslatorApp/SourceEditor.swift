// Sources/TranslatorApp/SourceEditor.swift
//
// Named for `SourceEditor` since the window's left half became two modes. `PaneHeader`
// lives here rather than in a file of its own because both panes use it and it was already
// shared before the split; `SourceCount`, which the исходник sheet's header shows, lives here
// beside the editor whose text it counts.
import SwiftUI
import TranslationCore

/// Which view the исходник pane hosts: the editor, or the same read-only rendered text view
/// the перевод pane uses.
///
/// A value rather than a condition inside the `ViewBuilder`, for `PrimaryAction`'s reason: the
/// rule is «this pane's own text has markup and the shared toggle says „Разметка"», and a
/// restated condition is how the two panes would come to disagree about what the toggle does.
/// Takes the `PaneRendering` the window already computed rather than scanning again: the same
/// scan feeds the toggle in the other pane's header, and one bounded scan per redraw is enough.
enum SourcePaneMode: Equatable {
    case editor, rendered

    static func of(_ rendering: PaneRendering) -> SourcePaneMode {
        rendering.showsRendered ? .rendered : .editor
    }
}

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
    /// Which view this pane hosts — decided by the window from one scan of the source, because
    /// the window needs the same answer for the toggle in the other pane's header, and two
    /// bounded scans of up to 128 KB per redraw is one too many. Defaulted to the editor so a
    /// call site that knows nothing about rendering gets the pane it always had.
    var paneMode: SourcePaneMode = .editor
    /// So a click in the pane's top margin can still put the caret in the editor. Counted
    /// rather than a flag: see `SourceEditorView.focusRequest`.
    @State private var focusRequest = 0

    /// The sheet's top margin for its text (`PaneSheet.textTopInset`), applied to the editor
    /// **and** to the placeholder from one place. Two copies of it is exactly how the caret and
    /// the grey text came to sit 8 pt apart.
    private static let textTopInset: CGFloat = SourceEditorView.topInset
    /// The исходник sheet's floor — the editor's and the file queue's, which take the same
    /// slot. `PaneSplit` holds the boundary to it.
    static let minWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if paneMode == .rendered {
                // The перевод pane's own view, read-only, over the source: what the user
                // pasted, or what the «Оформить» pass made of it, drawn as the document it
                // is. Editing is one click away in «Исходник». Never streaming — the source
                // does not arrive token by token — so the whole document is rendered at once.
                RenderedTextView(text: model.sourceText, font: font, rendersMarkup: true,
                                 isStreaming: false)
            } else {
            ZStack(alignment: .topLeading) {
                // A hosted text view and not `TextEditor`, since 2026-09-02, for one reason:
                // ⌘V has to read the pasteboard's HTML. `SourceTextView` says why nothing
                // short of hosting gives that. The 8 pt margin the `TextEditor` took as
                // SwiftUI padding is the view's own `textContainerInset` now, which is inside
                // its hit region — so the click-to-focus overlay the padding needed is gone
                // with it, and the strip above the first line places the caret by itself.
                SourceEditorView(text: $model.sourceText, font: font, focusRequest: focusRequest)
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
                        // The same constants the editor is inset by, so the two cannot drift.
                        // The 5 is `lineFragmentPadding`, measured, not chosen.
                        .padding(.top, Self.textTopInset)
                        .padding(.leading, SourceEditorView.leadingInset + 5)
                        // A click on the placeholder is a click into the empty editor.
                        .onTapGesture { focusRequest += 1 }
                }
            }
            }
        }
        .frame(minWidth: Self.minWidth)
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

/// «207 символов · 3 части» — in the исходник sheet's header since 2026-10-29, where the chosen
/// design puts it; it was an overlay in the editor's bottom corner. `showsChunks: false` is the
/// header's narrower form, for a sheet with no room for both.
///
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
struct SourceCount: View {
    let model: TranslationViewModel
    var showsChunks = true

    var body: some View {
        // Read once each. An earlier version read `expectedChunkCount` twice — once for the
        // test and once for the label — and so paid for chunking twice on every pass.
        let characters = model.sourceText.count
        let chunks = showsChunks ? model.expectedChunkCount : 0
        HStack(spacing: 6) {
            if characters > 0 {
                Text(RussianCopy.characterCount(characters))
            }
            if chunks > 1 {
                Text("·")
                Text(RussianCopy.chunkCount(chunks))
            }
        }
        // Tertiary, as the chosen design draws it: a count is read when wanted, and in the
        // header it stands beside the language, which is what the eye should land on first.
        .font(.caption).foregroundStyle(.tertiary)
    }
}

/// One sheet's header: what the sheet holds on the leading edge — its language, or its name
/// where it has none — and its actions on the trailing one. Shared by both sheets so they
/// cannot drift apart.
///
/// **Its actions are borderless, never `.link`** (2026-10-29). «Очистить», «Скопировать», «Ещё
/// вариант» and «Добавить…» are actions, and drawn as links they put the accent on chrome in up
/// to three places, reading as web links. HIG: do not give a colour two meanings; the accent
/// here means the primary action and the change marks. «Очистить» and «Скопировать» are
/// symbols — `PaneIconButton`, the platform's own glyphs, named for VoiceOver and in a tooltip.
///
/// **No band and no rule under it any more.** The header used to be a 28 pt grey strip over a
/// divider; on a sheet the sheet's own edge says where the pane starts, and a second band inside
/// it said it twice. Both sheets pin `PaneSheet.headerHeight`, so the two rows still line up
/// across the gap — which is what the old constant was for.
struct PaneHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 0)
            trailing().font(.caption)
        }
        .padding(.horizontal, PaneSheet.contentInset)
        .frame(height: PaneSheet.headerHeight)
    }
}

/// A sheet's name, where it has no language to name: «Оригинал» and «Правка». Set as the chosen
/// design sets them — the subheadline size, semibold — a step quieter than a language menu,
/// which is a control and takes the body size.
struct PaneTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold))
    }
}

/// «Очистить», «Скопировать»: a symbol in the secondary colour, its name for VoiceOver and the
/// tooltip. A `Label` with `.iconOnly` rather than a bare `Image`, so the button has a name
/// without a separate accessibility modifier that could come to say something else.
struct PaneIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    /// Read so a disabled button looks it. The explicit `.secondary` below overrides the
    /// dimming a borderless button gets for free: measured 2026-10-29 on `renderWindowPreview`'s
    /// images, «Очистить» over an empty editor and «Скопировать» over an empty перевод drew
    /// #929292 — the same grey as when they work.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 13))
                .frame(minWidth: 20, minHeight: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .help(title)
    }
}
