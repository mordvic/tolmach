// Sources/TranslatorApp/PaneViewChoice.swift
import Foundation

/// The перевод pane's header picker, as a value: which segments it offers and what each one
/// writes into the two settings it stands for.
///
/// One control, up to three segments, and never two pickers side by side — the pane's header
/// at its 280 pt minimum already holds this picker and two link buttons, and a second
/// segmented control is the shape `Scripts/toolbar-fit.swift` exists to refuse
/// (`docs/design/specs/2026-09-04-change-marks-spec.md`, «Deviations from the design»).
///
/// For перевод the picker is exactly what it was: «Разметка | Исходник» over
/// `AppSettings.showsRenderedMarkup`, drawn only when either pane has markup. For a finished
/// правка it gains «Изменения» — `AppSettings.showsChangeDetail` — and «Исходник» stays
/// reachable, because the same setting governs the исходник pane's editor and a правка over
/// a Markdown source still needs its raw view. The two settings are written from one segment
/// so the pane and the panel's «Вид» menu read one state.
///
/// A value rather than a `Binding` built inline, for `PrimaryAction`'s reason: which segments
/// exist and what «Исходник» leaves alone are decisions, and a decision inside a `body` can
/// only be read by rendering the header.
enum PaneViewChoice: String, CaseIterable, Identifiable {
    /// «Разметка» for перевод, «Результат» for правка — the rendered document (or plain text)
    /// with, for правка, the changed ranges underlined.
    case rendered
    /// «Изменения»: the same document with the removed text struck through inline. Offered
    /// only with a change set.
    case changes
    /// «Исходник»: the pane's raw characters — the Markdown itself, still with the underlines
    /// for правка.
    case source

    var id: String { rawValue }

    /// What the picker offers. `hasChanges` is «this pane shows a finished правка with a
    /// change set», `offersSource` is `TranslationPane.offersToggle` — either pane has markup.
    /// With neither there is no picker at all, which is the caller's guard, not this one's.
    static func segments(hasChanges: Bool, offersSource: Bool) -> [PaneViewChoice] {
        var result: [PaneViewChoice] = [.rendered]
        if hasChanges { result.append(.changes) }
        if offersSource { result.append(.source) }
        return result
    }

    /// Which segment the two settings currently describe.
    ///
    /// `showsRenderedMarkup == false` is «Исходник» whatever `showsChangeDetail` says, because
    /// the raw view has no inline deletions — the detail setting is left as it was so that
    /// coming back to «Разметка» restores the view the reader left. Without a change set the
    /// detail setting is ignored: a перевод pane never shows «Изменения», and a stale `true`
    /// from an earlier правка must not make its picker point at a segment it does not draw.
    static func current(showsRenderedMarkup: Bool, showsChangeDetail: Bool,
                        hasChanges: Bool) -> PaneViewChoice {
        guard showsRenderedMarkup else { return .source }
        return hasChanges && showsChangeDetail ? .changes : .rendered
    }

    /// The two settings a segment writes. `nil` for a setting the segment leaves alone.
    ///
    /// «Исходник» writes only `showsRenderedMarkup`: flipping the detail off there would make
    /// «Исходник» → «Разметка» land on «Результат» for a reader who had chosen «Изменения»,
    /// and the raw view never draws deletions anyway, so the setting has nothing to say there.
    var writes: (showsRenderedMarkup: Bool, showsChangeDetail: Bool?) {
        switch self {
        case .rendered: (true, false)
        case .changes: (true, true)
        case .source: (false, nil)
        }
    }

    /// The segment's label, which depends on what the pane is showing: the same first segment
    /// reads «Разметка» over a translation and «Результат» over a правка, because «разметка»
    /// of a corrected mail would name the wrong thing about it.
    func label(hasChanges: Bool) -> String {
        switch self {
        case .rendered: hasChanges ? "Результат" : "Разметка"
        case .changes: "Изменения"
        case .source: "Исходник"
        }
    }
}
