// Scripts/content-font.swift
//
// The measurements behind «Шрифт текста» (`ContentFont`, `docs/adr/0008`).
//
//     swiftc -O -o /tmp/cf Scripts/content-font.swift && /tmp/cf
//
// Compiled rather than interpreted, for `window-title.swift`'s reason: the interpreter cannot
// JIT the availability check SwiftUI emits.
//
// Six questions, none of which should be answered from memory:
//
//  1. **What the system calls «обычный».** The default has to reproduce what the app rendered
//     before the setting existed, and «13 looks right» is not that claim.
//  2. **Whether `.body` and `.system(size: 13)` are the same thing** — the same claim, made the
//     way it is actually checkable: by laying the same string out under both.
//  3. **Whether the three `Font.Design` values do anything**, and which of them is monospaced.
//     This is also where `.rounded` was dropped from the set.
//  4. **What happens to CJK.** `zh` and `ja` are supported targets, and a face chosen for a
//     Latin alphabet does not necessarily survive the fallback.
//  5. **Whether the font reaches `TextEditor`'s text view.** `TextEditor` exposes no font of
//     its own; had `.font` not carried through, the исходник pane would have needed AppKit.
//  6. **Reading measure and line height by size**, and the length at which the панель's
//     reservation stops changing the answer — which is what `ContentFont.reservationLimit`
//     generalises.
//
// Section 6's stand-in reproduces the panel's stack (a caption, the reservation, a status
// caption, a button row, 14 pt of padding) at the 560 pt `PanelSizer.maxWidth`. It is **not**
// the real `PanelView`; the numbers are the shape of the curve rather than the panel's own.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func ideal<V: View>(_ view: V) -> CGSize {
    let host = NSHostingController(rootView: view)
    host.view.layoutSubtreeIfNeeded()
    return host.view.fittingSize
}

print("== 1. what the system calls body ==")
print("NSFont.systemFontSize              \(NSFont.systemFontSize)")
print("preferredFont(.body).pointSize     \(NSFont.preferredFont(forTextStyle: .body).pointSize)")
for (name, style) in [("callout", NSFont.TextStyle.callout), ("footnote", .footnote),
                      ("caption1", .caption1), ("caption2", .caption2)] {
    print("preferredFont(.\(name)) ".padding(toLength: 35, withPad: " ", startingAt: 0)
          + "\(NSFont.preferredFont(forTextStyle: style).pointSize)")
}

print("\n== 2. .body against .system(size:) ==")
let sample = "Съешь ещё этих мягких французских булок, да выпей чаю."
let bodySize = ideal(Text(sample).font(.body).fixedSize())
print("Text.font(.body)                   \(bodySize)")
for pt in [12.0, 13.0, 14.0] {
    let s = ideal(Text(sample).font(.system(size: pt)).fixedSize())
    print("Text.font(.system(size: \(pt)))     \(s)   match=\(s == bodySize)")
}

print("\n== 3. the designs ==")
for (name, design) in [("default", Font.Design.default), ("monospaced", .monospaced),
                       ("serif", .serif), ("rounded", .rounded)] {
    let narrow = ideal(Text("iiiiiiiiii").font(.system(size: 13, design: design)).fixedSize())
    let wide = ideal(Text("MMMMMMMMMM").font(.system(size: 13, design: design)).fixedSize())
    print(String(format: "%-11@ iiii=%.1f MMMM=%.1f  monospaced=%@",
                 name as NSString, narrow.width, wide.width,
                 abs(narrow.width - wide.width) < 0.5 ? "yes" : "no"))
}

print("\n== 4. CJK under each design ==")
for (name, design) in [("default", Font.Design.default), ("monospaced", .monospaced),
                       ("serif", .serif), ("rounded", .rounded)] {
    let s = ideal(Text("日本語のテキストです").font(.system(size: 13, design: design)).fixedSize())
    print(String(format: "%-11@ width=%.1f", name as NSString, s.width))
}

print("\n== 5. the font inside TextEditor ==")
struct Editor: View {
    let font: Font
    var body: some View { TextEditor(text: .constant("Проверка шрифта")).font(font) }
}
func textView(in view: NSView) -> NSTextView? {
    if let t = view as? NSTextView { return t }
    for sub in view.subviews { if let t = textView(in: sub) { return t } }
    return nil
}
for (label, font) in [("system 13", Font.system(size: 13)),
                      ("system 22", Font.system(size: 22)),
                      ("monospaced 22", Font.system(size: 22, design: .monospaced)),
                      ("serif 22", Font.system(size: 22, design: .serif))] {
    let host = NSHostingView(rootView: Editor(font: font))
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let found = textView(in: host)
    print("\(label): NSTextView.font = "
          + (found?.font.map { "\($0.fontName) \($0.pointSize)" } ?? "nil"))
}

print("\n== 6. measure, line height, and where the reservation stops paying ==")
let prose = "Это обычное предложение на русском языке, набранное для измерения ширины строки."
func source(_ count: Int) -> String {
    var s = ""
    while s.count < count { s += prose + " " }
    return String(s.prefix(count))
}

/// The panel's stack, near enough to watch its height climb: a caption, the hidden
/// reservation, a status caption, a button row, and the 14 pt padding `PanelView` applies.
struct Stand: View {
    let reservation: String
    let font: Font
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("русский → английский").font(.caption)
            Text(reservation).font(font).hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("Перевожу…").font(.caption)
            HStack { Button("Скопировать") {}; Button("Открыть в окне") {}; Spacer() }
        }
        .padding(14)
    }
}

let width = 560.0                      // PanelSizer.maxWidth
let ceiling = (NSScreen.main?.visibleFrame.height ?? 900) * 0.6
func height(chars: Int, pt: CGFloat) -> CGFloat {
    let host = NSHostingController(rootView: Stand(reservation: source(chars),
                                                   font: .system(size: pt)))
    host.view.layoutSubtreeIfNeeded()
    return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
}

print(String(format: "ceiling on this display: %.0f pt (0.6 × visibleFrame)", ceiling))
print("  pt   chars/line   line height   chars at which the reserved height reaches the ceiling")
for pt in [11.0, 13.0, 17.0, 22.0, 28.0, 32.0] {
    let perChar = ideal(Text(prose).font(.system(size: pt)).fixedSize()).width
        / CGFloat(prose.count)
    let line = ideal(Text("Одна строка").font(.system(size: pt)).fixedSize()).height
    // Bisected rather than interpolated: the height is a step function of the line count, and
    // reading a crossing off two distant samples is how a plausible wrong number gets written
    // into a comment.
    var low = 1, high = 40_000
    if height(chars: high, pt: pt) < ceiling {
        print(String(format: "%4.0f   %8.1f   %10.1f   never below %d", pt,
                     (width - 28) / perChar, line, high))
        continue
    }
    while low < high {
        let mid = (low + high) / 2
        if height(chars: mid, pt: pt) >= ceiling { high = mid } else { low = mid + 1 }
    }
    print(String(format: "%4.0f   %8.1f   %10.1f   %d", pt, (width - 28) / perChar, line, low))
}
