// Sources/TranslatorApp/TranslationPane.swift
import SwiftUI

/// The window's right half: what came back.
///
/// A selectable `Text` in a `ScrollView` and **not** a `TextEditor`. The pane used to be a
/// `TextEditor` bound to `.constant(model.translatedText)`, which takes a caret and silently
/// discards every keystroke — a control that accepts input and does nothing with it.
///
/// Takes the four values it renders rather than a `TranslationViewModel`, because the file
/// queue's right pane shows a `FileQueueModel`'s translation through this same view. A view
/// that renders four values does not need a class reference to reach them, and a second
/// copy of this pane is how two surfaces come to disagree about what a translation looks
/// like.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: title) {
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
