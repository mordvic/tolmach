// Sources/TranslatorApp/MainWindowView.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TranslationCore

struct MainWindowView: View {
    @Bindable var model: TranslationViewModel
    /// Plain `let`, not `@Bindable`: nothing here binds to the store, it is only read
    /// (`lastProblem`) and messaged (`mute`/`save`). Observation still tracks the reads.
    let glossary: GlossaryStore
    /// The value, not the `OllamaStatusModel`. The window only reads the status; the app
    /// owns the model and the refresh schedule.
    let status: OllamaStatus
    var onCopy: () -> Void = {}
    /// Refreshes `OllamaStatusModel` whenever this window's `state` moves to anything that is
    /// not `.running` — the window's own half of the "after a translation attempt" trigger;
    /// `PanelHost` covers the hotkey half. That guard is deliberately wider than "a run
    /// settled": `swapLanguages()` and `adopt(from:)` both write `state` without a run having
    /// happened, and both therefore fire this too. Harmless in the direction it errs — every
    /// extra fire makes the glyph fresher, and `refresh()` is one probe — but it is a wider
    /// trigger than the name suggests, so the name is not what to trust here.
    ///
    /// Not defaulted, matching `PanelHost.onRunFinished`: there is exactly one call
    /// site (`TranslatorApp.swift`'s `Window` scene), and a default here would let a future
    /// second call site compile while silently never refreshing — the same trap a default
    /// would have been worth taking on `PanelHost` too, if it had more than one caller.
    let onRunFinished: () async -> Void
    /// The third model, owned by `TranslatorApp` beside the window's and the panel's.
    let queue: FileQueueModel

    /// Which half the left pane is showing. `@State` and not a setting: it is where the
    /// user is looking right now, not a preference to survive a relaunch.
    @State private var mode: SourceMode = .text

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    // The switch replaces the «Исходник» caption rather than sitting above
                    // it, so both panes still read as one row of chrome — which is what
                    // `PaneHeader.height` is pinned for.
                    PaneHeader(title: nil) {
                        Picker("", selection: $mode) {
                            ForEach(SourceMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(!queue.canChangeMode)
                        .help("Что переводить: набранный текст или очередь файлов")
                        Spacer()
                        if mode == .text {
                            Button("Очистить") { model.sourceText = "" }
                                .buttonStyle(.link)
                                .disabled(model.sourceText.isEmpty)
                        } else {
                            Button("Добавить…", action: addFiles)
                                .buttonStyle(.link)
                                .disabled(!queue.canChangeMode)
                        }
                    }
                    if mode == .text {
                        SourceEditor(model: model)
                    } else {
                        FileQueuePane(queue: queue)
                    }
                }
                TranslationPane(title: "Перевод",
                                text: model.translatedText,
                                isRunning: model.state == .running,
                                onCopy: onCopy)
            }
            Divider()
            RunStatusBar(model: model, status: status,
                         glossaryProblem: glossary.lastProblem,
                         onMute: mute,
                         onRetry: { Task { await model.translate() } })
        }
        .frame(minWidth: 700, minHeight: 480)
        .toolbar { toolbar }
        .onChange(of: model.state) { _, new in
            // Same condition `PanelHost` uses for the hotkey path: a state that is no longer
            // `.running` is the point this window may have something new to say about whether
            // Ollama answered. It is not only translation attempts — see `onRunFinished`,
            // which names the other two writers of `state`.
            guard new != .running else { return }
            Task { @MainActor in await onRunFinished() }
        }
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
        // Neither button declares a keyboard shortcut any more, and that is the point of the
        // change rather than a side effect. ⌘↩ and ⌘. now live once, in the «Перевод» menu
        // `TranslatorApp` installs — which is where a Mac user looks for them, and which keeps
        // working when this window is not the one in front. Declaring the same equivalent in
        // two places leaves two things to keep in step and no statement about which wins.
        ToolbarItem(placement: .primaryAction) {
            if model.state == .running {
                Button("Отмена") { model.cancel() }
            } else {
                Button("Перевести") { Task { await model.translate() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!status.isHealthy)
            }
        }
    }

    /// «Добавить…» — the other way into the queue.
    ///
    /// The panel's result goes through `QueueDrop.accept` exactly as a drop does, so the
    /// two doors into the queue cannot come to accept different things: one rule, one
    /// place, checked by `QueueDropTests`.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DroppedDocument.readableExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.prompt = "Добавить"
        panel.message = "Выберите текстовые файлы для перевода"
        guard panel.runModal() == .OK, let items = QueueDrop.accept(panel.urls) else { return }
        Task { await queue.add(dropped: items) }
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
