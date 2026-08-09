// Scripts/colour-contrast.swift
//
// Reads the system colours this app renders, in both appearances, and scores each against the
// ground the drawing puts it on. Run it when Apple changes a system colour, or before moving
// one of `StatusColour`'s constants:
//
//     swift Scripts/colour-contrast.swift
//
// It is here rather than in the test target because it *reports* rather than asserts — the
// assertions live in `Tests/TranslatorAppTests/StatusColourTests.swift`, and they check the
// three colours the app ships. This prints the whole comparison, including the system values
// the app deliberately does not use in the light appearance, which is what makes the
// difference between them legible.
//
// The one dependency is AppKit, so it needs no package build and does not open a window.
import AppKit

func srgb(_ colour: NSColor, in appearance: NSAppearance) -> (Double, Double, Double) {
    var out = (0.0, 0.0, 0.0)
    appearance.performAsCurrentDrawingAppearance {
        guard let c = colour.usingColorSpace(.sRGB) else { return }
        out = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
    return out
}

/// WCAG 2.1 relative luminance.
func luminance(_ rgb: (Double, Double, Double)) -> Double {
    func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(rgb.0) + 0.7152 * lin(rgb.1) + 0.0722 * lin(rgb.2)
}

func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    let (l1, l2) = (luminance(a), luminance(b))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

func hex(_ rgb: (Double, Double, Double)) -> String {
    String(format: "#%02x%02x%02x",
           Int(rgb.0 * 255 + 0.5), Int(rgb.1 * 255 + 0.5), Int(rgb.2 * 255 + 0.5))
}

func parse(_ s: String) -> (Double, Double, Double) {
    let v = Int(s.dropFirst(), radix: 16)!
    return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
}

let light = NSAppearance(named: .aqua)!
let dark = NSAppearance(named: .darkAqua)!
// The grounds the drawing puts these strings on: a white pane in light, #1e1e1e in dark.
let onLight = parse("#ffffff")
let onDark = parse("#1e1e1e")

// name, the system colour, what the drawing uses in light, what it uses in dark ("" = the
// drawing has no dark state for this one).
let rows: [(String, NSColor, String, String)] = [
    ("orange", .systemOrange, "#c26100", "#ff9f0a"),
    ("green",  .systemGreen,  "#1c7c34", ""),
    ("red",    .systemRed,    "#d0342c", ""),
]

/// `String(format: "%-7@")` does not pad an `NSString` on this platform — it prints the value
/// and ignores the width — so the columns are laid out here instead.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> String {
    String(format: "%.2f:1", contrast(a, b))
}

print(pad("colour", 9) + pad("appearance", 12) + pad("system", 12)
      + pad("contrast", 11) + pad("drawing", 12) + "contrast")
print(String(repeating: "-", count: 65))
for (name, colour, drawnLight, drawnDark) in rows {
    for (label, appearance, ground, drawn) in [("light", light, onLight, drawnLight),
                                               ("dark", dark, onDark, drawnDark)] {
        let sys = srgb(colour, in: appearance)
        var line = pad(name, 9) + pad(label, 12) + pad(hex(sys), 12) + pad(ratio(sys, ground), 11)
        line += drawn.isEmpty ? "— not drawn"
                              : pad(drawn, 12) + ratio(parse(drawn), ground)
        print(line)
    }
}
print("\nWCAG AA needs 4.5:1 for text below 18 pt, 3:1 for larger text and non-text.")
print("The app writes all three at 11 pt — see StatusColour.swift.")
