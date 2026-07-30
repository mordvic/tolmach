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
            Picker("Перевод на", selection: $language) {
                ForEach(Language.allCases, id: \.self) { Text($0.russianName).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 140)
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
