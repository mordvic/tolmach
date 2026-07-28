import Testing
import AppKit
import SwiftUI
@testable import TranslatorApp

@MainActor
@Test func thePanelIsNonActivatingAndFloating() {
    // The three properties spec 7.2 rests on. A panel missing `.nonactivatingPanel`
    // activates the app; one that is not floating disappears behind the source window; one
    // that hides on deactivate vanishes the moment it is shown, since this app is never
    // active when it appears.
    let panel = TranslationPanel()
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.level == .floating)
    #expect(panel.hidesOnDeactivate == false)
    #expect(panel.canBecomeKey)
}

/// Spec 7.2's actual claim, in the only form this process can falsify.
///
/// The brief asked for `NSWorkspace.shared.frontmostApplication` to be unchanged across the
/// show. It is — and it is unchanged *no matter what this code does*, which makes the
/// assertion worthless on its own. Measured, in a standalone binary built from this panel:
/// with `.nonactivatingPanel` deleted the frontmost app did not move; with an explicit
/// `NSApp.activate(ignoringOtherApps: true)` under `.regular` activation policy — the app
/// genuinely became active, `NSRunningApplication.current.isActive` flipped to `true` — the
/// frontmost app *still* read Safari. An unbundled test process cannot take the foreground
/// away from a bundled one, so no mutation can make that line fail. It is kept below as a
/// cheap regression net and named as documentation, not as proof.
///
/// What does have teeth is the other half of the same sentence: **key without active**.
/// A window only becomes key while its application is inactive if the style mask says
/// `.nonactivatingPanel`. This process runs at `.prohibited` activation policy, where
/// activation is impossible — measured: `NSApp.activate` there is a no-op and
/// `NSRunningApplication.current.isActive` stays `false`. So `panel.isKeyWindow == true`
/// here has exactly one possible cause, and deleting `.nonactivatingPanel` from the style
/// mask turns it `false`. That mutation was run; this test failed on it.
@MainActor
@Test func showingThePanelTakesKeyStatusWithoutItsProcessBecomingActive() {
    let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let menuBarBefore = NSWorkspace.shared.menuBarOwningApplication?.bundleIdentifier
    let controller = PanelController { AnyView(Text("перевод")) }
    controller.show(at: CGPoint(x: 300, y: 300))
    defer { controller.hide() }

    #expect(controller.isVisible)
    // The load-bearing pair. Key, so Esc and Enter arrive; not active, so the app the user
    // was working in keeps the foreground and its menu bar.
    #expect(controller.panel.isKeyWindow)
    #expect(NSRunningApplication.current.isActive == false)
    // Documentation, not proof — see the note above.
    #expect(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == before)
    #expect(NSWorkspace.shared.menuBarOwningApplication?.bundleIdentifier == menuBarBefore)
}

@MainActor
@Test func hidingIsIdempotent() {
    let controller = PanelController { AnyView(Text("перевод")) }
    controller.show(at: CGPoint(x: 300, y: 300))
    controller.hide()
    #expect(controller.isVisible == false)
    controller.hide()
    #expect(controller.isVisible == false)
}

/// The brief guarded this with `guard let screen = NSScreen.main else { return }`, which
/// turns a machine with no display into a silent pass. `#require` reports instead: if this
/// ever runs somewhere headless the run says so rather than counting an untested line as
/// green. On the machine this was written on `NSScreen.main` is non-nil even before
/// `NSApplication` is touched, so the body below did execute.
///
/// It also pins the frame exactly rather than only asking that the origin land somewhere on
/// the screen. `screen.visibleFrame.contains(origin)` is satisfied by any placement that is
/// merely *inside* the display — including one AppKit has shoved 200pt sideways, which is
/// what actually happens here without `constrainFrameRect` overridden.
@MainActor
@Test func thePanelLandsOnTheScreenThatHoldsTheCursor() throws {
    let screen = try #require(NSScreen.main, "no display attached; this test cannot run headless")
    let controller = PanelController { AnyView(Text("перевод")) }
    let size = controller.panel.frame.size
    let cursor = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
    controller.show(at: cursor)
    defer { controller.hide() }

    let expected = PanelPlacement.frame(cursor: cursor, size: size, screen: screen.visibleFrame)
    #expect(controller.panel.frame == expected)
    #expect(screen.visibleFrame.contains(controller.panel.frame))
}

/// The panel is placed against `visibleFrame`, not `frame`, and the difference between them
/// is exactly the menu bar. Every other case in this file is blind to that: swapping
/// `visibleFrame` for `frame` in `show(at:)` leaves them all green, because the clamp that
/// distinguishes the two only engages for a panel tall enough to reach the top of the
/// screen — which is precisely the long translation this panel exists to display.
///
/// The height is set on the panel directly, and the state it creates is **not currently
/// reachable in the app**: the panel is a fixed 380 × 260 and nothing resizes it, so at that
/// height the upward flip never comes near the menu bar. The test is kept anyway, and the
/// reason is narrow rather than defensive — `show(at:)` using `visibleFrame` is correct at
/// any size, the panel's size is one edit away from changing, and this is the only thing
/// that would notice if that edit and a `frame`-based `show` ever met.
@MainActor
@Test func aTallPanelOpensBelowTheMenuBarRatherThanUnderIt() throws {
    let screen = try #require(NSScreen.main, "no display attached; this test cannot run headless")
    let visible = screen.visibleFrame
    try #require(screen.frame.maxY > visible.maxY,
                 "this display reports no menu bar band, so the two frames cannot be told apart")

    let controller = PanelController { AnyView(Text("перевод")) }
    controller.show(at: CGPoint(x: visible.midX, y: visible.midY))
    var tall = controller.panel.frame
    tall.size = CGSize(width: 380, height: visible.height - 40)
    controller.panel.setFrame(tall, display: false)
    controller.hide()

    // Low enough that the panel flips upward, tall enough that the flip then clamps — the
    // one arrangement in which `frame` and `visibleFrame` give different answers.
    let cursor = CGPoint(x: visible.midX, y: visible.minY + 100)
    controller.show(at: cursor)
    defer { controller.hide() }

    #expect(controller.panel.frame
            == PanelPlacement.frame(cursor: cursor, size: tall.size, screen: visible))
    #expect(controller.panel.frame.maxY <= visible.maxY)
    #expect(controller.panel.frame.maxY < screen.frame.maxY)
}

/// Beyond the brief, and a real defect it left in.
///
/// `NSWindow` runs every frame through `constrainFrameRect(_:to:)` when the window is
/// ordered in, and for a `.titled` window that is not a no-op. Measured on this machine:
/// a frame at x = 19 came back at x = **221** — AppKit reserving the Stage Manager strip
/// down the left edge — so a selection near the left of the screen would open its panel
/// 202pt away from the pointer, and `PanelPlacement`'s whole flip-then-clamp arithmetic
/// would be silently overruled. The menu-bar case below is the machine-independent half:
/// a titled window whose frame crosses the menu bar band is pulled down on every Mac.
///
/// Overriding costs nothing, because `PanelPlacement` already clamps to `visibleFrame` —
/// which is strictly stronger than what AppKit's constraint guarantees. The brief's
/// prescribed test could not see this: it places the panel at the centre of the screen,
/// where the constraint has nothing to do.
@MainActor
@Test func appKitsOwnFrameConstraintDoesNotOverrideThePlacement() throws {
    let screen = try #require(NSScreen.main, "no display attached; this test cannot run headless")
    let panel = TranslationPanel()

    // Deliberately across the menu bar, which AppKit constrains on every configuration.
    let overMenuBar = CGRect(x: screen.frame.midX, y: screen.frame.maxY - 100,
                             width: 380, height: 260)
    #expect(panel.constrainFrameRect(overMenuBar, to: screen) == overMenuBar)
    // And hard against the left edge, which is where the Stage Manager strip bites.
    let atLeftEdge = CGRect(x: screen.frame.minX + 1, y: screen.visibleFrame.midY,
                            width: 380, height: 260)
    #expect(panel.constrainFrameRect(atLeftEdge, to: screen) == atLeftEdge)

    // End to end: a pointer near the left edge, through `show`, must land where
    // `PanelPlacement` said and not where AppKit would prefer.
    let controller = PanelController { AnyView(Text("перевод")) }
    let size = controller.panel.frame.size
    let cursor = CGPoint(x: screen.visibleFrame.minX + 5, y: screen.visibleFrame.midY)
    controller.show(at: cursor)
    defer { controller.hide() }
    #expect(controller.panel.frame
            == PanelPlacement.frame(cursor: cursor, size: size, screen: screen.visibleFrame))
}

// MARK: - Esc and Enter

private func keyDown(_ keyCode: UInt16, _ characters: String) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                     windowNumber: 0, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false,
                     keyCode: keyCode)!
}

/// Esc is not intercepted in `keyDown`; it is left to reach `cancelOperation(_:)`, which is
/// the responder-chain call AppKit makes for the Cancel key. That routing was measured
/// rather than assumed — a synthetic Esc handed to `sendEvent` arrives at `keyDown`, and
/// `super.keyDown` is what turns it into `cancelOperation`. Which is the trap worth pinning:
/// an override of `keyDown` that swallows Esc instead of calling `super` silently unhooks
/// the Escape handler, and nothing else in the app would notice.
@MainActor
@Test func escapeReachesTheEscapeHandlerThroughTheRealKeyPath() {
    let controller = PanelController { AnyView(Text("перевод")) }
    var escapes = 0
    var enters = 0
    controller.onEscape = { escapes += 1 }
    controller.onEnter = { enters += 1 }
    controller.show(at: CGPoint(x: 300, y: 300))
    defer { controller.hide() }

    controller.panel.sendEvent(keyDown(53, "\u{1b}"))
    #expect(escapes == 1)
    #expect(enters == 0)
}

/// Both Return keys. 36 is the one above the right Shift; 76 is the one on the numeric pad,
/// which sends a different code and is the key a user with a full-size keyboard reaches for.
/// Handling only 36 would leave that user pressing Enter at a panel that ignores it.
@MainActor
@Test func returnAndKeypadEnterReachTheEnterHandler() {
    let controller = PanelController { AnyView(Text("перевод")) }
    var escapes = 0
    var enters = 0
    controller.onEscape = { escapes += 1 }
    controller.onEnter = { enters += 1 }
    controller.show(at: CGPoint(x: 300, y: 300))
    defer { controller.hide() }

    controller.panel.sendEvent(keyDown(36, "\r"))
    #expect(enters == 1)
    controller.panel.sendEvent(keyDown(76, "\u{3}"))
    #expect(enters == 2)
    #expect(escapes == 0)
}

