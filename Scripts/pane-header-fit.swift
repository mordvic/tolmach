// Scripts/pane-header-fit.swift
//
// Whether the перевод pane's header fits at the pane's narrowest once a правка's picker has
// three segments. `TranslationPane` is `.frame(minWidth: 280)`, and its header holds the
// caption, the picker, «Ещё вариант» and «Скопировать» in one `HStack` — so a header that
// wants more than 280 pt does not wrap, it clips, and the control that clips is the one on
// the trailing edge.
//
//     swiftc -O -o /tmp/phf Scripts/pane-header-fit.swift && /tmp/phf
//     V=two   /tmp/phf   # the перевод header: «Разметка | Исходник»
//     V=menu  /tmp/phf   # the fallback: a `.menu` picker showing its longest label
//
// Measured with a detached `NSHostingController` and `fittingSize`, the way
// `Scripts/panel-proofread-row.swift` takes the panel row's width and `PanelController.measure`
// takes the panel's own — never the installed view, which measures what it is showing rather
// than what the content wants.
//
// The labels are the longest of each set: «Результат» / «Изменения» / «Исходник» for the three
// segments (a segmented control sizes every segment to its own label, so all three count),
// «Правка» for the caption, and both link buttons present — the state a finished
// «ошибки и стиль» правка is in. Treat the figure as a ranking between variants first and an
// absolute second, for `Scripts/toolbar-fit.swift`'s reason: a probe window is not the bundle.
import SwiftUI
import AppKit

let variant = ProcessInfo.processInfo.environment["V"] ?? "three"

struct Header: View {
    let variant: String
    @State private var choice = "Изменения"

    var body: some View {
        // `PaneHeader`'s own shape, without importing the app: caption, spacer, actions.
        HStack {
            Text("Правка").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 12) {
                picker
                Button("Ещё вариант") {}.buttonStyle(.link)
                Button("Скопировать") {}.buttonStyle(.link)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    @ViewBuilder private var picker: some View {
        switch variant {
        case "two":
            Picker("", selection: $choice) {
                Text("Разметка").tag("Разметка"); Text("Исходник").tag("Исходник")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        case "menu":
            Picker("", selection: $choice) {
                Text("Результат").tag("Результат"); Text("Изменения").tag("Изменения")
                Text("Исходник").tag("Исходник")
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
        default:
            Picker("", selection: $choice) {
                Text("Результат").tag("Результат"); Text("Изменения").tag("Изменения")
                Text("Исходник").tag("Исходник")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = NSHostingController(rootView: Header(variant: variant))
host.view.layoutSubtreeIfNeeded()
let size = host.view.fittingSize
// The floor moved from 280 to 360 on 2026-09-04, and the header gained a `ViewThatFits` that
// falls back to the `menu` form: so the question this answers is no longer «does the widest
// form fit the floor» — it does not, by design — but «does the *narrowest* form fit it», which
// is what keeps «Скопировать» on screen. Run with V=menu for the form the floor is set from.
let floor: CGFloat = 360
print(String(format: "%@ header wants %.1f × %.1f pt; the pane's floor is %.0f pt",
             variant, size.width, size.height, floor))
if variant == "menu" {
    print(size.width <= floor ? "FITS — the floor holds the narrowest form"
                              : "DOES NOT FIT — raise the floor or shorten the header; ViewThatFits has nothing narrower to fall back to")
} else {
    print(size.width <= floor ? "FITS — segments are shown at the floor"
                              : "does not fit at the floor — ViewThatFits shows the menu form there instead; run V=menu to check that one")
}
