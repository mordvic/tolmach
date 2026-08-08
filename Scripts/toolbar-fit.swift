// Scripts/toolbar-fit.swift
//
// The narrowest window width at which the toolbar shows every item — i.e. the width below
// which macOS starts pushing controls, «Перевести» first, into the » overflow. Compile it,
// because the interpreter cannot JIT the availability check SwiftUI emits:
//
//     swiftc -O -o /tmp/toolbar-fit Scripts/toolbar-fit.swift && /tmp/toolbar-fit
//     V=loose /tmp/toolbar-fit      # each label its own toolbar item, as it shipped once
//     V=bare /tmp/toolbar-fit       # no labels at all, as it shipped before that
//     V=paired-short /tmp/toolbar-fit
//
// `NSToolbar.visibleItems` excludes overflowed items, so the test is exact rather than
// visual. The sweep steps 10 pt, so a reported figure is the true threshold rounded up.
import SwiftUI
import AppKit

// Finds the narrowest window width at which the toolbar shows every item — i.e. the width
// below which macOS starts pushing controls, including «Перевести», into the » overflow.
// NSToolbar.visibleItems excludes overflowed items, so the test is exact rather than visual.

let languages = ["русский", "английский", "немецкий", "французский", "испанский",
                 "португальский", "итальянский", "китайский (упрощённый)", "японский"]
let shortLanguages = ["русский", "английский", "немецкий", "французский", "испанский",
                      "португальский", "итальянский", "китайский", "японский"]
let tones = ["нейтральный", "деловой", "разговорный", "технический", "буквальный"]

var variant: String { ProcessInfo.processInfo.environment["V"] ?? "paired-short" }
var langs: [String] { variant.contains("short") ? shortLanguages : languages }
var size: ControlSize { variant.contains("small") ? .small : .regular }
var forced: Bool { variant.contains("small") || variant.contains("regular") }

struct Probe: App {
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        MenuBarExtra { Text("m") } label: { Image(systemName: "a").task { await run() } }
        Window("Толмач", id: "w") {
            Color.clear.frame(minWidth: 500, minHeight: 400).toolbar { bar }
        }
    }

    @ToolbarContentBuilder var bar: some ToolbarContent {
        if variant.hasPrefix("bare") {
            // What shipped before the labels were added: three bare pickers, a swap and the
            // primary action.
            ToolbarItemGroup(placement: .navigation) {
                picker("Определить", langs)
                Button { } label: { Image(systemName: "arrow.left.arrow.right") }
                picker("По правилу", langs)
                picker("По умолчанию", tones)
            }
        } else if variant.hasPrefix("loose") {
            ToolbarItemGroup(placement: .navigation) {
                Text("Из"); picker("Определить", langs)
                Button { } label: { Image(systemName: "arrow.left.arrow.right") }
                Text("В"); picker("По правилу", langs)
                Text("Тон"); picker("По умолчанию", tones)
            }
        } else {
            ToolbarItem(placement: .navigation) { pair("Из", "Определить", langs) }
            ToolbarItem(placement: .navigation) {
                Button { } label: { Image(systemName: "arrow.left.arrow.right") }
            }
            ToolbarItem(placement: .navigation) { pair("В", "По правилу", langs) }
            ToolbarItem(placement: .navigation) { pair("Тон", "По умолчанию", tones) }
        }
        ToolbarItem(placement: .primaryAction) { Button("Перевести") { } }
    }

    @ViewBuilder func pair(_ label: String, _ current: String, _ items: [String]) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            picker(current, items)
        }
    }

    @ViewBuilder func picker(_ current: String, _ items: [String]) -> some View {
        let p = Picker("", selection: .constant(current)) {
            Text(current).tag(current)
            ForEach(items, id: \.self) { Text($0).tag($0) }
        }.labelsHidden().fixedSize()
        if forced { p.controlSize(size) } else { p }
    }

    @MainActor func run() async {
        NSApp.setActivationPolicy(.accessory)
        openWindow(id: "w")
        try? await Task.sleep(for: .milliseconds(900))
        guard let w = NSApp.windows.first(where: { $0.toolbar != nil }),
              let tb = w.toolbar else { print("no window"); return }
        var fits = -1
        for width in stride(from: 560, through: 1300, by: 10) {
            w.setContentSize(NSSize(width: CGFloat(width), height: 400))
            try? await Task.sleep(for: .milliseconds(45))
            let visible = tb.visibleItems?.count ?? 0
            if visible >= tb.items.count { fits = width; break }
        }
        print(String(format: "%-16@ items=%d  fits from %@ pt",
                     variant as NSString, tb.items.count,
                     (fits < 0 ? ">1300" : "\(fits)") as NSString))
        NSApp.terminate(nil)
    }
}
Probe.main()
