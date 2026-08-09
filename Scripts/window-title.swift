// Scripts/window-title.swift
//
// What this settles, and what it does not.
//
//     swiftc -O -o /tmp/window-title Scripts/window-title.swift && /tmp/window-title
//     MODE=once /tmp/window-title
//     MODE=navtitle /tmp/window-title
//
// Compiled, not `swift Scripts/window-title.swift`: the interpreter cannot JIT the
// availability check SwiftUI emits (`Symbols not found: ___isPlatformVersionAtLeast`).
//
// **Settles:** `.navigationTitle("")` and `titleVisibility = .hidden` both remove the drawn
// title, but the first leaves `NSWindow.title` empty and the second keeps «Толмач» — which is
// the name the «Окно» menu, Mission Control and VoiceOver use. That is why `WindowTitleHidden`
// takes the second.
//
// **Does not settle:** why a *single* assignment stops holding in the real app. This
// reproduces the scene shape as closely as it can — accessory activation policy, MenuBarExtra
// declared before the Window, a full .navigation toolbar group, .defaultSize, and the tick
// read in the *scene* body so the window is reconfigured repeatedly — and MODE=once still
// passes here while failing on the bundle. Keep that in mind before trusting it: this probe
// says one assignment is enough, and on the app it is not.
import SwiftUI
import AppKit

var mode: String { ProcessInfo.processInfo.environment["MODE"] ?? "reapply" }

struct Hider: NSViewRepresentable {
    let tick: Int
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ nsView: NSView, context: Context) {
        if mode != "once" { nsView.window?.titleVisibility = .hidden }
    }
    final class V: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didUpdateNotification, object: nil)
            guard let window else { return }
            window.titleVisibility = .hidden
            if mode != "once" {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(reassert(_:)),
                    name: NSWindow.didUpdateNotification, object: window)
            }
        }
        @objc private func reassert(_ note: Notification) {
            (note.object as? NSWindow)?.titleVisibility = .hidden
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct Probe: App {
    @Environment(\.openWindow) private var openWindow
    @State private var tick = 0

    var body: some Scene {
        MenuBarExtra {
            Text("menu")
        } label: {
            // Read here on purpose: this is the scene-body invalidation the real app has.
            Text("\(tick)").task { await run() }
        }
        Window("Толмач", id: "w") { content }
            .defaultSize(width: 900, height: 520)
    }

    @ViewBuilder var content: some View {
        let base = Color.clear
            .frame(minWidth: 700, minHeight: 480)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Text("Из")
                    Picker("Из", selection: .constant(0)) { Text("Определить").tag(0) }
                        .labelsHidden()
                }
                ToolbarItem(placement: .primaryAction) { Button("Перевести \(tick)") {} }
            }
        if mode == "navtitle" { base.navigationTitle("") } else { base.background(Hider(tick: tick)) }
    }

    @MainActor func run() async {
        NSApp.setActivationPolicy(.accessory)
        openWindow(id: "w")
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(150))
            tick += 1
        }
        try? await Task.sleep(for: .milliseconds(800))
        for w in NSApp.windows where w.toolbar != nil {
            var visible = 0
            func walk(_ v: NSView) {
                if let f = v as? NSTextField, f.stringValue.contains("Толмач"),
                   !f.isHidden, f.frame.width > 0 { visible += 1 }
                for sub in v.subviews { walk(sub) }
            }
            if let frame = w.contentView?.superview { walk(frame) }
            print("MODE=\(mode)  NSWindow.title=«\(w.title)»  "
                  + "titleVisibility=\(w.titleVisibility.rawValue)  "
                  + "visible title fields=\(visible)")
        }
        print("want: title «Толмач» kept, titleVisibility 1, 0 visible fields")
        NSApp.terminate(nil)
    }
}

// `swift file.swift` runs the file as top-level code, which is exactly what `@main`
// forbids — so the entry point is the call the attribute would have synthesised.
Probe.main()
