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
