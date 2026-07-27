// Sources/TranslatorApp/SettingsAdvancedView.swift
import SwiftUI

struct SettingsAdvancedView: View {
    /// `@Bindable` for the same reason as in `SettingsGeneralView`: both controls write back
    /// into the one shared `AppSettings`, whose properties are computed over `UserDefaults`
    /// with hand-written `access`/`withMutation` calls.
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            // Through `RussianCopy.plural` rather than a bare «символов». The stepper's own
            // 100-character step never leaves the «символов» form, but `chunkSize` reads
            // straight from `UserDefaults` on every access precisely so a value set outside
            // the app is picked up — and `defaults write … chunkSize 901` would then render
            // «901 символов».
            Stepper("Размер фрагмента: \(settings.chunkSize) "
                    + RussianCopy.plural(settings.chunkSize, "символ", "символа", "символов"),
                    value: $settings.chunkSize, in: 300...4000, step: 100)
            Text("Больше — связнее перевод длинного текста, но дольше до первого результата.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $settings.temperature, in: 0...1, step: 0.05) {
                // The locale is pinned rather than taken from the system. Every string in
                // this app is Russian and there is no localisation to switch, so on a
                // machine set to en_US the default format would put a Russian sentence next
                // to «0.20» — and the caption below, which names the default in Russian
                // notation, would disagree with the control right above it.
                Text("Температура: \(settings.temperature, format: .number.precision(.fractionLength(2)).locale(Locale(identifier: "ru_RU")))")
            }
            Text("Ниже — предсказуемее и ближе к оригиналу. По умолчанию 0,2.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
