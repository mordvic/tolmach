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

    /// The text of the download field is UI state with no meaning outside this pane, so it
    /// stays here rather than on the view model.
    @State private var modelToPull = ""

    private var pullTarget: String {
        modelToPull.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            // One picker, not two. There was a «Модель для фонового перевода» here and it did
            // nothing: both surfaces build `ChatOptions` from `interactiveModel`, and the
            // background path is batch file translation, which is v2. A control that stores a
            // value nothing reads is worse than a missing one — the user changes it, gets no
            // effect and no explanation, and has no way to tell a broken app from an inert
            // setting. It comes back with the feature.
            ModelChoice(title: "Модель для перевода",
                        selection: $settings.interactiveModel, models: models)

            TextField("Держать модель в памяти", text: $settings.keepAlive)
            // Guillemets, not backticks: building the string with `+` forces `Text`'s
            // plain-`String` initialiser instead of the `LocalizedStringKey` one, so
            // Markdown is never parsed and backticks would render as literal grave accents.
            Text("Формат Ollama: «30m», «1h», «0» — выгружать сразу, «-1» — держать всегда. "
                 + "Холодная загрузка стоит около двух секунд, поэтому короткое значение "
                 + "делает каждое первое нажатие хоткея заметно медленнее.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
            // Spec 8: the pane must say why it is empty. `error` covers both an unreachable
            // server at load and a download that failed halfway.
            if let error = models.error {
                SettingsNote(text: error, icon: "xmark.octagon.fill", tint: .red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .task { await models.reload() }
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
