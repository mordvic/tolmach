// Sources/TranslatorApp/TranslatorApp.swift
import SwiftUI
import OllamaKit
import TranslationCore

@main
struct TranslatorApp: App {
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
        _settings = State(initialValue: settings)
        _glossary = State(initialValue: glossary)
        _statusModel = State(initialValue: statusModel)
        _translation = State(initialValue: translation)
        _models = State(initialValue: ModelsViewModel())
        _client = State(initialValue: client)
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
                .task { await warmUp() }
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

/// A view of its own rather than the buttons inline, so `@Environment(\.openWindow)` has a
/// type to live on.
private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Открыть окно перевода") {
            openWindow(id: TranslatorApp.mainWindowID)
            // The app is an `LSUIElement`, so it is not activated by the menu click alone
            // and a freshly opened window would come up behind whatever the user was in.
            NSApp.activate(ignoringOtherApps: true)
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
