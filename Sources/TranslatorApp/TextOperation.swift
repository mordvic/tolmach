import Foundation

/// Which of the app's two operations a surface is performing. App-layer, not
/// TranslationCore: the engine has two entry points and no need for a switch between
/// them; the switch is a UI concept (spec §5).
enum TextOperation: String, CaseIterable, Identifiable {
    case translate, proofread
    var id: String { rawValue }

    /// The vocabulary words from the spec's §1, used by the window's and the panel's
    /// segmented switches alike.
    var label: String {
        switch self {
        case .translate: "Перевод"
        case .proofread: "Правка"
        }
    }
}
