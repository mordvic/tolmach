// Sources/TranslatorApp/PanelReplyView.swift
import Foundation

/// The panel's «Вид» menu, as a value: which of three texts the reply area is drawing.
///
/// The panel's counterpart to the pane's `PaneViewChoice`, and deliberately **not** the same
/// type. The pane's third segment is «Исходник» — the raw Markdown of the text it is already
/// showing — and the panel's third item is «оригинал», the text the user selected before
/// правка touched it. Those are two different things, and the panel says «оригинал» precisely
/// so that one word does not mean two of them one control apart: «Исходник» already means «the
/// raw form of a pane» everywhere else in this app (`CONTEXT.md`).
///
/// The panel has no «Исходник» item at all, for the reason the panel has no toggle of its own:
/// it is one column beside the pointer, and `AppSettings.showsRenderedMarkup` — written in the
/// window's pane — is what decides whether the reply is drawn from its Markdown here too.
///
/// A value rather than three conditions written inside `proofreadingControls`, for
/// `PaneViewChoice`'s reason: which items exist, which one the flags currently describe and
/// what each one writes are decisions, and a decision inside a `body` can only be read by
/// rendering the row.
enum PanelReplyView: String, CaseIterable, Identifiable {
    /// The правка's result, with every changed range underlined.
    case result
    /// The same result with the removed words spliced in, struck through, before what replaced
    /// them. Offered only when there is something to show — see `items(hasChanges:)`.
    case changes
    /// The text the user selected, unmarked. The window puts the исходник pane beside the
    /// перевод one; the panel has a single column, so this is the only place «what did it say
    /// before» can live there — story 9.
    case original

    var id: String { rawValue }

    /// What the menu offers.
    ///
    /// «изменения» is dropped rather than disabled when a правка changed nothing: with an empty
    /// change set it draws exactly the document «результат» draws, and `current(...)` below
    /// would then answer `.result` for a menu still pointing at «изменения» — a selection that
    /// snaps back the moment it is made. `PaneViewChoice.segments(hasChanges:offersSource:)`
    /// takes the same segment away for the same reason.
    static func items(hasChanges: Bool) -> [PanelReplyView] {
        hasChanges ? allCases : [.result, .original]
    }

    /// Which item the panel's two flags currently describe.
    ///
    /// «оригинал» wins outright: it is a per-presentation choice on `HotkeyCoordinator` and it
    /// says which *text* is drawn, while `showsChangeDetail` only says how the reply is marked
    /// once it is the reply being drawn. Without a change set the detail setting is ignored, for
    /// the reason `items(hasChanges:)` drops the item — a `true` left over from an earlier
    /// правка must not point the menu at something it does not offer.
    static func current(showsOriginal: Bool, showsChangeDetail: Bool,
                        hasChanges: Bool) -> PanelReplyView {
        if showsOriginal { return .original }
        return showsChangeDetail && hasChanges ? .changes : .result
    }

    /// The two things choosing this item writes: `HotkeyCoordinator.showsOriginal`, and
    /// `AppSettings.showsChangeDetail` — or nil for the item that leaves the setting alone.
    ///
    /// «оригинал» leaves it alone, which is `PaneViewChoice.source`'s rule and is there for the
    /// same reason: a reader who was on «изменения», glanced at the original and came back must
    /// land on «изменения» again rather than on «результат».
    var writes: (showsOriginal: Bool, showsChangeDetail: Bool?) {
        switch self {
        case .result: (false, false)
        case .changes: (false, true)
        case .original: (true, nil)
        }
    }
}
