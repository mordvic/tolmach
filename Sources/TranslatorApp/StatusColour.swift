// Sources/TranslatorApp/StatusColour.swift
import AppKit
import SwiftUI

/// The three colours this app uses to say how a run went — and the one place they are
/// spelled, because in the light appearance the system's own are not readable at the size
/// this app writes them.
///
/// **Measured on this machine**, reading `NSColor` in both appearances and scoring each
/// against the ground the drawing puts it on (white pane in light, `#1e1e1e` in dark).
/// `Scripts/colour-contrast.swift` is the probe; `docs/MEASUREMENTS.md` carries the table.
///
/// ```
/// colour   appearance  system     contrast   drawing    contrast
/// orange   light       #ff8d28     2.31:1     #c26100     4.20:1
/// orange   dark        #ff9230     7.47:1     #ff9f0a     8.11:1
/// green    light       #34c759     2.22:1     #1c7c34     5.27:1
/// green    dark        #30d158     8.25:1     — not drawn
/// red      light       #ff383c     3.57:1     #d0342c     4.99:1
/// red      dark        #ff4245     4.86:1     — not drawn
/// ```
///
/// Two things follow from that table and both are the reason this type exists.
///
/// **In the dark appearance the drawing is already using the system colours** — its
/// `#ff9f0a` and the measured `#ff9230` are the same colour to the eye — so there is nothing
/// to correct and the dark branch below returns the system colour rather than a second
/// hex to keep in step with Apple's.
///
/// **In the light appearance the drawing darkens all three, deliberately.** These strings
/// are 11 pt captions — «термины документа не удалось подготовить», «Ollama не запущена…»,
/// «✓ предоставлен» — and `systemOrange` on white is 2.31:1, which is not a legibility
/// quibble but text a sighted user has to lean into. The drawing's values roughly double it.
///
/// One shortfall is stated rather than silently fixed: 4.20:1 is still short of WCAG AA's
/// 4.5:1 for text this size. `#c26100` is the drawing's own number and this type is here to
/// implement the drawing, so it is used as drawn; `docs/OPEN-ITEMS.md` carries the gap as a
/// judgement owed to a human, and closing it is a change to one constant here.
///
/// Not `Color(.systemOrange)` with an opacity, and not a `.colorScheme` branch in each view:
/// a dynamic `NSColor` is resolved by whatever is drawing it, so this works in the settings
/// window, in the main window, and inside the panel's `.regularMaterial` — three surfaces
/// that do not share an appearance when the user has the window in dark and the panel over a
/// light one.
enum StatusColour {
    /// «нет доступа», «термины документа не удалось подготовить», a paused queue, a model on
    /// the blacklist — everything the app flags without refusing to go on.
    static let warning = adaptive(light: 0xc2_61_00, dark: .orange)
    /// «✓ предоставлен». The only success colour in the app, and the only place green is
    /// used at all.
    static let success = adaptive(light: 0x1c_7c_34, dark: .green)
    /// A run that failed and a glossary that could not be written — the two things that stop
    /// rather than warn.
    static let failure = adaptive(light: 0xd0_34_2c, dark: .red)

    /// Which system colour the dark branch answers with.
    ///
    /// An enum and not the `NSColor` itself, so the closure below captures nothing that is
    /// not `Sendable`: `NSColor` is a class and `NSColor(name:dynamicProvider:)` keeps its
    /// provider for the lifetime of the colour, which is the app's.
    private enum SystemTint {
        case orange, green, red

        var colour: NSColor {
            switch self {
            case .orange: .systemOrange
            case .green: .systemGreen
            case .red: .systemRed
            }
        }
    }

    /// `bestMatch(from:)` rather than a comparison against `.darkAqua` by name, because the
    /// appearance a view draws in may be a vibrant or accessibility variant — there are eight
    /// of them — and only two branches here. `bestMatch` maps every one onto the nearer of
    /// the two; an equality test would have sent `.accessibilityHighContrastDarkAqua` down
    /// the *light* branch, which is the appearance that needs the correction least and would
    /// suffer most from it.
    private static func adaptive(light hex: Int, dark: SystemTint) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.colour : srgb(hex)
        })
    }

    /// sRGB and not `deviceRGB`: the drawing's numbers are sRGB hex, and a device colour
    /// space would re-interpret them per display.
    private static func srgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }
}
