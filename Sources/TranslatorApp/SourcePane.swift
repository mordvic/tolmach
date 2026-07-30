// Sources/TranslatorApp/SourcePane.swift
import SwiftUI

/// The window's left half: what the user typed.
struct SourcePane: View {
    @Bindable var model: TranslationViewModel
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Исходник") {
                Button("Очистить", action: onClear)
                    .buttonStyle(.link)
                    .disabled(model.sourceText.isEmpty)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.sourceText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                // A placeholder and not a first line of grey text in the editor itself:
                // anything in the binding is text the user would have to delete, and would
                // be translated if they did not.
                if model.sourceText.isEmpty {
                    Text("Вставьте или наберите текст")
                        .font(.body).foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) { SourceFooter(model: model).padding(6) }
        }
        .frame(minWidth: 280)
    }
}

/// A `View` of its own rather than a computed property, and that is the whole point of the
/// type.
///
/// `MainWindowView` reads `model.translatedText`, so every streamed token invalidates its
/// body and everything inlined in it. `expectedChunkCount` runs `Chunker.chunk` in full — a
/// line split, a `String.count` per block, and `enumerateSubstrings(options: .bySentences)`
/// over oversized ones — and was measured at 2 evaluations per token, for a value whose only
/// inputs cannot change while a run is streaming.
///
/// As a separate view value holding a single class reference, SwiftUI compares the re-created
/// value against the previous one, finds the reference identical, and skips its body.
/// Observation then re-runs it only when `sourceText` itself changes. The character count is
/// here for the same protection, not for tidiness. This carries forward the measurement
/// `ChunkHint` in `MainWindowView.swift` recorded; that type is deleted once Task 7 rebuilds
/// the window around this pane, and this doc comment is where the reasoning survives it.
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
    let title: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            action().font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.25))
        Divider()
    }
}
