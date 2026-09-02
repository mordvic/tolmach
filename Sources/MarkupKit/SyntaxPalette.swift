// Sources/MarkupKit/SyntaxPalette.swift
import AppKit

/// The colour of each token kind, per appearance — chosen against the code card's fill and
/// measured, not taken from the system palette.
///
/// **Why not `systemPurple` and friends.** The renderer's rule elsewhere is semantic colours
/// only, and it holds because a label colour is drawn *for* text. The system accent colours are
/// not: measured 2026-09-02 against the card's fill (`quaternaryLabelColor` over white, then over
/// a 0.12 grey), `systemPurple` reads 3.34:1 in the light appearance, `systemRed` 2.86:1,
/// `systemBlue` 2.82:1, `systemTeal` 1.73:1 — the same defect `StatusColour` in the app was
/// written to remove, arriving in code instead of in warnings. So the palette is the app's own,
/// one value per appearance, each held to **≥ 4.5:1 on the card** (WCAG AA for body text) in a
/// test, the way `StatusColourTests` holds the status colours:
///
/// | Kind    | Light     | on card | Dark      | on card |
/// |---------|-----------|---------|-----------|---------|
/// | keyword | `#9B2393` | 5.51:1  | `#FF84BE` | 4.75:1  |
/// | string  | `#C41A16` | 4.80:1  | `#FF8F80` | 4.85:1  |
/// | comment | `#546270` | 5.01:1  | `#A3AEBA` | 4.76:1  |
/// | number  | `#1C00CF` | 8.63:1  | `#D0BF69` | 5.79:1  |
/// | key     | `#326D74` | 4.71:1  | `#7FC29E` | 5.16:1  |
/// | type    | `#0B4F79` | 6.99:1  | `#5DD8FF` | 6.50:1  |
///
/// The light values are Xcode's default theme where it already clears the bar and darkened
/// where it does not; the dark values are its dark theme lightened for the same reason. Dynamic
/// `NSColor`s, so a view resolves them for the appearance it draws in and the RTF flavour
/// resolves them for the appearance the copy was made in — one colour per token, no second
/// code path.
public enum SyntaxPalette {
    /// One `NSColor` per kind for the life of the process. A dynamic colour is a fresh object
    /// on every `init`, and two of them never compare equal even with the same provider — so
    /// they are made once, which also spares a block a closure allocation per token.
    public static func color(for kind: SyntaxHighlighter.Kind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .key: key
        case .type: type
        }
    }

    private static let keyword = dynamic(for: .keyword)
    private static let string = dynamic(for: .string)
    private static let comment = dynamic(for: .comment)
    private static let number = dynamic(for: .number)
    private static let key = dynamic(for: .key)
    private static let type = dynamic(for: .type)

    private static func dynamic(for kind: SyntaxHighlighter.Kind) -> NSColor {
        let (light, dark) = values(for: kind)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hex(dark) : hex(light)
        }
    }

    /// The pair behind `color(for:)`, exposed so the contrast test measures the same numbers
    /// the palette draws with.
    static func values(for kind: SyntaxHighlighter.Kind) -> (light: UInt32, dark: UInt32) {
        switch kind {
        case .keyword: (0x9B2393, 0xFF84BE)
        case .string: (0xC41A16, 0xFF8F80)
        case .comment: (0x546270, 0xA3AEBA)
        case .number: (0x1C00CF, 0xD0BF69)
        case .key: (0x326D74, 0x7FC29E)
        case .type: (0x0B4F79, 0x5DD8FF)
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
