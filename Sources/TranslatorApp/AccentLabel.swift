// Sources/TranslatorApp/AccentLabel.swift
import AppKit
import SwiftUI

/// What colour a label must be to stay readable on an accent-filled control.
///
/// `.borderedProminent` fills with `NSColor.controlAccentColor` — **the user's choice**, made
/// in System Settings, and macOS offers eight. The label is white whatever they picked, and
/// measured against every one of them that is not always defensible. White on the fill, in
/// both appearances, taken with `Scripts/accent-contrast.swift`:
///
/// ```
/// accent      light    dark
/// синий        3.52     3.23
/// фиолетовый   4.17     3.63
/// розовый      3.65     3.52
/// красный      3.57     3.43
/// графит       3.26     2.87
/// оранжевый    2.31     2.23
/// зелёный      2.22     2.02
/// жёлтый       1.51     1.41
/// ```
///
/// The bottom four are the point. «Перевести» is 13 pt, and white on the yellow accent is
/// 1.41:1 — not a legibility quibble but a label that is barely there. The same four carry
/// the panel's «Перевести» and the terms sheet's.
///
/// **The switch is at 3:1, not at WCAG's 4.5, and that is the whole design of this type.**
/// Maximising contrast would put black on *every* accent, including the default blue —
/// measured, black beats white on all eight — and a blue button with black lettering is not
/// what any other Mac app draws. 3:1 is the bar Apple holds its own controls to, so above it
/// this defers to the platform and the app looks native; below it the platform is producing
/// something unreadable and deferring stops being a kindness. Worst case across all eight
/// becomes **3.23:1** instead of 1.41:1.
///
/// Not `StatusColour`'s shape, though it is the same idea: that type overrides a system colour
/// outright, this one only overrides the *consequence* of the user's choice, and only where
/// their choice cannot be read.
enum AccentLabel {
    /// Below this the platform's own colour is unreadable rather than merely low-contrast.
    /// Apple's bar for controls, and the reason it is not 4.5 is in the type's comment.
    static let switchBelow: Double = 3

    /// The label colour for a fill, by contrast — the decision, separated from where the fill
    /// comes from so it can be checked against colours the test process cannot select.
    static func label(on fill: NSColor, in appearance: NSAppearance) -> NSColor {
        var onWhite = 0.0
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = fill.usingColorSpace(.sRGB) else { return }
            onWhite = contrast(Self.white, srgb)
        }
        // Zero means the conversion failed, which is «no idea» — white is what the platform
        // would have drawn, so an unanswerable case changes nothing.
        return onWhite == 0 || onWhite >= switchBelow ? .white : .black
    }

    /// The same decision as a colour, resolved per appearance whenever it is drawn.
    ///
    /// A fill may be dynamic itself — `controlAccentColor` is — so the provider takes the
    /// decision each time rather than closing over one answer. An accent changed in System
    /// Settings while the app runs is therefore picked up at the next draw; that part is
    /// reasoned from the colour being resolved on demand, not measured, because nothing here
    /// can change a system setting.
    static func label(on fill: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { label(on: fill, in: $0) })
    }

    /// `NSColor(srgbRed:…)` and **not** `NSColor.white` or `.init(white:alpha:)`, which live in
    /// the generic gray space: asking one of those for `redComponent` does not return a grey
    /// value, it raises `NSInvalidArgumentException` and takes the process with it. Caught by
    /// `AccentLabelTests` before it shipped.
    private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// WCAG 2.1 relative luminance. Both arguments must already be in sRGB — see `white`.
    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            func linear(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
                 + 0.0722 * linear(c.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
