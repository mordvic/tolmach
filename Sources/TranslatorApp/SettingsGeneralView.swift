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
                            .foregroundStyle(StatusColour.success).labelStyle(.titleAndIcon)
                    } else {
                        Label("нет доступа", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(StatusColour.warning).labelStyle(.titleAndIcon)
                    }
                }
                if !isTrusted {
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

            Section("Сочетания клавиш") {
                // Two rows, labelled by what they do rather than «первое» и «второе»: each
                // shortcut opens the panel already performing its own operation, and that is
                // the only difference between them.
                //
                // Each recorder is told what the other holds, so a collision is refused at
                // the keystroke instead of being stored and then refused by Carbon — see
                // `HotkeyRecorder.reserved`.
                LabeledContent("Перевод") {
                    HotkeyRecorder(combo: $settings.hotkey,
                                   reserved: [settings.proofreadHotkey])
                }
                LabeledContent("Правка") {
                    HotkeyRecorder(combo: $settings.proofreadHotkey,
                                   reserved: [settings.hotkey])
                }
                Text("Нажмите на поле и наберите новое сочетание. Нужен хотя бы один из "
                     + "модификаторов ⌃, ⌥ или ⌘ — иначе сочетание отняло бы обычную клавишу "
                     + "у всех остальных программ. Сочетания должны различаться: одно и то же "
                     + "система не отдаст дважды.")
                    .font(.caption).foregroundStyle(.secondary)
                    // The caption is three sentences now, and a `Text` given less width than
                    // it wants truncates rather than wrapping — the clause that would go is
                    // the one explaining the refusal.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Языки") {
                // «Мой язык» and «Второй язык», not «Основной» and «Рабочий». The old pair
                // named nothing a user could act on — which of two languages is «основной»
                // and which is «рабочий» is a question about this app's internals, not about
                // translation — so the whole direction rule had to be spelled out in a
                // caption underneath. The rule is now split across the two labels' own
                // captions, where each half sits next to the control it governs.
                //
                // The settings' stored names stay `primaryLanguage` and `workingLanguage`.
                // Renaming those would rewrite `UserDefaults` keys and silently reset every
                // existing install's languages, which is a far worse trade than a label and a
                // property that read differently.
                Picker("Мой язык", selection: $settings.primaryLanguage) {
                    ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                Text("На него переводится всё, что написано на других языках.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Второй язык", selection: $settings.workingLanguage) {
                    ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                Text("На него переводится текст, который уже на моём языке.")
                    .font(.caption).foregroundStyle(.secondary)
                // Equal languages make `targetLanguage(forDetected:)` return the same
                // language whatever the source is, so every translation becomes a round trip
                // into the primary language and the app quietly stops doing anything useful.
                // Say so rather than swapping the value back or refusing the selection: the
                // user is mid-edit, and only they know which of the two pickers they meant.
                if languagesCollide {
                    Label {
                        Text("Оба языка совпадают: любой текст, на каком бы языке он ни был, "
                             + "будет переводиться на \(settings.primaryLanguage.russianName) — "
                             + "включая текст, который уже на нём написан. Выберите разные языки.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption).foregroundStyle(StatusColour.warning)
                }
                // The section-wide caption that used to sit here — «Направление выбирается
                // само: текст на основном языке переводится в рабочий, любой другой — в
                // основной» — is gone. It existed to explain two labels that explained
                // nothing; each half now sits under the picker it describes, which is where
                // a reader looks for it.
            }

            Section("Перевод") {
                Picker("Тон по умолчанию", selection: $settings.defaultTone) {
                    ForEach(Tone.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
            }

            Section("Правка") {
                Picker("Степень по умолчанию", selection: $settings.defaultProofreadingLevel) {
                    ForEach(ProofreadingLevel.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                Text("«Только ошибки» — орфография, пунктуация и грамматика, формулировки не "
                     + "трогаются. «Ошибки и стиль» — плюс канцелярит, повторы и неуклюжие обороты.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Стиль по умолчанию", selection: $settings.defaultRewriteStyle) {
                    ForEach(RewriteStyle.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                // Disabled, not hidden — the same constructive rule as the toolbar (spec §7),
                // read from the one property both surfaces share.
                .disabled(!settings.defaultProofreadingLevel.allowsRewriteStyle)
                if let description = settings.defaultRewriteStyle.russianDescription {
                    Text(description)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Панель по сочетанию клавиш использует эти значения; в окне их можно "
                     + "переопределить на месте.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Поведение") {
                // Naming the shortcut is not padding, and it must stay. `autoCopy` is read in
                // exactly one place — `HotkeyCoordinator.runTranslation` — so a translation
                // done in the main window never touches the clipboard whatever this says.
                // Spec §7.2 puts automatic copying in the panel's section deliberately; the
                // label used to promise the whole app and quietly mean a third of it.
                //
                // «по сочетанию клавиш» and no longer «по хоткею», because the section above
                // this one is called «Сочетание клавиш». One concept under two names is the
                // drift `CONTEXT.md` exists to stop, and «хоткей» was also the only English
                // word in a window that is otherwise entirely Russian.
                Toggle("Копировать перевод по сочетанию клавиш", isOn: $settings.autoCopy)
                // «Прогревать модель при запуске» used to sit here. It moved to «Модели», next
                // to «Держать модель в памяти»: both settings govern the same thing — whether
                // the model is resident when the user presses the shortcut — and having them
                // in two different tabs meant neither could be understood without the other.
            }
        }
        .settingsPane()
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
