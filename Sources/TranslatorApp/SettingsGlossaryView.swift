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

    @State private var query = ""
    @State private var order: [Int] = []
    @State private var selection: Set<Int> = []

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
                GlossaryHeader(query: $query, language: languageBinding,
                               count: glossary.file.entries.count,
                               canRemove: !selection.isEmpty,
                               onAdd: add, onRemove: removeSelected)
            }

            Section("Термины") {
                if glossary.file.entries.isEmpty {
                    Text("Глоссарий пуст. Термины из него попадают в каждый перевод — "
                         + "добавьте первый кнопкой «плюс».")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if order.isEmpty {
                    Text("Ничего не найдено.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    // By index, and not a `Table`. Two independent reasons, both
                    // load-bearing. `Table` needs a stable identity per row, and rows have
                    // none: `term` is the only candidate, nothing on the path into
                    // `file.entries` uniques it — the file is hand-edited and «Добавить
                    // термин» appends a blank — so keying by term collapses two real rows
                    // into one and silently drops the other's translation.
                    List(order, id: \.self, selection: $selection) { index in
                        GlossaryEntryRow(entry: entryBinding(index),
                                         language: editingLanguage,
                                         onRemove: { remove(at: index) })
                    }
                    .frame(minHeight: 200)
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
                            // Bounds-checked for the same reason `entryBinding` is: during
                            // the update that follows a removal SwiftUI can still evaluate
                            // the body of a row that no longer exists, and an unchecked
                            // subscript traps there.
                            Text(glossary.file.mutedTerms.indices.contains(index)
                                 ? glossary.file.mutedTerms[index] : "")
                            Spacer()
                            Button("вернуть") { unmute(at: index) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }

            Section {
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
        }
        .settingsPane()
        .onAppear { reorder() }
        .onChange(of: query) { _, _ in reorder() }
    }

    private var languageBinding: Binding<Language> {
        Binding(get: { editingLanguage }, set: { languageOverride = $0 })
    }

    /// Recomputed here and nowhere else. See `GlossaryOrder`'s doc comment: recomputing on
    /// every keystroke would move the row the user is editing out from under the caret.
    private func reorder() {
        order = GlossaryOrder.visibleOrder(entries: glossary.file.entries, query: query)
        selection = selection.filter { order.contains($0) }
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

    private func add() {
        glossary.file.entries.append(GlossaryEntry(term: ""))
        persist()
        reorder()
    }

    private func remove(at index: Int) {
        guard glossary.file.entries.indices.contains(index) else { return }
        glossary.file.entries.remove(at: index)
        persist()
        reorder()
    }

    /// Descending, so each removal cannot shift the index of one not yet removed.
    private func removeSelected() {
        for index in selection.sorted(by: >) where glossary.file.entries.indices.contains(index) {
            glossary.file.entries.remove(at: index)
        }
        selection = []
        persist()
        reorder()
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
            // Guarded: `persist()` runs on every keystroke, and `@Observable` has no
            // equality short-circuit, so an unconditional `= nil` would invalidate every
            // view reading `lastProblem` — including the main window — per character typed.
            if glossary.lastProblem != nil { glossary.lastProblem = nil }
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

    /// Delegates straight to `load()`, which now fails closed: a throw there resets both
    /// `isLoaded` and the stamp, so a reload of a malformed file cannot leave the store
    /// holding this session's entries while stamped against the user's broken one. An
    /// earlier revision of this method pre-decoded the file to compensate for `load()` not
    /// doing that; the check belonged in the store and is now there.
    private func reload() {
        do {
            try glossary.load()
            glossary.lastProblem = nil
        } catch {
            glossary.lastProblem = "Не удалось прочитать файл глоссария, в приложении осталась "
                + "прежняя версия. Файл на диске не изменён: \(error.localizedDescription)"
        }
        reorder()
    }
}
