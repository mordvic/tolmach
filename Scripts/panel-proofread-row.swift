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
// common one: «ошибки и стиль» of the two степень values, «профессиональный» of the five
// стиль ones.
import SwiftUI
import AppKit

let levels = ["только ошибки", "ошибки и стиль"]
let styles = ["как в оригинале", "дружеский", "деловой", "профессиональный", "простой и ясный"]
let stacked = ProcessInfo.processInfo.environment["V"] == "stacked"

struct Row: View {
    let stacked: Bool
    @State private var level = "ошибки и стиль"
    @State private var style = "профессиональный"

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
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = NSHostingController(rootView: Row(stacked: stacked))
host.view.layoutSubtreeIfNeeded()
let size = host.view.fittingSize
print(String(format: "%@ row wants %.1f × %.1f pt; the floor gives 272 pt (300 − 2 × 14)",
             stacked ? "stacked" : "single", size.width, size.height))
print(size.width <= 272 ? "FITS" : "DOES NOT FIT — change the row's shape, not the panel's floor")
