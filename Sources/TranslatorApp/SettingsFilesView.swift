// Sources/TranslatorApp/SettingsFilesView.swift
import SwiftUI
import TranslationCore

/// Settings → «Файлы»: the queue's model, where its output goes, and whether it stops.
///
/// «Файлы» and not «Пакетный». Its three neighbours are «Основные», «Модели», «Глоссарий»
/// — all nouns — and «Пакетный» is an adjective with nothing to modify. It is also the same
/// word the window's own mode switch uses, which is what `CONTEXT.md`'s one-word-per-concept
/// rule is for.
struct SettingsFilesView: View {
    @Bindable var settings: AppSettings
    let models: ModelsViewModel

    var body: some View {
        Form {
            Section("Модель для пакетного перевода") {
                Picker("Модель", selection: $settings.batchModel) {
                    // Not a model name. `batchModel` has no fixed default because Ollama
                    // holds one model in memory — cold load ~2000 ms against ~155 ms warm —
                    // so a batch model differing from the interactive one costs two cold
                    // loads on every ⌥⌘T pressed during a queue run.
                    Text("Как для перевода по клавише").tag(String?.none)
                    // `options(selecting:)` and not `installedNames`, for the reason that
                    // function exists: a `Picker` bound to a value absent from its options
                    // renders blank, and a blank row is indistinguishable from «nothing
                    // selected» — so a stored model the user has since removed looked like
                    // the nil default, and touching the picker discarded it silently.
                    ForEach(models.options(selecting: settings.batchModel ?? ""), id: \.self) { name in
                        if !name.isEmpty { Text(models.optionLabel(name)).tag(String?.some(name)) }
                    }
                }
                Text("Здесь важнее качество перевода, чем время до первого символа, — можно "
                     + "взять модель медленнее той, что работает по сочетанию клавиш.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.batchModelDiffersFromInteractive {
                    Label("Ollama держит в памяти одну модель. Пока идёт очередь, каждое "
                          + "нажатие сочетания клавиш будет перезагружать модель — около "
                          + "двух секунд туда и столько же обратно.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Куда сохранять") {
                Toggle("Рядом с исходником", isOn: $settings.saveNextToSource)
                Text("techdoc-en.md → techdoc-en.ru.md. Существующий файл не "
                     + "перезаписывается — к имени добавляется номер.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Its own section, although the drawing puts this toggle under «Куда сохранять».
            // It governs when the queue stops, not where its output goes, and a user hunting
            // for «почему очередь встала» reads the heading and skips the section.
            Section("Очередь") {
                Toggle("Останавливаться на предупреждениях", isOn: $settings.stopOnWarnings)
                Text("Иначе очередь идёт до конца, а разметку и термины можно посмотреть "
                     + "у каждого файла после.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Термины документа") {
                Toggle("Показывать перед переводом", isOn: $settings.reviewDocumentTerms)
                Text("Список терминов можно поправить до перевода — они переводятся один раз "
                     + "и остаются одинаковыми во всех частях.")
                    .font(.caption).foregroundStyle(.secondary)
                // Not decoration: this is the only warning a user gets that ⌥⌘T may raise a
                // window, which is exactly the surprise the toggle ships off to avoid.
                Text("Работает везде, где перевод длиннее одной части, — и в окне, и по "
                     + "сочетанию клавиш. Для выделения по клавише главное окно выйдет "
                     + "на передний план.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // Nothing else loads the list for this tab: `reload()` is called from «Модели»'s
        // own `.task`, and `TabView` builds panes lazily — so opening Settings and clicking
        // «Файлы» first offered a picker with no models in it at all.
        .task { await models.reload() }
        .settingsPane()
    }
}
