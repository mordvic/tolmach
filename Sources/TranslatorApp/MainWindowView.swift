// Sources/TranslatorApp/MainWindowView.swift
import SwiftUI
import TranslationCore

struct MainWindowView: View {
    @Bindable var model: TranslationViewModel
    @Bindable var settings: AppSettings
    /// The value, not the `OllamaStatusModel`. The window only reads the status; the app
    /// owns the model and the refresh schedule.
    let status: OllamaStatus

    var body: some View {
        VStack(spacing: 12) {
            controls
            HStack(spacing: 12) {
                TextEditor(text: $model.sourceText)
                    .font(.body).frame(minWidth: 280, minHeight: 260)
                    .overlay(alignment: .bottomTrailing) { chunkHint.padding(6) }
                TextEditor(text: .constant(model.translatedText))
                    .font(.body).frame(minWidth: 280, minHeight: 260)
            }
            statusLine
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 460)
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
                Button("Отмена") { model.cancel() }
            } else {
                Button("Перевести") { Task { await model.translate() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!status.isHealthy)
            }
        }
    }

    private var chunkHint: some View {
        Group {
            if model.expectedChunkCount > 1 {
                Text(RussianCopy.chunkCount(model.expectedChunkCount))
                    .font(.caption).foregroundStyle(.secondary)
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
