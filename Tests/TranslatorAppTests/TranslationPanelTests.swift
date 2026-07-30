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
    #expect(controller.panel.frame == expected)
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

    #expect(frame.height <= visible.height * PanelSizer.maxHeightFraction)
    #expect(frame == PanelPlacement.frame(cursor: cursor, size: frame.size, screen: visible))
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

