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
    /// Owned here rather than created inside the settings pane so the installed list and a
    /// download in progress survive the settings window being closed and reopened.
    @State private var models: ModelsViewModel
    /// The same client the `Translator` above translates through, kept so `warmUp()` can
    /// reuse it instead of standing up a second `URLSession` for one request at launch.
    @State private var client: OllamaClient
    /// The hotkey path, which owns a `TranslationViewModel` of its own — see the comment on
    /// `HotkeyCoordinator.panelModel`. It shares this app's `settings`, `glossary` and
    /// `client`; only the view model is separate.
    @State private var coordinator: HotkeyCoordinator
    /// Built here rather than on first press so that a press never pays for an `NSPanel` and
    /// an `NSHostingView` before it can show anything.
    @State private var panel: PanelController

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
        let statusModel = OllamaStatusModel()
        let client = OllamaClient()
        let translation = TranslationViewModel(
            translator: Translator(client: client),
            settings: settings,
            glossary: glossary)
        // A second `Translator` over the *same* client. `Translator` is a value with no state
        // beyond the client, so this costs nothing and keeps the two view models independent;
        // sharing the client is what matters, because it is what holds the `URLSession`.
        let coordinator = HotkeyCoordinator(settings: settings, glossary: glossary,
                                            translator: Translator(client: client))
        _settings = State(initialValue: settings)
        _glossary = State(initialValue: glossary)
        _statusModel = State(initialValue: statusModel)
        _translation = State(initialValue: translation)
        _models = State(initialValue: ModelsViewModel())
        _client = State(initialValue: client)
        _coordinator = State(initialValue: coordinator)
        // Content is a placeholder until `configurePanel()` runs at launch. Everything the
        // real content needs — the panel itself, for «закрыть», and `openWindow` — either
        // does not exist yet here or is not readable outside a scene, and the panel is never
        // ordered in before that point.
        _panel = State(initialValue: PanelController { AnyView(EmptyView()) })
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
            MenuContent()
        } label: {
            // The `MenuBarExtra(_:systemImage:)` convenience initialiser this used to be
            // takes no view, and `warmUp()` needs one to hang a `.task` on — this label is
            // the only thing the app renders at launch. Its title argument was only ever an
            // accessibility label, so that is restored explicitly rather than dropped.
            Image(systemName: "character.bubble")
                .accessibilityLabel("Толмач")
                .task { await launch() }
        }

        Window("Толмач", id: TranslatorApp.mainWindowID) {
            MainWindowView(model: translation, settings: settings,
                           glossary: glossary, status: statusModel.status)
                .task { await statusModel.refresh(interactiveModel: settings.interactiveModel) }
        }

        // Declared last for the same reason `Window` is not first: whatever SwiftUI counts
        // as a window-bearing scene, the one it may open at launch is the first, and that
        // has to stay the `MenuBarExtra`.
        Settings {
            TabView {
                SettingsGeneralView(settings: settings)
                    .tabItem { Text("Основные") }
                SettingsModelsView(settings: settings, models: models)
                    .tabItem { Text("Модели") }
                SettingsGlossaryView(glossary: glossary, settings: settings)
                    .tabItem { Text("Глоссарий") }
                SettingsAdvancedView(settings: settings)
                    .tabItem { Text("Дополнительно") }
            }
        }
    }

    // MARK: - The hotkey path

    /// Everything this app does at launch, in the order it has to happen.
    ///
    /// The hotkey is registered **before** the warm-up, which is not what Task 10's brief
    /// said. `warmUp()` awaits a real HTTP request whose `timeoutIntervalForRequest` is 120
    /// seconds (`OllamaClient.swift:18`), so registering after it would leave the app's only
    /// shortcut dead for as long as Ollama takes to answer — two seconds on a cold model,
    /// and two *minutes* if Ollama accepts the connection and then never replies. Registration
    /// is synchronous and takes no I/O, so there is nothing to gain by deferring it.
    private func launch() async {
        configurePanel()
        // The refusal is swallowed here, and it is worth being honest that nothing surfaces
        // it: `AppSettings.hotkey` already guarantees a valid combination, and the only other
        // way `register` fails is -9878 for a combination another component of this process
        // already holds — nothing else in this process registers one. A user-visible message
        // needs UI that does not exist yet; see the task report.
        coordinator.start {
            // The pointer is sampled *here*, at the press, and used after the capture. The
            // read can take up to three quarters of a second and the user's hand is still on
            // the mouse; the panel belongs where they were looking when they pressed.
            let cursor = NSEvent.mouseLocation
            // Hidden before the capture and shown after it, never before. The brief said
            // before; doing that breaks the capture outright, because the panel becomes the
            // key window and the system-wide accessibility focus follows it — see the
            // comment in `HotkeyCoordinator.handlePress`, which carries the measurement.
            Task {
                await coordinator.handlePress(willCapture: { panel.hide() },
                                              afterCapture: { panel.show(at: cursor) })
            }
        }
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
        await warmUp()
    }

    /// Re-registers when the user changes the shortcut in settings.
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
    private func observeHotkeyChanges() {
        withObservationTracking {
            _ = settings.hotkey
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
        panel.setContent(AnyView(PanelHost(
            coordinator: coordinator,
            // Copying does not close. Enter is the shortcut that means «скопировать и
            // закрыть» (spec 7.2); the button is for a user who wants to keep reading.
            onCopy: { coordinator.copyResult() },
            onOpenInWindow: { handOffToWindow() },
            onGrantPermission: {
                // Both, and in this order. `requestTrust` is what actually puts this app into
                // the Accessibility list — a user sent straight to the pane by `openSettings`
                // alone would have to find the app with the «+» button first — and
                // `openSettings` is what the button's label promises.
                PermissionsGate.requestTrust()
                PermissionsGate.openSettings()
            })))
        panel.onEscape = {
            coordinator.panelModel.cancel()
            panel.hide()
        }
        panel.onEnter = {
            coordinator.copyResult()
            panel.hide()
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
        let options = ChatOptions(model: settings.interactiveModel,
                                  temperature: settings.temperature,
                                  keepAlive: settings.keepAlive)
        do {
            // Drained rather than abandoned after the first event: dropping the stream runs
            // `onTermination`, which cancels the request, and there is nothing to save by
            // cutting off a reply this short.
            for try await _ in client.chat(messages: [ChatMessage(role: "user", content: "ok")],
                                           options: options) {}
        } catch {
            // Swallowed on purpose, and this is the one place in the app where that is
            // right. A warm-up is by definition something the user did not ask for, so its
            // failure must cost them nothing; Ollama being unreachable is already the
            // window's status line's job to say, and saying it twice — once about a request
            // nobody made — would be worse than silence.
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
    let onCopy: () -> Void
    let onOpenInWindow: () -> Void
    let onGrantPermission: () -> Void

    var body: some View {
        PanelView(model: coordinator.panelModel,
                  selection: coordinator.selection,
                  onCopy: onCopy,
                  onOpenInWindow: onOpenInWindow,
                  onRetry: { Task { await coordinator.retry() } },
                  onGrantPermission: onGrantPermission)
    }
}

/// A view of its own rather than the buttons inline, so `@Environment(\.openWindow)` has a
/// type to live on.
private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Открыть окно перевода") {
            openWindow(id: TranslatorApp.mainWindowID)
            // The app is an `LSUIElement`, so it is not activated by the menu click alone
            // and a freshly opened window would come up behind whatever the user was in.
            activateThisApp()
        }
        // There is no application menu in an `LSUIElement` app, so the standard ⌘,
        // does not exist and this is the only way into the `Settings` scene.
        // `SettingsLink` is macOS 14+, i.e. available at the floor, and is preferable to
        // sending `showSettingsWindow:` by selector — a private-ish action whose name has
        // already changed once across releases. The label is supplied because the
        // no-argument initialiser renders the system's English «Settings».
        //
        // The button above works around this app not being activated by a menu click;
        // `SettingsLink` exposes no action to hang that on. Measured on the real bundle:
        // the settings window opens (420x450, visible) with `NSApp.isActive == false` and
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
