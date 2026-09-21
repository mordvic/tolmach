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
//     V=current /tmp/toolbar-fit            # today's перевод row, title hidden as the app hides it
//     V=current-proofread /tmp/toolbar-fit  # today's правка row
//     V=current-long /tmp/toolbar-fit       # …with the longest names selected («-proofread-long» too)
//     PRIO=0 V=current /tmp/toolbar-fit     # without the visibility priorities the app sets
//     SHOT=/some/dir V=current /tmp/toolbar-fit   # also screenshot the window at 700 pt
//
// **The `current` variants are what `MainWindowView.toolbar` is today** — the operation switch,
// the menus, the ⇄, the prominent primary button, the items a hidden control leaves empty,
// the title hidden, and the `visibilityPriority` pair — and they are why this file was
// reopened on 2026-09-22. macOS 27.0 (26A428), SDK 27.0, one run: перевод fits from 770 pt
// (800 with the longest names), правка from 670 (710). At the window's 700 pt minimum, without
// the priorities, 4 of 6 items were visible and the two in » were «Тон» **and «Перевести»** —
// the primary action is the trailing item, so it is the first to go. With them, 5 of 6, and
// the one in » is «Тон». `SHOT` exists because `screencapture -l` works from this process, so
// what the figures say can be looked at; the «unverified» warning below still stands for the
// absolute numbers, and the bundle re-measure is still owed (`docs/reference/OPEN-ITEMS.md`).
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
// here; `docs/reference/PLATFORM-TRAPS.md` carries it.
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

// **`languages` keeps «китайский (упрощённый)» on purpose, and `RussianCopy` no longer
// produces it.** That is not drift to be tidied away: this list is what reproduces the 740 and
// 810 pt figures `RussianCopy` cites as the reason the name was shortened, so removing it
// would delete the evidence for the decision it documents. `shortLanguages` below is what the
// app actually shows.
let languages = ["русский", "английский", "немецкий", "французский", "испанский",
                 "португальский", "итальянский", "китайский (упрощённый)", "японский"]
let shortLanguages = ["русский", "английский", "немецкий", "французский", "испанский",
                      "португальский", "итальянский", "китайский", "японский"]
let tones = ["нейтральный", "деловой", "разговорный", "технический", "буквальный"]

var variant: String { ProcessInfo.processInfo.environment["V"] ?? "menu" }
var langs: [String] { variant.contains("short") ? shortLanguages : languages }
var size: ControlSize { variant.contains("small") ? .small : .regular }
var forced: Bool { variant.contains("small") || variant.contains("regular") }

var isCurrent: Bool { variant.hasPrefix("current") }
var isProofread: Bool { variant.contains("proofread") }
var setsPriorities: Bool { ProcessInfo.processInfo.environment["PRIO"] != "0" }

extension ToolbarContent {
    /// `MainWindowView`'s `overflowing(_:)`, switchable so the two states can be compared.
    @ToolbarContentBuilder func overflowing(last: Bool) -> some ToolbarContent {
        if #available(macOS 26.1, *), setsPriorities {
            visibilityPriority(last ? .high : .low)
        } else {
            self
        }
    }
}

struct Probe: App {
    @Environment(\.openWindow) private var openWindow
    @State private var operation = 0
    var body: some Scene {
        MenuBarExtra { Text("m") } label: { Image(systemName: "a").task { await run() } }
        Window("Толмач", id: "w") {
            Color.clear.frame(minWidth: 300, minHeight: 400).toolbar { bar }
        }
    }

    /// Today's row, item for item — including the items whose `if` is false. Those cost
    /// nothing: eight are declared, and `NSToolbar.items` reads 6 for перевод and 4 for правка.
    @ToolbarContentBuilder var currentBar: some ToolbarContent {
        let long = variant.contains("long")
        ToolbarItem(placement: .navigation) {
            Picker("", selection: $operation) { Text("Перевод").tag(0); Text("Правка").tag(1) }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        }
        ToolbarItem(placement: .navigation) {
            if !isProofread { title("Из", long ? "португальский" : "Определить") }
        }
        ToolbarItem(placement: .navigation) {
            if !isProofread { Button { } label: { Image(systemName: "arrow.left.arrow.right") } }
        }
        ToolbarItem(placement: .navigation) {
            if !isProofread { title("В", long ? "португальский" : "По правилу") }
        }
        ToolbarItem(placement: .navigation) {
            if !isProofread { title("Тон", long ? "нейтральный" : "По умолчанию") }
        }
        .overflowing(last: false)
        ToolbarItem(placement: .navigation) {
            if isProofread { title("Степень", long ? "ошибки и стиль" : "По умолчанию") }
        }
        ToolbarItem(placement: .navigation) {
            if isProofread { title("Стиль", long ? "профессиональный" : "По умолчанию") }
        }
        .overflowing(last: false)
        ToolbarItem(placement: .primaryAction) {
            Button { } label: { Text(isProofread ? "Исправить" : "Перевести") }
                .buttonStyle(.borderedProminent)
        }
        .overflowing(last: true)
    }

    /// `MainWindowView.directionMenu`: one concatenated `Text` as the menu's title.
    @ViewBuilder func title(_ label: String, _ value: String) -> some View {
        Menu {
            Picker("", selection: .constant(value)) {
                ForEach(shortLanguages, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(label + " ").foregroundStyle(.secondary) + Text(value)
        }
        .fixedSize()
    }

    @ToolbarContentBuilder var bar: some ToolbarContent {
        if isCurrent {
            currentBar
        } else {
            legacyBar
        }
    }

    @ToolbarContentBuilder var legacyBar: some ToolbarContent {
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
        if isCurrent {
            // What `WindowTitleHidden` does in the app. The title costs the row its own width
            // — with it drawn, the same перевод row read 930 pt rather than 770.
            w.titleVisibility = .hidden
            try? await Task.sleep(for: .milliseconds(200))
        }
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
        if isCurrent {
            // The window's own minimum, which is the width that matters.
            w.setContentSize(NSSize(width: 700, height: 400))
            w.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(500))
            print("  at 700 pt: \(tb.visibleItems?.count ?? -1) of \(tb.items.count) visible"
                  + (setsPriorities ? ", priorities set" : ", no priorities"))
            if let dir = ProcessInfo.processInfo.environment["SHOT"] {
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", "\(w.windowNumber)",
                                  "\(dir)/toolbar-\(variant)\(setsPriorities ? "" : "-noprio")-700.png"]
                try? shot.run()
                shot.waitUntilExit()
            }
        }
        NSApp.terminate(nil)
    }
}
Probe.main()
