// Scripts/view-menu.swift
//
// Where the «Крупнее / Мельче / Обычный размер» items land, and how SwiftUI spells ⌘+.
//
//     swiftc -O -o /tmp/vm Scripts/view-menu.swift && /tmp/vm
//
// Compiled rather than run through the interpreter, for `window-title.swift`'s reason: the
// interpreter cannot JIT the availability check SwiftUI emits.
//
// Three things this settles, none of which should be taken from memory:
//
//  1. **Which menu `CommandGroup(replacing: .sidebar)` fills.** The app empties that group to
//     take away an empty «Вид»; putting items in it is only a good idea if they arrive in the
//     menu a macOS user expects to find them in.
//  2. **What `keyboardShortcut("+", modifiers: .command)` actually becomes** — the displayed
//     equivalent and the modifier mask AppKit stores. ⌘+ is typed as ⇧⌘= on a US layout, and
//     whether SwiftUI compensates is a fact about SwiftUI, not something to reason about.
//  3. **That `pruneEmptyMenus()` now leaves «Вид» alone**, because it is no longer empty.
//
// The scene shape mirrors `TranslatorApp`: MenuBarExtra first, then the Window, then Settings,
// with the same command groups. Anything less and the menu bar being dumped is not the app's.
import SwiftUI
import AppKit

struct Probe: App {
    var body: some Scene {
        MenuBarExtra {
            Text("menu")
        } label: {
            Text("T").task { await dump() }
        }
        Window("Толмач", id: "w") { Color.clear.frame(width: 300, height: 200) }
            .commands {
                // The three items under test, in the group the app currently empties.
                CommandGroup(replacing: .sidebar) {
                    Button("Крупнее") {}.keyboardShortcut("+", modifiers: .command)
                    Button("Мельче") {}.keyboardShortcut("-", modifiers: .command)
                    Button("Обычный размер") {}
                        .keyboardShortcut("0", modifiers: [.command, .control])
                }
                CommandGroup(replacing: .help) { }
                CommandMenu("Перевод") {
                    Button("Перевести") {}.keyboardShortcut(.return, modifiers: .command)
                }
                CommandGroup(after: .windowList) {
                    Button("Открыть окно перевода") {}.keyboardShortcut("0", modifiers: .command)
                }
            }
        Settings { Color.clear.frame(width: 200, height: 100) }
    }

    private func dump() async {
        try? await Task.sleep(nanoseconds: 700_000_000)
        await MainActor.run {
            print("=== NSApp.mainMenu, as SwiftUI installed it ===")
            report()
            // The app's own prune, reproduced: it removes any top-level menu left with no items.
            if let main = NSApp.mainMenu {
                for item in main.items.reversed() where item.submenu?.items.isEmpty == true {
                    main.removeItem(item)
                }
            }
            print("\n=== after pruneEmptyMenus() ===")
            report()
            exit(0)
        }
    }

    @MainActor private func report() {
        guard let main = NSApp.mainMenu else { print("no main menu"); return }
        for item in main.items {
            let count = item.submenu?.items.count ?? 0
            print("\(item.title)  [\(count) items]")
            for sub in item.submenu?.items ?? [] where !sub.isSeparatorItem {
                let key = sub.keyEquivalent.isEmpty
                    ? "" : "  key=\(describe(sub.keyEquivalent)) mask=\(describe(sub.keyEquivalentModifierMask))"
                print("    · \(sub.title)\(key)")
            }
        }
    }

    private func describe(_ key: String) -> String {
        switch key {
        case "\r": "⏎"
        case "\u{1b}": "esc"
        default: "'\(key)'"
        }
    }

    private func describe(_ mask: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if mask.contains(.control) { parts.append("⌃") }
        if mask.contains(.option) { parts.append("⌥") }
        if mask.contains(.shift) { parts.append("⇧") }
        if mask.contains(.command) { parts.append("⌘") }
        return parts.isEmpty ? "none" : parts.joined()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Probe.main()
