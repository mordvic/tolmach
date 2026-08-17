// Tests/TranslatorAppTests/StatusColourTests.swift
import Testing
import AppKit
import SwiftUI
@testable import TranslatorApp

/// The one thing about this app's palette that can be checked rather than looked at.
///
/// Every other visual property here is owed to a human, because nothing in this environment
/// can see a screen. Contrast is the exception: it is arithmetic over two colours, both of
/// which AppKit will resolve on demand for whatever appearance it is asked about. So the
/// claim `StatusColour` is built on — that the system's own orange, green and red are not
/// legible as 11 pt text on a light pane, and that the drawing's darker values are — is
/// pinned here rather than asserted in a comment.
///
/// `@MainActor` for the reason `WarningsViewTests` is: this reaches AppKit.
@MainActor
struct StatusColourTests {
    // MARK: - The measuring apparatus

    /// The sRGB components a dynamic colour resolves to in one appearance.
    ///
    /// `performAsCurrentDrawingAppearance` and not `NSColor.resolvedColor` — the latter does
    /// not exist for `NSColor` on macOS, and a dynamic provider only runs while an appearance
    /// is the current drawing one. Without the block every colour here would resolve against
    /// whatever the test process happens to be in, which is the light appearance, and the
    /// dark half of these tests would silently check the light half twice.
    static func components(_ colour: Color,
                           in appearance: NSAppearance) -> (r: Double, g: Double, b: Double) {
        var out = (r: 0.0, g: 0.0, b: 0.0)
        appearance.performAsCurrentDrawingAppearance {
            guard let resolved = NSColor(colour).usingColorSpace(.sRGB) else { return }
            out = (Double(resolved.redComponent),
                   Double(resolved.greenComponent),
                   Double(resolved.blueComponent))
        }
        return out
    }

    /// WCAG 2.1 relative luminance.
    static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func contrast(_ a: (r: Double, g: Double, b: Double),
                         _ b: (r: Double, g: Double, b: Double)) -> Double {
        let (first, second) = (luminance(a), luminance(b))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// The two grounds the drawing puts these strings on: a white pane in the light
    /// appearance, `#1e1e1e` in the dark one.
    static let lightGround = (r: 1.0, g: 1.0, b: 1.0)
    static let darkGround = (r: 30.0 / 255, g: 30.0 / 255, b: 30.0 / 255)

    static let aqua = NSAppearance(named: .aqua)!
    static let darkAqua = NSAppearance(named: .darkAqua)!

    // MARK: - The claims

    /// The reason the type exists. Measured on this machine at the time it was written:
    /// `systemOrange` resolves to `#ff8d28` in the light appearance, which is 2.31:1 on
    /// white — for an 11 pt caption. The drawing's `#c26100` is 4.1969:1.
    ///
    /// The bar below is 4.19 and the tables elsewhere say «4.20», and that is not a
    /// disagreement: the tables are the probe's output at two places, and 4.1969 rounds to
    /// it. The assertion has to sit under the true value rather than under its rounding —
    /// setting it at 4.2 failed by three ten-thousandths, which is the sort of failure that
    /// teaches a reader to loosen thresholds instead of reading them.
    ///
    /// That it sits below WCAG AA's 4.5 at all is deliberate rather than an oversight:
    /// `#c26100` is the drawing's own value and this type implements the drawing.
    /// `StatusColour`'s doc comment and `docs/reference/OPEN-ITEMS.md` both carry it, and closing it is
    /// a change to one constant. What must not happen quietly is a *regression* — a return to
    /// the system colour, or a lighter value chosen to match something else — and that is
    /// what this number is here to catch.
    @Test func theWarningColourIsLegibleOnALightPaneWhereTheSystemOrangeIsNot() {
        let drawn = Self.contrast(Self.components(StatusColour.warning, in: Self.aqua),
                                  Self.lightGround)
        let system = Self.contrast(Self.components(Color(nsColor: .systemOrange), in: Self.aqua),
                                   Self.lightGround)
        #expect(drawn >= 4.19)
        // Not merely «better»: the whole point is that the correction is large. Anything less
        // than a doubling and the change would not have been worth making.
        #expect(drawn > system * 1.7)
    }

    /// Both clear WCAG AA outright — 5.27:1 and 4.99:1 as measured — so unlike the warning
    /// above these are pinned at the standard rather than below it.
    @Test func theSuccessAndFailureColoursClearTheContrastStandardOnALightPane() {
        #expect(Self.contrast(Self.components(StatusColour.success, in: Self.aqua),
                              Self.lightGround) >= 4.5)
        #expect(Self.contrast(Self.components(StatusColour.failure, in: Self.aqua),
                              Self.lightGround) >= 4.5)
    }

    /// The dark half is the system's, and that is a rule rather than a coincidence of values.
    ///
    /// The drawing's own dark orange (`#ff9f0a`) and the measured `systemOrange` in the dark
    /// appearance (`#ff9230`) are the same colour to the eye, so there is nothing to correct
    /// there — and answering with the system colour rather than a second hex is what keeps
    /// this type from having to track Apple's palette. Asserting equality with the system
    /// colour states that rule; asserting a hex would restate a number Apple owns.
    @Test func theDarkAppearanceAnswersWithTheSystemColoursRatherThanTheDarkenedOnes() {
        for (ours, system) in [(StatusColour.warning, NSColor.systemOrange),
                               (StatusColour.success, NSColor.systemGreen),
                               (StatusColour.failure, NSColor.systemRed)] {
            let mine = Self.components(ours, in: Self.darkAqua)
            let theirs = Self.components(Color(nsColor: system), in: Self.darkAqua)
            #expect(abs(mine.r - theirs.r) < 0.001)
            #expect(abs(mine.g - theirs.g) < 0.001)
            #expect(abs(mine.b - theirs.b) < 0.001)
        }
    }

    /// And they are still readable there. The correction is one-sided by design — it applies
    /// to the light appearance only — so this is the assertion that the untouched half was
    /// worth leaving untouched.
    @Test func allThreeStayLegibleOnTheDarkWindowGround() {
        for colour in [StatusColour.warning, StatusColour.success, StatusColour.failure] {
            #expect(Self.contrast(Self.components(colour, in: Self.darkAqua),
                                  Self.darkGround) >= 4.5)
        }
    }

    /// The light and dark answers must actually differ, or the type is an expensive alias.
    ///
    /// This is the test that fails if `bestMatch(from:)` is ever replaced by an equality
    /// check against an appearance name that the process is not in — the branch would then
    /// resolve one way for every appearance and nothing else here would notice, because every
    /// other assertion above passes for a colour that ignores its argument.
    @Test func theTwoAppearancesResolveToDifferentColours() {
        for colour in [StatusColour.warning, StatusColour.success, StatusColour.failure] {
            let light = Self.components(colour, in: Self.aqua)
            let dark = Self.components(colour, in: Self.darkAqua)
            #expect(Self.luminance(light) < Self.luminance(dark))
        }
    }
}
