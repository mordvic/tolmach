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
    /// ⇄. The last of the mode-sensitive controls to be routed through here, and it was
    /// the most destructive of them: in «Файлы» its `disabled` read the *text* model, so it
    /// stayed live mid-queue-run and `swapLanguages()` moved that model's translation into
    /// its source pane — off screen, with nothing to undo it.
    let canSwap: Bool
    let swap: () -> Void

    static func forMode(_ mode: SourceMode,
                        text: TranslationViewModel,
                        queue: FileQueueModel) -> PrimaryAction {
        switch mode {
        case .text:
            PrimaryAction(
                isRunning: text.state == .running,
                // Not while the queue is running: one model lives in Ollama's memory, and
                // the mode switch no longer stands between the user and a second run.
                canStart: !text.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !queue.isRunning,
                start: { await text.translate() },
                cancel: { text.cancel() },
                canCopy: !text.translatedText.isEmpty,
                copy: { await text.copyToPasteboard() },
                canClear: !text.sourceText.isEmpty && text.state != .running,
                clear: { text.sourceText = "" },
                canSwap: text.canSwapLanguages,
                swap: { text.swapLanguages() })
        case .files:
            PrimaryAction(
                isRunning: queue.isRunning,
                // The same statement in both modes: there is nothing to translate. Asked of
                // the model rather than restated here — `hasWorkLeft`'s own doc comment
                // promises this button and the stop-on-warnings pause cannot disagree, and
                // a copy of the condition is how a seventh `FileJob.State` gets remembered
                // in one place and forgotten in the other.
                canStart: queue.hasWorkLeft && text.state != .running,
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
                clear: {},
                // The pickers are all there is to exchange here, and exchanging them must
                // not touch the text model's panes: they are not on screen.
                canSwap: text.canSwapOverrides && !queue.isRunning,
                swap: { text.swapOverrides() })
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

    /// Looking is always allowed. **Starting** is what must not happen twice.
    ///
    /// This used to require both models idle, so that switching away from a run could not be
    /// followed by «Перевести» starting a second one against the one model Ollama holds.
    /// That prevented the right thing in the wrong place, and it made a trap in each
    /// direction: a running queue locked the user out of «Текст» — including the pane
    /// «Открыть в окне» had just handed a translation to — and a running text translation
    /// locked them out of watching the queue.
    ///
    /// The rule belongs on the action, not on the view: `PrimaryAction.canStart` now refuses
    /// while *either* model is running, so switching is free and starting is still single.
    /// «Добавить…» keeps its own guard, because adding to a queue mid-run is a different
    /// question and `FileQueueModel.canChangeMode` is the one that answers it.

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
                        .help("Что переводить: набранный текст или очередь файлов")
                        // The drawing's «Файлы · 3». Only in that mode and only when there
                        // is something to count: «Файлы · 0» beside an empty pane says
                        // nothing the pane is not already saying louder.
                        // `translatable`, not `jobs`: `statusLine` right below counts the
                        // same way, and counting `.unreadable` rows here put «Файлы · 5»
                        // directly above «Перевожу 1-й файл из 3» — two counts for one
                        // queue, on screen at once.
                        if mode == .files, queue.translatableCount > 0 {
                            Text("· \(queue.translatableCount)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode == .text {
                            // Through `PrimaryAction`, like the menu item it mirrors. Read
                            // directly, this button stayed live during a run while «Очистить
                            // исходник» in the menu was disabled — so it emptied the editor
                            // under a translation still streaming into the pane beside it,
                            // with no undo. That is the gap the type was introduced to close.
                            Button("Очистить", action: action.clear)
                                .buttonStyle(.link)
                                .disabled(!action.canClear)
                        } else {
                            Button("Добавить…", action: addFiles)
                                .buttonStyle(.link)
                                .disabled(!queue.canChangeMode)
                        }
                    }
                    if mode == .text {
                        SourceEditor(model: model)
                    } else {
                        FileQueuePane(queue: queue, canStart: status.isHealthy && action.canStart)
                    }
                }
                // Dispatches on mode like the primary action does. Wiring this to the text
                // model in «Файлы» — or to the queue's live stream rather than its selection
                // — puts one document's text under another document's name.
                TranslationPane(title: mode == .text ? "Перевод" : queue.selectedTitle,
                                text: mode == .text ? model.translatedText : queue.selectedText,
                                isRunning: mode == .text ? action.isRunning : queue.selectedIsRunning,
                                onCopy: { Task { await action.copy() } })
            }
            Divider()
            RunStatusBar(model: model, status: status,
                         queue: mode == .files ? queue : nil,
                         glossaryProblem: glossary.lastProblem,
                         onMute: mute,
                         onRetry: { Task { await action.start() } })
        }
        // 840, not the drawing's 700, and the extra 140 pt is the drawing being wrong about
        // this rather than the app being greedy. The drawing's toolbar is 22 pt-tall pills
        // sized to the string showing; a real `NSPopUpButton` is as wide as its widest menu
        // item and sits in a macOS toolbar at the platform's own control size. Swept with
        // `Scripts/toolbar-fit.swift`, this row needs 830 pt before `NSToolbar` stops pushing
        // items into the » overflow — and the first thing it pushes is «Перевести».
        //
        // A minimum that guarantees the primary action is hidden is not a minimum worth
        // keeping. 840 is the measured 830 plus one step of the sweep, because the threshold
        // depends on the system font and on the longest language name, and both can move.
        // `.controlSize` is deliberately **not** used to buy the difference: measured at 10 pt
        // between the toolbar default and `.regular`, which is not worth leaving the
        // platform's own metrics for.
        .frame(minWidth: 840, minHeight: 480)
        .toolbar { toolbar }
        // The window's title is **not** drawn, and the drawing is deliberate about it: every
        // settings pane in it has a centred title bar of its own, and the main window has
        // none — the toolbar is full, and «Толмач» in the middle of it says nothing the menu
        // bar's own glyph does not.
        //
        // Without this it is not merely present, it is *interleaved*: macOS lays the title
        // out after the `.navigation` group, so «Толмач» appeared between the tone picker and
        // «Перевести», reading as a fourth control. Adding the three labels above makes that
        // row wider still, which is what turned this from a cosmetic difference into one
        // worth reaching into AppKit for.
        .background(WindowTitleHidden())
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
        // `termsRequest` is read **here**, in `body`, and the binding hands back the value
        // that read produced. Reading it only inside the getter leaves the observation of
        // three different `@Observable` models to whenever SwiftUI happens to invoke that
        // getter, which is a presentation-update detail this environment cannot render and
        // check — and if it does not register, the failure is the one
        // `DocumentTermsRequest` exists to prevent: a run on a continuation with no sheet
        // on screen. The sharp case is the second and third sheet of a queue run with the
        // window already open and frontmost, where the escalation's `openWindow` and
        // `activateThisApp()` change nothing and cannot force the update.
        .sheet(item: Binding(get: { [request = termsRequest] in request }, set: { _ in })) { request in
            DocumentTermsView(request: request,
                              showsSuppress: queue.pendingTermsRequest === request,
                              onAddToGlossary: { promoteToGlossary(request) })
                .interactiveDismissDisabled()
                .onAppear { presented = request }
                .onDisappear {
                    // Clears the pin and **does not cancel**. It used to cancel here, as
                    // insurance against a sheet taken away without an answer — and that
                    // turned an ordinary action into a silent kill: ⌘W tears down this
                    // view, so closing the window during a queue's review interrupted the
                    // file and abandoned the eleven behind it. `TranslatorApp.launch()`
                    // says the opposite in as many words, that ⌘W during a run is survivable.
                    //
                    // The insurance was not needed either. `termsRequest` reads the models'
                    // own `pendingTermsRequest`, which outlives this view, and `presented`
                    // is `@State` that dies with it — so a reopened window finds the request
                    // still waiting and presents it again. What remains unverifiable from
                    // here is whether SwiftUI re-presents without the window being closed
                    // and reopened; `docs/OPEN-ITEMS.md` carries that.
                    if presented === request { presented = nil }
                }
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
        // **Each label travels with its control, in one toolbar item.**
        //
        // A `ToolbarItemGroup`'s children are separate toolbar items, not one — measured:
        // the group below used to produce 8 items and now produces 5. That is not
        // bookkeeping. macOS spaces items apart and overflows them one at a time, so seven
        // loose children meant «Из» sat a toolbar gap away from the pop-up it names, and a
        // narrow window could push the pop-up into the » overflow and leave its label behind
        // on the bar.
        //
        // It is also 60 pt of width. `Scripts/toolbar-fit.swift` sweeps the window and asks
        // `NSToolbar.visibleItems` when everything is on screen: 960 pt loose against 900 pt
        // paired, and 830 pt paired once the longest language name stopped carrying a
        // parenthetical (see `Language.russianName`). The window opens at 900, so the loose
        // arrangement hid «Перевести» in the overflow **at the default size** — the state the
        // screenshot that prompted this caught.
        ToolbarItem(placement: .navigation) {
            // **The label is drawn, not declared.** A `Picker`'s own title is not rendered
            // inside a toolbar — SwiftUI keeps it only as the accessibility label — so this
            // row shipped as three unlabelled pop-ups reading «Определить», «По правилу»,
            // «По умолчанию», with nothing on screen saying which chose the source, which the
            // target and which the tone. No reading of the source could catch it: the code
            // says `Picker("Из", …)` in plain sight.
            //
            // `.labelsHidden()` keeps that title as the accessibility label, so VoiceOver
            // still says «Из» and does not meet the word twice.
            //
            // 6 pt inside the pair against the toolbar's own spacing between items — the
            // contrast is what makes a label read as belonging to the control beside it.
            HStack(spacing: 6) {
                Text("Из").foregroundStyle(.secondary)
                // `russianName`, not `shortCode`. The settings name these languages in words
                // and this window used to name them in codes — one vocabulary under two
                // names, which is exactly what `CONTEXT.md` exists to prevent. It is also why
                // the width problem above was solved by shortening one name rather than by
                // going back to «RU»/«EN» here.
                Picker("Из", selection: $model.sourceOverride) {
                    Text("Определить").tag(Language?.none)
                    ForEach(Language.allCases, id: \.self) {
                        Text($0.russianName).tag(Language?.some($0))
                    }
                }
                .labelsHidden()
            }
        }
        ToolbarItem(placement: .navigation) {
            Button {
                action.swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(!action.canSwap)
            .help("Перевести в обратную сторону")
        }
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Text("В").foregroundStyle(.secondary)
                Picker("В", selection: $model.targetOverride) {
                    Text("По правилу").tag(Language?.none)
                    ForEach(Language.allCases, id: \.self) {
                        Text($0.russianName).tag(Language?.some($0))
                    }
                }
                .labelsHidden()
            }
        }
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Text("Тон").foregroundStyle(.secondary)
                Picker("Тон", selection: $model.toneOverride) {
                    Text("По умолчанию").tag(Tone?.none)
                    ForEach(Tone.allCases, id: \.self) {
                        Text($0.russianName).tag(Tone?.some($0))
                    }
                }
                .labelsHidden()
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
                                                          to: glossary.glossary,
                                                          target: request.draft.target))
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

/// Hides the window's *displayed* title without emptying `NSWindow.title`.
///
/// **Setting it once does not hold in this app — measured on the running bundle.**
/// `viewDidMoveToWindow` fires with the window present, the assignment lands
/// (`titleVisibility` reads `1` immediately after), and by the next sample it is `0` again
/// with `_NSToolbarTitleField` visible at 60 × 19. Polled every 400 ms for 2.4 s on one
/// window: `1` at the assignment, `0` at all six samples after. With the three re-assertions
/// below, the same instrumentation reads `1` and zero visible title fields at all five
/// samples over 3 s.
///
/// **What resets it is not established, and this comment does not pretend otherwise.**
/// `Scripts/window-title.swift` reproduces the app's scene shape — accessory policy,
/// `MenuBarExtra` before the `Window`, a full `.navigation` group, `.defaultSize`, and state
/// read in the *scene* body so the window is reconfigured repeatedly — and in that probe a
/// single assignment survives. So the reset needs something this app has and that probe does
/// not, and the difference has not been isolated. Three suspects were tested and cleared:
/// saved-window-state restoration (no saved state existed), `.defaultSize`, and view-level
/// churn. The fix is therefore re-assertion rather than a better first assignment, and it is
/// verified where it matters — on the app, not on the probe. **A reader tempted to delete two
/// of the three as redundant should re-instrument the bundle rather than re-run the probe:
/// the probe will say all three are unnecessary, and it is wrong.**
///
/// `titleVisibility` and not `.navigationTitle("")`, and *this* choice the probe does settle:
/// both remove the drawn title, but `navigationTitle("")` leaves `NSWindow.title` empty while
/// this leaves it «Толмач». The title string is what the «Окно» menu lists the window under —
/// a menu this app deliberately adds «Открыть окно перевода» to — as well as what Mission
/// Control and VoiceOver announce.
///
/// `docs/PLATFORM-TRAPS.md` carries both findings.
private struct WindowTitleHidden: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TitleHidingView() }

    /// The second of the three. Empty in the first version of this type, which is most of why
    /// it did not work.
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.titleVisibility = .hidden
    }

    private final class TitleHidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Dropped before re-adding: this fires again whenever the view changes windows —
            // a full-screen transition replaces the window — and registering per window
            // without this leaves one observation per transition, all firing.
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didUpdateNotification, object: nil)
            guard let window else { return }
            window.titleVisibility = .hidden
            NotificationCenter.default.addObserver(
                self, selector: #selector(reassert(_:)),
                name: NSWindow.didUpdateNotification, object: window)
        }

        /// Re-asserting inside an update notification does not recurse: assigning the value it
        /// already holds is a no-op, so the update this could provoke is only ever the first
        /// one. Checked by running the probe to completion rather than by reading the header —
        /// a loop here would have hung it.
        @objc private func reassert(_ note: Notification) {
            (note.object as? NSWindow)?.titleVisibility = .hidden
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
