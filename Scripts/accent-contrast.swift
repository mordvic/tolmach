// Scripts/accent-contrast.swift
//
// White text on every accent macOS lets the user pick, in both appearances — the table
// `AccentLabel` is built from. Compile it, because the interpreter cannot JIT the availability
// checks AppKit emits here:
//
//     swiftc -O -o /tmp/accent Scripts/accent-contrast.swift && /tmp/accent
//
// The first block reads `controlAccentColor`, i.e. whatever *this* machine is set to. The
// second walks all eight presets by their system colours, which is what a user can choose
// between, and shows what each does to a white label and to a black one.

import AppKit

func srgb(_ c: NSColor, _ a: NSAppearance) -> (Double, Double, Double) {
    var o = (0.0, 0.0, 0.0)
    a.performAsCurrentDrawingAppearance {
        guard let r = c.usingColorSpace(.sRGB) else { return }
        o = (Double(r.redComponent), Double(r.greenComponent), Double(r.blueComponent))
    }
    return o
}
func lum(_ c: (Double, Double, Double)) -> Double {
    func f(_ v: Double) -> Double { v <= 0.03928 ? v/12.92 : pow((v+0.055)/1.055, 2.4) }
    return 0.2126*f(c.0) + 0.7152*f(c.1) + 0.0722*f(c.2)
}
func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    let (x, y) = (lum(a), lum(b)); return (max(x,y)+0.05)/(min(x,y)+0.05)
}
func hex(_ c: (Double, Double, Double)) -> String {
    String(format: "#%02x%02x%02x", Int(c.0*255+0.5), Int(c.1*255+0.5), Int(c.2*255+0.5))
}
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
let white = (1.0, 1.0, 1.0), black = (0.0, 0.0, 0.0)

print("== what the app ships: the system accent, whatever the user picked ==")
for (n, a) in [("light", light), ("dark", dark)] {
    let c = srgb(.controlAccentColor, a)
    print("  accent \(pad(n,6)) \(hex(c))  white text on it: \(String(format: "%.2f:1", contrast(white, c)))")
}

print("\n== every accent macOS offers, white text on the filled button ==")
let choices: [(String, NSColor)] = [
    ("синий",   .systemBlue),   ("фиолетовый", .systemPurple), ("розовый", .systemPink),
    ("красный", .systemRed),    ("оранжевый",  .systemOrange), ("жёлтый",  .systemYellow),
    ("зелёный", .systemGreen),  ("графит",     .systemGray),
]
print("  " + pad("accent", 12) + pad("light", 22) + "dark")
for (name, col) in choices {
    let l = srgb(col, light), d = srgb(col, dark)
    let cl = contrast(white, l), cd = contrast(white, d)
    let mark = { (v: Double) in v >= 4.5 ? "OK " : (v >= 3 ? "AA-large" : "FAIL") }
    print("  " + pad(name, 12)
          + pad("\(hex(l)) \(String(format: "%.2f:1", cl)) \(mark(cl))", 22)
          + "\(hex(d)) \(String(format: "%.2f:1", cd)) \(mark(cd))")
}

print("\n== what the drawing specified ==")
for (n, h) in [("fill", 0x007aff), ("border", 0x0a6bd8)] {
    let c = (Double((h>>16)&0xff)/255, Double((h>>8)&0xff)/255, Double(h&0xff)/255)
    print("  \(pad(n,7)) \(hex(c))  white on it: \(String(format: "%.2f:1", contrast(white, c)))")
}
print("\nWCAG AA: 4.5:1 for text under 18pt, 3:1 for large text and UI components.")
print("The button's label is 12–13 pt.")

print("== label colour derived from the fill, instead of always white ==")
print("  " + pad("accent",12) + pad("light: white / black -> best",34) + "dark: white / black -> best")
var worst = 99.0
for (name, col) in [("синий", NSColor.systemBlue), ("фиолетовый", .systemPurple),
                    ("розовый", .systemPink), ("красный", .systemRed),
                    ("оранжевый", .systemOrange), ("жёлтый", .systemYellow),
                    ("зелёный", .systemGreen), ("графит", .systemGray)] {
    var cells: [String] = []
    for a in [light, dark] {
        let f = srgb(col, a)
        let w = contrast(white, f), b = contrast(black, f)
        let best = max(w, b)
        worst = min(worst, best)
        cells.append(String(format: "%.2f / %.2f -> %.2f %@", w, b, best,
                            best >= 4.5 ? "OK" : "low"))
    }
    print("  " + pad(name,12) + pad(cells[0],34) + cells[1])
}
print(String(format: "\n  worst case across every accent, both appearances: %.2f:1", worst))

print("\n== the queue row's accent tint, on the pane it sits on ==")
for (n, a, bg) in [("light", light, (1.0,1.0,1.0)), ("dark", dark, (30.0/255,30.0/255,30.0/255))] {
    let acc = srgb(.controlAccentColor, a)
    // 8% fill over the pane
    let f = (acc.0*0.08 + bg.0*0.92, acc.1*0.08 + bg.1*0.92, acc.2*0.08 + bg.2*0.92)
    let b = (acc.0*0.35 + bg.0*0.65, acc.1*0.35 + bg.1*0.65, acc.2*0.35 + bg.2*0.65)
    print(String(format: "  %@  fill-vs-pane %.2f:1   border-vs-pane %.2f:1",
                 pad(n,6), contrast(f, bg), contrast(b, bg)))
}
print("  (a non-text indicator wants 3:1 to be perceivable)")

// ---- Change marks (spec #81, measurement item 7) -------------------------------------------
// The правка underline is a hairline in the accent, drawn on the pane's own ground — not white
// text on a filled button. What decides whether it is *perceivable* is the accent against the
// pane, and WCAG's figure for a non-text indicator is 3:1. The link underline sits beside it in
// `linkColor`, so the two are printed together: on the default accent both are blue, and how far
// apart they are is the question `docs/reference/OPEN-ITEMS.md` carries for a pair of eyes.
print("\n== change-mark underline: every accent against the pane, both appearances ==")
let panes: [(String, NSAppearance, (Double, Double, Double))] = [
    ("light", light, (1.0, 1.0, 1.0)), ("dark", dark, (30.0/255, 30.0/255, 30.0/255)),
]
print("  " + pad("accent", 12) + pad("light vs pane", 24) + "dark vs pane")
var worstMark = 99.0
for (name, col) in choices {
    var cells: [String] = []
    for (_, a, bg) in panes {
        let c = srgb(col, a)
        let r = contrast(c, bg)
        worstMark = min(worstMark, r)
        cells.append(String(format: "%@ %.2f:1 %@", hex(c), r, r >= 3 ? "OK" : "low"))
    }
    print("  " + pad(name, 12) + pad(cells[0], 24) + cells[1])
}
print(String(format: "  worst accent on either pane: %.2f:1 (3:1 is the non-text floor)", worstMark))
print("\n== the link underline beside it ==")
for (n, a, bg) in panes {
    let link = srgb(.linkColor, a), blue = srgb(.systemBlue, a), acc = srgb(.controlAccentColor, a)
    print(String(format: "  %@  linkColor %@ (%.2f:1 vs pane) · systemBlue %@ · this machine's accent %@ · link-vs-blue %.2f:1",
                 pad(n, 6), hex(link), contrast(link, bg), hex(blue), hex(acc), contrast(link, blue)))
}
print("  (a ratio near 1:1 between the link and the blue accent means the two underlines are told apart by nothing but context)")

// ---- The mark's colour cannot be the bare accent ---------------------------------------------
// Measured above: three of the eight accents sit under 3:1 on the light pane. `StatusColour`'s
// answer to the same failure was a darkened light-appearance value held to a floor by a test;
// this prints what blending the accent toward black by a fixed fraction does to every accent, so
// the fraction `ChangeMarks` uses is the smallest one that clears 3:1 for all eight.
print("\n== accent blended toward black in the light appearance, vs the white pane ==")
print("  " + pad("fraction", 10) + "worst accent → ratio (all eight must clear 3:1)")
for f in [0.0, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4] {
    var worst = (name: "", ratio: 99.0)
    for (name, col) in choices {
        let c = srgb(col, light)
        let b = (c.0 * (1 - f), c.1 * (1 - f), c.2 * (1 - f))
        let r = contrast(b, (1.0, 1.0, 1.0))
        if r < worst.ratio { worst = (name, r) }
    }
    print(String(format: "  %@ %@ → %.2f:1 %@", pad(String(format: "%.2f", f), 10), pad(worst.name, 12),
                 worst.ratio, worst.ratio >= 3 ? "OK" : "low"))
}
