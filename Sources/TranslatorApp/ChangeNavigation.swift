// Sources/TranslatorApp/ChangeNavigation.swift
import TranslationCore

/// Whether «Следующее изменение» / «Предыдущее изменение» are live — the «Перевод» menu's
/// rule, as a value the menu and a test both read.
///
/// The menu is declared in the app's scene and cannot be rendered in a test, so this is the
/// same shape `PrimaryAction` takes: the decision is a function over what the menu can see,
/// and the menu item reads it rather than restating it. Two conditions and both matter —
/// «Текст» because the queue's pane never carries marks (a файл's translation is a перевод),
/// and a non-empty set because a стрелка that wraps over zero changes would flash nothing.
enum ChangeNavigation {
    static func isAvailable(mode: SourceMode, changes: ChangeSet?) -> Bool {
        mode == .text && (changes?.count ?? 0) > 0
    }
}
