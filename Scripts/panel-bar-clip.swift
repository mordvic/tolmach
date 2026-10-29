// Scripts/panel-bar-clip.swift
//
// Where the hotkey panel's change bars can be drawn (openspec improve-change-mark-legibility,
// task 7). The reply starts at x = 0 of its text view by measurement (`RenderedReplyView.inset`),
// so its bars stand 7 pt left of it, outside the view, in the panel's 14 pt padding. Two
// questions, answered on a real window:
//
//  - Does a hosted `NSView` with `clipsToBounds = false` draw into the SwiftUI padding around it?
//  - Inside a `ScrollView` (the panel's long-reply layout), and with the scroll region pushed 8 pt
//    into the padding by `.contentMargins` plus a negative padding — does the bar show, and does
//    the text still start where the flat layout starts it?
//
//     swiftc -O -o /tmp/pbc Scripts/panel-bar-clip.swift && /tmp/pbc
//
// Measured 2026-10-29: drawn outside in both layouts, the text starting at 14.7 pt in both.
// Without the margin trick, the `ScrollView` clipped the bar. It captures only its own window
// (`screencapture -l`), so nothing of another application is read.
import AppKit
import SwiftUI

// Does an NSViewRepresentable's view that draws at negative x reach the SwiftUI padding around it?
final class Outside: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.red.setFill(); NSRect(x: -7, y: 4, width: 3, height: 30).fill()   // outside, in the padding
        NSColor.blue.setFill(); NSRect(x: 0, y: 4, width: 40, height: 30).fill()  // inside
    }
}
struct Rep: NSViewRepresentable {
    func makeNSView(context: Context) -> Outside { let v = Outside(); v.clipsToBounds = false; return v }
    func updateNSView(_ v: Outside, context: Context) {}
}
struct Panel: View {
    let scrolls: Bool
    var body: some View {
        Group {
            if scrolls { ScrollView { Rep().frame(width: 200, height: 40) }.contentMargins(.leading, 8, for: .scrollContent).padding(.leading, -8) }
            else { VStack { Rep().frame(width: 200, height: 40) } }
        }
        .padding(14)
        .background(Color.white)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
for scrolls in [false, true] {
    let w = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 240, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: Panel(scrolls: scrolls))
    w.level = .floating
    w.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let file = NSTemporaryDirectory() + "/clip-\(scrolls ? "scroll" : "flat").png"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", file]; try! p.run(); p.waitUntilExit()
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: file)))!
    let scale = CGFloat(rep.pixelsWide) / 240
    // The red bar should sit at x = 14 - 7 + 1 = 8 pt, 14 + 4 + 15 pt down.
    let c = rep.colorAt(x: Int(8.5 * scale), y: Int(33 * scale))!.usingColorSpace(.sRGB)!
    // The blue box (the "text") starts at x = 14 in both layouts if nothing moved.
    func blueAt(_ x: CGFloat) -> Bool { let b = rep.colorAt(x: Int(x * scale), y: Int(33 * scale))!.usingColorSpace(.sRGB)!; return b.blueComponent > 0.8 && b.redComponent < 0.3 }
    var firstBlue = -1
    for px in 0..<rep.pixelsWide { let b = rep.colorAt(x: px, y: Int(33 * scale))!.usingColorSpace(.sRGB)!; if b.blueComponent > 0.8 && b.redComponent < 0.3 && b.greenComponent < 0.3 { firstBlue = px; break } }
    print("  text (blue) starts at", String(format: "%.1f pt", CGFloat(firstBlue) / scale))
    print(scrolls ? "scroll:" : "flat:", String(format: "r %.2f g %.2f b %.2f", c.redComponent, c.greenComponent, c.blueComponent),
          c.redComponent > 0.8 && c.greenComponent < 0.3 ? "→ drawn outside" : "→ clipped")
    w.orderOut(nil)
}
