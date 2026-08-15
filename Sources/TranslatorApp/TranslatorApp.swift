// Sources/TranslatorApp/TranslatorApp.swift
import SwiftUI
import OllamaKit
import TranslationCore
import TextCapture

@main
struct TranslatorApp: App {
    /// Read here rather than only in `MenuContent`, because the panel's «Открыть в окне» has
    /// nowhere else to get it: the panel is hosted in a detached `NSHostingView`, which has no
    /// scene environment to inherit. `@Environment` on an `App` is the documented shape (it is
    /// how `scenePhase` is read), and this is verified in the live pass rather than assumed.
    @Environment(\.openWindow) private var openWindow
    // Built once in `init` and handed to `State` explicitly, because `@State`'s
    // declaration-site initialisers cannot reference each other and the view model needs
    // the very same settings and glossary the rest of the app reads. Two `AppSettings`
    // would each track their own observation: a change made in the menu bar would not
    // reach the window, and the view model would translate with stale settings.
    @State private var settings: AppSettings
    @State private var glossary: GlossaryStore
    @State private var statusModel: OllamaStatusModel
    @State private var translation: TranslationViewModel
    /// The file queue — the window's third model, beside its own `translation` and the
    /// panel's inside `coordinator`.
    ///
    /// Owned here for the reason the other two are: the app owns the models and the scenes
    /// read them. One run per model with a per-instance guard is what keeps the three from
    /// overwriting each other, and it only holds while nobody builds a second copy.
    @State private var queue: FileQueueModel
    /// Owned here rather than created inside the settings pane so the installed list and a
    /// download in progress survive the settings window being closed and reopened.
    @State private var models: ModelsViewModel
    /// The **only** `OllamaClient` this process builds, and therefore the only `URLSession`.
    ///
    /// It backs all five things that talk to Ollama: both view models' translations through
    /// `Translator`, `warmUp()`, the health probe behind the menu-bar glyph, the installed and
    /// resident lists in «Модели», and model downloads. Sharing it is what the doc comment here
    /// always claimed — see `init`, which carries what was actually happening instead.
    @State private var client: OllamaClient
    /// The hotkey path, which owns a `TranslationViewModel` of its own — see the comment on
    /// `HotkeyCoordinator.panelModel`. It shares this app's `settings`, `glossary` and
    /// `client`; only the view model is separate.
    @State private var coordinator: HotkeyCoordinator
    /// Built here rather than on first press so that a press never pays for an `NSPanel` and
    /// an `NSHostingView` before it can show anything.
    @State private var panel: PanelController
    /// Which half of the window's left pane is showing.
    ///
    /// Owned here rather than inside `MainWindowView`, and that is not tidying: the
    /// «Перевод» menu's ⌘↩ and ⌘. must drive whichever mode is visible, and a menu built in
    /// this scene cannot read a `@State` declared in that view. The window binds to it.
    @State private var mode: SourceMode = .text

    init() {
        let settings = AppSettings()
        let glossary = GlossaryStore()
        // Read the user's glossary before anything in the app can write it. `save()` is
        // gated on a successful `load()`, so a failure here is contained rather than
        // compounded: `isLoaded` stays false, «не показывать» refuses to persist, and the
        // file the user still has on disk cannot be overwritten by this session. The
        // failure is recorded instead of swallowed — starting silently blank would tell
        // the user their glossary is empty when it is merely unread.
        do {
            try glossary.load()
        } catch {
            glossary.lastProblem = "Не удалось прочитать глоссарий, перевод идёт без него. "
                + "Файл на диске не изменён: \(error.localizedDescription)"
        }
        // One client for the whole process, and it has to be built before anything that talks
        // to Ollama rather than after.
        //
        // The comment on `client` above has said since it was written that it is shared «so
        // `warmUp()` can reuse it instead of standing up a second `URLSession` for one request
        // at launch». That was true of `warmUp()` and false of the app: `OllamaStatusModel()`
        // and `ModelsViewModel()` each defaulted to a `LiveOllamaProbe` that built an
        // `OllamaClient` of its own, and `ModelsViewModel`'s default puller built **another one
        // per download**. Three sessions at launch, and one more every time a model is pulled,
        // under a comment explaining why there is one.
        //
        // The defaults stay where they are — they are what lets a test construct either model
        // without an Ollama — but nothing in the app takes them now.
        let client = OllamaClient()
        let statusModel = OllamaStatusModel(probe: LiveOllamaProbe(client: client))
        let translation = TranslationViewModel(
            translator: Translator(client: client),
            settings: settings,
            glossary: glossary)
        // A second `Translator` over the *same* client. `Translator` is a value with no state
        // beyond the client, so this costs nothing and keeps the two view models independent;
        // sharing the client is what matters, because it is what holds the `URLSession`.
        let coordinator = HotkeyCoordinator(settings: settings, glossary: glossary,
                                            translator: Translator(client: client))
        // A third `Translator` over the same client, for the same reason as the second.
        // The save closure is where the queue meets the filesystem, and it is injected
        // rather than reached for inside the runner so a test can run a whole queue
        // without writing anything.
        let queue = FileQueueModel(
            translator: Translator(client: client), settings: settings, glossary: glossary,
            // The target comes from the model, which knows what the run resolved. Working
            // it out here re-detected the text and applied the settings rule, so a toolbar
            // override was ignored and a German translation was written as «a.ru.md».
            // Detached: this is where the file system is actually touched, and the model
            // deliberately does not do it on the actor its rows are drawn from.
            save: { source, text, target in
                await Task.detached(priority: .userInitiated) {
                    TranslatedFileWriter.write(text, beside: source, target: target)
                }.value
            },
            saveAs: { text, url in
                await Task.detached(priority: .userInitiated) {
                    TranslatedFileWriter.write(text, to: url)
                }.value
            })
        _settings = State(initialValue: settings)
        _glossary = State(initialValue: glossary)
        _statusModel = State(initialValue: statusModel)
        _translation = State(initialValue: translation)
        _queue = State(initialValue: queue)
        // Both halves of this take the shared client: the probe behind the installed and
        // resident lists, and the puller behind «Скачать». `OllamaClient` is a `Sendable`
        // struct — `LLMClient` requires it — so the closure may capture it.
        _models = State(initialValue: ModelsViewModel(
            probe: LiveOllamaProbe(client: client),
            puller: { model in client.pull(model: model) }))
        _client = State(initialValue: client)
        _coordinator = State(initialValue: coordinator)
        // Content is a placeholder until `configurePanel()` runs at launch. Everything the
        // real content needs — the panel itself, for «закрыть», and `openWindow` — either
        // does not exist yet here or is not readable outside a scene, and the panel is never
        // ordered in before that point.
        _panel = State(initialValue: PanelController { _ in AnyView(EmptyView()) })
    }

    var body: some Scene {
        // Scene order is load-bearing — do not "tidy" the `Window` back to the top.
        // SwiftUI opens the *first* window-bearing scene at launch, so declaring `Window`
        // first made this `LSUIElement` utility pop a 900x492 window on every login.
        // With `MenuBarExtra` first, nothing opens at launch and the menu's
        // «Открыть окно перевода» still reaches the window via `openWindow(id:)`.
        // (`Scene.defaultLaunchBehavior(.suppressed)`, the declarative fix, is macOS 15+
        // and the platform floor here is macOS 14.)
        MenuBarExtra {
            MenuContent(status: statusModel.status)
        } label: {
            // The `MenuBarExtra(_:systemImage:)` convenience initialiser this used to be
            // takes no view, and `warmUp()` needs one to hang a `.task` on — this label is
            // the only thing the app renders at launch. Its title argument was only ever an
            // accessibility label, so that is restored explicitly rather than dropped.
            //
            // `statusModel.status` is read here, not hard-coded, so this glyph is the same
            // "the app renders it at scene-body-evaluation time" pattern the `Window` and
            // `Settings` scenes below already rely on for their own `status:` arguments —
            // there is no second reactivity mechanism to keep in step with those.
            Image(systemName: statusModel.status.menuBarSymbol)
                .accessibilityLabel("Толмач")
                .task { await launch() }
        }

        Window("Толмач", id: TranslatorApp.mainWindowID) {
            MainWindowView(model: translation,
                           glossary: glossary, status: statusModel.status,
                           onRunFinished: {
                               await statusModel.refresh(interactiveModel: settings.interactiveModel)
                           },
                           queue: queue, panelModel: coordinator.panelModel, mode: $mode)
                .task { await statusModel.refresh(interactiveModel: settings.interactiveModel) }
        }
        // The drawing's number, and it is the drawing's for a reason: every main-window state
        // in the design is 900×520, and the two panes were drawn against that width — 450 pt
        // each in «Текст», which is what makes a 900-character часть fit without wrapping into
        // a column. Undeclared, SwiftUI picked its own: the comment above records a 900x492
        // window, so the height was 28 pt short and the split was never stated at all.
        //
        // `minWidth`/`minHeight` stay on `MainWindowView` and are **not** the same statement:
        // 700×480 is how small the user may drag this window, and this is how big it opens the
        // first time. A default is remembered per window afterwards, so this governs the first
        // launch and every fresh window state, not what the user has since resized to.
        .defaultSize(width: 900, height: 520)
        // **Twelve points of chrome, measured, for nothing given up.** The toolbar band —
        // `frame.height - contentLayoutRect.height` — is 52 pt under `.unified` and **40**
        // under `.unifiedCompact`, and the row still fits from the same width in both, so the
        // narrowest window that keeps «Перевести» out of the » overflow does not move.
        //
        // It is also the style this window actually is. `.unifiedCompact` puts the title on
        // the toolbar's own row rather than above it, and this window draws no title at all —
        // see `WindowTitleHidden`. `.unified` was reserving a line for something that is not
        // there.
        //
        // `.controlSize` is **not** the lever and was measured not to be: the band stays 52 at
        // `.regular`, `.small` and `.mini` alike, while the controls inside it shrink from 26
        // to 24 to 21 — smaller controls floating in an unchanged band, which is worse than
        // where this started. Same conclusion the toolbar's width reached, for a different
        // reason.
        .windowToolbarStyle(.unifiedCompact)
        // The app had no commands at all, and SwiftUI's defaults for this scene combination
        // are not a menu bar anyone would design. Measured on a copy of these three scenes at
        // `.accessory` activation policy, dumping `NSApp.mainMenu`: «Вид» is installed and
        // **empty**, «Справка» carries a help-book item this app has no help book for, and the
        // three actions a user actually performs — перевести, отменить, скопировать — appear
        // nowhere, so they exist only as buttons inside a window that is usually closed.
        //
        // Every equivalent below is declared here and **only** here. The window's toolbar used
        // to carry ⌘↩ and ⌘. itself; it no longer does.
        .commands {
            // Both of these remove rather than add. `.sidebar` is what puts the empty «Вид»
            // there — this window is an `HSplitView`, which has no sidebar to toggle — and
            // `.help` opens a help book that does not exist, so the menu it heads is a menu
            // whose every item does nothing.
            CommandGroup(replacing: .sidebar) { }
            CommandGroup(replacing: .help) { }

            CommandMenu("Перевод") {
                // Disabled while a run is in flight, which is also what keeps this from
                // fighting the panel. `TranslationPanel` has its own ⌘. on its «Отмена», and
                // a *disabled* menu item does not consume its equivalent — it declines, and
                // the key window's own handler gets it. So a hotkey run being cancelled while
                // this window sits idle reaches the panel, not this. That the fall-through
                // happens in that order is the one part of this block a physical key press
                // still has to confirm; `docs/OPEN-ITEMS.md` §1 carries it.
                //
                // Both items read `PrimaryAction`, the same value the toolbar button reads,
                // so the three cannot disagree about which model they drive. Before this,
                // all three called `translation` directly and «Файлы» had no way to start
                // or stop a queue at all.
                //
                // The ⌘. argument above still holds and its condition is unchanged in
                // spirit: the item is disabled unless the **visible mode** is running, so a
                // window sitting idle in either mode still declines ⌘. and lets the panel
                // have it. What changed is that «running» now means the visible mode's run
                // rather than the text model's.
                let action = PrimaryAction.forMode(mode, text: translation, queue: queue)
                Button(action.startTitle) { Task { await action.start() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(action.isRunning || !action.canStart || !statusModel.status.isHealthy)
                Button("Отмена") { action.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!action.isRunning)

                Divider()

                // ⌃⌘S rather than anything with ⌥: the toolbar's ⇄ is the discoverable half
                // and this is the shortcut for it, and ⌥-combinations are where the system's
                // own reserved space is thickest.
                Button("Поменять языки местами") { action.swap() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .disabled(!action.canSwap)

                Divider()

                // ⇧⌘C, not ⌘C: plain ⌘C belongs to «Правка» → «Скопировать» and must keep
                // working on a selection inside the source editor. This copies the whole
                // translation, which is a different action and deserves a different key.
                // Both read the same `PrimaryAction` the toolbar does. Before this ⇧⌘C was
                // disabled by the *text* model's emptiness while a file's translation sat on
                // screen, and «Очистить исходник» acted on a pane that was not visible.
                Button("Скопировать перевод") { Task { await action.copy() } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!action.canCopy)
                Button("Очистить исходник", action: action.clear)
                    .disabled(!action.canClear)
            }

            // In «Окно», beside the window list, because that is what it does. It duplicates
            // the menu-bar item deliberately: the menu bar is the only route in today, and it
            // is the one surface that disappears if the user ever hides the status item.
            CommandGroup(after: .windowList) {
                Button("Открыть окно перевода") {
                    openWindow(id: TranslatorApp.mainWindowID)
                    activateThisApp()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        // Declared last for the same reason `Window` is not first: whatever SwiftUI counts
        // as a window-bearing scene, the one it may open at launch is the first, and that
        // has to stay the `MenuBarExtra`.
        Settings {
            // `Label` and not `Image`, so the tab bar keeps its words as well as gaining
            // glyphs. That is what a macOS settings toolbar is — Mail, Safari and Xcode all
            // draw the icon above its title — and it is the shape `.tabItem` was built for.
            // Icon-only would leave three unlabelled glyphs to guess at, and would need an
            // `accessibilityLabel` on each or VoiceOver would read the English symbol name
            // out of a window whose every other string is Russian.
            //
            // All three symbols are SF Symbols 2, i.e. macOS 11, so they are available at
            // this project's macOS 14 floor with room to spare and need no `#available`.
            // `shippingbox` for «Модели» because that pane is about what has been pulled and
            // what is on disk, not about inference; `book.closed` for «Глоссарий» because the
            // dictionary-shaped `character.book.closed` is SF Symbols 4 and buys nothing here.
            TabView {
                SettingsGeneralView(settings: settings)
                    .tabItem { Label("Основные", systemImage: "gearshape") }
                SettingsModelsView(settings: settings, models: models,
                                   status: statusModel.status,
                                   onRefresh: {
                                       await statusModel.refresh(
                                           interactiveModel: settings.interactiveModel)
                                   })
                    .tabItem { Label("Модели", systemImage: "shippingbox") }
                SettingsGlossaryView(glossary: glossary, settings: settings)
                    .tabItem { Label("Глоссарий", systemImage: "book.closed") }
                SettingsFilesView(settings: settings, models: models)
                    .tabItem { Label("Файлы", systemImage: "doc.on.doc") }
            }
            // «Модели» now shows Ollama's health line, which this scene's own `Window` also
            // shows independently — so the pane needs its own initial check rather than
            // relying on the main window having opened first.
            .task { await statusModel.refresh(interactiveModel: settings.interactiveModel) }
        }
    }

    // MARK: - The hotkey path

    /// Everything this app does at launch, in the order it has to happen.
    ///
    /// The hotkey is registered **before** the warm-up, which is not what Task 10's brief
    /// said. `warmUp()` awaits a real HTTP request whose `timeoutIntervalForRequest` is 120
    /// seconds (`OllamaClient.swift:33`), so registering after it would leave the app's only
    /// shortcut dead for as long as Ollama takes to answer — two seconds on a cold model,
    /// and two *minutes* if Ollama accepts the connection and then never replies. Registration
    /// is synchronous and takes no I/O, so there is nothing to gain by deferring it.
    private func launch() async {
        configurePanel()
        // Whoever raises a terms sheet needs the window that presents it. Set here, from a
        // scene that is always alive, rather than observed from the window's own content —
        // that content does not exist while the window is closed, which is the app's normal
        // state, and the sheet would then appear nowhere at all.
        //
        // All three raisers get it: the window's own model too, because ⌘W during a run
        // leaves it in the same position as the other two.
        let present = { openWindow(id: TranslatorApp.mainWindowID); activateThisApp() }
        translation.onTermsRequested = present
        queue.onTermsRequested = present
        coordinator.panelModel.onTermsRequested = present
        pruneEmptyMenus()
        // The refusal still raises nothing on screen, and that part is unchanged: a
        // user-visible message needs UI that does not exist yet. What it no longer does is
        // vanish — but the message no longer lives here either. It moved into
        // `HotkeyCoordinator.apply`, which is where both registration paths meet: this call
        // registers two combinations now, and `refreshRegistration()` — the path a user
        // actually reaches, by choosing a combination another program holds — had no logging
        // at all while it lived here. The two operations also log at different levels, and
        // only `apply` knows which one it is failing.
        //
        // Both registrations are still expected to succeed: `AppSettings` guarantees a valid
        // combination for each, and the only other failure is -9878 for a combination another
        // component of this process already holds.
        coordinator.start(onPress: { operation in
            // The pointer is sampled *here*, at the press, and used after the capture. The
            // read can take up to three quarters of a second and the user's hand is still on
            // the mouse; the panel belongs where they were looking when they pressed.
            let cursor = NSEvent.mouseLocation
            // Hidden before the capture and shown after it, never before. The brief said
            // before; doing that breaks the capture outright, because the panel becomes the
            // key window and the system-wide accessibility focus follows it — see the
            // comment in `HotkeyCoordinator.handlePress`, which carries the measurement.
            Task {
                await coordinator.handlePress(operation: operation,
                                              willCapture: { panel.hide() },
                                              afterCapture: { panel.show(at: cursor) })
            }
        })
        observeHotkeyChanges()
        // Spec 6.1's onboarding, in the only shape an `LSUIElement` app can offer it: there is
        // no window at launch to put a screen in, so the system's own dialog is the screen.
        //
        // Prompted once, at first launch only. `requestTrust()` shows the system dialog;
        // asking again on every launch would be nagging, and the standing indicator in
        // Settings plus the panel's own prompt already cover the user who declined.
        //
        // The latch is set *before* the call, not after: `requestTrust` returns the state
        // before the user answers, so there is no success to condition on, and a crash between
        // the two would otherwise put the dialog back on the next launch.
        //
        // After the hotkey registration, so nothing about the modal delays the app's only
        // shortcut becoming live; before `warmUp()`, which awaits a request that can take two
        // minutes to time out.
        if !settings.hasRequestedAccessibility {
            settings.hasRequestedAccessibility = true
            PermissionsGate.requestTrust()
        }
        // Ahead of `warmUp()`, not after — corrected from an earlier version of this method
        // that put it last for `OllamaProbe.ps()`'s residency accuracy. That reasoning named a
        // benefit `menuBarSymbol` cannot receive: the glyph maps *both* `.running` cases to the
        // same symbol (see its doc comment), so residency only ever changes `status.label`'s
        // text, never the icon. What refreshing after `warmUp()` actually costs is the glyph's
        // *first* honest reading: `warmUp()` awaits a request whose timeout is 120 seconds
        // (`OllamaClient.swift:33`) — the same hazard the comment above this one registers the
        // hotkey ahead of — so an Ollama that accepts the connection and then never answers
        // would leave `.unknown` (which reads as the healthy glyph) on screen for up to two
        // minutes, which is the one situation this indicator exists to reveal. Refreshing first
        // still costs something, just not to the glyph: if `warmUpOnLaunch` is about to make the
        // model resident, `status.label`'s text can read "не загружена" for a few seconds until
        // the next refresh trigger corrects it — text-only, and already inside the staleness
        // `menuBarSymbol`'s doc comment accepts.
        await statusModel.refresh(interactiveModel: settings.interactiveModel)
        await warmUp()
    }

    /// Removes the top-level menus SwiftUI installs with nothing inside them.
    ///
    /// `CommandGroup(replacing:)` empties a group; it does **not** take away the menu that
    /// held it. Measured on a copy of this app's three scenes carrying the same `.commands`
    /// block: «Вид» and «Справка» both survive as titles with zero items — «Вид» was already
    /// empty before any of this, since an `HSplitView` has no sidebar to toggle, and «Справка»
    /// becomes empty once the help-book item this app has no help book for is replaced. Two
    /// headings that open onto nothing are worse than the one dead item they replace.
    ///
    /// Done in AppKit because SwiftUI offers no way to say it. Three things were measured
    /// before settling on this shape, all on that same probe:
    ///
    /// - the menu is **fully built by the time this `.task` first runs** — `NSApp.mainMenu`
    ///   already holds all six items at t=0 — so this needs no sleep in front of it, and does
    ///   not have one;
    /// - the removal **sticks**: no empty menu had come back 2.5 s later;
    /// - it removes exactly «Справка» and «Вид», and nothing else — every other top-level menu
    ///   here has items.
    ///
    /// Written as «remove whatever is empty» rather than «remove these two by title», because
    /// a title is the one thing about a system menu that is localised: this app now declares
    /// `ru`, so those two are «Вид» and «Справка» here and would be «View» and «Help» in a
    /// process that did not.
    @MainActor
    private func pruneEmptyMenus() {
        guard let main = NSApp.mainMenu else { return }
        // Reversed, so removing by index cannot shift an item this loop has not reached yet.
        for item in main.items.reversed() where item.submenu?.items.isEmpty == true {
            main.removeItem(item)
        }
    }

    /// Re-registers when the user changes either shortcut in settings.
    ///
    /// Observation rather than the brief's other suggestion — «a simple comparison on each
    /// panel show» — because that one cannot work: after a change the *old* combination is
    /// still the registered one, so the user presses the new one, nothing happens, and the
    /// comparison that would have fixed it never runs. The re-registration has to happen
    /// without a press.
    ///
    /// `withObservationTracking` and not `Observations`, which is macOS 26 and this app's
    /// floor is 14. It is one-shot, so the callback re-arms; and its `onChange` fires
    /// *before* the new value is stored, so the re-read happens on a later turn of the main
    /// actor rather than inside the callback, where `settings.hotkey` would still be the old
    /// combination.
    ///
    /// Both properties are read in the one tracking block, so a single callback re-arms for
    /// both — and `refreshRegistration()` re-registers only the one that actually moved.
    private func observeHotkeyChanges() {
        withObservationTracking {
            _ = settings.hotkey
            _ = settings.proofreadHotkey
        } onChange: {
            Task { @MainActor in
                coordinator.refreshRegistration()
                observeHotkeyChanges()
            }
        }
    }

    /// The panel's content and its two key actions, wired once at launch.
    ///
    /// Not in `init()`: the actions need the `PanelController` itself, which cannot be
    /// referenced while it is being constructed, and «Открыть в окне» needs `openWindow`,
    /// which is only readable from inside a scene.
    private func configurePanel() {
        // A builder rather than a view: the controller builds the content twice over, once to
        // measure and once to install, and the two are not the same view — see
        // `PanelContentVariant`.
        panel.setContentBuilder { variant in
            AnyView(PanelHost(
                coordinator: coordinator,
                windowModel: translation,
                scrolls: variant.scrolls,
                fillsPanel: variant.fillsPanel,
                // Copying does not close. Enter is the shortcut that means «скопировать и
                // закрыть» (spec 7.2); the button is for a user who wants to keep reading.
                onCopy: { Task { await coordinator.copyResult() } },
                onOpenInWindow: { handOffToWindow() },
                // The panel's own ⨯, which exists because dropping `.titled` from the style
                // mask took the standard close button with it. Same two steps as Esc.
                onClose: {
                    coordinator.panelModel.cancel()
                    panel.hide()
                },
                onGrantPermission: {
                    // Both, and in this order. `requestTrust` is what actually puts this app
                    // into the Accessibility list — a user sent straight to the pane by
                    // `openSettings` alone would have to find the app with the «+» button
                    // first — and `openSettings` is what the button's label promises.
                    PermissionsGate.requestTrust()
                    PermissionsGate.openSettings()
                },
                onSwitchOperation: { op in Task { await coordinator.switchOperation(to: op) } },
                onAnotherVariant: { Task { await coordinator.anotherVariant() } },
                settings: settings,
                onProofreadingLevelChange: { level in
                    Task { await coordinator.setProofreadingLevel(level) }
                },
                onRewriteStyleChange: { style in
                    Task { await coordinator.setRewriteStyle(style) }
                },
                onContentChange: { settling in panel.contentDidChange(settling: settling) },
                // Gated on `variant`, not unconditional: `PanelController` builds *two* live
                // hosts from this same closure — `hosting` (installed) and `measuring`
                // (measured, for `PanelController.measure`) — and both carry a `PanelHost`
                // with its own `.onChange(of: coordinator.panelModel.state)`, because that
                // hook lives on `PanelHost` itself rather than varying by variant. Wiring
                // `onRunFinished` unconditionally, as `onContentChange` above is, would fire
                // the refresh twice per settle — measured, in a scratch test with one
                // `NSHostingView` and one detached `NSHostingController` over the same
                // `@Observable`, both laid out: `installed=1 measured=1`. `onContentChange`
                // tolerates that doubling because `applyFit` is idempotent against the frame
                // it already set and `contentDidChange` gates on `panel.isVisible`; `refresh()`
                // has neither guard, so a second call is a second live HTTP round trip and a
                // second unguarded write to `status`. Restricting the real closure to
                // `.installed` — the variant `hosting` builds — makes the measured copy's
                // closure a no-op instead, so only one host ever calls it.
                onRunFinished: {
                    guard case .installed = variant else { return }
                    // Announced from here rather than from a modifier inside `PanelView`, and
                    // the reason is the same one this closure is already gated for: the
                    // controller builds two live hosts from this builder, and a `.onChange`
                    // written in the view would fire on both — so a settle would be spoken
                    // twice. This closure only exists on the installed variant.
                    //
                    // What to say is `PanelView.announcement(for:)`, which is a value and is
                    // tested; posting it is all that happens here.
                    if let said = PanelView.announcement(
                        for: coordinator.panelModel.state,
                        operation: coordinator.panelModel.resolvedOperation ?? .translate) {
                        AccessibilityNotification.Announcement(said).post()
                    }
                    await statusModel.refresh(interactiveModel: settings.interactiveModel)
                }))
        }
        panel.onEscape = {
            coordinator.panelModel.cancel()
            panel.hide()
        }
        panel.onEnter = {
            // Cancelled first, like Esc and the ⨯ — this was the one dismissal that did not.
            // With the terms gate on, ⏎ while the run is suspended on the escalated sheet
            // copied whatever little had arrived, hid the panel, and left a modal demanding
            // edits for a run whose only output surface was gone: answering it then streamed
            // the finished translation into a hidden panel, where `autoCopy` is off by
            // default and nothing else would ever show it.
            coordinator.panelModel.cancel()
            // Hidden first, then copied. `copyResult()` suspends while the write goes through
            // `GeneralPasteboard`'s serialisation, and Enter means «copy and close» — leaving
            // the panel up for the length of that suspension would make the close look laggy
            // for a keystroke whose whole point is to be instant.
            panel.hide()
            Task { await coordinator.copyResult() }
        }
    }

    /// Spec 7.2's «Открыть в окне»: the panel's texts move to the window, and the window
    /// comes forward. Both are written, not just the source — the translation is the thing
    /// the user wants to keep, and re-running it would cost them the wait a second time.
    private func handOffToWindow() {
        // The whole run moves, not just its two strings — `outcome`, `resolvedTarget` and
        // `state` with them, through `adopt(from:)`, which is what keeps the window from
        // showing a previous window translation's elapsed time and warnings underneath the
        // text it was just handed.
        //
        // The panel stays up when the window refuses. It refuses only while it is running a
        // translation of its own, and hiding the panel then would throw away a result the
        // user asked to keep in exchange for nothing.
        guard translation.adopt(from: coordinator.panelModel) else {
            openWindow(id: TranslatorApp.mainWindowID)
            activateThisApp()
            return
        }
        // Only now that something has actually been handed over. Set before the guard, it
        // was a side effect of a path that returns without doing its job: a refused hand-off
        // yanked the window out of «Файлы» and left it there having moved nothing.
        //
        // The window must be *showing* the pane it was given. Without this the translation
        // landed in «Текст» while the window sat in «Файлы» — not drawn, and formerly not
        // even reachable, because the switch stayed disabled until the queue finished.
        mode = .text
        panel.hide()
        openWindow(id: TranslatorApp.mainWindowID)
        // The app is an `LSUIElement` and the panel is non-activating, so nothing so far has
        // brought it to the foreground; without this the window opens behind the application
        // the user was reading.
        activateThisApp()
    }

    /// One throwaway request at launch, so the first hotkey press does not pay to load the
    /// model. Spec §5 measured a cold load at about 2000 ms against 155 ms warm, and
    /// `keep_alive` is what keeps the model resident afterwards — so this must pass
    /// `settings.keepAlive`, or it would load the model and let it fall straight back out
    /// of memory before the user ever pressed anything.
    ///
    /// Hung on the `MenuBarExtra`'s label, not on the main window's `.task` where the plan
    /// put it. No window opens at launch — see the scene-order comment above, which is the
    /// whole reason `MenuBarExtra` is declared first — so a warm-up there would have fired
    /// only once the user opened the window by hand, at which point they are already
    /// looking at the app and the pause it exists to remove has nothing left to hide behind.
    /// The label view is the one thing this app does render at launch.
    ///
    /// Straight to `OllamaClient.chat`, deliberately below both `TranslationViewModel` and
    /// `Translator`. The view model owns the window's visible state, so warming through it
    /// would move `state`, `translatedText` and `outcome` for a translation the user never
    /// asked for. `Translator` would add language detection, chunking, a glossary merge,
    /// response cleaning and a markup diff — all discarded, and none of it what makes the
    /// model resident. `chat` is the layer that actually carries `keep_alive` to the server,
    /// which is the entire job.
    private func warmUp() async {
        guard settings.warmUpOnLaunch else { return }
        // The same options a real run gets, think decision included: a warm-up that reasoned
        // while the run did not would page the model in under a regime nothing else uses.
        let options = settings.chatOptions(model: settings.interactiveModel)
        do {
            // Drained rather than abandoned after the first event: dropping the stream runs
            // `onTermination`, which cancels the request, and there is nothing to save by
            // cutting off a reply this short.
            for try await _ in client.chat(messages: [ChatMessage(role: "user", content: "ok")],
                                           options: options) {}
        } catch {
            // Still swallowed as far as the user is concerned, and that part is right: a
            // warm-up is by definition something they did not ask for, so its failure must
            // cost them nothing, and Ollama being unreachable is already the window's status
            // line's job to say. Saying it twice — once about a request nobody made — would be
            // worse than silence.
            //
            // `.debug` and not `.error`, because at launch this failing is *ordinary*: Ollama
            // is simply not up yet on a good proportion of logins. It is here so that «the
            // first translation is always slow» has somewhere to be answered from.
            Log.engine.debug("""
                warm-up failed, first translation will pay the cold-load cost: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    static let mainWindowID = "main"
}

/// The panel's SwiftUI content.
///
/// A view of its own so that `selection` is *read inside a body* rather than baked in at the
/// call site. `PanelController` builds its `NSHostingView` once and keeps it; a
/// `PanelView(selection: coordinator.selection)` written where the content is constructed
/// would freeze whatever the selection was at launch — `.empty` — and the panel would show
/// the «выделите текст» hint forever. Read here, it registers observation on the
/// `@Observable` coordinator and the panel re-renders on every capture.
private struct PanelHost: View {
    let coordinator: HotkeyCoordinator
    /// The *window's* view model. The panel needs it to ask whether the window would take
    /// this run — `TranslationViewModel.adoptionRefusal(from:)` — because the button that
    /// would be refused lives here. Asked inside `body`, so observation picks the change up
    /// and the button re-enables when the window finishes.
    let windowModel: TranslationViewModel
    /// Decided by `PanelController` from the measurement, not by this view: the content is
    /// measured in its non-scrolling form, and only the variant that is *displayed* scrolls.
    let scrolls: Bool
    /// False only for the copy the controller measures. Both of these come from one
    /// `PanelContentVariant` at the call site, so they cannot be set to a combination that
    /// does not exist.
    let fillsPanel: Bool
    let onCopy: () -> Void
    let onOpenInWindow: () -> Void
    let onClose: () -> Void
    let onGrantPermission: () -> Void
    /// The header's «Перевод | Правка» switch, threaded to `PanelView` like every other
    /// callback here — see `HotkeyCoordinator.switchOperation(to:)`.
    let onSwitchOperation: (TextOperation) -> Void
    /// «Ещё вариант», threaded the same way — see `HotkeyCoordinator.anotherVariant()`.
    let onAnotherVariant: () -> Void
    /// The settings, read **inside `body`** rather than resolved at the call site — the same
    /// reason `selection` is read here. `PanelController` builds its hosting view once and
    /// keeps it, so a степень resolved where the content is constructed would freeze at
    /// whatever it was when the panel was built. Read in the body, it registers observation on
    /// `@Observable` `AppSettings` and the row redraws when the value changes.
    let settings: AppSettings
    /// The степень and стиль pickers, threaded like every other callback here — see
    /// `HotkeyCoordinator.setProofreadingLevel(_:)`.
    let onProofreadingLevelChange: (ProofreadingLevel) -> Void
    let onRewriteStyleChange: (RewriteStyle) -> Void
    let onContentChange: (Bool) -> Void
    /// Refreshes `OllamaStatusModel` after a hotkey run settles. Folded into the
    /// `panelModel.state` hook below rather than a second `.onChange` on the same value —
    /// two observers of one `@Observable` property race on ordering for no benefit here.
    let onRunFinished: () async -> Void

    var body: some View {
        PanelView(model: coordinator.panelModel,
                  selection: coordinator.selection,
                  awaitingRun: coordinator.isStartingRun,
                  adoptionRefusal: windowModel.adoptionRefusal(from: coordinator.panelModel),
                  onCopy: onCopy,
                  onOpenInWindow: onOpenInWindow,
                  onRetry: { Task { await coordinator.retry() } },
                  onGrantPermission: onGrantPermission,
                  onSwitchOperation: onSwitchOperation,
                  onAnotherVariant: onAnotherVariant,
                  proofreadingLevel: settings.defaultProofreadingLevel,
                  rewriteStyle: settings.defaultRewriteStyle,
                  onProofreadingLevelChange: onProofreadingLevelChange,
                  onRewriteStyleChange: onRewriteStyleChange,
                  scrolls: scrolls,
                  onClose: onClose,
                  fillsPanel: fillsPanel)
            // Deferred to a later turn of the main actor on purpose. These fire *during*
            // the view update that produced the new text, and resizing a window from
            // inside a SwiftUI update re-enters layout on a view AppKit is already laying
            // out. The controller's own throttle then coalesces the burst.
            .onChange(of: coordinator.panelModel.translatedText) { _, _ in
                Task { @MainActor in onContentChange(false) }
            }
            .onChange(of: coordinator.panelModel.state) { _, new in
                // A state that is no longer `.running` is the settle: the last size this
                // presentation will be asked for, and the only one animated — and also the
                // point a hotkey run has something new to say about whether Ollama answered.
                Task { @MainActor in
                    onContentChange(new != .running)
                    if new != .running { await onRunFinished() }
                }
            }
    }
}

/// A view of its own rather than the buttons inline, so `@Environment(\.openWindow)` has a
/// type to live on.
private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    /// Spec §6: "the menu gains a first row stating the same thing [as the glyph] in words."
    /// A plain value, not a refresh hook — this view has no `.task` of its own. An earlier
    /// draft of this task also threaded an `onRefresh: () async -> Void` through here to
    /// trigger a refresh when the menu opens, but `MenuBarExtra`'s content is not guaranteed
    /// to re-run `.task`/`.onAppear` on every opening (it is cached and reused on some macOS
    /// versions and rebuilt on others), so that refresh would have been unreliable exactly
    /// when a user opens the menu to check. That trigger is dropped rather than shipped
    /// silently broken; see `OllamaStatus.menuBarSymbol`'s doc comment for what does drive
    /// the refresh instead.
    let status: OllamaStatus

    var body: some View {
        Text(status.label)
        Divider()
        Button("Открыть окно перевода") {
            openWindow(id: TranslatorApp.mainWindowID)
            // The app is an `LSUIElement`, so it is not activated by the menu click alone
            // and a freshly opened window would come up behind whatever the user was in.
            activateThisApp()
        }
        // This used to say «there is no application menu in an `LSUIElement` app, so the
        // standard ⌘, does not exist and this is the only way into the `Settings` scene».
        // **Both halves of that were wrong, and it is measured now rather than reasoned.**
        // Dumping `NSApp.mainMenu` from a copy of these three scenes at `.accessory`
        // activation policy: the application menu is there, and it carries «Настройки…» with
        // ⌘, — the `Settings` scene installs it, exactly as Apple's own documentation for the
        // menu bar says it does. `LSUIElement` governs the Dock tile and whether the bar is
        // *drawn*; it does not stop the menu being installed, and key equivalents are
        // dispatched through it either way.
        //
        // So this is not the only way in, and the conclusion survives anyway: it is the only
        // *discoverable* way in for a user who never sees a menu bar, which is every user of
        // this app until they open a window. `SettingsLink` is macOS 14+, i.e. available at
        // the floor, and is preferable to sending `showSettingsWindow:` by selector — a
        // private-ish action whose name has already changed once across releases. The label is
        // supplied because the no-argument initialiser renders the system's English «Settings».
        //
        // The button above works around this app not being activated by a menu click;
        // `SettingsLink` exposes no action to hang that on. Measured on the real bundle:
        // the settings window opens (measured then at 420x450; every pane takes one
        // 560 × 480 frame from `settingsPane()` since, and the size is not what this
        // measurement was about) with `NSApp.isActive == false` and
        // no key window, so the caveat applies here too — the pane comes up unfocused
        // until it is clicked. Fixing it would mean swapping this standard control for a
        // `Button` calling `openSettings()` plus `NSApp.activate`, and nothing in this
        // environment could show that `activate` takes effect, so the standard control
        // stays and the caveat is written down instead of papered over.
        SettingsLink { Text("Настройки…") }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
    }
}

/// Bring this application forward.
///
/// `NSApp.activate(ignoringOtherApps:)` is deprecated on macOS 14 and, measured, does not
/// do it: after «Открыть в окне» the translation window is front and answers `AXMain`, but
/// the application is not frontmost, so the user's keystrokes still go to whatever they were
/// reading. The same failure makes the `Settings` window swallow its first click — that click
/// is spent activating rather than reaching the control under the pointer.
///
/// macOS 14 replaced unilateral activation with a cooperative form: the application that
/// currently holds activation is named, and the system treats the request as a hand-off
/// rather than a steal. `NSRunningApplication.activate(from:options:)` is that API and is
/// available at this project's floor. When nothing else is frontmost there is nobody to hand
/// off from, so that case falls through to the no-argument `NSApplication.activate()`, which
/// is the macOS 14 replacement for the deprecated call and not the same thing as it.
///
/// `.activateAllWindows` and not the default: an `LSUIElement` app that has just been asked
/// to show a window has exactly one thing the user wants to see, and leaving the rest behind
/// the previous app is the failure this exists to fix.
@MainActor
func activateThisApp() {
    if let yielding = NSWorkspace.shared.frontmostApplication,
       yielding != NSRunningApplication.current {
        NSRunningApplication.current.activate(from: yielding, options: [.activateAllWindows])
    } else {
        NSApp.activate()
    }
}
