// Sources/TranslatorApp/SettingsGlossaryView.swift
import Foundation
import SwiftUI
import TranslationCore

struct SettingsGlossaryView: View {
    /// A plain `let`, not `@Bindable`, for the same reason `MainWindowView` uses one: every
    /// binding in this pane is built by hand below so it can be bounds-checked and can
    /// persist on write, so there is nothing for `$glossary` to produce. Observation still
    /// tracks the reads of `file` and `lastProblem` through a stored reference.
    let glossary: GlossaryStore
    /// Read only. The pane needs a language to key the translation column by; it never
    /// writes settings.
    let settings: AppSettings

    /// Which language's translation the rows show. `nil` means "follow the working
    /// language", which is the useful default: that is the language the primary-language
    /// text gets translated into. A `@State` initialised from `settings` instead would be
    /// captured once, at the first render, and then silently stop following the setting.
    @State private var languageOverride: Language?

    private var editingLanguage: Language { languageOverride ?? settings.workingLanguage }

    /// Not observable — `FileManager` has nothing to notify SwiftUI with. It does not need
    /// to be: the only thing that creates this file is a save from this app, and every save
    /// here follows a mutation of `glossary.file`, which is observed and redraws the pane.
    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: glossary.url.path)
    }

    var body: some View {
        Form {
            Section {
                // C2: `lastProblem`'s unconditional home. It was previously rendered only
                // inside `MainWindowView`'s `state == .finished` block, so a glossary that
                // failed to load at startup told the user nothing until they had finished a
                // translation — by which point the run had already gone out without the
                // glossary. Here it is on screen whenever there is something to say.
                if let problem = glossary.lastProblem {
                    Label { Text(problem) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                HStack {
                    // Reveals in Finder rather than opening — hence the label. The plan said
                    // «Открыть файл», but `activateFileViewerSelecting` does not open
                    // anything, and a button that names an action it does not perform is the
                    // kind of small lie this app's copy avoids elsewhere.
                    Button("Показать файл в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([glossary.url])
                    }
                    .disabled(!fileExists)
                    // C2: without this the app has no way back once `save()` starts throwing
                    // `fileChangedOnDisk` — nothing else re-reads the file, so saving stays
                    // broken for the rest of a session that, in a menu-bar app, can run for
                    // days. Always available, not only after a failure: hand-editing
                    // glossary.json is the documented workflow (spec 9), and picking the
                    // edit up without a relaunch is worth a button on its own.
                    Button("Перечитать файл") { reload() }
                }
                // C5: `activateFileViewerSelecting` on a path that does not exist selects
                // nothing and opens nothing — a button that appears to do nothing at all.
                // The file is not created eagerly to make the button work: writing to disk
                // is not what «показать» promises, and on the one path where it would matter
                // most — a glossary that failed to load — `save()` refuses anyway, by
                // design. So the button is disabled and the reason is written down.
                Text(fileExists
                     ? "Файл: \(glossary.url.path)"
                     : "Файла ещё нет — он появится при первом изменении. Тогда его можно "
                       + "будет править и вручную: \(glossary.url.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Термины") {
                Picker("Показывать перевод на", selection: languageBinding) {
                    ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
                }
                // C3: by index, and not a `Table`. Two independent reasons, both load-bearing.
                // `Table` needs bindings into its rows, and until this task `GlossaryEntry`'s
                // stored properties were `let`, so there was nothing to bind to. And rows
                // have no stable identity: `term` is the only candidate, nothing on the path
                // into `file.entries` uniques it — the file is hand-edited and «Добавить
                // термин» appends a blank — so keying by term collapses two real rows into
                // one and silently drops the other's translation.
                ForEach(Array(glossary.file.entries.indices), id: \.self) { index in
                    GlossaryEntryRow(entry: entryBinding(index),
                                     language: editingLanguage,
                                     onRemove: { remove(at: index) })
                }
                Button("Добавить термин") {
                    glossary.file.entries.append(GlossaryEntry(term: ""))
                    persist()
                }
            }

            if !glossary.file.mutedTerms.isEmpty {
                Section("Скрытые предупреждения") {
                    ForEach(Array(glossary.file.mutedTerms.indices), id: \.self) { index in
                        HStack {
                            // Indexed for the same reason as the entries above: `mute` dedupes
                            // what it adds, but the file is hand-editable and can hold two
                            // identical lines, and removing "one of the two" by value would
                            // take both.
                            Text(glossary.file.mutedTerms[index])
                            Spacer()
                            Button("вернуть") { unmute(at: index) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }

    private var languageBinding: Binding<Language> {
        Binding(get: { editingLanguage }, set: { languageOverride = $0 })
    }

    /// Bounds-checked in both directions on purpose. The rows are identified by index, so
    /// during the update that follows a removal SwiftUI can still read and write the binding
    /// of a row that no longer exists; an unchecked `entries[index]` traps there.
    ///
    /// Persisting inside `set` rather than at each call site is what makes "every mutation
    /// is saved" structural: `TextField` and `Toggle` write through this binding and have no
    /// other hook to hang a save on.
    private func entryBinding(_ index: Int) -> Binding<GlossaryEntry> {
        Binding(
            get: {
                glossary.file.entries.indices.contains(index)
                    ? glossary.file.entries[index]
                    : GlossaryEntry(term: "")
            },
            set: { newValue in
                guard glossary.file.entries.indices.contains(index) else { return }
                glossary.file.entries[index] = newValue
                persist()
            })
    }

    private func remove(at index: Int) {
        guard glossary.file.entries.indices.contains(index) else { return }
        glossary.file.entries.remove(at: index)
        persist()
    }

    private func unmute(at index: Int) {
        guard glossary.file.mutedTerms.indices.contains(index) else { return }
        glossary.file.mutedTerms.remove(at: index)
        persist()
    }

    /// C1: a real `do`/`catch`, not `try?`. The plan asked for `try? glossary.save()`, which
    /// is precisely what Task 9 replaced in `MainWindowView.mute` and for the same reason —
    /// a silent failure leaves the user believing an edit is on disk when it is not, and
    /// they lose it on quit. The three cases need three different things said, so they are
    /// caught separately; the wording deliberately tracks `MainWindowView.mute`'s.
    private func persist() {
        do {
            try glossary.save()
            glossary.lastProblem = nil
        } catch GlossaryStoreError.saveBeforeLoad {
            glossary.lastProblem = "Глоссарий не был прочитан при запуске, поэтому изменения не "
                + "сохранены — иначе пустой список записался бы поверх вашего файла. "
                + "Исправьте файл и нажмите «Перечитать файл»."
        } catch GlossaryStoreError.fileChangedOnDisk {
            // Not «не удалось сохранить»: nothing is broken. The file changed under the app,
            // the app refused to write its stale copy over it, and unlike the main window —
            // which could only tell the user to relaunch — this pane has the way out on it.
            glossary.lastProblem = "Файл глоссария изменился на диске после запуска приложения, "
                + "поэтому изменения не сохранены — иначе ваши правки в файле были бы затёрты. "
                + "Нажмите «Перечитать файл», чтобы прочитать новую версию; сделанное здесь "
                + "после появления этого сообщения придётся ввести заново."
        } catch {
            glossary.lastProblem = "Не удалось сохранить глоссарий, изменения продержатся только "
                + "до перезапуска: \(error.localizedDescription)"
        }
    }

    /// Decodes the file before handing it to `load()`, which looks redundant and is not.
    ///
    /// `GlossaryStore.load()` stamps the file *before* it reads it, and leaves `isLoaded`
    /// alone when the decode throws. So a reload of a malformed file would leave the store
    /// holding this session's entries while stamped against the user's broken file — and the
    /// next save would then pass Task 9's guard and write over it. That is the very clobber
    /// the guard exists to prevent, re-armed backwards by the button meant to help. Decoding
    /// first means `load()` is only ever called with bytes already known to parse, so it
    /// cannot fail after moving the stamp. When the check fails nothing in the store is
    /// touched at all: it stays stamped against the version it read at launch, so saving
    /// keeps refusing and the user's file keeps surviving.
    private func reload() {
        do {
            if FileManager.default.fileExists(atPath: glossary.url.path) {
                _ = try JSONDecoder().decode(GlossaryFile.self,
                                             from: try Data(contentsOf: glossary.url))
            }
            try glossary.load()
            glossary.lastProblem = nil
        } catch {
            glossary.lastProblem = "Не удалось прочитать файл глоссария, в приложении осталась "
                + "прежняя версия. Файл на диске не изменён: \(error.localizedDescription)"
        }
    }
}

/// A view of its own so each row owns one `Binding<GlossaryEntry>` and SwiftUI can tell the
/// rows apart; also the only place that knows how an empty translation field maps onto the
/// dictionary.
private struct GlossaryEntryRow: View {
    @Binding var entry: GlossaryEntry
    let language: Language
    let onRemove: () -> Void

    /// An empty field means "this entry has no translation into this language", which is
    /// the absence of a key and not an empty string: `requiredTranslation(for:)` would
    /// otherwise hand `PromptBuilder` a rule instructing the model to render the term as
    /// nothing at all, and `GlossaryVerifier` would then look for that nothing in the output.
    ///
    /// The emptiness test trims but the stored value does not, so a user midway through
    /// typing «сервер профилей» does not have the space they just typed taken back out from
    /// under the cursor.
    private var translation: Binding<String> {
        Binding(
            get: { entry.translations[language.rawValue] ?? "" },
            set: { typed in
                if typed.trimmingCharacters(in: .whitespaces).isEmpty {
                    entry.translations.removeValue(forKey: language.rawValue)
                } else {
                    entry.translations[language.rawValue] = typed
                }
            })
    }

    var body: some View {
        HStack {
            TextField("термин", text: $entry.term)
                .frame(minWidth: 110)
            Toggle("не переводить", isOn: $entry.doNotTranslate)
                .toggleStyle(.checkbox)
            // Disabled rather than hidden, and the text stays readable: `doNotTranslate`
            // wins over `translations` everywhere it is consulted (see
            // `GlossaryEntry.requiredTranslation(for:)`), so an enabled field here would
            // accept edits that change nothing about any translation.
            TextField("перевод", text: translation)
                .frame(minWidth: 110)
                .disabled(entry.doNotTranslate)
            Button(role: .destructive) { onRemove() } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Удалить термин")
        }
    }
}
