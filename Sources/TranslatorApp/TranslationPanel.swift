// Sources/TranslatorApp/TranslationPanel.swift
import AppKit
import SwiftUI

/// The floating result panel.
///
/// `.nonactivatingPanel` is not decoration. Without it, ordering this window in activates
/// the application: the source app leaves the foreground, the menu bar changes under the
/// user and whatever they were doing is interrupted — which is precisely the failure spec
/// 7.2 names. With it, the panel can still become *key* and so receive Esc and Enter, while
/// the owning application stays inactive. Key and active are different things, and this
/// window needs the first without the second.
@MainActor
final class TranslationPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
                   backing: .buffered, defer: false)
        // Both already true of a fresh `NSPanel` — measured, `level` reads `.floating` and
        // `isFloatingPanel` reads `true` before either line runs. Kept as the statement of
        // what this window requires, since nothing in the API promises those defaults.
        isFloatingPanel = true
        level = .floating
        // The app is never active when this appears, so a panel that hid on deactivation
        // would be dismissed by the very state it is shown in. Redundant *while* the mask
        // says `.nonactivatingPanel` — that alone flips the default from true to false —
        // and load-bearing the moment anyone touches the mask, which is the case it guards.
        hidesOnDeactivate = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        // Follows the user across desktops and sits over full-screen apps, because the
        // selection it is translating came from one.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// Belt and braces, and worth being honest about which: a `.titled` `NSPanel` already
    /// answers `true` here with or without `.nonactivatingPanel` — measured both ways — so
    /// this override changes nothing today. What it does *not* do is make the panel key
    /// while the app is inactive; only the style mask does that. `canBecomeKey` is
    /// permission, `.nonactivatingPanel` is the grant, and confusing the two is how a panel
    /// ends up looking correct and never receiving Esc.
    override var canBecomeKey: Bool { true }
    /// Deliberately false. Main status belongs to the document window; a panel taking it
    /// would make the app behave as though it had been activated.
    override var canBecomeMain: Bool { false }

    /// AppKit runs every frame through this on the way in, and for a `.titled` window it is
    /// not a no-op: measured on the development machine, a frame at x = 19 came back at
    /// x = 221, because Stage Manager reserves a strip down the left edge. A panel that is
    /// placed relative to the pointer cannot accept that — a selection near the left of the
    /// screen would open its result 202pt away from where the user is looking, with
    /// `PanelPlacement`'s flip-and-clamp arithmetic silently overruled.
    ///
    /// Returning the rect untouched is safe rather than reckless: `PanelPlacement` already
    /// clamps the whole frame inside `visibleFrame`, which is strictly stronger than what
    /// this constraint promises — it keeps the entire panel on screen and below the menu
    /// bar, not merely its title bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    var onEscape: () -> Void = {}
    var onEnter: () -> Void = {}

    /// Spec 7.2: Esc closes and cancels, Enter copies and closes. Handled on the panel
    /// rather than in SwiftUI because the content has no focused control to receive them —
    /// the panel is a readout, not a form.
    ///
    /// Esc arrives here rather than in `keyDown` because AppKit turns the Cancel key into
    /// this responder-chain call; `keyDown` below must keep calling `super` for that to
    /// happen. Measured, not assumed.
    override func cancelOperation(_ sender: Any?) { onEscape() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {   // Return, and the numeric pad's Enter
            onEnter()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class PanelController {
    /// Internal rather than private so the tests can drive real `NSEvent`s through it and
    /// read the frame AppKit actually settled on. The app talks to the controller.
    let panel = TranslationPanel()
    private let hosting: NSHostingView<AnyView>

    var onEscape: () -> Void = {}
    var onEnter: () -> Void = {}

    var isVisible: Bool { panel.isVisible }

    init(content: () -> AnyView) {
        hosting = NSHostingView(rootView: content())
        panel.contentView = hosting
        // Forwarded through the controller's own properties rather than assigned to the
        // panel directly, so a caller that sets `onEscape` after construction — which is
        // every caller — still gets the key press.
        panel.onEscape = { [weak self] in self?.onEscape() }
        panel.onEnter = { [weak self] in self?.onEnter() }
    }

    func setContent(_ view: AnyView) { hosting.rootView = view }

    func show(at cursor: CGPoint) {
        // The screen the pointer is on, not `NSScreen.main` — which is the screen with the
        // key window, i.e. usually the wrong one when the user is working in another app on
        // a second display.
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        // `visibleFrame`, not `frame`: the difference is the menu bar, and placing against
        // `frame` opens a tall panel underneath it.
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrame(PanelPlacement.frame(cursor: cursor, size: size, screen: visible), display: false)
        // `makeKeyAndOrderFront` on a `.nonactivatingPanel` gives the panel key status
        // without activating the app — checked by
        // `showingThePanelTakesKeyStatusWithoutItsProcessBecomingActive`.
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel.orderOut(nil) }

    func resize(to size: CGSize) {
        guard panel.isVisible else { return }
        var frame = panel.frame
        // Grows downwards from the top edge, so the panel does not appear to jump while
        // text streams into it.
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }
}
