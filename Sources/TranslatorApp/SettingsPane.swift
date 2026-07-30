// Sources/TranslatorApp/SettingsPane.swift
import SwiftUI

/// The one size and form style every settings tab uses.
///
/// A modifier rather than three copies of two lines, because three copies is how the window
/// came to resize on every tab switch: the panes fixed 420, 420, 520 × 440 and 420, and a
/// `TabView` takes the size of the tab currently showing.
struct SettingsPane: ViewModifier {
    /// Wide enough for the glossary's four columns, which is the widest thing in the window.
    static let width: CGFloat = 560
    /// Tall enough for the models tab, which is the longest.
    static let height: CGFloat = 480

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .frame(width: Self.width, height: Self.height)
    }
}

extension View {
    func settingsPane() -> some View { modifier(SettingsPane()) }
}
