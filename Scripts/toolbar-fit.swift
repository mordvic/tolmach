// Scripts/toolbar-fit.swift
//
// The narrowest window width at which the toolbar shows every item — i.e. the width below
// which macOS starts pushing controls, «Перевести» among them, into the » overflow. Compile
// it, because the interpreter cannot JIT the availability check SwiftUI emits:
//
//     swiftc -O -o /tmp/toolbar-fit Scripts/toolbar-fit.swift && /tmp/toolbar-fit
//     V=paired /tmp/toolbar-fit   # a Text beside a Picker inside one toolbar item
//     V=loose  /tmp/toolbar-fit   # each label its own toolbar item
//     V=bare   /tmp/toolbar-fit   # no labels at all
//
// `NSToolbar.visibleItems` excludes overflowed items, so the test is exact rather than
// visual. The sweep steps 10 pt, so a reported figure is the true threshold rounded up.
//
// The default `menu` variant is what the app ships: one `Menu` per control with its label
// folded into the button title. The other three are the arrangements it replaced, kept
// because the numbers between them are the argument for the one that shipped. What the
// widths cannot show is the reason those three were wrong — a `Picker` inside a toolbar item
// draws a bezelled control inside the item's own chrome, so a `Text` beside it makes the item
// a container of two things rather than one control. That was measured on the bundle, not
// here; `docs/PLATFORM-TRAPS.md` carries it.
//
// **Treat every absolute figure this prints as unverified.** It has produced two now that did
// not survive checking. The header once claimed «`menu` reports 810 pt» when it printed 560 —
// 810 was a *bundle* figure quoted as if it came from here — and the 560 itself was an
// artefact: the probe window's own `minWidth` was 700, so every sweep step below that was
// clamped to a width where the row already fitted. With the floor lowered it prints, in one
// run: menu 550, menu-long 550, paired 980, loose 1050, bare 920 — and `menu-long`, which
// hands the longest language name to both buttons, agreeing with `menu` to the point is not
// credible on its face. It is left as it stands rather than tuned until it looks right.
//
// So: use it to rank arrangements against each other, which is what the four variants are for
// and what it has been reliable at. The app's own numbers are taken on the running bundle, by
// driving the real window and reading `NSToolbar.visibleItems`, and those are the ones its
// comments cite — `MainWindowView` records 650 pt as the row usually stands and 680 with the
// longest names on both sides; `RussianCopy` records 740 and 810 for «китайский (упрощённый)»
// chosen once and twice. When the two disagree the bundle wins, the same lesson
// `Scripts/window-title.swift` carries, where a probe said one assignment was enough and the
// app said otherwise.
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

var variant: String { ProcessInfo.processInfo.environment["V"] ?? "menu" }
var langs: [String] { variant.contains("short") ? shortLanguages : languages }
var size: ControlSize { variant.contains("small") ? .small : .regular }
var forced: Bool { variant.contains("small") || variant.contains("regular") }

struct Probe: App {
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        MenuBarExtra { Text("m") } label: { Image(systemName: "a").task { await run() } }
        Window("Толмач", id: "w") {
            Color.clear.frame(minWidth: 300, minHeight: 400).toolbar { bar }
        }
    }

    @ToolbarContentBuilder var bar: some ToolbarContent {
        if variant.hasPrefix("menu") {
            // What ships: one control per item, the label inside its title.
            ToolbarItem(placement: .navigation) { menu("Из", sourceTitle, langs) }
            ToolbarItem(placement: .navigation) {
                Button { } label: { Image(systemName: "arrow.left.arrow.right") }
            }
            ToolbarItem(placement: .navigation) { menu("В", targetTitle, langs) }
            ToolbarItem(placement: .navigation) { menu("Тон", "По умолчанию", tones) }
        } else if variant.hasPrefix("bare") {
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

    /// A `Menu`'s button is as wide as the title it is given, so what the toolbar costs
    /// depends on the *selection* and not on the list. `V=menu` asks about the placeholders —
    /// the state the row is usually in — and `V=menu-long` about the longest language name,
    /// which is the case the window's minimum width has to survive.
    var sourceTitle: String { variant.contains("long") ? langs.max(by: { $0.count < $1.count })! : "Определить" }
    var targetTitle: String { variant.contains("long") ? langs.max(by: { $0.count < $1.count })! : "По правилу" }

    @ViewBuilder func menu(_ label: String, _ current: String, _ items: [String]) -> some View {
        Menu {
            Picker("", selection: .constant(current)) {
                ForEach(items, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(.secondary)
                Text(current)
            }
        }
        .fixedSize()
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
        for width in stride(from: 320, through: 1300, by: 10) {
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
