// Sources/TranslatorApp/SettingsModelsView.swift
import SwiftUI
import TranslationCore

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
    let status: EngineStatus
    let engineName: String
    var onRefresh: () async -> Void

    /// The text of the download field is UI state with no meaning outside this pane, so it
    /// stays here rather than on the view model.
    @State private var modelToPull = ""

    private var pullTarget: String {
        modelToPull.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section("Движок") {
                // The switch itself. A `Picker` and not two radio rows, because the pane is a
                // grouped `Form` and every other choice in it is a picker; `RussianCopy` owns
                // the names, exhaustive with no `default:`, so a third engine could not ship
                // with an empty label.
                Picker("Движок", selection: $settings.engine) {
                    ForEach(ModelEngine.allCases, id: \.self) { engine in
                        Text(RussianCopy.engineName(engine)).tag(engine)
                    }
                }
                LabeledContent("Состояние") {
                    Label(RussianCopy.engineStatus(status, engineName: engineName), systemImage: status.isHealthy
                          ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        // `StatusColour`, like every other status hue in the app. This row
                        // was missed when the three colours were spelled: on a white grouped
                        // form `systemOrange` is 2.31:1 and `systemGreen` 2.22:1, and this is
                        // the most prominent status string in Settings — the one a user with
                        // Ollama stopped comes here to read.
                        .foregroundStyle(status.isHealthy ? StatusColour.success
                                                          : StatusColour.warning)
                        .labelStyle(.titleAndIcon)
                }
                // Spec §5.3 asks this section for whether the engine is running, its address,
                // and a re-check. The address is now a **port**, and the host is not settable
                // at all: `127.0.0.1` is what makes «текст не покидает машину» a property of
                // this code rather than of what somebody typed into a field. The whole address
                // is still shown, because it is the first thing a user checks when the state
                // above says there is no connection — and it is built from the same setting the
                // app calls, so the two cannot disagree.
                LabeledContent("Порт") {
                    HStack(spacing: 8) {
                        TextField("Порт", value: $settings.enginePort,
                                  format: .number.grouping(.never))
                            .frame(width: 80)
                            .labelsHidden()
                        Text(settings.engine.address(port: settings.enginePort))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Проверить снова") { Task { await refresh() } }
                    // Offered only while the engine is silent, and only when its application is
                    // actually installed — Ollama is commonly a Homebrew binary with no bundle
                    // anywhere, and a button that cannot do anything is worse than none.
                    //
                    // It *reveals* the application; it does not start or stop a server. The
                    // reasoning is on `EngineApplication`, and it closes design spec §8's
                    // never-implemented «Запустить Ollama» button: the user starts the server
                    // where they started it before.
                    if !status.isHealthy, EngineApplication.url(for: settings.engine) != nil {
                        Button("Открыть \(RussianCopy.engineName(settings.engine))") {
                            EngineApplication.reveal(settings.engine)
                        }
                    }
                }
            }

            Section("Модель для перевода") {
                // One picker, not two. There was a «Модель для фонового перевода» here and
                // it did nothing: both surfaces build `ChatOptions` from `interactiveModel`,
                // and the background path is batch file translation, which is v2. A control
                // that stores a value nothing reads is worse than a missing one — the user
                // changes it, gets no effect and no explanation, and has no way to tell a
                // broken app from an inert setting. It comes back with the feature.
                ModelChoice(title: "Модель для перевода",
                            selection: $settings.interactiveModel, models: models,
                            onDownload: download)
            }

            Section("Модель для правки") {
                // The same optional-with-a-named-default shape as «Файлы»'s batch picker,
                // for the same reason it has one: «как для перевода» is a real state, not
                // an absent value, and the user has to be able to return to it.
                Picker("Модель", selection: $settings.proofreadModel) {
                    Text("Как для перевода").tag(String?.none)
                    // `options(selecting:)` and not `installedNames`: a `Picker` bound to a
                    // value absent from its options renders blank, and a blank row reads as
                    // «как для перевода» while a removed model is still stored underneath.
                    ForEach(models.options(selecting: settings.proofreadModel ?? ""), id: \.self) { name in
                        if !name.isEmpty { Text(models.optionLabel(name)).tag(String?.some(name)) }
                    }
                }
                // Measured, not preferred — `AppSettings.proofreadModel` carries the numbers.
                Text("Модель, которая хорошо переводит, не обязательно хорошо правит: "
                     + "переводческие модели меняют больше, чем просят. Для правки лучше "
                     + "универсальная модель — она исправляет только ошибки.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.proofreadModelDiffersFromInteractive {
                    // Not a warning: two models that fit in memory stay resident together
                    // (measured on Ollama 0.32.14 — `AppSettings.proofreadModel`), and both
                    // are warmed at launch. It says what the cost is when they do not fit.
                    Text("Обе модели загружаются при запуске и остаются в памяти, если хватает "
                         + "места. Если не хватает, первое переключение между переводом и "
                         + "правкой будет ждать загрузки около двух секунд.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Установленные модели") {
                if models.installed.isEmpty {
                    Text(models.error == nil
                         ? "\(engineName) не сообщил ни одной модели."
                         : "Список не получен.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(models.installed, id: \.name) { model in
                        LabeledContent(model.name) {
                            HStack(spacing: 8) {
                                Text(models.isResident(model)
                                     ? RussianCopy.modelSize(model.sizeBytes) + " · в памяти"
                                     : RussianCopy.modelSize(model.sizeBytes))
                                    .foregroundStyle(.secondary)
                                // Per row, and only for a model the engine says it is holding.
                                // There is deliberately no «выгрузить всё»: a loaded instance
                                // reports its id and its configuration and nothing about who
                                // loaded it, so a blanket command could only reach another
                                // application's model or lie about its own scope.
                                if models.isResident(model) {
                                    Button("Выгрузить") {
                                        Task {
                                            await models.unload(model)
                                            // The status line and the menu-bar glyph both read
                                            // residency, and neither is on a timer — so the
                                            // action that changes it is the one that has to say
                                            // so, or the app goes on claiming the model is
                                            // resident until something unrelated refreshes.
                                            await onRefresh()
                                        }
                                    }
                                    .disabled(models.isPulling)
                                }
                            }
                        }
                    }
                }
            }

            // Spec §5.3 calls this section «Загрузка» and it ships as «Загрузить модель»,
            // deliberately. «Загрузка» is ambiguous in exactly the place it cannot afford to
            // be: this pane says «модель в памяти» and «модель не загружена» a few rows above,
            // so the bare noun reads as «loading into memory» as readily as «downloading»,
            // which is the one thing this section does not do. The verb phrase says which.
            // «Скачать», not «Загрузить», and the rename is the point of this section rather
            // than tidying. «Загрузка» already means something else two sections down — the
            // `keepAlive` caption says «Холодная загрузка стоит около двух секунд», where it
            // is the model being lifted into memory. One word for two operations in one pane
            // is the failure `CONTEXT.md` exists to prevent, seen from the other side: not one
            // concept under two names, but two concepts under one. Downloading is «скачать»
            // here and nowhere else; loading into memory keeps «загрузка».
            Section("Скачать модель") {
                // No `LabeledContent` label. The section header already says «Скачать модель»
                // and the button says «Скачать»; a third repetition on the row said nothing
                // and took horizontal space off the field, which is the control that needs it.
                HStack {
                    TextField("qwen2.5:3b", text: $modelToPull)
                    Button("Скачать") {
                        download(pullTarget)
                    }
                    .disabled(pullTarget.isEmpty || models.isPulling)
                }
                // The format belongs here and not in the placeholder. A placeholder is the
                // one piece of help that disappears at the moment it is needed — it clears on
                // focus, i.e. exactly when the user has decided to type — and it cannot say
                // where a name comes from. Ollama's own naming is the whole contract, so name
                // it and point at the catalogue.
                //
                // Guillemets, not backticks: built with `+`, so this reaches `Text`'s
                // plain-`String` initialiser, which never parses Markdown and would render a
                // backtick as a grave accent.
                Text("Имя такое же, как у команды «ollama pull» — «название:тег». "
                     + "Каталог моделей: ollama.com/library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Said before the request rather than after it. Ollama answers a pull for an
                // installed model by re-fetching it, which is a legitimate way to update a
                // tag and a surprising way to spend several gigabytes — so the distinction is
                // worth drawing while the button is still unpressed.
                if !pullTarget.isEmpty, models.installedNames.contains(pullTarget) {
                    SettingsNote(text: "«\(pullTarget)» уже установлена — скачивание обновит её.",
                                 icon: "arrow.triangle.2.circlepath", tint: .secondary)
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
                    SettingsNote(text: error, icon: "xmark.octagon.fill", tint: StatusColour.failure)
                }
            }

            // Two sections where «Дополнительно» used to be one. That section held three
            // settings answering two unrelated questions — how fast a translation starts, and
            // how good it is — under a heading that said only that they were rare. Splitting
            // them lets each heading say what its settings are for, and puts the two residency
            // settings side by side: «Загружать при запуске» gets the model into memory once,
            // «Держать в памяти» decides how long it stays. Neither is understandable without
            // the other, and until now they were in different tabs.
            Section("Модель в памяти") {
                Toggle("Загружать модель при запуске", isOn: $settings.warmUpOnLaunch)
                Text("Первый перевод иначе ждёт около двух секунд, пока модель поднимается "
                     + "в память.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.engine == .lmStudio {
                    // The `keepAlive` field below is Ollama's `keep_alive` and nothing else:
                    // LM Studio's chat endpoint **rejects** a `ttl` field outright (measured
                    // 2026-08-21 — HTTP 400, «Unrecognized key(s) in object: 'ttl'»), and a
                    // model this app loads explicitly stays until it is unloaded. Hidden rather
                    // than disabled, because a disabled field invites the reader to look for
                    // the switch that enables it, and there is none.
                    Text("LM Studio держит модель до выгрузки — время простоя задаётся в самом "
                         + "LM Studio, а не здесь. Выгрузить вручную можно в «Установленных "
                         + "моделях».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                TextField("Держать модель в памяти", text: $settings.keepAlive)
                // Guillemets, not backticks: building the string with `+` forces `Text`'s
                // plain-`String` initialiser instead of the `LocalizedStringKey` one, so
                // Markdown is never parsed and backticks would render as literal grave
                // accents.
                Text("Формат Ollama: «30m», «1h», «0» — выгружать сразу, «-1» — держать всегда. "
                     + "Короткое значение возвращает те же две секунды каждому первому "
                     + "переводу после паузы.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Качество перевода") {
                // «Длина одного запроса к модели», not «Размер фрагмента». `CONTEXT.md` names
                // this concept «чанк» and lists «фрагмент» under _Avoid_ — those lists are
                // words that caused a real ambiguity, not preferences — so the old label broke
                // the project's own glossary. «Чанк» is not the fix either: it is a
                // transliteration that means nothing to someone translating a document. The
                // way out is to name the setting by what the number governs rather than by the
                // internal concept, so the concept needs no user-facing word at all.
                //
                // Through `RussianCopy.plural` rather than a bare «символов». The stepper's
                // own 100-character step never leaves the «символов» form, but `chunkSize`
                // reads straight from `UserDefaults` on every access precisely so a value set
                // outside the app is picked up — and `defaults write … chunkSize 901` would
                // then render «901 символов».
                Stepper("Длина одного запроса к модели: \(settings.chunkSize) "
                        + RussianCopy.plural(settings.chunkSize, "символ", "символа", "символов"),
                        value: $settings.chunkSize, in: 300...4000, step: 100)
                Text("Длинный текст переводится по частям. Больше — связнее перевод, "
                     + "но дольше до первого результата.")
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
                // The caption now says what the number *is* before saying which way to turn
                // it. «Температура» is the model's own term and stays — it is what every other
                // tool calls this and what the user will meet elsewhere — but a term nobody
                // defines is a number nobody dares move.
                Text("Насколько модель вольна отступать от буквального перевода. "
                     + "Ниже — предсказуемее и ближе к оригиналу. По умолчанию 0,2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Отключать рассуждение модели", isOn: $settings.quietThinking)
                // The caption says what the app does with the trace, because that is the fact
                // that makes the default defensible: a discarded trace costs only time.
                // Measured 2026-08-11: qwen3:8b writes 2621 characters of it before the first
                // character of translation.
                Text("Некоторые модели сначала рассуждают вслух. В перевод это не попадает — "
                     + "приложение отбрасывает такой текст, — но тратит время до первого слова.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Not `settings.usesGptOss` any more: on LM Studio no publisher-qualified name
                // matches `ModelPolicy`'s prefix table, so that rule would never draw the row
                // there. `ModelsViewModel` asks the right question per engine — the table on
                // Ollama, and «offers levels but cannot be silenced» on LM Studio, which is
                // also what keeps this control from contradicting the checkbox above it.
                if models.showsReasoningLength(for: settings) {
                    Picker("Длина рассуждения:", selection: $settings.gptOssThinkingLevel) {
                        ForEach(ThinkRequest.Level.allCases, id: \.self) { level in
                            Text(level.russianName).tag(level)
                        }
                    }
                    // Disabled rather than hidden: a control that vanished when an unrelated
                    // switch moved would read as a bug rather than as a dependency.
                    .disabled(!settings.quietThinking)
                    Text("Эта модель не умеет выключать рассуждение — только укоротить.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsPane()
        .task { await reload() }
    }

    /// The one download path, reached from two places: the «Скачать» button beside the field,
    /// and the one beside «не установлена» in the picker's note.
    ///
    /// The success case clears the field **only when the field is what asked for this
    /// download**. The picker's button downloads a name the picker knows, which may be
    /// nothing like whatever the user has half-typed below it; emptying the field there would
    /// throw away their work for a download they started somewhere else.
    ///
    /// On failure the name stays either way, so a retry costs no retyping — and the failure
    /// itself is on screen, because `pull` puts it in `models.error` and this section renders
    /// it.
    private func download(_ name: String) {
        guard !name.isEmpty else { return }
        Task {
            await models.pull(name)
            if models.error == nil, name == pullTarget { modelToPull = "" }
        }
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
    /// Starts a download of the named model, exactly as the «Скачать модель» section's own
    /// button does. Passed in rather than calling `models.pull` here, so both entry points go
    /// through the one method that also clears the field and reports failure.
    let onDownload: (String) -> Void

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
            // A button, not an instruction. This note used to read «Введите это имя в поле
            // „Загрузить модель“ ниже» — the app asking the user to retype a string the app
            // was already holding, and the commonest reason anyone types in that field at all.
            // The name is known exactly here, so the download is one press.
            HStack {
                SettingsNote(text: "«\(selection)» не установлена.",
                             icon: "arrow.down.circle", tint: StatusColour.warning)
                Button("Скачать") { onDownload(selection) }
                    .font(.caption)
                    .disabled(models.isPulling)
            }
        }
        // Blacklisted models stay selectable: the reason is measured evidence, and the user
        // may have a reason to override it.
        if let warning = models.warning(for: selection) {
            SettingsNote(text: warning, icon: "exclamationmark.triangle.fill", tint: StatusColour.warning)
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
