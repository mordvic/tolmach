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
            MainWindowView(model: translation, settings: settings, status: statusModel.status)
                .task { await statusModel.refresh(interactiveModel: settings.interactiveModel) }
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
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
    }
}
