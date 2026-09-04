// Scripts/panel-proofread-row.swift
//
// Whether the panel's степень/стиль row fits at the panel's narrowest. `PanelSizer` clamps the
// width to 300–560 pt and freezes it for a whole presentation, and `PanelView` pads by 14 on
// each side — so the row has 272 pt, and a row that wants more widens every правка panel for
// the whole of its life rather than wrapping.
//
//     swiftc -O -o /tmp/pr Scripts/panel-proofread-row.swift && /tmp/pr
//     V=stacked /tmp/pr    # the fallback: one picker per line
//
// Measured with a detached `NSHostingController` and `fittingSize`, which is how
// `PanelController.measure` takes the panel's own ideal width — never the installed view,
// which measures what it is showing rather than what the content wants.
//
// The labels are the longest of each set, so the figure is the worst case rather than the
// common one: «ошибки и стиль» of the three степень values (a `.menu` picker's width
// follows the *selected* label, and «переписать» is shorter — re-measured 2026-08-25,
// still 242 × 16 with the third item in the menu), «профессиональный» of the five стиль
// ones. The third picker — «Вид», spec #81 step 4 — has three items of nearly equal length,
// so the row is measured with each of them selected in turn and the widest is the verdict.
import SwiftUI
import AppKit

let levels = ["только ошибки", "ошибки и стиль", "переписать"]
let styles = ["как в оригинале", "дружеский", "деловой", "профессиональный", "простой и ясный"]
// `PanelReplyView.items(hasChanges:)` drops «изменения» for a правка that changed nothing, so
// two of these three are also a shape the row really takes; the widest of all three is what
// has to fit.
let views = ["результат", "изменения", "оригинал"]
let stacked = ProcessInfo.processInfo.environment["V"] == "stacked"

struct Row: View {
    let stacked: Bool
    /// Whether the «Вид» picker is in the row — false reproduces the two-picker figure this
    /// script recorded before spec #81, so the third menu's cost is a difference and not a
    /// memory.
    let offersView: Bool
    @State private var level = "ошибки и стиль"
    @State private var style = "профессиональный"
    /// `@State` with an injected initial value rather than a plain `let`: a `Picker` bound to a
    /// constant measures differently from one that can move, and this row is measured to
    /// predict the shipped one.
    @State private var view: String

    init(stacked: Bool, offersView: Bool = true, view: String = "результат") {
        self.stacked = stacked
        self.offersView = offersView
        _view = State(initialValue: view)
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 4) { pickers }
            } else {
                HStack(spacing: 8) { pickers; Spacer(minLength: 0) }
            }
        }
        .pickerStyle(.menu)
        .controlSize(.mini)
        .labelsHidden()
    }

    @ViewBuilder private var pickers: some View {
        Picker("", selection: $level) {
            ForEach(levels, id: \.self) { Text($0).tag($0) }
        }
        .fixedSize()
        Picker("", selection: $style) {
            ForEach(styles, id: \.self) { Text($0).tag($0) }
        }
        .fixedSize()
        if offersView {
            Picker("", selection: $view) {
                ForEach(views, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
        }
    }
}

func measure(_ row: Row) -> CGSize {
    let host = NSHostingController(rootView: row)
    host.view.layoutSubtreeIfNeeded()
    return host.view.fittingSize
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let pair = measure(Row(stacked: stacked, offersView: false))
print(String(format: "степень + стиль          %.1f × %.1f pt", pair.width, pair.height))
var widest = CGSize.zero
var widestLabel = ""
for label in views {
    let size = measure(Row(stacked: stacked, view: label))
    print(String(format: "  + вид: %-10@   %.1f × %.1f pt", label as NSString,
                 size.width, size.height))
    if size.width > widest.width { widest = size; widestLabel = label }
}
print(String(format: "%@ row wants %.1f × %.1f pt at «вид: %@»; the floor gives 272 pt (300 − 2 × 14)",
             stacked ? "stacked" : "single", widest.width, widest.height, widestLabel))
print(widest.width <= 272 ? "FITS the 272 pt content floor"
      : """
        WIDER THAN 272 pt — and 272 is the floor, not the width. Before reshaping the row, \
        measure the whole `PanelView` in this state: the bottom action row wants more than \
        `PanelSizer.minWidth` on its own, so a row narrower than *that* costs the panel nothing.
        """)
