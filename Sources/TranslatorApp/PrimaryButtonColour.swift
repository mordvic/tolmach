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
/// fills closer than roughly 60 in sRGB read as the same colour. `#15807E` is the only
/// candidate that clears all three **with one value in both appearances** — the deeper teal
/// and the indigo both dissolve into the dark window, and every darker variant that separates
/// on white fails to separate on `#1e1e1e`.
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
    static let fillColour = NSColor(srgbRed: 0x15 / 255, green: 0x80 / 255, blue: 0x7E / 255,
                                    alpha: 1)

    /// Applied with `.tint`, which is what actually re-fills a `.borderedProminent` button —
    /// measured by rendering one and counting pixels: the untinted button's dominant colour is
    /// `#007afe`, the tinted one's `#137f7d`.
    static let fill = Color(nsColor: fillColour)

    /// Derived rather than written as `.white`, so the fill above can be changed without
    /// quietly taking the label's contrast with it.
    static let label = AccentLabel.label(on: fillColour)
}
