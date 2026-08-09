// Scripts/toolbar-height.swift
//
// What the main window's toolbar band costs, per style and per control size. Compile it — the
// interpreter cannot JIT the availability checks SwiftUI emits:
//
//     swiftc -O -o /tmp/tbh Scripts/toolbar-height.swift && /tmp/tbh
//     V=small /tmp/tbh    # and V=mini, to see that the band does not follow the controls
//
// The band is `window.frame.height - window.contentLayoutRect.height`. It reports the width
// each style needs as well, so a shorter toolbar cannot be bought with a wider window without
// that showing up. Like `Scripts/toolbar-fit.swift`, treat the widths as a comparison between
// arrangements and take absolutes from the bundle.
import SwiftUI
import AppKit

var variant: String { ProcessInfo.processInfo.environment["V"] ?? "unified-regular" }
var compact: Bool { variant.contains("compact") }
var size: ControlSize {
    variant.contains("small") ? .small : (variant.contains("mini") ? .mini : .regular)
}

struct Probe: App {
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        MenuBarExtra { Text("m") } label: { Image(systemName: "a").task { await run() } }
        Window("Толмач", id: "w") {
            Color.clear.frame(minWidth: 700, minHeight: 400).toolbar { bar }
        }
    }

    @ToolbarContentBuilder var bar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { menu("Из", "Определить") }
        ToolbarItem(placement: .navigation) {
            Button { } label: { Image(systemName: "arrow.left.arrow.right") }
                .controlSize(size)
        }
        ToolbarItem(placement: .navigation) { menu("В", "По правилу") }
        ToolbarItem(placement: .navigation) { menu("Тон", "По умолчанию") }
        ToolbarItem(placement: .primaryAction) {
            Button { } label: { Text("Перевести") }.buttonStyle(.borderedProminent)
                .controlSize(size)
        }
    }

    @ViewBuilder func menu(_ label: String, _ current: String) -> some View {
        Menu {
            Button("а") { }
            Button("б") { }
        } label: {
            // An `HStack` and not the app's own `Text + Text`: the concatenation is
            // deprecated as of macOS 26 and this file compiles against the host SDK rather
            // than the package's macOS 14 floor, so it warns here and not there. The
            // difference does not reach the band, which is what this measures.
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Text(current)
            }
        }
        .fixedSize()
        .controlSize(size)
    }

    @MainActor func run() async {
        NSApp.setActivationPolicy(.accessory)
        openWindow(id: "w")
        try? await Task.sleep(for: .milliseconds(1100))
        guard let w = NSApp.windows.first(where: { $0.toolbar != nil }),
              let tb = w.toolbar else { print("no window"); return }
        for (name, style) in [("unified", NSWindow.ToolbarStyle.unified),
                              ("unifiedCompact", .unifiedCompact)] {
            w.toolbarStyle = style
            try? await Task.sleep(for: .milliseconds(350))
            let band = w.frame.height - w.contentLayoutRect.height
            let hs = tb.items.compactMap { $0.view?.frame.height }
            var fits = -1
            for width in stride(from: 500, through: 1200, by: 10) {
                w.setContentSize(NSSize(width: CGFloat(width), height: 400))
                try? await Task.sleep(for: .milliseconds(40))
                if (tb.visibleItems?.count ?? 0) >= tb.items.count { fits = width; break }
            }
            w.setContentSize(NSSize(width: 900, height: 400))
            try? await Task.sleep(for: .milliseconds(120))
            print(String(format: "  %-16@ band=%3.0f  items=%@  fits from %@ pt",
                         name as NSString, band,
                         "\(hs.map { Int($0) })" as NSString,
                         (fits < 0 ? ">1200" : "\(fits)") as NSString))
        }
        NSApp.terminate(nil)
    }
}
Probe.main()
