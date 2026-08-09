import Testing
import AppKit
import SwiftUI
import Foundation
@testable import TranslatorApp
@testable import TranslationCore
@testable import TextCapture

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

/// `.resizable` alone is a flag with no implementation, and this is the test that did not
/// exist while that was true.
///
/// The panel carried `.resizable` without `.titled` from the day it started sizing itself, and
/// `isResizable` answered `true` the whole time — so nothing here noticed, and the defect was
/// found by a person pulling at an edge and watching nothing happen.
///
/// Measured, on stock `NSPanel`s with no overrides, which is why the mask and not the flag is
/// what this asserts:
///
///     no `.titled`, `.resizable`     isResizable true    frame view NSNextStepFrame
///     `.titled` + `.resizable`       isResizable true    frame view NSThemeFrame
///     `.titled`, no `.resizable`     isResizable false   frame view NSThemeFrame
///
/// Edge and corner drag tracking lives in `NSThemeFrame`; a borderless window gets
/// `NSNextStepFrame`, which has none. So the two flags are only worth anything together, and
/// `isResizable` cannot tell them apart. The frame view's class would, but it is private API by
/// name; the mask is the stable statement of the same fact.
///
/// What this still cannot do is drag an edge. That stays in `docs/OPEN-ITEMS.md` §1.
@MainActor
@Test func thePanelCarriesBothFlagsThatHandResizingNeeds() {
    let panel = TranslationPanel()
    #expect(panel.styleMask.contains(.resizable))
    #expect(panel.styleMask.contains(.titled),
            "`.resizable` does nothing without `.titled` — a borderless window's frame view has no resize tracking")
    #expect(panel.isResizable)
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
    let controller = PanelController { _ in AnyView(Text("перевод")) }
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
    let controller = PanelController { _ in AnyView(Text("перевод")) }
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
    let controller = PanelController { _ in AnyView(Text("перевод")) }
    let cursor = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
    controller.show(at: cursor)
    defer { controller.hide() }

    // The size is read *after* the show, not before. It used to be readable before, because
    // the panel was born 380 × 260 and stayed that way; it is now whatever the content
    // measured to, and the panel's own frame is the only place that number exists.
    let size = controller.panel.frame.size
    let expected = PanelPlacement.frame(cursor: cursor, size: size, screen: screen.visibleFrame)
    #expect(isNear(controller.panel.frame, expected))
    #expect(screen.visibleFrame.contains(controller.panel.frame))
}

/// The panel is placed against `visibleFrame`, not `frame`, and the difference between them
/// is exactly the menu bar. Every other case in this file is blind to that: swapping
/// `visibleFrame` for `frame` in `show(at:)` leaves them all green, because the clamp that
/// distinguishes the two only engages for a panel tall enough to reach the top of the
/// screen — which is precisely the long translation this panel exists to display.
///
/// The state this needs used to be **unreachable in the app** — the panel was a fixed
/// 380 × 260, so the height was forced onto it by hand and the note here said as much. It is
/// reachable now: content past the ceiling produces exactly this panel, so the height comes
/// from the content and the test exercises the real path.
///
/// `visibleFrame` also governs one more thing than it did. It is the screen rect handed to
/// `PanelSizer`, so it sets the height ceiling as well as the placement — which gives this
/// test a second, machine-independent way to catch the swap: `frame` is taller than
/// `visibleFrame` by the menu bar band, and 0.6 of the taller number is a taller panel. The
/// `#require` above is what makes that difference exist.
@MainActor
@Test func aTallPanelOpensBelowTheMenuBarRatherThanUnderIt() throws {
    let screen = try #require(NSScreen.main, "no display attached; this test cannot run headless")
    let visible = screen.visibleFrame
    try #require(screen.frame.maxY > visible.maxY,
                 "this display reports no menu bar band, so the two frames cannot be told apart")

    // Far past any ceiling, so the panel opens at exactly `maxHeightFraction` of the screen.
    let controller = PanelController { _ in
        AnyView(Text(String(repeating: "строка ", count: 4000)).padding(14))
    }
    // Halfway up: with a panel this tall the downward placement overflows the bottom, so it
    // flips upward, and the flip then overflows the top and clamps — the one arrangement in
    // which `frame` and `visibleFrame` give different answers.
    let cursor = CGPoint(x: visible.midX, y: visible.midY)
    controller.show(at: cursor)
    defer { controller.hide() }
    let frame = controller.panel.frame

    // `.rounded(.up)` rather than a bare comparison: AppKit hands back a whole number of
    // points, so a ceiling of 408.6 is honoured by a panel 409 tall. Measured on CI, where
    // exactly that 0.4 pt made this red.
    #expect(frame.height <= (visible.height * PanelSizer.maxHeightFraction).rounded(.up))
    #expect(isNear(frame, PanelPlacement.frame(cursor: cursor, size: frame.size, screen: visible)))
    #expect(frame.maxY <= visible.maxY)
    #expect(frame.maxY < screen.frame.maxY)
}

/// Beyond the brief, and a real defect it left in.
///
/// `NSWindow` runs every frame through `constrainFrameRect(_:to:)` when the window is
/// ordered in, and it is not a no-op. Measured on this machine when the panel was still
/// `.titled`: a frame at x = 19 came back at x = **221** — AppKit reserving the Stage
/// Manager strip down the left edge — so a selection near the left of the screen would open
/// its panel 202pt away from the pointer, and `PanelPlacement`'s whole flip-then-clamp
/// arithmetic would be silently overruled.
///
/// Dropping `.titled` did not retire that. Re-measured against a *stock* `NSPanel` carrying
/// this panel's new mask, i.e. with no override: a frame whose top crossed the menu bar band
/// came back pulled down by the height of the band, identically to the titled panel. The
/// menu-bar case below is the machine-independent half; the Stage Manager one depends on
/// whether Stage Manager is enabled and did not reproduce on the re-measurement, which is
/// exactly why it is asserted rather than relied upon.
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
    let controller = PanelController { _ in AnyView(Text("перевод")) }
    let cursor = CGPoint(x: screen.visibleFrame.minX + 5, y: screen.visibleFrame.midY)
    controller.show(at: cursor)
    defer { controller.hide() }
    // Size read after the show: the panel is sized from its content now, so there is no
    // size to know beforehand.
    let size = controller.panel.frame.size
    #expect(isNear(controller.panel.frame,
                   PanelPlacement.frame(cursor: cursor, size: size, screen: screen.visibleFrame)))
}

/// Two frames compared with a one-point tolerance.
///
/// `NSWindow` rounds a frame onto its backing store, while `PanelPlacement` computes in
/// unrounded points — so on a display whose `visibleFrame` has a fractional midpoint the two
/// legitimately differ by half a point. Measured by CI on its first run, on a `macos-15`
/// runner: the panel came back at y = 268.0 where `PanelPlacement` said 268.5, and two tests
/// that had never failed on a developer's Mac went red.
///
/// **The tolerance does not weaken what these tests pin.** Each of them exists to catch AppKit
/// relocating the panel, and the two observations behind them are a 202 pt sideways shove from
/// the Stage Manager strip and a pull down by the height of the menu-bar band — three orders of
/// magnitude away from one point. `docs/TESTING.md` shape 3 is the hazard to avoid here, and it
/// is about bounds that only catch movement in one direction; this stays an equality in both.
/// Verified by mutation: restoring `constrainFrameRect` to `super`'s behaviour still kills all
/// three tests.
private func isNear(_ frame: CGRect, _ expected: CGRect,
                    within tolerance: CGFloat = 1) -> Bool {
    abs(frame.minX - expected.minX) <= tolerance
        && abs(frame.minY - expected.minY) <= tolerance
        && abs(frame.width - expected.width) <= tolerance
        && abs(frame.height - expected.height) <= tolerance
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
    let controller = PanelController { _ in AnyView(Text("перевод")) }
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
    let controller = PanelController { _ in AnyView(Text("перевод")) }
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

// MARK: - The panel sized to its content

@MainActor
@Test func theUntitledPanelStillTakesKeyStatusWithoutItsProcessBecomingActive() {
    // The measurement this replaces was taken with `.titled` in the mask. Dropping `.titled`
    // is what buys the rounded material panel, and it is also the one change that could
    // silently cost the panel its key status — and with it Esc and Enter, which are the
    // only way to close and copy. This process runs at `.prohibited` activation policy,
    // where activation is impossible, so `isKeyWindow == true` here has exactly one
    // possible cause. Same reasoning as the test above it; re-run because the mask changed.
    //
    // It has more teeth than it looks. Measured against a stock `NSPanel` with no override:
    // with `.titled` in the mask `canBecomeKey` answered `true`, with the mask this panel
    // now carries it answered `false` and `makeKeyAndOrderFront` left `isKeyWindow` false.
    // So this test now covers `TranslationPanel.canBecomeKey` as well as the style mask.
    let controller = PanelController { _ in AnyView(Text("готово")) }
    controller.show(at: CGPoint(x: 300, y: 400))
    #expect(controller.panel.isKeyWindow)
    #expect(NSRunningApplication.current.isActive == false)
    controller.hide()
}

@MainActor
@Test func aPanelWithLittleToSayOpensSmallerThanOneWithALot() {
    // The change in one line. Both panels are built the same way and differ only in their
    // content, so a fixed-size panel fails this and a content-sized one does not.
    let short = PanelController { _ in AnyView(Text("Готово.").padding(14)) }
    let long = PanelController { _ in
        AnyView(Text(String(repeating: "Длинная строка перевода. ", count: 40)).padding(14))
    }
    short.show(at: CGPoint(x: 300, y: 500))
    long.show(at: CGPoint(x: 300, y: 500))
    #expect(short.panel.frame.height < long.panel.frame.height)
    short.hide()
    long.hide()
}

@MainActor
@Test func theMeasuredPanelStaysInsideTheSizersBounds() {
    // Whatever the hosting view reports, the frame that reaches AppKit is the sizer's.
    let controller = PanelController { _ in
        AnyView(Text(String(repeating: "строка ", count: 4000)).padding(14))
    }
    controller.show(at: CGPoint(x: 300, y: 500))
    let frame = controller.panel.frame
    #expect(frame.width >= PanelSizer.minWidth)
    #expect(frame.width <= PanelSizer.maxWidth)
    #expect(frame.height >= PanelSizer.minHeight)
    #expect(frame.width.isFinite && frame.height.isFinite)
    controller.hide()
}

@MainActor
@Test func growingContentLeavesTheAnchoredCornerWhereItWas() {
    // The reason the panel was a fixed size for so long: growth that moves the corner
    // nearest the pointer drags every already-read line with it.
    let text = Box("Готово.")
    let controller = PanelController { _ in AnyView(Text(text.value).padding(14)) }
    controller.show(at: CGPoint(x: 300, y: 700))
    let before = controller.panel.frame
    text.value = String(repeating: "Ещё одна строка перевода. ", count: 30)
    controller.contentDidChange()
    let after = controller.panel.frame
    #expect(after.height > before.height)
    #expect(after.minX == before.minX)
    #expect(after.maxY == before.maxY)
    controller.hide()
}

/// Beyond the brief, and it closes a hole the brief's own cases leave open.
///
/// Every other test here puts the pointer where the panel hangs down and to the right, so
/// the anchor is `.topLeading` — which is also the field's initial value. Deleting
/// `anchor = placement.anchor` from `show(at:)` therefore left all of them green: the
/// placement's anchor was never consulted and nothing noticed. That mutation was run; this
/// test is what fails on it.
///
/// A pointer near the bottom of the screen flips the panel upward, and the corner nearest
/// it is then the bottom-left. Growth must push the *top* edge up and leave `minY` alone;
/// with the anchor stuck at `.topLeading` it holds `maxY` instead and the panel grows down
/// off the bottom of the screen, where the clamp then drags the whole thing — and every
/// line the user has already read — downwards.
///
/// Only the vertical half of the anchor can be checked from here, and that is a property of
/// the app rather than of the test: `frozenWidth` fixes the width for the whole
/// presentation, so no resize during a presentation changes it, so `isLeading` has nothing
/// to act on. `growingFromATopRightAnchorLeavesTheTopRightCornerWhereItWas` in
/// `PanelPlacementTests` covers the horizontal half at the level where it is reachable.
@MainActor
@Test func aPanelThatOpenedUpwardsGrowsUpwardsToo() throws {
    let screen = try #require(NSScreen.main, "no display attached; this test cannot run headless")
    let visible = screen.visibleFrame
    let text = Box("Готово.")
    let controller = PanelController { _ in AnyView(Text(text.value).padding(14)) }
    // Close enough to the bottom edge that hanging downwards would leave the screen.
    controller.show(at: CGPoint(x: visible.midX, y: visible.minY + 30))
    let before = controller.panel.frame
    text.value = String(repeating: "Ещё одна строка перевода. ", count: 30)
    controller.contentDidChange()
    let after = controller.panel.frame
    #expect(after.height > before.height)
    #expect(after.minY == before.minY)
    controller.hide()
}

@MainActor
@Test func hidingThePanelForgetsTheSizeSoTheNextPressStartsFresh() {
    let text = Box(String(repeating: "Длинный первый перевод. ", count: 30))
    let controller = PanelController { _ in AnyView(Text(text.value).padding(14)) }
    controller.show(at: CGPoint(x: 300, y: 700))
    let tall = controller.panel.frame.height
    controller.hide()
    text.value = "Да."
    controller.show(at: CGPoint(x: 300, y: 700))
    #expect(controller.panel.frame.height < tall)
    controller.hide()
}

/// A reference box so a test can change the content a `@escaping` builder closes over.
/// `@MainActor` rather than `Sendable`: everything here runs on the main actor.
@MainActor final class Box {
    var value: String
    init(_ value: String) { self.value = value }
}

// MARK: - The sizer in front of the view that actually ships

/// A client that is never asked for anything. These tests set `translatedText` directly
/// rather than run a translation, because what is being measured is the view's geometry and
/// a run would only add a delay and a source of variation.
private final class SilentClient: LLMClient, @unchecked Sendable {
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private func panelModel(showing translated: String) -> TranslationViewModel {
    let model = TranslationViewModel(
        translator: Translator(client: SilentClient()),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "panel-size")),
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-size-\(UUID().uuidString).json")))
    model.translatedText = translated
    return model
}

@MainActor
private func realPanelContent(_ model: TranslationViewModel) -> (PanelContentVariant) -> AnyView {
    { variant in
        AnyView(PanelView(model: model, selection: .text("исходный текст"),
                          adoptionRefusal: nil,
                          scrolls: variant.scrolls, fillsPanel: variant.fillsPanel))
    }
}

/// The same claim as `aPanelWithLittleToSayOpensSmallerThanOneWithALot`, made against the
/// view that ships instead of against a `Text` standing in for it — and it is the substitution
/// that made the first version of this task wrong.
///
/// Every other measuring test here hands the controller `Text(…).padding(14)`, which pins the
/// controller's arithmetic and nothing about the panel. The real `PanelView` behaves
/// differently in a way none of them could see: it carries `frame(maxWidth: .infinity,
/// maxHeight: .infinity)` so its material paints to the window's edge, and a view that accepts
/// whatever proposal it is given answers the proposal back. Measured through the same two
/// calls `PanelController.measure` makes, before the fix:
///
///     PanelView short: unbounded=(1.797e+308, 1.797e+308)  at400=(400.0, 1.797e+308)
///     PanelView long:  unbounded=(1.797e+308, 1.797e+308)  at400=(400.0, 1.797e+308)
///
/// `greatestFiniteMagnitude` is finite and positive, so `PanelSizer.measured` takes it for a
/// real measurement rather than for «no idea»: every panel came out `maxWidth` wide and at the
/// height ceiling, `scrolls` was always true, and `applyFit`'s `guard fit.size !=
/// panel.frame.size` then returned early on every token — so the panel never resized at all,
/// and the whole task was inert in the shipped app while thirteen tests stayed green.
///
/// After the fix the same two calls answer 274 × 94 and 6929 × 302, which is why both axes are
/// asserted below: the height alone would pass on a build that still clamped every width to
/// `maxWidth`.
@MainActor
@Test func theRealPanelViewIsMeasuredRatherThanEchoingTheProposalBackAtTheSizer() {
    let short = PanelController(content: realPanelContent(panelModel(showing: "Готово.")))
    let long = PanelController(content: realPanelContent(panelModel(
        showing: String(repeating: "Длинная строка перевода. ", count: 40))))
    short.show(at: CGPoint(x: 300, y: 500))
    long.show(at: CGPoint(x: 300, y: 500))

    #expect(short.panel.frame.height < long.panel.frame.height)
    #expect(short.panel.frame.width < long.panel.frame.width)
    // Named rather than merely relative, because "smaller than the other one" is also true of
    // two panels that are both wrong. A one-word translation belongs at the floors.
    #expect(short.panel.frame.width == PanelSizer.minWidth)
    #expect(short.panel.frame.height == PanelSizer.minHeight)
    short.hide()
    long.hide()
}

/// A second press must be sized for what it is showing, not for what the last one showed.
///
/// Every other measuring test builds a **fresh** `PanelController`, which is the one shape
/// where this cannot fail: a host that has never measured anything has nothing stale to
/// return. The app reuses one controller for the life of the process.
///
/// The content has to change the way the app's does, and that is the whole point of the test.
/// `hidingThePanelForgetsTheSizeSoTheNextPressStartsFresh` above also reuses a controller, but
/// its builder reads a captured `String`, so each rebuild produces a genuinely different view
/// and SwiftUI re-evaluates it unasked. `PanelHost` instead reads `coordinator.selection` and
/// the view model *inside* `body`: the rebuilt view's stored properties are identical — the
/// same model reference — so nothing looks changed and the pending observation invalidation is
/// not flushed until something forces layout. Measured on one reused host: after the text
/// changed and `rootView` was reassigned, `fittingSize` still answered the previous 274 and
/// `sizeThatFits(560)` still answered 94 tall; only `layoutSubtreeIfNeeded()` moved them to
/// 6929 and 302. Through the controller, and re-taken against the real `PanelHost` driven
/// through the real `HotkeyCoordinator.handlePress`, five presses — short, long, `.empty`,
/// `.notPermitted`, short — came out 300 × 120 / 300 × 120 / 326 × 120 / 560 × 131 / 560 × 305
/// with that call and 300 × 120 / 300 × 120 / **560 × 305 / 326 × 120 / 560 × 131** without it.
/// An earlier version of this comment said four alternating presses «all came out 300 × 120»
/// without the call; that came from a probe that stood in for `PanelHost` and is refuted —
/// against the real type the size lags by about one press rather than freezing.
///
/// `show(at:)` is where it does the most damage, because it measures in the same turn of the
/// main actor as the selection it is showing — nothing has yielded in between. A `.text` press
/// corrects itself on its first token, in both axes since `show(at:)` stopped freezing the
/// width; an `.empty` or `.notPermitted` press runs no translation, so `contentDidChange` is
/// never called and the panel keeps the wrong size for its whole life. Those are the two states
/// a new user meets first.
///
/// **Five alternations rather than two, and that is a measurement about this test itself.**
/// With one long press and one short one it caught the `layoutSubtreeIfNeeded()` mutation 3/3
/// under `--filter Panel` but only 39/40 under the full suite, which is the suite the project
/// gates on. The escape is per *measurement*, not per run — on the one escaping run of forty,
/// `aPanelShownBeforeItsTranslationArrivesEndsUpAsWideAsThatTranslationNeeds` caught the same
/// mutation in the same process, so the host was freshened for one measurement and not the
/// other. Something outside this test occasionally flushes SwiftUI's pending update before the
/// read; what that something is was not isolated. Alternating five times makes every one of
/// them have to be lucky at once. It is not a proof of determinism and is not claimed as one —
/// see `docs/OPEN-ITEMS.md` §2 — it is a measured reduction, from 1 escape in 40 to 0 in 40.
@MainActor
@Test func aReusedControllerMeasuresThePressItIsShowingNotThePreviousOne() {
    let longText = String(repeating: "Длинная строка перевода. ", count: 40)
    let model = panelModel(showing: "Готово.")
    let controller = PanelController(content: realPanelContent(model))

    // Content changed through observation, exactly as a run changes it — no value the builder
    // captured, which is the whole point: a captured `String` rebuilds into a genuinely
    // different view and SwiftUI re-evaluates it unasked.
    func press(showing text: String) -> CGSize {
        model.translatedText = text
        controller.show(at: CGPoint(x: 300, y: 600))
        let size = controller.panel.frame.size
        controller.hide()
        return size
    }

    let short = press(showing: "Готово.")
    let long = press(showing: longText)

    #expect(long.height > short.height)
    #expect(long.width > short.width)
    // Both named, because "the second is bigger" would also pass on a build that lagged one
    // press behind in a way that happened to grow.
    #expect(short == CGSize(width: PanelSizer.minWidth, height: PanelSizer.minHeight))
    #expect(long.width == PanelSizer.maxWidth)

    // And back down again, four more times. Shrinking is the direction `PanelSizer`'s monotonic
    // height makes easy to miss, and a lagging host is just as wrong in it.
    for _ in 0..<2 {
        #expect(press(showing: "Да.") == short)
        #expect(press(showing: longText) == long)
    }
}

/// The panel is shown *before* the text it is going to show exists, and it must still end up
/// the width that text deserves.
///
/// This drives the app's real ordering rather than a convenient one. `HotkeyCoordinator`
/// assigns `panelModel.sourceText` **after** the `afterCapture()` that calls `show(at:)`, and
/// the translation only lands token by token after that — so at the moment the panel is placed,
/// the measuring host legitimately holds the previous presentation's result, or nothing at all
/// on the first press of a session. Every other measuring test in this file assigns the content
/// first, which is the one ordering under which a width chosen in `show(at:)` looks right.
///
/// It is not the staleness `layoutSubtreeIfNeeded()` fixes, and no layout call can reach it:
/// the host reflects the model correctly, the model has not been written yet.
///
/// What it cost while `show(at:)` froze the width: the first hotkey translation of a session
/// came up at `minWidth`, and because height is monotonic and width was not, it compensated by
/// growing to roughly twice its proper height — which on a laptop display crosses the 0.6
/// ceiling and swaps in the scrolling variant for content that would have fitted unscrolled.
/// The control below is the assertion that matters: the same content assigned *before* the
/// show is the size this press deserves, and for this long reply the two agree — both land at
/// `maxWidth`. That does not generalize to every length: the same comparison with a short
/// reply has `afterRun` stuck at the button-row width the run started from (347 × 120)
/// against a deserved 300 × 120, and with a medium reply `afterRun` settles at 560 × 134
/// against a deserved 560 × 120 — the width only grows and the height only grows within a
/// run, so a reply that never needed the room it grew through disagrees with what a fresh
/// `show(at:)` would give it. Long text is the one case where growth and deserved size land
/// on the same number.
@MainActor
@Test func aPanelShownBeforeItsTranslationArrivesEndsUpAsWideAsThatTranslationNeeds() {
    let longText = String(repeating: "Длинная строка перевода. ", count: 40)

    let model = panelModel(showing: "")
    let controller = PanelController(content: realPanelContent(model))
    controller.show(at: CGPoint(x: 300, y: 600))
    let atShow = controller.panel.frame.size

    // The reply arrives. Exactly one content update, and it is `settling: false` — which is
    // what `PanelHost` passes for every change of `translatedText`. Both halves of that are
    // forced rather than chosen: `contentDidChange` throttles to ten a second and defers the
    // rest onto a trailing `Task`, so a second synchronous call in the same turn would be
    // coalesced away; and `applyFit` *animates* the settling resize, so after a
    // `settling: true` call `panel.frame` still reads the old frame for the length of the
    // tween. Neither is worth a sleep here. The freeze itself — that the width stops moving
    // once the settle has chosen it — is pinned in `PanelSizerTests`, where it is arithmetic
    // and can fail.
    model.translatedText = longText
    controller.contentDidChange()
    let afterRun = controller.panel.frame.size
    controller.hide()

    let control = PanelController(content: realPanelContent(panelModel(showing: longText)))
    control.show(at: CGPoint(x: 300, y: 600))
    let deserved = control.panel.frame.size
    control.hide()

    // Nothing to measure at the show — this is the state the defect froze a width against.
    #expect(atShow.width == PanelSizer.minWidth)
    // The width catches up with the reply instead of having been decided before it existed.
    #expect(afterRun.width > atShow.width)
    #expect(afterRun == deserved)
    // Named as well as compared, because "the two agree" would also hold if both were wrong.
    #expect(afterRun.width == PanelSizer.maxWidth)
}

/// The other half of the same defect, and the one the height check above cannot see: a panel
/// whose content fits must not be handed the scrolling variant. Before the fix every
/// measurement exceeded every ceiling, so `scrolls` was true for a one-word result — which is
/// a scroll view wrapped around a line of text, inside a panel sized to the whole screen.
///
/// Checked through `PanelSizer` on the numbers the real view now reports, because `scrolls` is
/// private to the controller and the thing worth pinning is the measurement that feeds it.
@MainActor
@Test func aShortTranslationInTheRealPanelViewDoesNotAskToScroll() throws {
    let screen = try #require(NSScreen.main, "no display attached; this test cannot run headless")
    let host = NSHostingController(rootView: realPanelContent(panelModel(showing: "Готово."))(.measured))
    let idealWidth = host.view.fittingSize.width
    let idealHeight = host.sizeThatFits(
        in: CGSize(width: PanelSizer.minWidth, height: CGFloat.greatestFiniteMagnitude)).height
    #expect(idealWidth.isFinite)
    #expect(idealHeight.isFinite)

    let fit = PanelSizer.fit(ideal: CGSize(width: idealWidth, height: idealHeight),
                             frozenWidth: nil, previous: .zero,
                             screen: screen.visibleFrame, userSized: false)
    #expect(fit.scrolls == false)
    #expect(fit.size.height < screen.visibleFrame.height * PanelSizer.maxHeightFraction)
}


/// The panel's view model, built the one way every test here needs it.
///
/// Six copies of these five lines differed only in a `UserDefaults` prefix that no test read.
/// `InMemoryDefaults` per instance for the reason `CLAUDE.md` gives: a written suite leaves a
/// plist in ~/Library/Preferences that nothing reliably removes.
@MainActor
private func panelModel() -> TranslationViewModel {
    TranslationViewModel(
        translator: Translator(client: ScriptedClient(responses: ["x"])),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "panel")),
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("g-\(UUID().uuidString).json")))
}

// MARK: - The panel does not grow under the reader's hands

/// Builds a real `PanelView` in a real panel, the way `TranslatorApp` does.
@MainActor
private func panelSize(source: String, translated: String,
                       state: TranslationState,
                       awaitingRun: Bool = false) -> CGSize {
    let model = panelModel()
    model.state = state
    model.translatedText = translated
    let controller = PanelController { variant in
        AnyView(PanelView(model: model, selection: .text(source),
                          awaitingRun: awaitingRun,
                          scrolls: variant == .installed(scrolls: true),
                          fillsPanel: variant != .measured))
    }
    controller.show(at: CGPoint(x: 600, y: 600))
    defer { controller.hide() }
    return controller.panel.frame.size
}

private let sentence = "Каждый профиль обязан ссылаться на тип, который он ограничивает, "

/// The «кнопки прыгают» report, as an assertion.
///
/// The panel used to open at its 120 pt floor and gain ~16 pt per sentence as the reply
/// arrived — 120 → 198 for a six-sentence paragraph, in five steps, each one moving the
/// button row underneath. It now reserves the reply's room from the selection it is about to
/// translate, so the height it opens at is the height it ends at.
///
/// Stated as «opens at least as tall as it settles» rather than as equality, because the
/// running panel also carries the «Перевожу…» row that the settled one does not. Equality
/// would be a stricter claim than the fix makes, and a false one.
@MainActor
@Test func thePanelOpensAtTheSizeTheReplyWillNeedRatherThanGrowingIntoIt() {
    for count in [2, 4, 6, 12] {
        let source = String(repeating: sentence, count: count)
        // The press window: captured, shown, `translate()` not yet reached.
        let opening = panelSize(source: source, translated: "", state: .idle, awaitingRun: true)
        let settled = panelSize(source: source, translated: source, state: .finished)
        #expect(opening.height >= settled.height)
        #expect(opening.width >= settled.width)
    }
}

/// The other half, and the one that has already been got wrong once: the room is reserved in
/// the *installed* copy only.
///
/// `PanelController` measures a detached copy with no fill frame, and a `Spacer` in it is
/// greedy on its own axis — with one present in the measured copy every panel came back at
/// 998 pt, the 0.6-of-screen ceiling, for every reply length from one sentence to twenty. A
/// panel holding two sentences must be nowhere near that.
@MainActor
@Test func aShortReplyDoesNotMeasureToTheHeightCeiling() {
    let source = String(repeating: sentence, count: 2)
    let ceiling = (NSScreen.main?.visibleFrame.height ?? 900) * PanelSizer.maxHeightFraction
    let size = panelSize(source: source, translated: source, state: .finished)
    #expect(size.height < ceiling / 2)
}

/// The «при первом открытии кнопки перекрываются нижней границей» report, as an assertion.
///
/// It reproduces `HotkeyCoordinator.handlePress`'s ordering, which is what made this hard to
/// see: the selection is assigned, then the panel is shown, and only then is the model given
/// the text and asked to translate. So at the instant `show(at:)` measures, the model still
/// holds the *previous* press — and a reservation gated on `state == .running` was not yet in
/// force. The panel opened at 300 × 120, the floor on both axes, against content that needed
/// 134, 198, 294 and 486 pt at one, three, six and twelve sentences: short by up to 366 pt,
/// with the button row below the bottom edge until the next `applyFit`.
///
/// Asserted as «what it opens at covers what it needs», against the same measuring path the
/// controller uses, because that is the property — not any particular height.
@MainActor
@Test func thePanelOpensCoveringWhatTheRunIsAboutToNeed() {
    for count in [1, 3, 6, 12] {
        let source = String(repeating: sentence, count: count)
        let model = panelModel()
        // Exactly what the coordinator has done by the time it calls `afterCapture()`: the
        // selection is known, `isStartingRun` is set, and the model has been left alone —
        // `translate()` has not run, so its state and its pane still describe the last press.
        model.state = .finished
        model.translatedText = "перевод прошлого нажатия"

        let controller = PanelController { variant in
            AnyView(PanelView(model: model, selection: .text(source),
                              awaitingRun: true,
                              scrolls: variant == .installed(scrolls: true),
                              fillsPanel: variant != .measured))
        }
        controller.show(at: CGPoint(x: 600, y: 600))
        let opened = controller.panel.frame.size
        defer { controller.hide() }

        // …and now `runTranslation()` starts. What the content needs at the width the panel
        // has already committed to.
        model.state = .running
        model.translatedText = ""
        let host = NSHostingController(
            rootView: PanelView(model: model, selection: .text(source),
                                scrolls: false, fillsPanel: false))
        host.view.layoutSubtreeIfNeeded()
        let needed = host.sizeThatFits(in: CGSize(width: opened.width,
                                                  height: .greatestFiniteMagnitude))
        #expect(opened.height >= needed.height)
    }
}

// MARK: - A hand-resize

/// Builds a panel over a finished translation and reports which variant is installed.
@MainActor
private func resizablePanel(text: String)
    -> (PanelController, TranslationViewModel, () -> String) {
    let model = panelModel()
    model.sourceText = text
    model.translatedText = text
    model.state = .finished
    final class Box: @unchecked Sendable { var variant = "?" }
    let box = Box()
    let controller = PanelController { variant in
        if case .installed(let scrolls) = variant { box.variant = scrolls ? "scrolling" : "flat" }
        return AnyView(PanelView(model: model, selection: .text(text),
                                 scrolls: variant == .installed(scrolls: true),
                                 fillsPanel: variant != .measured))
    }
    return (controller, model, { box.variant })
}

/// «Когда изменяю размер, кнопки и всё остальное исчезает.»
///
/// `windowDidEndLiveResize` recorded that the size was the user's and stopped there, and
/// nothing else re-fits after a drag — `contentDidChange` is driven by the run, and a finished
/// translation has nothing more to say. So a panel dragged shorter than its content kept the
/// flat variant: measured at 560 × 120 holding 270 pt of unscrollable content, with the whole
/// bottom section — the status row, the warnings and both buttons — below the window's edge.
@MainActor
@Test func aPanelDraggedShorterThanItsContentStartsScrollingInstead() {
    let text = String(repeating: sentence, count: 12)
    let (controller, _, variant) = resizablePanel(text: text)
    controller.show(at: CGPoint(x: 600, y: 600))
    defer { controller.hide() }
    #expect(variant() == "flat")

    // The user drags the bottom edge up and lets go. 100 pt and not 150: the panel's own
    // floor is `PanelSizer.minHeight`, and a test that drags through it would be asserting
    // that the floor is not applied rather than that the variant changed.
    var frame = controller.panel.frame
    frame.size.height -= 100
    frame.origin.y += 100
    controller.panel.setFrame(frame, display: true)
    controller.windowDidEndLiveResize(
        Notification(name: NSWindow.didEndLiveResizeNotification, object: controller.panel))

    #expect(variant() == "scrolling")
    // And the drag is still honoured — re-fitting must not undo it.
    #expect(controller.panel.frame.height == frame.height)
}

/// The trap the `inLiveResize` guard exists for.
///
/// `windowDidResize` cannot tell a drag from `applyFit`'s own `setFrame` by the notification
/// alone, and AppKit posts it for both. Without the guard the panel's first programmatic fit
/// would set `userSized` and freeze its automatic sizing for the rest of the presentation, so
/// a reply arriving after it would never be given room — which is a worse defect than the one
/// the resize handler was added to fix.
@MainActor
@Test func aProgrammaticResizeIsNotMistakenForAHandResize() {
    let (controller, model, _) = resizablePanel(text: "короткий")
    controller.show(at: CGPoint(x: 600, y: 600))
    defer { controller.hide() }
    let opened = controller.panel.frame.height

    // The reply grows, exactly as it does while a run streams. Every fit along the way sets
    // the frame, and every one of those posts `didResize` to this same delegate.
    model.translatedText = String(repeating: sentence, count: 10)
    controller.contentDidChange()

    #expect(controller.panel.frame.height > opened)
}

/// A long warning list must not take the translation's height away from it.
///
/// The warnings left `scrollingMiddle` when the panel became three sections, and unbounded
/// content in a pinned flow starves the flexible section beside it rather than pushing the
/// buttons out of it. Measured on a bare 560 × 540 stack before the fix — the 0.6-of-screen
/// cap on a 900 pt display — the middle's clip view came out 438, 365, 215 and **0** pt tall
/// at 0, 5, 15 and 30 warning rows. At zero the translation is not small, it is unreachable.
///
/// Asserted against the installed hierarchy rather than the ideal size, because the starving
/// happens in layout: the sizer is content, and the clip view is where it shows.
@MainActor
@Test func aLongWarningListDoesNotStarveTheTranslation() {
    let text = String(repeating: sentence, count: 12)
    let model = panelModel()
    model.sourceText = text
    model.translatedText = text
    model.state = .finished
    model.outcome = TranslationOutcome(
        final: text, chunks: [], translatedChunks: [text], documentGlossary: [],
        detectedSource: .en,
        checks: [],
        markupDiffs: (0..<30).map { _ in
            MarkupDiff(expected: nil, actual: nil, note: "потеряно: граница абзаца")
        },
        stats: [], timeToFirstTokenMS: 12, totalMS: 34,
        documentGlossaryFailure: nil, documentGlossaryAttempted: false)

    let controller = PanelController { variant in
        AnyView(PanelView(model: model, selection: .text(text),
                          scrolls: variant == .installed(scrolls: true),
                          fillsPanel: variant != .measured))
    }
    controller.show(at: CGPoint(x: 600, y: 600))
    defer { controller.hide() }
    controller.panel.contentView?.layoutSubtreeIfNeeded()

    var clipHeights: [CGFloat] = []
    func walk(_ v: NSView) {
        if v is NSClipView { clipHeights.append(v.frame.height) }
        for s in v.subviews { walk(s) }
    }
    if let content = controller.panel.contentView { walk(content) }
    // Every scrolling region in the panel must have somewhere to put its content.
    #expect(!clipHeights.isEmpty)
    #expect(clipHeights.allSatisfy { $0 > 0 })
}

/// The window's own minimum and the sizer's floors are the same two numbers, and they have to
/// be: `PanelSizer.fit`'s `userSized` branch answers `max(previous, floor)`, so any size AppKit
/// lets the user reach below a floor is a size the sizer will disagree with — and it disagrees
/// by writing a frame, under a hand that is still moving the edge.
@Test @MainActor func theWindowRefusesTheSizesTheSizerWouldOverrule() {
    let controller = PanelController { _ in AnyView(Text("перевод")) }
    #expect(controller.panel.contentMinSize.width == PanelSizer.minWidth)
    #expect(controller.panel.contentMinSize.height == PanelSizer.minHeight)
}

/// A selection of a few pages must not cost half a second before the panel appears.
///
/// The reservation lays a hidden copy of the selection out to decide the panel's opening size.
/// Measured showing the real panel at each length: 500 chars → 214 pt in 15.7 ms, 8 000 →
/// 998 pt (this display's 0.6-of-screen ceiling, 997) in 29.3 ms, 200 000 → the same 998 pt in
/// **419 ms**. Every character past the ceiling is laid out to produce a number that has
/// already stopped changing, on the main actor, at the moment the panel is meant to appear.
/// `@MainActor` because it calls statics on a `View` — the trap `CLAUDE.md` records.
@MainActor
@Test func theReservationStopsAtTheLengthThatStopsChangingTheAnswer() {
    let long = String(repeating: "слово ", count: 20_000)
    #expect(long.count > PanelView.reservationLimit)
    #expect(PanelView.reservation(for: long).count == PanelView.reservationLimit)
    // Short selections are reserved whole — the cap must not truncate the ordinary case.
    let short = "Каждый профиль обязан ссылаться на тип."
    #expect(PanelView.reservation(for: short) == short)
}

/// Pressing ⌥⌘T twice over the same paragraph must be the same as pressing it once.
///
/// The reservation used to key on `model.sourceText != source`, which is false the second
/// time: the panel reserved nothing and opened showing the first run's own status — after a
/// failure, «Ollama не запущена…» with a «Повторить» button, under a run already in flight.
/// `HotkeyCoordinator` now clears the previous reply before the panel is shown, and the panel
/// asks about the run's state rather than comparing two strings.
@MainActor
@Test func aSecondPressOverTheSameSelectionReservesAsMuchAsTheFirst() {
    let text = String(repeating: sentence, count: 6)

    func opening(afterPreviousRun previous: Bool) -> CGFloat {
        let model = panelModel()
        if previous {
            // A run over this very selection has already finished. `handlePress` leaves all
            // of it alone — that is the point: `translate()` keeps the previous reply until
            // the next one's first token, and the panel must reserve for the new run anyway.
            model.sourceText = text
            model.translatedText = text
            model.state = .finished
        }

        let controller = PanelController { variant in
            AnyView(PanelView(model: model, selection: .text(text),
                              awaitingRun: true,
                              scrolls: variant == .installed(scrolls: true),
                              fillsPanel: variant != .measured))
        }
        controller.show(at: CGPoint(x: 600, y: 600))
        defer { controller.hide() }
        return controller.panel.frame.height
    }

    #expect(opening(afterPreviousRun: true) == opening(afterPreviousRun: false))
}

/// The reservation must *lift*, and nothing pinned that until this test.
///
/// The three tests that measure the panel's opening all build it while the reply is still to
/// come, so every one of them passes when the reservation is made unconditional — checked,
/// all three green with `awaitingReply` hard-wired to `true`. What that would ship is a panel
/// that keeps room for the source's whole length after the run has ended: a hole between a
/// short translation and the button row, for the rest of the presentation.
///
/// Measured through `sizeThatFits` rather than a panel, so no animation and no clock: the
/// settle is the one resize `PanelController` animates, and a frame read after it is only
/// sometimes there.
@MainActor
@Test func aFinishedShortReplyDoesNotKeepTheRoomReservedForItsSource() {
    let source = String(repeating: sentence, count: 12)
    let model = panelModel()
    model.sourceText = source

    func idealHeight(awaitingRun: Bool = false) -> CGFloat {
        let host = NSHostingController(
            rootView: PanelView(model: model, selection: .text(source),
                                awaitingRun: awaitingRun,
                                scrolls: false, fillsPanel: false))
        host.view.layoutSubtreeIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 560, height: CGFloat.greatestFiniteMagnitude)).height
    }

    // Waiting for the reply: the room is the source's.
    model.translatedText = ""
    model.state = .idle
    let awaiting = idealHeight(awaitingRun: true)

    // The reply arrives and is short. The room must go back.
    model.translatedText = "Короткий ответ."
    model.state = .finished
    let settled = idealHeight()

    #expect(settled < awaiting / 2)
}
