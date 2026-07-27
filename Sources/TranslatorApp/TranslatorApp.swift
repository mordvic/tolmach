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
        let translation = TranslationViewModel(
            translator: Translator(client: OllamaClient()),
            settings: settings,
            glossary: glossary)
        _settings = State(initialValue: settings)
        _glossary = State(initialValue: glossary)
        _statusModel = State(initialValue: statusModel)
        _translation = State(initialValue: translation)
    }

    var body: some Scene {
        // Scene order is load-bearing — do not "tidy" the `Window` back to the top.
        // SwiftUI opens the *first* window-bearing scene at launch, so declaring `Window`
        // first made this `LSUIElement` utility pop a 900x492 window on every login.
        // With `MenuBarExtra` first, nothing opens at launch and the menu's
        // «Открыть окно перевода» still reaches the window via `openWindow(id:)`.
        // (`Scene.defaultLaunchBehavior(.suppressed)`, the declarative fix, is macOS 15+
        // and the platform floor here is macOS 14.)
        MenuBarExtra("Толмач", systemImage: "character.bubble") {
            MenuContent()
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
            }
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
