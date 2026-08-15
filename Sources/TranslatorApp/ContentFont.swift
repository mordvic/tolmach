// Sources/TranslatorApp/ContentFont.swift
import SwiftUI

/// Which face the user's own text is drawn in.
///
/// Three, and the closed set is the decision: these are `Font.Design` values, so nothing here
/// can name a font that is not installed, and there is no failure mode where a chosen face
/// disappears from the system and the app renders a blank picker. A list of installed families
/// would buy real freedom and cost exactly that guarantee.
///
/// `russianName` lives on the type rather than in `RussianCopy`, like `TextOperation.label`:
/// that file is for the domain enums `TranslationCore` owns, and this concept exists only in the
/// app layer.
///
/// **`.rounded` was considered and dropped.** SF Rounded is drawn for labels and dials rather
/// than paragraphs, and measured it is barely distinguishable from the system face at the same
/// size — `Scripts/content-font.swift` reports «iiiiiiiiii» at 32.0 pt wide under both, and
/// «MMMMMMMMMM» at 113.0 against 114.0. A fourth entry that looks like the first is a list that
/// reads as unconsidered.
enum ContentTypeface: String, CaseIterable, Identifiable, Sendable {
    case system, monospaced, serif

    var id: String { rawValue }

    /// «Шрифт» in the settings, never «начертание»: in Russian typography that word names bold
    /// or italic *within* a family, and what is chosen here is the family. See `CONTEXT.md`.
    var russianName: String {
        switch self {
        case .system: "Системный"
        case .monospaced: "Моноширинный"
        case .serif: "С засечками"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: .default
        case .monospaced: .monospaced
        case .serif: .serif
        }
    }
}

/// The typeface and size the **user's own text** is drawn in — the исходник, the перевод, and
/// the text in the панель. Not the interface's: every label, button, status row and table keeps
/// the system's size. `docs/adr/0008` carries why that boundary is where it is.
///
/// A value with rules rather than two loose numbers read at each site, for `PanelSizer`'s
/// reason: the range, the step and what «обычный размер» means are decisions, and decisions
/// spelled out at three call sites can only be read, not checked.
struct ContentFont: Equatable, Sendable {
    let typeface: ContentTypeface
    /// Always inside `sizes` — the initialiser is the only way in and it clamps. See below.
    let size: CGFloat

    /// **The floor is one point above the interface, and that is the whole of its reasoning.**
    /// Measured (`Scripts/content-font.swift`): every caption in this app is `.caption`, which
    /// is 10 pt; `.callout` is 12 and `.body` is 13. At 10 the user's text matches the words
    /// labelling it and at 9 it is smaller than them, which inverts the hierarchy — a
    /// translation set finer than the word «Перевод» above it.
    ///
    /// The ceiling is deliberately not lowered to something that keeps the панель pretty. At
    /// 32 pt a 560 pt panel holds 33 characters of Russian prose per line, which is a narrow
    /// column — but the only argument for 24 is that column, and the argument against it is
    /// that a person who needs large text needs it for real. The panel scrolls; the window
    /// wraps.
    static let sizes: ClosedRange<CGFloat> = 11...32

    /// 13 pt, and not «about the system size»: measured, `Text.font(.body)` and
    /// `Text.font(.system(size: 13))` lay the same string out to an identical 375.0 × 16.0, and
    /// `NSFont.preferredFont(forTextStyle: .body).pointSize` is 13.0. So an install that never
    /// opens the setting renders exactly as it did before the setting existed — pixel for pixel,
    /// not approximately.
    ///
    /// A literal rather than a call into AppKit, so the default cannot move under an install
    /// silently. `defaultSizeStillMatchesTheSystemsBodyStyle` is the canary: the day the system
    /// disagrees, the suite says so instead of the users noticing.
    static let defaultSize: CGFloat = 13

    /// One point, and the same one for the stepper and for «Крупнее»/«Мельче». Two step sizes
    /// would put the two controls on different grids, so a user who nudged the stepper to 14
    /// and then pressed ⌘+ twice would land somewhere neither control could reach on its own.
    static let step: CGFloat = 1

    static let `default` = ContentFont(typeface: .system, size: defaultSize)

    /// Clamps rather than trapping or trusting. The stored value comes from a plist a user can
    /// edit by hand — the same reasoning `AppSettings.hotkey` gives for re-checking `isValid` on
    /// the way out — and a 400 pt translation pane is not a state this app should be able to
    /// reach. Clamping *here* rather than at the read site means there is one gate rather than
    /// one per caller.
    init(typeface: ContentTypeface, size: CGFloat) {
        self.typeface = typeface
        self.size = Self.clamped(size)
    }

    /// The clamp on its own, so `AppSettings` can apply it to the stored size without building
    /// a whole value to throw away — and so there is one expression of the rule rather than two.
    ///
    /// **`NaN` is replaced rather than clamped, and the infinities are not.** `Swift.max(.nan,
    /// 11)` answers `.nan` — the comparison it is built on is false in both directions — so a
    /// plain clamp passes `NaN` straight through to `NSWindow.setFrame` by way of the panel's
    /// measurement, where it is unrecoverable. `±infinity` needs no such help: `min`/`max` order
    /// it correctly, so it lands on the bound it is nearest, which is the honest answer for it.
    static func clamped(_ size: CGFloat) -> CGFloat {
        guard !size.isNaN else { return defaultSize }
        return min(max(size, sizes.lowerBound), sizes.upperBound)
    }

    var font: Font { .system(size: size, design: typeface.design) }

    var canGrow: Bool { size < Self.sizes.upperBound }
    var canShrink: Bool { size > Self.sizes.lowerBound }

    func larger() -> ContentFont { ContentFont(typeface: typeface, size: size + Self.step) }
    func smaller() -> ContentFont { ContentFont(typeface: typeface, size: size - Self.step) }

    /// «Обычный размер» — the size only. The typeface was chosen once and deliberately, and a
    /// menu item named for the size has no business undoing it.
    func atDefaultSize() -> ContentFont {
        ContentFont(typeface: typeface, size: Self.defaultSize)
    }

    /// How much of a selection is worth laying out to reserve the reply's room, at this size.
    ///
    /// `PanelView.reservationLimit` was 16 000 flat, justified as «twice the length that already
    /// reached this display's ceiling». That justification has an input that stopped being
    /// constant the moment the size became a setting: the length which reaches the
    /// 0.6-of-screen ceiling is a function of the line height.
    ///
    /// **The square is measured, not assumed** — and the linear version written first was
    /// wrong. A line is `size` tall and holds `1/size` of the characters, so the height of a
    /// block of text grows with the *square* of the size. `Scripts/content-font.swift` bisects
    /// for the length at which the reserved height first reaches the ceiling (774 pt on the
    /// display it was run on):
    ///
    ///     11 pt  3817      22 pt  1032
    ///     13 pt  2914      28 pt   661
    ///     17 pt  1789      32 pt   511
    ///
    /// Against 13 pt those are 1.31× / 1.63× / 2.82× / 4.41× / 5.70×, where `(size/13)²` gives
    /// 1.40 / 1.71 / 2.86 / 4.64 / 6.06 — the residual is the panel's fixed chrome, which does
    /// not scale. `13/size` alone gives 1.18 / 1.31 / 1.69 / 2.15 / 2.46, i.e. less than half
    /// the movement, and would have left the cap far too generous at the sizes it exists for.
    ///
    /// **The cost side was not re-measured.** The original figure — 16 000 characters costing
    /// 43.1 ms through `show(at:)` — could not be reproduced by a stand-in probe, so this
    /// generalisation rests on «the same answer for less work» rather than on a measured
    /// saving. Re-taking it needs the assembled bundle; `docs/OPEN-ITEMS.md` carries that.
    ///
    /// **It only ever goes down, and that asymmetry is the point rather than an oversight.**
    /// The formula is symmetric and the cap must not be: 16 000 is the one length whose *cost*
    /// was ever measured, so letting the square raise it — 18 778 characters at 12 pt, 22 347 at
    /// 11 — would spend more main-actor layout inside `show(at:)` than the worst case anybody
    /// has timed, in exchange for nothing. At 11 pt the reserved height already reaches the
    /// ceiling at 3 817 characters, so both numbers produce the identical panel; the smaller one
    /// produces it sooner.
    var reservationLimit: Int {
        let ratio = Self.defaultSize / size
        return min(16_000, Int((16_000 * ratio * ratio).rounded()))
    }
}
