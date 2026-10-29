// Scripts/pane-header-fit.swift
//
// Whether a sheet's header fits at the sheet's narrowest. The перевод sheet is
// `.frame(minWidth: TranslationPane.minWidth)`, 360, which `V=two-menu-file` holds, and its
// header holds what the sheet is — the target language's menu in перевод, «Правка» in правка —
// then the view picker, «Ещё вариант» and «Скопировать» in one `HStack`; a header that wants
// more than the floor does not wrap, it clips, and the control that clips is the one on the
// trailing edge. The исходник sheet's floor is 280 (`V=source`).
//
//     swiftc -O -o /tmp/phf Scripts/pane-header-fit.swift && /tmp/phf
//     V=menu       /tmp/phf   # правка's fallback: a `.menu` picker showing its longest label
//     V=two        /tmp/phf   # перевод: the longest language, «Разметка | Исходник»
//     V=two-menu   /tmp/phf   # …and its `.menu` fallback
//     V=two-menu-file /tmp/phf   # …with the queue's file name after the language, squeezed
//     V=source     /tmp/phf   # the исходник sheet: language, «207 символов · 3 части», ✕ (floor 280)
//     V=source-chars /tmp/phf # …with the count of parts dropped, its first fallback
//     SHAPE=old V=… /tmp/phf   # the header before the sheets (caption, 8 pt sides, link-width buttons)
//
// Measured with a detached `NSHostingController` and `fittingSize`, the way
// `Scripts/panel-proofread-row.swift` takes the panel row's width and `PanelController.measure`
// takes the panel's own — never the installed view, which measures what it is showing rather
// than what the content wants.
//
// The labels are the longest of each set: «Результат» / «Изменения» / «Исходник» for the three
// segments (a segmented control sizes every segment to its own label, so all three count),
// «Португальский» for the language, and «Ещё вариант» present wherever the operation
// can offer it — the state a finished «ошибки и стиль» правка is in. Treat the figure as a
// ranking between variants first and an absolute second, for `Scripts/toolbar-fit.swift`'s
// reason: a probe window is not the bundle.
import SwiftUI
import AppKit

let variant = ProcessInfo.processInfo.environment["V"] ?? "three"

struct Header: View {
    let variant: String
    @State private var choice = "Изменения"
    var isTranslation: Bool { variant.hasPrefix("two") }
    var showsFile: Bool { variant.hasSuffix("file") }
    var isSource: Bool { variant.hasPrefix("source") }
    var oldShape: Bool { ProcessInfo.processInfo.environment["SHAPE"] == "old" }

    var body: some View {
        if oldShape {
            // `PaneHeader` before 2026-10-29: caption, spacer, actions, 8 pt sides.
            HStack {
                Text("Правка").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 12) {
                    picker
                    Button("Ещё вариант") {}.buttonStyle(.borderless)
                    Button("Скопировать") {}.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        } else {
            // `PaneHeader` on a sheet: what the sheet is, a spacer, the actions — 10 pt apart,
            // `PaneSheet.contentInset` (14) a side, `PaneSheet.headerHeight` (40) tall. The
            // language is `LanguageMenu`: the body size, regular, no note since 2026-10-29.
            HStack(spacing: 10) {
                if isSource {
                    Menu { Text("a") } label: { Text("Португальский") }
                        .font(.body).buttonStyle(.borderless).fixedSize()
                        .padding(.leading, -3)
                } else if isTranslation {
                    Menu { Text("a") } label: { Text("Португальский") }
                    .font(.body).buttonStyle(.borderless).fixedSize()
                    .padding(.leading, -3)
                    if showsFile {
                        Text("release-notes-2026-q3.md")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text("Правка").font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if isSource {
                        // `SourceCount` at its widest — 128 KB is the paste ceiling, so six digits
                        // of characters; the parts are a two-digit count.
                        Text(variant.hasSuffix("chars") ? "131 072 символа" : "131 072 символа · 33 части")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        picker
                    }
                    if !isTranslation && !isSource { Button("Ещё вариант") {}.buttonStyle(.borderless) }
                    Button {} label: {
                        Label("Скопировать", systemImage: isSource ? "xmark.circle" : "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 13)).frame(minWidth: 20, minHeight: 20)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
    }

    @ViewBuilder private var picker: some View {
        switch variant {
        case "two":
            Picker("", selection: $choice) {
                Text("Разметка").tag("Разметка"); Text("Исходник").tag("Исходник")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        case "two-menu", "two-menu-file":
            Picker("", selection: $choice) {
                Text("Разметка").tag("Разметка"); Text("Исходник").tag("Исходник")
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
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
// The floor moved from 280 to 360 on 2026-09-04, to 380 and back to 360 on 2026-10-29 (the sheet
// header, first with «по правилу» after the language and then without), and on the first of
// those the header gained a `ViewThatFits` that
// falls back to the `menu` form: so the question this answers is no longer «does the widest
// form fit the floor» — it does not, by design — but «does the *narrowest* form fit it», which
// is what keeps «Скопировать» on screen. Run with V=menu for the form the floor is set from.
let floor: CGFloat = Double(ProcessInfo.processInfo.environment["FLOOR"] ?? "")
    ?? (variant.hasPrefix("source") ? 280 : 360)
print(String(format: "%@ header wants %.1f × %.1f pt; the pane's floor is %.0f pt",
             variant, size.width, size.height, floor))
// What it takes when offered only the floor — the width a compressible part (the queue's file
// name) gives up to. Larger than the floor means something is clipped there.
let squeezed = host.sizeThatFits(in: CGSize(width: floor, height: 40))
print(String(format: "  offered %.0f pt it takes %.1f", floor, squeezed.width))
if variant == "source" {
    print(size.width <= floor ? "FITS — the count is shown whole at the floor"
                              : "does not fit at the floor — ViewThatFits drops the count of parts; run V=source-chars")
} else if variant == "source-chars" {
    print(size.width <= floor ? "FITS — the floor holds the count of characters"
                              : "DOES NOT FIT — ViewThatFits drops the count altogether at the floor")
} else if variant.hasSuffix("menu") || variant.hasSuffix("file") {
    print(min(size.width, squeezed.width) <= floor ? "FITS — the floor holds the narrowest form"
                              : "DOES NOT FIT — raise the floor or shorten the header; ViewThatFits has nothing narrower to fall back to")
} else {
    print(size.width <= floor ? "FITS — segments are shown at the floor"
                              : "does not fit at the floor — ViewThatFits shows the menu form there instead; run V=menu to check that one")
}
