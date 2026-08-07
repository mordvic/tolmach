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
                    ForEach(models.installedNames, id: \.self) { Text($0).tag(String?.some($0)) }
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
                Toggle("Останавливаться на предупреждениях", isOn: $settings.stopOnWarnings)
                Text("Иначе очередь идёт до конца, а разметку и термины можно посмотреть "
                     + "у каждого файла после.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Термины документа") {
                Toggle("Показывать перед переводом", isOn: $settings.reviewDocumentTerms)
                    // Disabled until the review gate lands. A switch that does nothing is
                    // worse than one that says it is not ready yet: the first is a bug the
                    // user reports, the second is a promise.
                    .disabled(true)
                Text("Список терминов из файла можно будет поправить до перевода. "
                     + "Пока не работает — появится вместе с окном «Термины документа».")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}
