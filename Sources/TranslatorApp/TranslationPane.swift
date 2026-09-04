// Sources/TranslatorApp/TranslationPane.swift
import MarkupKit
import SwiftUI
import TranslationCore

/// Whether this text has markup, whether the pane is therefore drawing it, and what
/// «Скопировать» should carry — one value, because three surfaces have to agree.
///
/// The pane reads it to decide what to draw and whether to offer the toggle at all; the
/// window's «Скопировать» button and the «Перевод» menu's ⇧⌘C read it to decide whether to put
/// a rich flavour on the pasteboard. Restating «the setting is on *and* there is markup» at
/// each of those is how the toolbar comes to copy RTF for a pane that is showing raw Markdown.
/// The same reasoning `PrimaryAction` was introduced under.
struct PaneRendering {
    /// True when `MarkdownPresence` found something a renderer could draw differently. False
    /// means the pane is exactly what it was before any of this existed: one `Text`, no
    /// toggle, no text view.
    let hasMarkup: Bool
    /// True only when there is markup *and* the setting says «Разметка».
    let showsRendered: Bool

    static func of(_ text: String, showsRenderedMarkup: Bool) -> PaneRendering {
        let hasMarkup = MarkdownPresence.hasMarkup(text)
        return PaneRendering(hasMarkup: hasMarkup,
                             showsRendered: hasMarkup && showsRenderedMarkup)
    }

    /// The rich flavour «Скопировать» should write beside the Markdown, or nil.
    ///
    /// Nil while the pane shows «Исходник» and nil when there is no markup — a plain-prose
    /// translation never arrives in Word wearing a font this app chose (design §6). Built here
    /// rather than at the button, so the flavour is the *same converter's* output as the pixels
    /// the user is looking at.
    ///
    /// Called when the button is pressed and never from a view body: an RTF serialisation of a
    /// 2 MB translation is not something to do once per streamed token.
    func rtf(of text: String, font: ContentFont) -> Data? {
        guard showsRendered else { return nil }
        return MarkdownToAttributed.rendering(of: text, config: font.markdownConfig).rtf
    }
}

/// The window's right half: what came back.
///
/// Two modes since 2026-08-31, and only when there is something to choose between:
/// «Разметка» draws the Markdown as a document in a hosted `NSTextView`
/// (`RenderedTextView`), «Исходник» shows the same string in the same view with no
/// conversion. With no markup at all the pane is what it always was — a selectable `Text` in a
/// `ScrollView`, and **not** a `TextEditor`: the pane used to be a `TextEditor` bound to
/// `.constant(model.translatedText)`, which takes a caret and silently discards every
/// keystroke, a control that accepts input and does nothing with it.
///
/// Takes the values it renders rather than a `TranslationViewModel`, because the file
/// queue's right pane shows a `FileQueueModel`'s translation through this same view. A view
/// that renders values does not need a class reference to reach them, and a second
/// copy of this pane is how two surfaces come to disagree about what a translation looks
/// like. The toggle and the rendering therefore reach the queue's pane for free, which is the
/// point.
struct TranslationPane: View {
    /// «Перевод», or «Перевод · techdoc-en.md» in the queue. A parameter and not a constant
    /// because the queue names the file whose translation is showing.
    let title: String
    let text: String
    let isRunning: Bool
    let onCopy: () -> Void
    /// «Ещё вариант» — present only when the window offers it (a finished правка whose
    /// степень was «ошибки и стиль», spec §6). Nil hides the button entirely, so the
    /// queue's use of this pane never shows it.
    var onAnotherVariant: (() -> Void)? = nil
    /// «Шрифт текста», a fifth value alongside the four this pane already renders — and it
    /// reaches both surfaces at once, because the file queue's right-hand pane is this same
    /// view. Defaulted so a call site that knows nothing about the setting renders what the
    /// app rendered before it existed.
    var font: ContentFont = .default
    /// «Разметка | Исходник». A `Binding` and not a value, because the toggle *is* the
    /// setting — the same treatment the panel's степень/стиль pickers get: a choice made where
    /// the text is read survives the window closing. Defaulted to a constant so a call site
    /// that has no settings object still compiles and still renders markup.
    var showsRenderedMarkup: Binding<Bool> = .constant(true)
    /// Whether the исходник pane beside this one has markup of its own. The toggle in this
    /// header governs both panes since 2026-09-02, so it has to appear when *either* has
    /// something to show — a Markdown source with no translation yet still needs its way back
    /// to the editor. The queue passes nothing: its left pane is a file list.
    var sourceHasMarkup = false
    /// A finished правка's change set, or nil — nil for перевод, for the queue, and while a run
    /// is in flight. `MainWindowView` passes `model.changes`, which is already gated on
    /// `state == .finished`, so an interrupted run's partial text is never marked.
    var changes: ChangeSet? = nil
    /// «Результат | Изменения» — the setting, written through by the header's picker like
    /// `showsRenderedMarkup` is. Defaulted for the queue, which has no правка.
    var showsChangeDetail: Binding<Bool> = .constant(false)
    /// The change the status bar's stepper is standing on; the text view selects and flashes it.
    var changeCursor: Int? = nil

    /// The one rule for whether «Разметка | Исходник» is drawn. A function so a test can pin
    /// it without rendering the header.
    static func offersToggle(translationHasMarkup: Bool, sourceHasMarkup: Bool) -> Bool {
        translationHasMarkup || sourceHasMarkup
    }

    /// Whether the header draws a picker at all: the raw view when either pane has markup, or
    /// the «Результат | Изменения» pair when there is a change set. With neither, the header
    /// is exactly what it was — a plain translation grows no control that would do nothing.
    static func offersPicker(translationHasMarkup: Bool, sourceHasMarkup: Bool,
                             hasChanges: Bool) -> Bool {
        offersToggle(translationHasMarkup: translationHasMarkup, sourceHasMarkup: sourceHasMarkup)
            || hasChanges
    }

    var body: some View {
        // One scan per body evaluation, and the value both halves of the pane read. `hasMarkup`
        // walks the blocks and stops at the first non-paragraph, so the expensive case is
        // plain prose — the same order of work the `Text` below already does laying it out.
        let rendering = PaneRendering.of(text, showsRenderedMarkup: showsRenderedMarkup.wrappedValue)
        // A set with no changes still counts: «изменений нет» is a result, and its pane is a
        // hosted text view like any other правка's, so switching степень does not swap the
        // pane's whole kind of view under the reader.
        let hasChanges = changes != nil
        let offersSource = Self.offersToggle(translationHasMarkup: rendering.hasMarkup,
                                             sourceHasMarkup: sourceHasMarkup)
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: title) {
                // Only when there is something to choose between. With no markup and no правка
                // the header is exactly what it was, which is what keeps a plain translation
                // from growing a control that would do nothing.
                if Self.offersPicker(translationHasMarkup: rendering.hasMarkup,
                                     sourceHasMarkup: sourceHasMarkup, hasChanges: hasChanges) {
                    // One picker, up to three segments — `PaneViewChoice` is the rule. The
                    // binding reads the two settings and writes whichever the chosen segment
                    // stands for; «Исходник» leaves the detail alone, and that is a decision
                    // with a test, not an accident of the binding.
                    //
                    // **Segmented, and measured to cost 98 pt over today's header.**
                    // `Scripts/pane-header-fit.swift` (2026-09-04, detached host, `fittingSize`,
                    // caption + picker + both link buttons): three segments 495 pt, today's two
                    // 397 pt, a `.menu` fallback 352 pt — against this pane's 280 pt `minWidth`,
                    // which *today's* header already exceeds. The spec's fallback rule («a
                    // `.menu` for правка if it does not fit at 280») therefore has no state to
                    // apply to: nothing fits at 280 and nothing did before. Segmented is kept so
                    // правка's picker is the same control as перевод's; what the numbers say is
                    // that the header's real floor is the picker plus two link buttons, and a
                    // pane narrower than that clips the trailing button in either operation —
                    // owed a look in `docs/reference/OPEN-ITEMS.md`.
                    Picker("", selection: Binding(
                        get: {
                            PaneViewChoice.current(
                                showsRenderedMarkup: showsRenderedMarkup.wrappedValue,
                                showsChangeDetail: showsChangeDetail.wrappedValue,
                                hasChanges: hasChanges)
                        },
                        set: { choice in
                            let writes = choice.writes
                            showsRenderedMarkup.wrappedValue = writes.showsRenderedMarkup
                            if let detail = writes.showsChangeDetail {
                                showsChangeDetail.wrappedValue = detail
                            }
                        })) {
                        ForEach(PaneViewChoice.segments(hasChanges: hasChanges,
                                                        offersSource: offersSource)) { choice in
                            Text(choice.label(hasChanges: hasChanges)).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help(hasChanges
                          ? "Показывать результат, изменения с удалённым текстом или исходный текст"
                          : "Показывать разметку как документ или как исходный текст")
                }
                if let onAnotherVariant {
                    Button("Ещё вариант", action: onAnotherVariant)
                        .buttonStyle(.link)
                }
                Button("Скопировать", action: onCopy)
                    .buttonStyle(.link)
                    // Enabled the moment the first token lands, not only at the end: an
                    // interrupted run leaves partial output the app keeps on purpose, and
                    // keeping it while refusing to copy it would be pointless. Same rule as
                    // the panel's own copy button.
                    .disabled(text.isEmpty)
            }
            if text.isEmpty && !isRunning {
                VStack(spacing: 8) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Здесь появится перевод")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rendering.hasMarkup || hasChanges {
                // Both modes are the same hosted text view: «Исходник» is this string without
                // the conversion, which is what makes the raw Markdown selectable as one
                // document rather than a `Text` the toggle swaps in and out. A правка takes
                // this view even without markup, because its marks are attributes a `Text`
                // cannot carry and its stepper needs a selection to move.
                RenderedTextView(text: text, font: font,
                                 rendersMarkup: rendering.showsRendered,
                                 isStreaming: isRunning,
                                 changes: isRunning ? nil : changes,
                                 showsChangeDetail: showsChangeDetail.wrappedValue,
                                 changeCursor: changeCursor)
            } else {
                ScrollView {
                    Text(text)
                        .font(font.font)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
        .frame(minWidth: 280)
    }
}
