// Sources/TranslatorApp/TranslationPane.swift
import SwiftUI

/// The window's right half: what came back.
///
/// A selectable `Text` in a `ScrollView` and **not** a `TextEditor`. The pane used to be a
/// `TextEditor` bound to `.constant(model.translatedText)`, which takes a caret and silently
/// discards every keystroke — a control that accepts input and does nothing with it.
struct TranslationPane: View {
    let model: TranslationViewModel
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Перевод") {
                Button("Скопировать", action: onCopy)
                    .buttonStyle(.link)
                    // Enabled the moment the first token lands, not only at the end: an
                    // interrupted run leaves partial output the app keeps on purpose, and
                    // keeping it while refusing to copy it would be pointless. Same rule as
                    // the panel's own copy button.
                    .disabled(model.translatedText.isEmpty)
            }
            if model.translatedText.isEmpty && model.state != .running {
                VStack(spacing: 8) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Здесь появится перевод")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(model.translatedText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
        .frame(minWidth: 280)
    }
}
