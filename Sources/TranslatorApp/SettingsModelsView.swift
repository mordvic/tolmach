// Sources/TranslatorApp/SettingsModelsView.swift
import SwiftUI

struct SettingsModelsView: View {
    /// `@Bindable` for the same reason as in `SettingsGeneralView`: the pickers write back
    /// into the one shared `AppSettings`.
    @Bindable var settings: AppSettings

    /// A plain `let`, not `@State` or `@Bindable`: nothing here writes to the view model
    /// through a binding, and `@Observable`'s tracking works from a stored reference. It is
    /// owned by `TranslatorApp` so the list survives the settings window closing.
    let models: ModelsViewModel

    /// Handed down from `TranslatorApp` rather than probed a second time here: the same
    /// `OllamaStatusModel` already backs the main window's status line, and a second probe
    /// on a second timer would show two answers about the one thing Ollama is or is not
    /// doing.
    let status: OllamaStatus
    var onRefresh: () async -> Void

    /// The text of the download field is UI state with no meaning outside this pane, so it
    /// stays here rather than on the view model.
    @State private var modelToPull = ""

    private var pullTarget: String {
        modelToPull.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section("Ollama") {
                LabeledContent("Состояние") {
                    Label(status.label, systemImage: status.isHealthy
                          ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isHealthy ? .green : .orange)
                        .labelStyle(.titleAndIcon)
                }
                Button("Проверить снова") { Task { await refresh() } }
            }

            Section("Модель для перевода") {
                // One picker, not two. There was a «Модель для фонового перевода» here and
                // it did nothing: both surfaces build `ChatOptions` from `interactiveModel`,
                // and the background path is batch file translation, which is v2. A control
                // that stores a value nothing reads is worse than a missing one — the user
                // changes it, gets no effect and no explanation, and has no way to tell a
                // broken app from an inert setting. It comes back with the feature.
                ModelChoice(title: "Модель для перевода",
                            selection: $settings.interactiveModel, models: models)
            }

            Section("Установленные модели") {
                if models.installed.isEmpty {
                    Text(models.error == nil
                         ? "Ollama не сообщила ни одной модели."
                         : "Список не получен.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(models.installed, id: \.name) { model in
                        LabeledContent(model.name) {
                            Text(models.resident.contains(model.name)
                                 ? RussianCopy.modelSize(model.sizeBytes) + " · в памяти"
                                 : RussianCopy.modelSize(model.sizeBytes))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Загрузить модель") {
                LabeledContent("Загрузить модель") {
                    HStack {
                        TextField("aya-expanse:8b", text: $modelToPull)
                        Button("Загрузить") {
                            let target = pullTarget
                            Task {
                                await models.pull(target)
                                // Clear only on success. Leaving the name after a failure lets
                                // the user retry without retyping it; leaving it after a
                                // success leaves a live button that would redownload it.
                                if models.error == nil { modelToPull = "" }
                            }
                        }
                        .disabled(pullTarget.isEmpty || models.isPulling)
                    }
                }
                if let progress = models.pullProgress {
                    ProgressView(value: progress)
                }
                if let status = models.pullStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                // Spec 8: the pane must say why it is empty. `error` covers both an
                // unreachable server at load and a download that failed halfway.
                if let error = models.error {
                    SettingsNote(text: error, icon: "xmark.octagon.fill", tint: .red)
                }
            }

            Section("Дополнительно") {
                TextField("Держать модель в памяти", text: $settings.keepAlive)
                // Guillemets, not backticks: building the string with `+` forces `Text`'s
                // plain-`String` initialiser instead of the `LocalizedStringKey` one, so
                // Markdown is never parsed and backticks would render as literal grave
                // accents.
                Text("Формат Ollama: «30m», «1h», «0» — выгружать сразу, «-1» — держать всегда. "
                     + "Холодная загрузка стоит около двух секунд, поэтому короткое значение "
                     + "делает каждое первое нажатие хоткея заметно медленнее.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Through `RussianCopy.plural` rather than a bare «символов». The stepper's
                // own 100-character step never leaves the «символов» form, but `chunkSize`
                // reads straight from `UserDefaults` on every access precisely so a value set
                // outside the app is picked up — and `defaults write … chunkSize 901` would
                // then render «901 символов».
                Stepper("Размер фрагмента: \(settings.chunkSize) "
                        + RussianCopy.plural(settings.chunkSize, "символ", "символа", "символов"),
                        value: $settings.chunkSize, in: 300...4000, step: 100)
                Text("Больше — связнее перевод длинного текста, но дольше до первого результата.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.temperature, in: 0...1, step: 0.05) {
                    // The locale is pinned rather than taken from the system. Every string in
                    // this app is Russian and there is no localisation to switch, so on a
                    // machine set to en_US the default format would put a Russian sentence
                    // next to «0.20» — and the caption below, which names the default in
                    // Russian notation, would disagree with the control right above it.
                    Text("Температура: \(settings.temperature, format: .number.precision(.fractionLength(2)).locale(Locale(identifier: "ru_RU")))")
                }
                Text("Ниже — предсказуемее и ближе к оригиналу. По умолчанию 0,2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
        .task { await reload() }
    }

    /// Fetches the installed and resident lists this pane shows. Separate from `refresh()`
    /// below because appearing needs only what this pane displays, while the button also
    /// re-runs the health probe `TranslatorApp` owns.
    private func reload() async {
        await models.reload()
    }

    /// «Проверить снова»: re-checks both the health line, owned by `TranslatorApp` so the
    /// main window agrees with this pane, and this pane's own installed/resident lists —
    /// Ollama may have loaded or evicted a model since the pane opened.
    private func refresh() async {
        await onRefresh()
        await reload()
    }
}

/// A view of its own rather than a `@ViewBuilder` method, so each picker owns its binding
/// and SwiftUI can tell the two rows apart.
private struct ModelChoice: View {
    let title: String
    @Binding var selection: String
    let models: ModelsViewModel

    var body: some View {
        Picker(title, selection: $selection) {
            // The configured model is always among the options — see
            // `ModelsViewModel.options(selecting:)`. Without that a user who has not pulled
            // the default, or whose Ollama is down, would face a blank picker.
            ForEach(models.options(selecting: selection), id: \.self) { name in
                Text(models.optionLabel(name)).tag(name)
            }
        }
        if models.availability(of: selection) == .notInstalled {
            SettingsNote(text: "«\(selection)» не установлена. Введите это имя в поле "
                         + "«Загрузить модель» ниже, чтобы скачать её.",
                         icon: "arrow.down.circle", tint: .orange)
        }
        // Blacklisted models stay selectable: the reason is measured evidence, and the user
        // may have a reason to override it.
        if let warning = models.warning(for: selection) {
            SettingsNote(text: warning, icon: "exclamationmark.triangle.fill", tint: .orange)
        }
    }
}

/// The same caption-sized, tinted `Label` appears five times in this pane; extracted so the
/// notes cannot drift apart from each other. It is `private` to this file, so
/// `SettingsGeneralView`'s same-shaped warning is deliberately not covered by it.
private struct SettingsNote: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: icon) }
            .font(.caption)
            .foregroundStyle(tint)
    }
}
