// Scripts/change-grounds.swift
//
// The grounds a правка's marks are drawn on, read off the screen — the numbers
// `ChangeMarks.lightGrounds` / `darkGrounds` hold every mark colour against
// (openspec/changes/improve-change-mark-legibility, design D1).
//
//     swiftc -O -o /tmp/cg Scripts/change-grounds.swift && /tmp/cg
//
// Compiled rather than interpreted, for `window-title.swift`'s reason: the interpreter cannot
// JIT the availability check SwiftUI emits.
//
// Why a probe and not `NSColor`: what a system colour resolves to offscreen is not what is on
// the screen. `windowBackgroundColor` resolves to #1e1e1e in the dark appearance, and a titled
// window's content measured #31302d on the screen of 2026-10-29; the hotkey panel is
// `.regularMaterial` (`PanelView.background`), whose colour depends on what is behind it; the
// change card is an `NSPopover`, glass on macOS 27. The tests before this script held the marks
// against #1e1e1e and white only, and the marks failed on the panel.
//
// **It opens windows on the screen for about ten seconds**, above other applications'
// (`.floating`), without taking focus — so every window it samples is *inactive*, which is how
// the hotkey panel is drawn while the user reads it in another application. Nothing sits over
// the probe's windows only if nothing is pinned above `.floating` at the top-left of the main
// screen; a sample that comes out tinted by something else is that, not the material. It reads
// a 40 × 40 pt patch in the middle of its own windows and prints colours, never pixels of
// anything else.
//
// Three readings, each in the light and the dark appearance:
//  - the content of a titled window — the window's перевод pane draws no background of its own;
//  - `.regularMaterial` in a clear, borderless panel over five backdrops (white, black, grey,
//    blue, orange) — the spread is how much the material moves with what is behind it;
//  - an `NSPopover`'s content — `ChangeCardView`'s host — over a backdrop the colour of the pane.
import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

typealias RGB = (r: Double, g: Double, b: Double)
let screenHeight = NSScreen.screens[0].frame.height
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("change-grounds")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// The mean colour of a 40 × 40 pt patch centred on `point` (screen coordinates, bottom-left
/// origin), through `screencapture -R`, which takes top-left points.
func sample(at point: NSPoint) -> RGB {
    let file = scratch.appendingPathComponent("sample.png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", "\(Int(point.x) - 20),\(Int(screenHeight - point.y) - 20),40,40", file.path]
    try! p.run(); p.waitUntilExit()
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: file))!
    var sum: RGB = (0, 0, 0)
    var n = 0.0
    for x in stride(from: 8, to: rep.pixelsWide - 8, by: 4) {
        for y in stride(from: 8, to: rep.pixelsHigh - 8, by: 4) {
            let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            sum = (sum.r + c.redComponent, sum.g + c.greenComponent, sum.b + c.blueComponent)
            n += 1
        }
    }
    return (sum.r / n, sum.g / n, sum.b / n)
}

func hex(_ c: RGB) -> String {
    String(format: "#%02x%02x%02x", Int(c.r * 255 + 0.5), Int(c.g * 255 + 0.5), Int(c.b * 255 + 0.5))
}
func luminance(_ c: RGB) -> Double {
    func f(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
}

struct MaterialPane: View {
    var body: some View { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial) }
}
struct EmptyCard: View {
    var body: some View { Color.clear.frame(width: 200, height: 120) }
}

let backdrop = NSWindow(contentRect: NSRect(x: 60, y: 120, width: 520, height: 420),
                        styleMask: [.borderless], backing: .buffered, defer: false)
backdrop.level = .floating

let titled = NSWindow(contentRect: NSRect(x: 160, y: 200, width: 300, height: 200),
                      styleMask: [.titled], backing: .buffered, defer: false)
titled.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

let panel = NSPanel(contentRect: NSRect(x: 160, y: 200, width: 300, height: 200),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
panel.contentView = NSHostingView(rootView: MaterialPane())

let backdrops: [(String, NSColor)] = [
    ("white", .white), ("black", .black), ("grey", NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
    ("blue", NSColor(srgbRed: 0.12, green: 0.37, blue: 0.75, alpha: 1)),
    ("orange", NSColor(srgbRed: 0.91, green: 0.64, blue: 0.24, alpha: 1)),
]

var grounds: [String: [(String, RGB)]] = [:]
for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    var found: [(String, RGB)] = []
    let centre = NSPoint(x: 310, y: 280)

    titled.appearance = NSAppearance(named: appearance)
    titled.orderFrontRegardless(); pump(0.6)
    found.append(("window", sample(at: NSPoint(x: centre.x, y: centre.y - 20))))
    titled.orderOut(nil)

    panel.appearance = NSAppearance(named: appearance)
    backdrop.orderFrontRegardless(); panel.orderFrontRegardless()
    for (label, colour) in backdrops {
        backdrop.backgroundColor = colour
        backdrop.display(); panel.display(); pump(0.6)
        found.append(("panel over \(label)", sample(at: centre)))
    }
    panel.orderOut(nil)

    let pane: NSColor = appearance == .aqua ? .white : NSColor(srgbRed: 0x31 / 255.0, green: 0x30 / 255.0,
                                                               blue: 0x2d / 255.0, alpha: 1)
    backdrop.backgroundColor = pane
    let host = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 420, height: 60),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    host.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    host.backgroundColor = pane
    host.appearance = NSAppearance(named: appearance)
    let anchor = NSView(frame: NSRect(x: 200, y: 20, width: 20, height: 16))
    host.contentView!.addSubview(anchor)
    host.orderFrontRegardless(); pump(0.3)
    let popover = NSPopover()
    popover.behavior = .applicationDefined
    popover.contentViewController = NSHostingController(rootView: EmptyCard())
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    pump(0.8)
    let frame = popover.contentViewController!.view.window!.frame
    found.append(("card", sample(at: NSPoint(x: frame.midX, y: frame.midY))))
    popover.close(); host.orderOut(nil); backdrop.orderOut(nil); pump(0.2)

    grounds[name] = found
}

for name in ["light", "dark"] {
    print("== \(name)")
    for (label, colour) in grounds[name]! {
        print("  \(label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(hex(colour))")
    }
    // The ground a mark has least contrast against: the darkest of the light grounds, the
    // lightest of the dark ones.
    let all = grounds[name]!
    let worst = name == "light" ? all.min { luminance($0.1) < luminance($1.1) }!
                                : all.max { luminance($0.1) < luminance($1.1) }!
    print("  worst for a mark: \(hex(worst.1)) (\(worst.0))")
}
