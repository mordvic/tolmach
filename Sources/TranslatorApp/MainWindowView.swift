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
    var onCopy: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SourcePane(model: model, onClear: { model.sourceText = "" })
                TranslationPane(model: model, onCopy: onCopy)
            }
            Divider()
            RunStatusBar(model: model, status: status,
                         glossaryProblem: glossary.lastProblem,
                         onMute: mute,
                         onRetry: { Task { await model.translate() } })
        }
        .frame(minWidth: 700, minHeight: 480)
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // `russianName`, not `shortCode`. The settings name these languages in words and
            // this window used to name them in codes — one vocabulary under two names, which
            // is exactly what `CONTEXT.md` exists to prevent.
            Picker("Из", selection: $model.sourceOverride) {
                Text("Определить").tag(Language?.none)
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag(Language?.some($0)) }
            }
            Button {
                model.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(!model.canSwapLanguages)
            .help("Перевести в обратную сторону")
            Picker("В", selection: $model.targetOverride) {
                Text("По правилу").tag(Language?.none)
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag(Language?.some($0)) }
            }
            Picker("Тон", selection: $model.toneOverride) {
                Text("По умолчанию").tag(Tone?.none)
                ForEach(Tone.allCases, id: \.self) { Text($0.russianName).tag(Tone?.some($0)) }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if model.state == .running {
                // ⌘. is the macOS convention for cancelling an operation in progress.
                // Without it a run is unstoppable from the keyboard: ⌘↩ belongs to
                // «Перевести», which is not on screen while the run is going.
                Button("Отмена") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Перевести") { Task { await model.translate() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!status.isHealthy)
            }
        }
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
}
