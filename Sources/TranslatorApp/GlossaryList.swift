// Sources/TranslatorApp/GlossaryList.swift
import SwiftUI
import TranslationCore

struct GlossaryHeader: View {
    @Binding var query: String
    @Binding var language: Language
    let count: Int
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Поиск", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
            Text("\(count) " + RussianCopy.plural(count, "термин", "термина", "терминов"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            // Spec §5.4 names this control «Показывать перевод на», and that wording is
            // restored here. It stays `.labelsHidden()` all the same: this is a header row
            // that already carries a search field, a term count and two buttons, and a
            // visible four-word label would take the width from the picker itself, which is
            // capped at 140 pt and is listed in `docs/reference/OPEN-ITEMS.md` §1 as not yet known to
            // fit the longest Russian language name. Hidden is visual only — the string is
            // still the control's accessibility label — and `.help` gives a sighted user the
            // same sentence on hover, which is what a bare popup was missing.
            Picker("Показывать перевод на", selection: $language) {
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 140)
            .help("Показывать перевод на выбранный язык")
            Button(action: onAdd) { Image(systemName: "plus") }
                .help("Добавить термин")
            Button(action: onRemove) { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Удалить выделенные термины")
        }
    }
}

/// A view of its own so each row owns one `Binding<GlossaryEntry>` and SwiftUI can tell the
/// rows apart; also the only place that knows how an empty translation field maps onto the
/// dictionary.
struct GlossaryEntryRow: View {
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
            // Stated, not inherited. These two fields carried no style at all while the
            // search field in `GlossaryHeader` above them and the «перевод» field in
            // `DocumentTermsView` both ask for `.roundedBorder` — three fields for one kind
            // of value, described by two rules. The drawing gives all of them the same
            // border, and `.automatic` inside a `List` inside a grouped `Form` is a
            // container-dependent answer to a question this row should not be asking.
            TextField("термин", text: $entry.term)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 110)
            Toggle("не переводить", isOn: $entry.doNotTranslate)
                .toggleStyle(.checkbox)
            // Disabled rather than hidden, and the text stays readable: `doNotTranslate`
            // wins over `translations` everywhere it is consulted (see
            // `GlossaryEntry.requiredTranslation(for:)`), so an enabled field here would
            // accept edits that change nothing about any translation.
            TextField("перевод", text: translation)
                .textFieldStyle(.roundedBorder)
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
