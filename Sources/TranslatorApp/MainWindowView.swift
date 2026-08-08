// Sources/TranslatorApp/MainWindowView.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TranslationCore

/// What every mode-sensitive control does right now — one answer, read by all of them.
///
/// The toolbar's «Перевести»/«Отмена», its «Скопировать», the «Перевод» menu's ⌘↩, ⌘.,
/// ⇧⌘C and «Очистить исходник» all have to agree about which model they are driving, and in
/// «Файлы» that is not the one they were written against: every one of them reached
/// `TranslationViewModel` directly.
///
/// Each of those was a real defect, and they are worth naming because they were invisible
/// to the tests that existed. «Перевести» ran an empty text model and returned. «Отмена»
/// never appeared. «Скопировать» was lit — its `disabled` came from the *displayed* text —
/// and copied the text model's empty translation, which `GeneralPasteboard.write` drops, so
/// pressing it did nothing at all. ⇧⌘C was disabled while a translation sat on screen.
///
/// A value rather than a condition restated at each site, for `canSwapLanguages`' reason: a
/// control has to answer before it is pressed, and six restatements of one rule is six
/// places for a third mode to be forgotten.
@MainActor
struct PrimaryAction {
    let isRunning: Bool
    let canStart: Bool
    let start: () async -> Void
    let cancel: () -> Void
    let canCopy: Bool
    let copy: () async -> Void
    /// «Очистить исходник» names the *text* pane, and in «Файлы» that pane is not on
    /// screen. Repurposing the item to empty the queue would throw away translations that
    /// may not be saved yet, from a menu item with no visible counterpart — so it is simply
    /// not offered there. Rows leave the queue one at a time, through their own context menu.
    let canClear: Bool
    let clear: () -> Void

    static func forMode(_ mode: SourceMode,
                        text: TranslationViewModel,
                        queue: FileQueueModel) -> PrimaryAction {
        switch mode {
        case .text:
            PrimaryAction(
                isRunning: text.state == .running,
                canStart: !text.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                start: { await text.translate() },
                cancel: { text.cancel() },
                canCopy: !text.translatedText.isEmpty,
                copy: { await text.copyToPasteboard() },
                canClear: !text.sourceText.isEmpty && text.state != .running,
                clear: { text.sourceText = "" })
        case .files:
            PrimaryAction(
                isRunning: queue.isRunning,
                // The same statement in both modes: there is nothing to translate. An
                // `.unreadable` задание is not something to translate either — the queue
                // skips it — so it does not light the button on its own.
                canStart: queue.jobs.contains { $0.state != .finished && $0.state != .unreadable },
                // The toolbar's three pickers are drawn on this screen and must configure
                // this run. They are read from the text model because that is what the
                // toolbar binds to — one owner for those values, passed in per run.
                start: { await queue.run(source: text.sourceOverride,
                                         target: text.targetOverride,
                                         tone: text.toneOverride) },
                cancel: { queue.cancel() },
                canCopy: !queue.selectedText.isEmpty,
                copy: { await queue.copySelection() },
                canClear: false,
                clear: {})
        }
    }
}

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
    /// The ⌥⌘T panel's model. Read for one thing only: its terms sheet, which is presented
    /// here rather than in the panel — see `TranslatorApp`'s escalation.
    var panelModel: TranslationViewModel?

    /// Which half the left pane is showing.
    ///
    /// A `@Binding` and not `@State`: the «Перевод» menu's ⌘↩ and ⌘. have to drive whichever
    /// mode is visible, and a menu declared in the app's scene cannot read state that lives
    /// in this view. `TranslatorApp` owns it. Not a setting either — it is where the user is
    /// looking right now, not a preference to survive a relaunch.
    @Binding var mode: SourceMode
    /// The request the sheet is actually showing. See `termsRequest`.
    @State private var presented: DocumentTermsRequest?

    /// Every mode-sensitive control in this window reads this one value.
    private var action: PrimaryAction { .forMode(mode, text: model, queue: queue) }

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
                        // The drawing's «Файлы · 3». Only in that mode and only when there
                        // is something to count: «Файлы · 0» beside an empty pane says
                        // nothing the pane is not already saying louder.
                        if mode == .files, !queue.jobs.isEmpty {
                            Text("· \(queue.jobs.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
                // Dispatches on mode like the primary action does. Wiring this to the text
                // model in «Файлы» — or to the queue's live stream rather than its selection
                // — puts one document's text under another document's name.
                TranslationPane(title: mode == .text ? "Перевод" : queue.selectedTitle,
                                text: mode == .text ? model.translatedText : queue.selectedText,
                                isRunning: action.isRunning,
                                onCopy: { Task { await action.copy() } })
            }
            Divider()
            RunStatusBar(model: model, status: status,
                         queue: mode == .files ? queue : nil,
                         glossaryProblem: glossary.lastProblem,
                         onMute: mute,
                         onRetry: { Task { await action.start() } })
        }
        .frame(minWidth: 700, minHeight: 480)
        .toolbar { toolbar }
        // One sheet, three raisers: the window's own run, the queue's, and — through
        // `TranslatorApp` — the ⌥⌘T panel, which escalates here rather than editing text
        // fields inside a `.nonactivatingPanel`. Whichever model is asking, the surface is
        // this one; a second sheet is how two paths come to ask the same question
        // differently.
        // The setter does nothing on purpose, and `.interactiveDismissDisabled` is why it
        // can. It used to cancel `termsRequest` — re-evaluating the priority chain, which by
        // then could resolve to a *different* model's request, so a dismissal stopped a
        // translation the user never asked to stop. Now the only ways out are the sheet's
        // own button and its Esc, both of which hold the specific request they were built
        // with.
        .sheet(item: Binding(get: { termsRequest }, set: { _ in })) { request in
            DocumentTermsView(request: request,
                              showsSuppress: queue.pendingTermsRequest === request,
                              onAddToGlossary: { promoteToGlossary(request) })
                .interactiveDismissDisabled()
                .onAppear { presented = request }
                .onDisappear { if presented === request { presented = nil } }
        }
        // The queue's half of the same trigger. `onRunFinished` re-probes Ollama, and
        // nothing watched the queue: a thirteen-file run could fail every file to a dead
        // server and leave the idle line reporting the last known healthy state, with
        // «Перевести» still enabled on it.
        .onChange(of: queue.isRunning) { _, running in
            guard !running else { return }
            Task { @MainActor in await onRunFinished() }
        }
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
            // Reads `PrimaryAction` rather than `model.state`, so the button and the two
            // menu items cannot disagree about which model they drive. In «Файлы» reading
            // the text model would run an empty pane and return.
            if action.isRunning {
                Button("Отмена") { action.cancel() }
            } else {
                Button("Перевести") { Task { await action.start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!status.isHealthy || !action.canStart)
            }
        }
    }

    /// Whichever model is currently asking — but a sheet already up stays up.
    ///
    /// Three models can raise a request and there is one sheet. Without the first clause a
    /// second raiser replaces the first on screen: the panel's run would keep waiting on a
    /// continuation, with «Жду ваших правок…» showing and its sheet gone. Pinning the
    /// presented request until it is answered makes the second one queue behind it instead,
    /// and the chain picks it up as soon as the first is done.
    private var termsRequest: DocumentTermsRequest? {
        if let presented, !presented.isAnswered { return presented }
        return model.pendingTermsRequest ?? queue.pendingTermsRequest ?? panelModel?.pendingTermsRequest
    }

    /// «Добавить…» — the other way into the queue.
    ///
    /// The panel's result goes to `add(droppedURLs:)`, the same entry point a drop uses, so
    /// the two doors read and plan files by one rule. What differs is the refusal, and
    /// deliberately: see the note at the guard below.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DroppedDocument.readableExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.prompt = "Добавить"
        panel.message = "Выберите текстовые файлы для перевода"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // No `acceptable` guard here, unlike the drop. A drop that is refused springs back —
        // that is the platform's own feedback and the whole error channel the design names.
        // A file chosen in an open panel has no spring-back, so refusing it silently would
        // be a click that does nothing; it becomes a named `.unreadable` row instead,
        // exactly as an unreadable file in a mixed drop already does.
        Task { await queue.add(droppedURLs: panel.urls) }
    }

    /// «Добавить в пользовательский глоссарий» — promote the reviewed terms.
    ///
    /// Saving fails in the same three ways `mute(_:)` handles, and reuses its sentences
    /// verbatim rather than writing new ones: two spellings of one failure is how they
    /// drift. Only the subject of the first clause differs.
    private func promoteToGlossary(_ request: DocumentTermsRequest) {
        glossary.replaceEntries(GlossaryPromotion.entries(adding: request.entries,
                                                          to: glossary.glossary))
        do {
            try glossary.save()
            glossary.lastProblem = nil
        } catch GlossaryStoreError.saveBeforeLoad {
            glossary.lastProblem = "Глоссарий не был прочитан, поэтому новые термины не сохранены. "
                + "Они действуют только до перезапуска."
        } catch GlossaryStoreError.fileChangedOnDisk {
            glossary.lastProblem = "Файл глоссария изменился на диске после запуска приложения, "
                + "поэтому новые термины не сохранены — иначе ваши правки были бы затёрты. "
                + "Они действуют только до перезапуска; перезапустите приложение, чтобы прочитать новую версию."
        } catch {
            glossary.lastProblem = "Не удалось сохранить глоссарий, новые термины действуют только "
                + "до перезапуска: \(error.localizedDescription)"
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
