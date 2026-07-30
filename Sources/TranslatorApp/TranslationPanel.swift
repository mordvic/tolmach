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
    /// Opened at 380 × 260 and immediately resized.
    ///
    /// The initial rect is not a design decision, it is somewhere to stand: `PanelController`
    /// measures the content and sets the real frame before the panel is ordered in. It stays
    /// non-zero because an `NSWindow` built at `.zero` reports a degenerate frame to the
    /// first layout pass, and the measurement is taken from a detached hosting controller
    /// anyway.
    ///
    /// `.titled` is deliberately **absent**. A titled panel cannot be given a corner radius
    /// without the square window background showing through at the corners, and its
    /// titlebar is 22pt of chrome over a readout with no title. Dropping it costs the
    /// standard close button — `PanelView` draws its own ⨯ — and it invalidates the
    /// measurement that used to sit on `canBecomeKey`, which is why
    /// `theUntitledPanelStillTakesKeyStatusWithoutItsProcessBecomingActive` exists.
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                   styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView, .utilityWindow],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // The app is never active when this appears, so a panel that hid on deactivation
        // would be dismissed by the very state it is shown in. Redundant *while* the mask
        // says `.nonactivatingPanel` — that alone flips the default from true to false —
        // and load-bearing the moment anyone touches the mask, which is the case it guards.
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        // A rounded corner needs the window to stop painting its own. `PanelView` draws the
        // material and clips it to a `RoundedRectangle`, but that only shapes what SwiftUI
        // draws: an `NSWindow` is a rectangle and fills its whole frame with `backgroundColor`
        // underneath, so the corners the `clipShape` cuts away expose the window's fill rather
        // than what is behind the window. The first two lines stop that fill; the third puts
        // the shadow back, because a window with no background loses the one AppKit derives
        // from it. **Not observed** — nothing in this environment can see the screen, and the
        // corners are listed in `docs/OPEN-ITEMS.md` §1 as owed to a human.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Follows the user across desktops and sits over full-screen apps, because the
        // selection it is translating came from one.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    /// Load-bearing since `.titled` left the style mask, and it was not before.
    ///
    /// The measurement that used to sit here said a `.titled` `NSPanel` answers `true` with
    /// or without the override, so the override changed nothing. That is no longer the
    /// panel this is. Re-measured in this process against a stock `NSPanel` with no override
    /// at all: with the old mask it answered `true`, with the mask above — the same one
    /// minus `.titled` — it answered **`false`**, and `makeKeyAndOrderFront` then left
    /// `isKeyWindow` false. So without this line the panel would come up looking correct and
    /// silently never receive Esc or Enter, which are its only way to close and to copy.
    /// `theUntitledPanelStillTakesKeyStatusWithoutItsProcessBecomingActive` is the test.
    ///
    /// What it still does *not* do is make the panel key while the app is inactive; only
    /// `.nonactivatingPanel` does that. `canBecomeKey` is permission, `.nonactivatingPanel`
    /// is the grant, and both are now required.
    override var canBecomeKey: Bool { true }
    /// Deliberately false. Main status belongs to the document window; a panel taking it
    /// would make the app behave as though it had been activated.
    override var canBecomeMain: Bool { false }

    /// AppKit runs every frame through this on the way in, and it is not a no-op: measured
    /// on the development machine, a frame at x = 19 came back at x = 221, because Stage
    /// Manager reserves a strip down the left edge. A panel that is placed relative to the
    /// pointer cannot accept that — a selection near the left of the screen would open its
    /// result 202pt away from where the user is looking, with `PanelPlacement`'s
    /// flip-and-clamp arithmetic silently overruled. It matters twice over now that the
    /// panel resizes: every growth step goes through here too.
    ///
    /// Dropping `.titled` did not retire it. Re-measured against a stock `NSPanel` carrying
    /// this panel's new mask: a frame whose top crossed the menu bar band still came back
    /// pulled down by the height of the band, exactly as the titled one did.
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

/// Which of the two jobs a build of the panel's content is for.
///
/// The two are not interchangeable, and an enum rather than a pair of `Bool`s because the
/// combination that must never exist — measured *and* filling the panel — is then unspeakable
/// rather than merely discouraged. It cost a defect once: the measured copy carried
/// `PanelView`'s fill frame, answered `greatestFiniteMagnitude` on both axes to every
/// proposal, and the panel silently stopped resizing. See `PanelView.fillsPanel`.
enum PanelContentVariant: Equatable {
    /// Installed as the panel's content view and looked at.
    case installed(scrolls: Bool)
    /// Held by the detached host and only ever asked for a size.
    case measured

    /// Never true while measuring: a `ScrollView` compresses to nothing, so the measured copy
    /// would report a tiny ideal height and the panel would never grow back.
    var scrolls: Bool {
        switch self {
        case .installed(let scrolls): scrolls
        case .measured: false
        }
    }

    /// Never true while measuring: a view that accepts whatever proposal it is given cannot
    /// be asked how big it wants to be.
    var fillsPanel: Bool {
        switch self {
        case .installed: true
        case .measured: false
        }
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// Internal rather than private so the tests can drive real `NSEvent`s through it and
    /// read the frame AppKit actually settled on. The app talks to the controller.
    let panel = TranslationPanel()
    private let hosting: NSHostingView<AnyView>
    /// A second host that is never installed in a window, holding the *non-scrolling*
    /// content, used only to be asked for a size.
    ///
    /// It exists because measuring the installed view would be measuring the wrong thing the
    /// moment the scrolling variant is swapped in: a `ScrollView` compresses to nothing, so
    /// the panel would report a tiny ideal height and never grow back. This one always holds
    /// the variant whose height means something.
    ///
    /// An `NSHostingController` and not the `NSHostingView` the plan named, because the two
    /// passes below need two different questions asked and only the controller can ask the
    /// second. Measured in this process on the same content: an `NSHostingView` reports
    /// `fittingSize` and `intrinsicContentSize` of 6929 × 44 for a long paragraph — the whole
    /// of it on one line — and goes on reporting 6929 × 44 after its frame is set to 560 wide,
    /// so it cannot be asked for a height *at a width*.
    /// `NSHostingController.sizeThatFits(in:)` answers 374 × 348 for the same content at 400
    /// and is the only public API on either type that takes a proposal.
    ///
    /// Both questions are asked of this one object: `sizeThatFits(in:)` on the controller for
    /// the height, and `fittingSize` on its own `view` for the ideal width — see `measure`,
    /// which carries the reason the width cannot come from a proposal. It works fully
    /// detached: no window, no superview, no `layoutSubtreeIfNeeded`.
    private let measuring: NSHostingController<AnyView>
    /// Not a `let`: the real content is only knowable from inside a scene, so it is replaced
    /// once at launch — see `setContentBuilder(_:)`.
    private var build: (PanelContentVariant) -> AnyView

    private var anchor: PanelAnchor = .topLeading
    private var frozenWidth: CGFloat?
    private var userSized = false
    private var scrolls = false
    private var lastFit: CFAbsoluteTime = 0
    private var pendingFit = false

    var onEscape: () -> Void = {}
    var onEnter: () -> Void = {}

    var isVisible: Bool { panel.isVisible }

    init(content: @escaping (PanelContentVariant) -> AnyView) {
        build = content
        hosting = NSHostingView(rootView: content(.installed(scrolls: false)))
        measuring = NSHostingController(rootView: content(.measured))
        super.init()
        // The panel must not be sized by its hosting view, and this line is what stops it.
        // The mechanism is what carries forward: an `NSHostingView` installed as a window's
        // `contentView` publishes Auto Layout constraints derived from SwiftUI's *compressed*
        // measurement, and AppKit then shrinks the window to satisfy them. A `ScrollView`
        // compresses to nothing, so the panel collapsed to the height of its chrome and the
        // permission prompt's instructions truncated to one line. `[]` leaves the frame to
        // this controller, which is now the only thing that knows how big the content is.
        //
        // **The numbers behind it can no longer be reproduced, and that is recorded rather
        // than quietly dropped.** They were 380 × 120 before the line and 380 × 260 after,
        // taken on the running bundle three times and twice respectively — but on a `.titled`
        // panel, where 120 was 97pt of content plus the title bar, and against a fixed 380 ×
        // 260 that was the whole of the panel's sizing. Neither condition still holds: the
        // title bar is gone with `.titled`, and there is no fixed size to come back to. Nobody
        // can re-take that measurement from here — it needs the assembled bundle on a screen —
        // so the line stays on the strength of the mechanism above, and re-measuring it is
        // listed in `docs/OPEN-ITEMS.md` §1 with everything else this task owes a human.
        //
        // **No test in this file can hold it either, and one was written and deleted rather
        // than kept.** The shrink does not reproduce in the test process: a `PanelController`
        // built with a `ScrollView`, shown, and laid out reported the same content view size
        // with these three lines *and without them* — all three removals were applied and all
        // three passed.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.delegate = self
        // Forwarded through the controller's own properties rather than assigned to the
        // panel directly, so a caller that sets `onEscape` after construction — which is
        // every caller — still gets the key press.
        panel.onEscape = { [weak self] in self?.onEscape() }
        panel.onEnter = { [weak self] in self?.onEnter() }
    }

    /// The real content is only knowable from inside a scene — «Открыть в окне» needs
    /// `openWindow`, and the close action needs this controller — so the builder is replaced
    /// once at launch rather than passed to `init`. This is what `setContent(_:)` used to be;
    /// it takes a builder now because the controller has to be able to rebuild the content in
    /// its other variant when the ceiling is reached.
    func setContentBuilder(_ builder: @escaping (PanelContentVariant) -> AnyView) {
        build = builder
        hosting.rootView = builder(.installed(scrolls: scrolls))
        measuring.rootView = builder(.measured)
    }

    func show(at cursor: CGPoint) {
        // Every per-presentation decision is reset here, not in `hide()`: a panel shown
        // twice without an intervening hide — which nothing does today, and which a future
        // caller might — must still start from automatic sizing.
        frozenWidth = nil
        userSized = false
        setScrolling(false)

        // The screen the pointer is on, not `NSScreen.main` — which is the screen with the
        // key window, i.e. usually the wrong one when the user is working in another app on
        // a second display.
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        // `visibleFrame`, not `frame`: the difference is the menu bar and the Dock. It
        // governs two things now — where the panel is placed, and the height ceiling
        // `PanelSizer` derives from it — so a `frame`-based show opens a tall panel both
        // under the menu bar and 0.6 × the menu-bar band too tall.
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // `previous: .zero` is what makes a press start fresh: `PanelSizer`'s height is
        // monotonic *within* a presentation, and this is where the presentation begins.
        let fit = measure(previous: .zero, screen: visible)
        frozenWidth = fit.size.width
        setScrolling(fit.scrolls)
        let placement = PanelPlacement.place(cursor: cursor, size: fit.size, screen: visible)
        anchor = placement.anchor
        panel.setFrame(placement.frame, display: false)
        // `makeKeyAndOrderFront` on a `.nonactivatingPanel` gives the panel key status
        // without activating the app — checked by
        // `showingThePanelTakesKeyStatusWithoutItsProcessBecomingActive`.
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        pendingFit = false
    }

    /// The content changed shape, so the panel may need to be a different size.
    ///
    /// Throttled to ten times a second because it is called on every streamed token and the
    /// measurement is a full SwiftUI layout pass. The throttle can only *delay* growth,
    /// never skip it: a call that arrives too soon sets `pendingFit`, and the trailing call
    /// re-measures whatever the content has become by then.
    /// - Parameter settling: the run has just ended, so this is the last resize and the one
    ///   worth animating. It also bypasses the throttle: making the final size wait up to
    ///   100ms behind a token that arrived just before it is the one delay a user would see.
    func contentDidChange(settling: Bool = false) {
        guard panel.isVisible else { return }
        if settling {
            pendingFit = false
            applyFit(settling: true)
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFit >= 0.1 else {
            guard !pendingFit else { return }
            pendingFit = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.pendingFit else { return }
                self.pendingFit = false
                self.applyFit()
            }
            return
        }
        applyFit()
    }

    /// - Parameter settling: this is the resize that follows the end of a run, rather than
    ///   one of the many during it.
    private func applyFit(settling: Bool = false) {
        lastFit = CFAbsoluteTimeGetCurrent()
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = measure(previous: panel.frame.size, screen: visible)
        setScrolling(fit.scrolls)
        guard fit.size != panel.frame.size else { return }
        let frame = PanelPlacement.reframe(current: panel.frame, newSize: fit.size,
                                           anchor: anchor, screen: visible)
        // Unanimated while a run streams, and that is not an omission. The steps are a line
        // of text at a time and arrive up to ten times a second; animating each one puts a
        // 150ms tween on top of a 100ms interval, so the animations overlap and the panel
        // shivers instead of growing. The settle is the one resize worth animating — it is
        // where the shape genuinely changes, because the warnings appear and the scrolling
        // variant is swapped out — and it happens once.
        guard settling, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func measure(previous: CGSize, screen: CGRect) -> PanelSizer.Fit {
        // Rebuilt on every measurement rather than once in `init`, and this line is what
        // makes growth work at all. Measured in this process: an `NSHostingController` holds
        // whatever `rootView` it was last assigned, so after the content behind the builder
        // changed, `sizeThatFits` went on answering the *old* 74 × 44 — and answered
        // 275 × 396 the instant `rootView` was reassigned, with no layout pass in between.
        // Without this the panel would size itself to whatever the content was at launch.
        measuring.rootView = build(.measured)
        // Two passes, and the order matters. The first asks how wide the content would like
        // to be with nothing wrapping it; the second asks how tall it is *once the width is
        // settled*, because height without a width is not a number — it is a different
        // number for every width.
        //
        // The first pass reads `fittingSize` and **not** a second `sizeThatFits`, and the two
        // are not interchangeable here. `sizeThatFits` answers a *proposal*, and the panel's
        // content contains three `Spacer`s and a `Text` under `frame(maxWidth: .infinity)` —
        // all of which take whatever they are offered. Measured on the real `PanelView`:
        // `sizeThatFits(in: unbounded)` answered `greatestFiniteMagnitude` wide for both a
        // one-word translation and a forty-sentence one, which `PanelSizer` reads as a real
        // measurement and clamps to `maxWidth`, so every panel came out 560 wide.
        // `fittingSize` asks for the *ideal* size instead, where a `Spacer` is 0: the same two
        // views answer 274 and 6929, which clamp to `minWidth` and `maxWidth` respectively.
        // It tracks a reassigned `rootView` just as `sizeThatFits` does — measured.
        let idealWidth = measuring.view.fittingSize.width
        // `height: 0` is not a measurement and is not meant to be one. `PanelSizer` reads a
        // non-positive height as «not measured yet» and hands back `minHeight`; this call
        // discards that and reads only `.size.width`, so the floor is not applied twice.
        let width = PanelSizer.fit(ideal: CGSize(width: idealWidth, height: 0),
                                   frozenWidth: frozenWidth, previous: previous,
                                   screen: screen, userSized: userSized).size.width
        let idealHeight = measuring.sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        return PanelSizer.fit(ideal: CGSize(width: idealWidth, height: idealHeight),
                              frozenWidth: frozenWidth ?? width, previous: previous,
                              screen: screen, userSized: userSized)
    }

    private func setScrolling(_ wanted: Bool) {
        guard wanted != scrolls else { return }
        scrolls = wanted
        hosting.rootView = build(.installed(scrolls: wanted))
    }

    /// The user dragged an edge. That is an instruction, and it holds until the panel hides.
    func windowDidEndLiveResize(_ notification: Notification) {
        userSized = true
    }
}
