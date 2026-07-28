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
            // Spec 6.1's standing indicator: the half of onboarding the panel's own prompt
            // cannot cover, because the panel's prompt only appears once the user has already
            // pressed the shortcut and been met with nothing.
            //
            // Reads the cached `isTrusted`, refreshed on appearance and on every activation
            // — see the property's own comment for why reading `PermissionsGate` here
            // directly was wrong. TCC publishes no notification this app subscribes to, so
            // the row still lags a grant made without leaving the app; that window is the
            // seconds between flipping the switch and clicking back, and closing it would
            // mean polling a privileged call on a timer for a cosmetic gain.
            if !isTrusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Сочетание клавиш не сможет прочитать выделенный текст",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("Приложению нужен доступ в разделе «Конфиденциальность и "
                         + "безопасность» → «Универсальный доступ». Главное окно работает "
                         + "и без него.")
                        .font(.caption).foregroundStyle(.secondary)
                        // Same reason as the panel's prompt: a `Text` given less width than it
                        // wants truncates rather than wrapping, and the clause that would go
                        // is the one saying where the setting actually lives.
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Открыть настройки системы") { PermissionsGate.openSettings() }
                }
            }
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
        // On appearance rather than in the property's initialiser: `@State`'s initial value is
        // evaluated once for the lifetime of the view's storage, so a pane opened before the
        // permission was granted would keep the value it was born with. It starts `true` so a
        // granted user never sees the warning flash on the way in.
        .onAppear { isTrusted = PermissionsGate.isTrusted() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = PermissionsGate.isTrusted()
        }
    }
}
