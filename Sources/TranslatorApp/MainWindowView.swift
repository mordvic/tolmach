// Sources/TranslatorApp/MainWindowView.swift
import SwiftUI
import TranslationCore

struct MainWindowView: View {
    @Bindable var model: TranslationViewModel
    @Bindable var settings: AppSettings
    /// Plain `let`, not `@Bindable`: nothing here binds to the store, it is only read
    /// (`lastProblem`) and messaged (`mute`/`save`). Observation still tracks the reads.
    let glossary: GlossaryStore
    /// The value, not the `OllamaStatusModel`. The window only reads the status; the app
    /// owns the model and the refresh schedule.
    let status: OllamaStatus

    var body: some View {
        VStack(spacing: 12) {
            controls
            HStack(spacing: 12) {
                TextEditor(text: $model.sourceText)
                    .font(.body).frame(minWidth: 280, minHeight: 260)
                    .overlay(alignment: .bottomTrailing) { ChunkHint(model: model).padding(6) }
                TextEditor(text: .constant(model.translatedText))
                    .font(.body).frame(minWidth: 280, minHeight: 260)
            }
            statusLine
            if let outcome = model.outcome, model.state == .finished {
                WarningsView(outcome: outcome,
                             target: model.resolvedTarget,
                             problem: glossary.lastProblem,
                             onMute: mute)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 460)
    }

    /// Muting is two steps and only the first is guaranteed. `mute` updates the in-memory
    /// list, so the term is already hidden for this session; `save` is what makes that
    /// survive a restart, and it can fail — most importantly when the glossary never
    /// loaded, in which case `GlossaryStore` refuses rather than overwriting the user's
    /// file. A `try?` here would leave the user believing the term is gone for good.
    private func mute(_ term: String) {
        glossary.mute(term)
        do {
            try glossary.save()
            glossary.lastProblem = nil
        } catch GlossaryStoreError.saveBeforeLoad {
            glossary.lastProblem = "Глоссарий не был прочитан, поэтому список скрытых терминов не сохранён. "
                + "«\(term)» скрыт только до перезапуска."
        } catch {
            glossary.lastProblem = "Не удалось сохранить глоссарий, «\(term)» скрыт только до перезапуска: "
                + error.localizedDescription
        }
    }

    private var controls: some View {
        HStack {
            Picker("Из", selection: $model.sourceOverride) {
                Text("определить").tag(Language?.none)
                ForEach(Language.allCases, id: \.self) { Text($0.shortCode).tag(Language?.some($0)) }
            }.frame(width: 150)
            Picker("В", selection: $model.targetOverride) {
                Text("по правилу").tag(Language?.none)
                ForEach(Language.allCases, id: \.self) { Text($0.shortCode).tag(Language?.some($0)) }
            }.frame(width: 150)
            Picker("Тон", selection: $model.toneOverride) {
                Text("по умолчанию").tag(Tone?.none)
                ForEach(Tone.allCases, id: \.self) { Text($0.russianName).tag(Tone?.some($0)) }
            }.frame(width: 170)
            Spacer()
            if model.state == .running {
                // ⌘. is the macOS convention for cancelling an operation in progress.
                // Without it a run is unstoppable from the keyboard: ⌘↩ belongs to
                // «Перевести», which is not on screen while the run is going.
                Button("Отмена") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Перевести") { Task { await model.translate() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!status.isHealthy)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch model.state {
        case .idle: Text(status.label).font(.caption).foregroundStyle(.secondary)
        case .running: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Перевожу…").font(.caption) }
        case .finished:
            if let outcome = model.outcome {
                Text("Готово за \(Int(outcome.totalMS)) мс").font(.caption).foregroundStyle(.secondary)
            }
        case .interrupted:
            Text("Перевод прерван — показана та часть, что успела прийти")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

/// A `View` of its own rather than a computed property on `MainWindowView`, and that is
/// the whole point of the type.
///
/// `MainWindowView.body` reads `model.translatedText`, so every streamed token
/// invalidates it. A computed property is just part of that body, so the hint was rebuilt
/// on every token — and `expectedChunkCount` runs `Chunker.chunk` in full: a line split,
/// a `String.count` per block, and `enumerateSubstrings(options: .bySentences)` over
/// oversized ones. Measured at 2 evaluations per token, for a value whose only inputs
/// (`sourceText`, `settings.chunkSize`) cannot change while a run is streaming.
///
/// As a separate view value holding a single class reference, SwiftUI compares the
/// re-created `ChunkHint` against the previous one, finds the reference identical, and
/// skips its body. Observation then re-runs it only when `sourceText` itself changes.
private struct ChunkHint: View {
    let model: TranslationViewModel

    var body: some View {
        // Read once. The old computed property read it twice — once for the test and once
        // for the label — and so paid for chunking twice on every pass.
        let count = model.expectedChunkCount
        if count > 1 {
            Text(RussianCopy.chunkCount(count))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
