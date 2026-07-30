// Sources/TranslatorApp/SettingsGeneralView.swift
import SwiftUI
import TranslationCore
import TextCapture

struct SettingsGeneralView: View {
    /// `@Bindable`, not `@State`: the settings object is created once in `TranslatorApp`
    /// and shared, so this pane must bind to that instance rather than own one. Each
    /// `AppSettings` property is computed over `UserDefaults` with hand-written
    /// `access(keyPath:)` / `withMutation(keyPath:)` calls, which is what makes these
    /// bindings notify — a getter missing its `access` would read fine here and never
    /// redraw.
    @Bindable var settings: AppSettings

    /// Held as state rather than read straight from `PermissionsGate` inside `body`, because
    /// the permission is not observable and reading it there made the warning below outlive
    /// the problem it describes.
    ///
    /// The failing sequence is the one the warning's own button creates: the user clicks
    /// «Открыть настройки системы», grants the permission, and comes back to a Settings
    /// window that never closed. Nothing in it changed, so SwiftUI does not re-evaluate
    /// `body`, `isTrusted()` is never asked again, and the row still says the shortcut
    /// cannot read anything — telling the user that the thing they just did did not work.
    ///
    /// `didBecomeActiveNotification` is the signal precisely because that is what coming
    /// back *is*. It costs one privileged call per activation, unlike polling.
    @State private var isTrusted = true

    private var languagesCollide: Bool {
        settings.primaryLanguage == settings.workingLanguage
    }

    var body: some View {
        Form {
            Section("Доступ") {
                // Visible whether or not the permission is granted, unlike the block this
                // replaces. A row that appears only on failure makes the form jump when the
                // user comes back from System Settings, and leaves a user whose permission
                // *is* granted with no way to learn the permission exists.
                LabeledContent("Доступ к тексту в других программах") {
                    if isTrusted {
                        Label("предоставлен", systemImage: "checkmark.circle")
                            .foregroundStyle(.green).labelStyle(.titleAndIcon)
                    } else {
                        Label("нет доступа", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).labelStyle(.titleAndIcon)
                    }
                }
                if !isTrusted {
                    Text("Приложению нужен доступ в разделе «Конфиденциальность и "
                         + "безопасность» → «Универсальный доступ». Главное окно работает "
                         + "и без него.")
                        .font(.caption).foregroundStyle(.secondary)
                        // A `Text` given less width than it wants truncates rather than
                        // wrapping, and the clause that gets cut is the one saying where the
                        // setting actually lives.
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Открыть настройки системы") { PermissionsGate.openSettings() }
                }
            }

            Section("Сочетание клавиш") {
                LabeledContent("Сочетание клавиш") { HotkeyRecorder(combo: $settings.hotkey) }
                Text("Нажмите на поле и наберите новое сочетание. Нужен хотя бы один из "
                     + "модификаторов ⌃, ⌥ или ⌘ — иначе сочетание отняло бы обычную клавишу "
                     + "у всех остальных программ.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Языки") {
                Picker("Основной язык", selection: $settings.primaryLanguage) {
                    ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                Picker("Рабочий язык", selection: $settings.workingLanguage) {
                    ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                // Equal languages make `targetLanguage(forDetected:)` return the same
                // language whatever the source is, so every translation becomes a round trip
                // into the primary language and the app quietly stops doing anything useful.
                // Say so rather than swapping the value back or refusing the selection: the
                // user is mid-edit, and only they know which of the two pickers they meant.
                if languagesCollide {
                    Label {
                        Text("Основной и рабочий языки совпадают: любой текст, на каком бы "
                             + "языке он ни был, будет переводиться на "
                             + "\(settings.primaryLanguage.russianName) — включая текст, "
                             + "который уже на нём написан. Выберите разные языки.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption).foregroundStyle(.orange)
                }
                Text("Направление выбирается само: текст на основном языке переводится в "
                     + "рабочий, любой другой — в основной.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Перевод") {
                Picker("Тон по умолчанию", selection: $settings.defaultTone) {
                    ForEach(Tone.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
            }

            Section("Поведение") {
                // «по хоткею» is not padding. `autoCopy` is read in exactly one place —
                // `HotkeyCoordinator.runTranslation` — so a translation done in the main
                // window never touches the clipboard whatever this says. Spec §7.2 puts
                // automatic copying in the panel's section deliberately; the label used to
                // promise the whole app and quietly mean a third of it.
                Toggle("Копировать результат по хоткею автоматически", isOn: $settings.autoCopy)
                Toggle("Прогревать модель при запуске", isOn: $settings.warmUpOnLaunch)
            }
        }
        .settingsPane()
        .onAppear { isTrusted = PermissionsGate.isTrusted() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = PermissionsGate.isTrusted()
        }
    }
}
