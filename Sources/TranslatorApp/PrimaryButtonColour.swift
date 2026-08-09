// Sources/TranslatorApp/PrimaryButtonColour.swift
import AppKit
import SwiftUI

/// What «Перевести» is filled with, and what its label must be on that fill.
///
/// **A colour of the app's own, not the system accent.** `.borderedProminent` fills with
/// `controlAccentColor` by default, which is the user's setting — respecting it is the HIG
/// answer and it was what shipped until now. Two things argued it down. It cannot be relied
/// on: white on the accent measures 4.02:1 at best and 1.41:1 on the yellow one, against the
/// 4.5 a 13 pt label needs (`AccentLabel` carries that table). And the primary action of an
/// app is the one control worth owning.
///
/// **Teal, measured against the three things a fill here has to satisfy:**
///
/// ```
///                       label   separation      distance to
///                       white   light  dark   failure warning success
/// teal    #15807E        4.75    4.75   3.51     218     216      74
/// teal    #0F6E6E        6.04    6.04   2.76     212     210      61
/// indigo  #3A3F8F        9.18    9.18   1.82     180     200     114
/// cinnabar#C24A33        4.86    4.86   3.43      27      56     173
/// accent  #007AFF        4.02    4.02   4.15     304     321     205
/// ```
///
/// The label wants 4.5:1 at 13 pt; a control wants 3:1 against the surface behind it; and two
/// fills closer than roughly 60 in sRGB read as the same colour. `#15807E` was chosen as the
/// one value clearing all three in both appearances — and then 4.75:1 turned out not to be
/// enough to read, so the fill below is a **pair**. This table is what ruled the alternatives
/// out; `fillColour`'s own comment carries what replaced the single value and why.
///
/// The icon's own `cinnabar` was the first candidate and is the one to explain: it is 27 from
/// `StatusColour.failure`, so the app's primary action would have been the colour of its
/// error messages.
///
/// 74 from `StatusColour.success` is the one number here with any slack in it. They are told
/// apart by more than hue — success is an 11 pt label with a ✓ beside it, this is a filled
/// button carrying a verb — and `docs/OPEN-ITEMS.md` carries it as something to look at rather
/// than something measured away.
enum PrimaryButtonColour {
    /// sRGB, stated the way `StatusColour` states its own: a literal here is a colour this app
    /// owns, not a system one to be resolved.
    ///
    /// **Two values, because one could not serve both appearances.** A single `#15807E` put the
    /// label at 4.75:1 — over WCAG's 4.5, and still reported as hard to read, which is the
    /// known weakness of that formula for light text on a saturated mid-tone. Going deeper
    /// fixes the label and costs the separation the control needs from a `#1e1e1e` window:
    ///
    /// ```
    ///           label   sep. light  sep. dark   to success
    /// #15807E    4.75      4.75        3.51         74
    /// #0F6E6E    6.04      6.04        2.76         61
    /// #0C6060    7.35      7.35        2.27         55
    /// #0A5555    8.59      8.59        1.94         54
    /// ```
    ///
    /// So the light appearance takes the deeper one, where the ground is white and separation
    /// is free, and the dark appearance keeps the one that can still be seen against it. The
    /// column that stops this going deeper still is the last: `#0C6060` is 55 from
    /// `StatusColour.success`, inside the ~60 at which two fills read as one colour.
    static let fillColour = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x15 / 255, green: 0x80 / 255, blue: 0x7E / 255, alpha: 1)
            : NSColor(srgbRed: 0x0F / 255, green: 0x6E / 255, blue: 0x6E / 255, alpha: 1)
    }

    /// Applied with `.tint`, which is what actually re-fills a `.borderedProminent` button —
    /// measured by rendering one and counting pixels: the untinted button's dominant colour is
    /// `#007afe`, the tinted one's `#137f7d`.
    static let fill = Color(nsColor: fillColour)

    /// Derived rather than written as `.white`, so the fill above can be changed without
    /// quietly taking the label's contrast with it.
    static let labelColour = AccentLabel.label(on: fillColour)

    /// The whole label, built once for the two buttons that share it.
    ///
    /// **`isEnabled` is why this is a view and not three modifiers.** An explicitly styled
    /// `Text` keeps its colour through `.disabled()` — SwiftUI dims a button's *default*
    /// foreground, and this one has none — so «Перевести» rendered white semibold on the
    /// system's desaturated prominent fill in exactly the state a user with Ollama stopped
    /// meets first. Handing the colour back when disabled lets the platform dim it as it does
    /// every other button.
    ///
    /// It is also the fix for the same five modifiers living in two files: the window's
    /// «Перевести» and the terms sheet's now cannot drift.
    struct Label: View {
        let title: String
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Text(title)
                .foregroundStyle(isEnabled ? AnyShapeStyle(labelColour) : AnyShapeStyle(.primary))
                .fontWeight(labelWeight)
                .padding(.horizontal, labelPadding)
        }
    }

    static func label(_ title: String) -> Label { Label(title: title) }

    /// Extra breathing room around the label, per side, on top of what the style already gives.
    ///
    /// Measured: `.borderedProminent` puts «Перевести» in a 93 pt control against a 68 pt
    /// label — 12.4 pt a side — while the toolbar's three `Menu`s come out 134 to 168 pt wide.
    /// Discounting their chevron leaves roughly 17–18 pt around their own labels, so the
    /// primary action had the least air of anything in the row it leads. This brings it to
    /// ~18.4 and the control to 105 pt.
    ///
    /// It costs width in a row whose width is already argued over — see `MainWindowView`'s
    /// minimum — so the fit was re-measured on the bundle rather than assumed.
    static let labelPadding: CGFloat = 6

    /// Weight, which is the other half of «плохо читаем» and the half no contrast ratio sees.
    ///
    /// Measured by rendering the button and counting the glyphs' own pixels against the fill's:
    /// regular lays down 991 px of them, `.medium` 1139 and `.semibold` **1197** — 21% more
    /// ink for the same colours. That is what carries light text on a saturated fill, and it is
    /// why the fill was not simply darkened further: the two levers cost different things, and
    /// this one costs nothing at all.
    static let labelWeight: Font.Weight = .semibold
}
