// Sources/TranslatorApp/SettingsGeneralView.swift
import SwiftUI
import TranslationCore

struct SettingsGeneralView: View {
    /// `@Bindable`, not `@State`: the settings object is created once in `TranslatorApp`
    /// and shared, so this pane must bind to that instance rather than own one. Each
    /// `AppSettings` property is computed over `UserDefaults` with hand-written
    /// `access(keyPath:)` / `withMutation(keyPath:)` calls, which is what makes these
    /// bindings notify — a getter missing its `access` would read fine here and never
    /// redraw.
    @Bindable var settings: AppSettings

    private var languagesCollide: Bool {
        settings.primaryLanguage == settings.workingLanguage
    }

    var body: some View {
        Form {
            LabeledContent("Сочетание клавиш") {
                HotkeyRecorder(combo: $settings.hotkey)
            }
            Text("Нажмите на поле и наберите новое сочетание. Нужен хотя бы один из "
                 + "модификаторов ⌃, ⌥ или ⌘ — иначе сочетание отняло бы обычную клавишу "
                 + "у всех остальных программ.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Основной язык", selection: $settings.primaryLanguage) {
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
            }
            Picker("Рабочий язык", selection: $settings.workingLanguage) {
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
            }
            // Equal languages make `targetLanguage(forDetected:)` return the same language
            // whatever the source is, so every translation becomes a round trip into the
            // primary language and the app quietly stops doing anything useful. Say so
            // rather than swapping the value back or refusing the selection: the user is
            // mid-edit, and only they know which of the two pickers they meant to change.
            if languagesCollide {
                Label {
                    Text("Основной и рабочий языки совпадают: любой текст, на каком бы языке "
                         + "он ни был, будет переводиться на \(settings.primaryLanguage.russianName) — "
                         + "включая текст, который уже на нём написан. Выберите разные языки.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            Picker("Тон по умолчанию", selection: $settings.defaultTone) {
                ForEach(Tone.allCases, id: \.self) { Text($0.russianName).tag($0) }
            }
            Toggle("Копировать результат автоматически", isOn: $settings.autoCopy)
            Toggle("Прогревать модель при запуске", isOn: $settings.warmUpOnLaunch)
            Text("Направление выбирается само: текст на основном языке переводится в рабочий, "
                 + "любой другой — в основной.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
