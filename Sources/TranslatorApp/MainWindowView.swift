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
                let warnings = WarningsView(outcome: outcome,
                                            target: model.resolvedTarget,
                                            problem: glossary.lastProblem,
                                            onMute: mute)
                // `WarningsView` has no natural ceiling: `documentGlossary` is one row per
                // term the model extracted, and the disclosure expands in place, so an
                // unbounded panel takes whatever it wants from the editors — which are the
                // reason the window exists.
                //
                // 140pt comes off the window's own budget rather than out of the air. Of
                // the 460pt minimum, the chrome takes ~112 (32 of padding, ~28 for the
                // controls row, ~16 for the status caption, three 12pt gaps) and the
                // editors' `minHeight: 260` takes the next 260, leaving ~88. That 88 is
                // what the panel gets at the minimum window size no matter what this cap
                // says, because the editors' 260 is a hard floor and the panel is the only
                // child that can give — it shrinks and scrolls rather than pushing anything
                // out. What the cap actually governs is a *taller* window: the panel may
                // claim up to 140 (about nine caption rows — a heading and its bullets, or
                // the head of an expanded document glossary) and then stops, so every
                // further pixel of a resized window goes to the editors.
                //
                // `ViewThatFits` and not a bare `ScrollView`, because a `ScrollView` is
                // greedy in its scroll axis: it would sit at the full 140 under a two-line
                // warning and leave the rest blank. This takes the plain stack's own height
                // while that fits, and only falls back to scrolling once it does not.
                //
                // Gated on `hasContent` for the same reason the panel is: an outcome with no
                // diffs, no missing terms and no document glossary draws an empty `VStack`,
                // and reserving 140pt for it is reserving space for nothing. Measured in the
                // panel, where the cost was 86 of 260 points; not measured here, where the
                // editors' floor absorbs more of it — applied because "do not reserve space
                // for something that will not draw" is right either way.
                if warnings.hasContent {
                    ViewThatFits(in: .vertical) {
                        warnings
                        ScrollView { warnings }
                    }
                    .frame(maxHeight: 140)
                }
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
        } catch GlossaryStoreError.fileChangedOnDisk {
            // Deliberately not «не удалось сохранить»: nothing is broken and there is
            // nothing to retry. The file changed under the app, the app refused to write
            // its stale copy over it, and the user is the only one who knows which version
            // they want — so say what happened and what to do about it.
            glossary.lastProblem = "Файл глоссария изменился на диске после запуска приложения, "
                + "поэтому список скрытых терминов не сохранён — иначе ваши правки были бы затёрты. "
                + "«\(term)» скрыт только до перезапуска; перезапустите приложение, чтобы прочитать новую версию."
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
            // Spec 8 pairs both failure rows — a timed-out request and an empty model reply
            // — with a retry, and Plan 2 built the states but never the button. Reachable:
            // `translate()` opens with `guard state != .running`, and `.failed` is not
            // `.running`, so the guard passes. The source text is still in the editor, so
            // retrying costs the user nothing but the wait.
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить") { Task { await model.translate() } }
                    .font(.caption)
                Spacer()
            }
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
