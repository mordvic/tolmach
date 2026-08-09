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

    /// The language the user picked in the header, or nil while they have not picked one.
    @State private var languageOverride: Language?

    /// The language the *glossary* says it is written in, worked out by `GlossaryColumn` when
    /// the pane appears and when the file is re-read.
    ///
    /// Held rather than recomputed, and that is a correctness requirement rather than a
    /// performance one — see `GlossaryColumn`'s contract. `entryBinding` writes through
    /// `translations[editingLanguage.rawValue]`, so a language that moved between two
    /// keystrokes would put the rest of a word under a different key.
    ///
    /// Nil only before the first `onAppear`, which is why the expression below still ends in a
    /// setting: for that one evaluation there is nothing derived to use yet.
    @State private var derivedLanguage: Language?

    @State private var query = ""
    @State private var order: [Int] = []
    @State private var selection: Set<Int> = []

    /// The user's choice, else what the glossary is written in, else the language this app
    /// translates into by default.
    ///
    /// `primaryLanguage` and no longer `workingLanguage` at the end of that chain.
    /// `AppSettings.targetLanguage(forDetected:)` sends everything that is not already in the
    /// user's own language *into* it, so the primary language is where translations land in the
    /// common direction — and the old default named the other one. `GlossaryColumn` carries
    /// what that cost: a pane whose every «перевод» field was blank on a default install.
    private var editingLanguage: Language {
        languageOverride ?? derivedLanguage ?? settings.primaryLanguage
    }

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
                    .foregroundStyle(StatusColour.failure)
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
                    // C3: by index, and not a `Table`. `Table` needs a stable identity per
                    // row, and rows have none: `term` is the only candidate, nothing on the
                    // path into `file.entries` uniques it — the file is hand-edited and
                    // «Добавить термин» appends a blank — so keying by term collapses two
                    // real rows into one and silently drops the other's translation.
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
                            // «Вернуть» with a capital, like every other button in this window.
                            // A `.link` style is not a reason to lowercase a label — the two
                            // «не показывать» links in `WarningsView` sit inside a sentence and
                            // read as its continuation, but this one stands alone at the end of
                            // a row and is a button in everything except its styling.
                            Button("Вернуть") { unmute(at: index) }
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
        .onAppear { deriveColumn(); reorder() }
        .onChange(of: query) { _, _ in reorder() }
    }

    private var languageBinding: Binding<Language> {
        Binding(get: { editingLanguage }, set: { languageOverride = $0 })
    }

    /// Recomputed at exactly two moments, and the omissions are the point.
    ///
    /// Appearing and re-reading the file are the two occasions on which the whole set of
    /// entries can be something this pane has not seen. Adding, removing, searching and typing
    /// are deliberately **not** among them: those happen while the user is working in the
    /// rows, and `GlossaryColumn`'s contract is that the column must not move under an
    /// editing caret — `entryBinding` writes through the language, so a move mid-word splits
    /// one translation across two keys.
    ///
    /// It does not touch `languageOverride`. A user who picked a language keeps it for the
    /// life of the pane, including across a re-read.
    private func deriveColumn() {
        derivedLanguage = GlossaryColumn.language(for: glossary.file.entries,
                                                  fallback: settings.primaryLanguage)
    }

    /// Recomputed here and nowhere else. See `GlossaryOrder`'s doc comment: recomputing on
    /// every keystroke would move the row the user is editing out from under the caret.
    ///
    /// `indicesMayHaveShifted` must be true from `remove(at:)` and `reload()`: a removal
    /// shifts every later index down by one, and a re-read can replace what an index points
    /// at, so a selected index surviving `order.contains(_:)` there can silently now denote a
    /// different row. `.onAppear`, the search changing and `add()` never shift or repurpose
    /// an existing index, so the default lets a selection survive them.
    private func reorder(indicesMayHaveShifted: Bool = false) {
        order = GlossaryOrder.visibleOrder(entries: glossary.file.entries, query: query)
        selection = GlossaryOrder.selection(selection, survivingIn: order,
                                            indicesMayHaveShifted: indicesMayHaveShifted)
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
        reorder(indicesMayHaveShifted: true)
    }

    /// Descending, so each removal cannot shift the index of one not yet removed.
    private func removeSelected() {
        for index in selection.sorted(by: >) where glossary.file.entries.indices.contains(index) {
            glossary.file.entries.remove(at: index)
        }
        // `indicesMayHaveShifted: true`, because removal is exactly the situation that
        // parameter names — every index after the smallest one removed now points at a
        // different row. `selection = []` two lines up already empties the set `reorder`
        // would filter, so today the flag cannot change the outcome; it is passed anyway so
        // the truth sits in the contract instead of in the order of these statements. Belt
        // and braces on purpose: swap these two lines, or add a second removal path that
        // forgets the clear, and `false` here would silently reintroduce the stale-index
        // defect `indicesMayHaveShifted` exists to prevent — a selection surviving past a
        // removal it should not have survived, deleting the wrong term on the next edit.
        selection = []
        persist()
        reorder(indicesMayHaveShifted: true)
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
        // The file that was just read can be written in a different language from the one this
        // session started with — that is the whole point of «Перечитать файл», and a glossary
        // edited by hand or pulled from git is exactly where it happens. Recomputed before the
        // rows are, so the column and the order describe the same file.
        deriveColumn()
        // A file re-read at the same or a greater row count leaves every selected index in
        // range, but now naming whatever term is at that position in the new file — not the
        // row the user actually selected. Only a shrink past the selected index would be
        // caught by a plain membership filter, which is why this must clear rather than
        // filter, on both the success and the failure path.
        reorder(indicesMayHaveShifted: true)
    }
}
