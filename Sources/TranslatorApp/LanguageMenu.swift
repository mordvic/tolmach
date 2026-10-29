// Sources/TranslatorApp/LanguageMenu.swift
import SwiftUI
import TranslationCore

/// A sheet's language, named over the text it describes, as a menu that changes it.
///
/// **Over the text, not in the toolbar, since 2026-10-29.** The toolbar read «Из Определить ⇄
/// В По правилу» — a sentence about two panes, half a window away from either. On the sheets each
/// name sits over the text that is in that language, which is what DeepL and Google Translate
/// do, and the toolbar keeps what the whole window does: the operation, how, and the primary
/// action. The «Из» and «В» the toolbar needed to say which side was which are gone with it —
/// the position says it.
///
/// The binding is whichever model owns the visible mode's run — the queue's own in «Файлы» —
/// for the reason `MainWindowView` gives: one binding for both modes is how a hand-off into
/// «Текст» once reset a queue's language.
struct LanguageMenu: View {
    let selection: Binding<Language?>
    /// The row that clears the override, and the title while nothing better is known. Passed
    /// once and used for both, so the header cannot come to show one word while the menu under
    /// it offers another.
    let placeholder: String
    /// The language the sheet's text is actually in when no override names one. The перевод
    /// sheet passes the target the run on screen resolved by the settings' rule; the исходник
    /// sheet passes what that run detected — but only while the text under it is still the text
    /// that was detected (`TranslationViewModel.detectedSourceOnScreen`), because a header naming
    /// the language of a text that is no longer there is worse than «Определить язык».
    var resolved: Language? = nil
    let help: String

    /// The title: the chosen language, else the one the sheet's text is in, else the placeholder.
    /// Named plainly either way, as the chosen design draws it; the menu's check mark on
    /// «Определить язык» or «По правилу» is what says the name was not picked by hand.
    static func title(selection: Language?, resolved: Language?, placeholder: String) -> String {
        (selection ?? resolved)?.russianTitle ?? placeholder
    }

    var body: some View {
        Menu {
            Picker(help, selection: selection) {
                Text(placeholder).tag(Language?.none)
                ForEach(Language.allCases, id: \.self) {
                    Text($0.russianTitle).tag(Language?.some($0))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(Self.title(selection: selection.wrappedValue, resolved: resolved,
                            placeholder: placeholder))
        }
        // The body size at its regular weight, as the chosen design sets a sheet's language.
        .font(.body)
        .buttonStyle(.borderless)
        .fixedSize()
        // A borderless menu draws its title 3 pt in from its own leading edge — measured
        // 2026-10-29 by rendering a `Text` and a borderless `Menu` with the same title to a
        // bitmap, both `.menuStyle`s, at the medium and at the regular weight: first ink at
        // 21 pt and 24 pt every time. Without this the language stood 3 pt right of the
        // sheet's text and of «Оригинал»/«Правка», which `PaneTitle` draws as plain text.
        .padding(.leading, -3)
        .help(help)
    }
}
