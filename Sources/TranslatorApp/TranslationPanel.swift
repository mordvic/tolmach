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

    /// AppKit runs every frame through this on the way in, and it is not a no-op. A panel that
    /// is placed relative to the pointer cannot accept a frame being rewritten under it, and
    /// it matters twice over now that the panel resizes: every growth step goes through here
    /// too.
    ///
    /// Two observations, and they no longer have the same standing — which is the point of
    /// spelling both out. Re-measured against a *stock* `NSPanel` carrying this panel's
    /// current mask, i.e. with no override at all:
    ///
    /// - **The menu-bar band reproduces.** A frame whose top crossed it still came back pulled
    ///   down by the height of the band, exactly as it did on the `.titled` panel this
    ///   evidence was first taken on.
    /// - **The Stage Manager case did not reproduce.** The original figure — a frame at x = 19
    ///   coming back at x = 221, AppKit reserving the strip down the left edge, so a selection
    ///   near the left of the screen would open its result 202 pt from where the user is
    ///   looking — was taken on a machine with Stage Manager switched on, and the
    ///   re-measurement did not have it on. The observation is not withdrawn; it is no longer
    ///   live evidence for this override, and it is recorded here rather than left in a task
    ///   report where nobody would find it.
    ///
    /// The first alone is enough to keep the override.
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
    /// second. Measured in this process on the same content — and re-taken since, because the
    /// `intrinsicContentSize` half of it was once stated without a probe behind it: an
    /// `NSHostingView` over `Text(long).padding(14)` answers `fittingSize` **and**
    /// `intrinsicContentSize` of 6929 × 44 for a long paragraph — the whole of it on one line —
    /// and goes on answering 6929 × 44 from both after its frame is set to 560 × 120, so it
    /// cannot be asked for a height *at a width*.
    /// `NSHostingController.sizeThatFits(in:)` answers 374 × 348 for the same content at 400
    /// and is the only public API on either type that takes a proposal.
    ///
    /// Both questions are asked of this one object: `sizeThatFits(in:)` on the controller for
    /// the height, and `fittingSize` on its own `view` for the ideal width — see `measure`,
    /// which carries the reason the width cannot come from a proposal. It works fully detached:
    /// no window and no superview. It does need `layoutSubtreeIfNeeded()`, for the reason
    /// `measure` gives — an earlier version of this comment said it did not, on a measurement
    /// that only covered content changing through a captured value.
    private let measuring: NSHostingController<AnyView>
    /// Not a `let`: the real content is only knowable from inside a scene, so it is replaced
    /// once at launch — see `setContentBuilder(_:)`.
    private var build: (PanelContentVariant) -> AnyView

    private var anchor: PanelAnchor = .topLeading
    /// Nil until this presentation's run settles, and the presentation's width from then on.
    /// It is deliberately *not* set by `show(at:)` — see the comment there, and the width rule
    /// in `PanelSizer.fit` for the measurement that says why no earlier moment will do.
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
        // panel, where the 120 included the title bar, and against a fixed 380 × 260 that was
        // the whole of the panel's sizing. (An earlier version of this line decomposed the 120
        // as «97 pt of content plus the title bar»; the title bar is 22 pt, so those two come
        // to 119 and the decomposition was never the arithmetic it looked like. The 97 was the
        // ideal height the panel then reported, retired with the doc comment that held it.)
        // Neither condition still holds: the
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
    ///
    /// Only the *installed* host is refreshed here. The measuring one used to be refreshed
    /// alongside it and that line was dead: `measure()` reassigns `measuring.rootView` on
    /// every single pass — it has to, for the staleness reason recorded there — so nothing
    /// could ever read the copy assigned in this method.
    func setContentBuilder(_ builder: @escaping (PanelContentVariant) -> AnyView) {
        build = builder
        hosting.rootView = builder(.installed(scrolls: scrolls))
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
        // `previous: .zero` is what makes a press start fresh: `PanelSizer`'s height and width
        // are both monotonic *within* a presentation, and this is where the presentation
        // begins.
        //
        // **Provisional, and it does not freeze the width.** This runs in the same turn of the
        // main actor as the press that asked for it, and `HotkeyCoordinator.handlePress`
        // assigns `panelModel.sourceText` *after* the `afterCapture()` that calls this — so for
        // a `.text` press the measuring host legitimately still holds the previous run's
        // translation, and no layout call can help, because the model has not been written yet.
        // Spec §3.3 puts the width freeze on the first content update after `show(at:)` for
        // exactly this reason. What is needed here is only *a* size: somewhere to put the panel
        // and a corner to anchor it by. `applyFit` corrects both as the reply arrives.
        //
        // `selection` is the half that *is* right by now — `handlePress` assigns it before
        // `afterCapture()` — so an `.empty` or a `.notPermitted` press is measured against its
        // real content here and is correct at this point, which matters because neither runs a
        // translation and so neither ever reaches `applyFit`.
        let fit = measure(previous: .zero, screen: visible)
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
        // The settle is where the width stops being provisional and becomes this
        // presentation's width, for the reason `PanelSizer.fit`'s width rule measures out: the
        // panel asks for 347 pt before any of the reply has arrived and for 6929 once all of it
        // has, so a width chosen any earlier is a width chosen against content that is not
        // there. From here it does not move again — a «Повторить» inside the same presentation
        // re-runs into the width the first result earned, which is the one the user is already
        // reading at. Set before the early return below, because the frame not needing to
        // change is not a reason to leave the width unsettled.
        if settling { frozenWidth = fit.size.width }
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
        // Rebuilt on every measurement rather than once in `init`, and then laid out. Both
        // lines are load-bearing and they answer two different kinds of staleness.
        //
        // The assignment is what makes the host see new content at all: an
        // `NSHostingController` keeps whatever `rootView` it was last assigned, so without
        // this the panel would size itself to whatever the content was at launch, for ever.
        //
        // The layout pass is what makes the host see content that changed **through
        // observation**, which is how the app's content changes — `PanelHost` reads
        // `coordinator.selection` and the view model inside `body` rather than capturing
        // values. Reassigning `rootView` then hands SwiftUI a view whose stored properties
        // are identical (the same model *reference*), so nothing looks changed and the
        // pending invalidation is not flushed until something forces layout. Measured on one
        // reused host with an app-shaped builder: after the view model's text changed and
        // `rootView` was reassigned, `fittingSize` still answered the previous 274 × 94 and
        // `sizeThatFits(560)` still answered 94 tall; after `layoutSubtreeIfNeeded()` they
        // answered 6929 × 94 and 302.
        //
        // Through a whole `PanelController` the sequence is this, and it was re-taken against
        // the **real** `PanelHost` driven through the real `HotkeyCoordinator.handlePress`,
        // frame read at `show(at:)`. Five presses — short text, long text, `.empty`,
        // `.notPermitted`, short text — deterministic over repeated runs and identical whether
        // or not the panel is hidden between them:
        //
        //     with this line     300 × 120 / 300 × 120 / 326 × 120 / 560 × 131 / 560 × 305
        //     without it         300 × 120 / 300 × 120 / 560 × 305 / 326 × 120 / 560 × 131
        //
        // An earlier note here read «four presses with alternating short and long content all
        // came out 300 × 120 without this line». That is refuted: it came from a probe that
        // replaced `PanelHost` with a look-alike, and against the real type the size **lags**
        // by roughly one press rather than freezing. Presses 1 and 2 agreeing in both columns
        // is not staleness at all — see `show(at:)`, which measures before the press's own text
        // has been assigned.
        //
        // The earlier note here also claimed the reassignment alone was enough, «measured».
        // That measurement was real but narrow: it was taken with a builder that captured a
        // `String`, where the rebuilt view genuinely differs and SwiftUI re-evaluates without
        // being asked. It does not generalise to the observation case, and the app is the
        // observation case. `show(at:)` is where it bites hardest, because it measures in the
        // same turn of the main actor as the selection it is showing: an `.empty` or
        // `.notPermitted` press runs no translation, so `contentDidChange` is never called and
        // whatever size `show(at:)` computed is the size that press keeps for its whole life.
        // A `.text` press does get a second chance — every fit after the first re-measures both
        // axes now, because `show(at:)` no longer freezes the width — but a stale host would
        // still open it at the previous press's size for as long as the first token takes.
        measuring.rootView = build(.measured)
        measuring.view.layoutSubtreeIfNeeded()
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
        //
        // It goes stale in exactly the same way `sizeThatFits` does, and on the same terms —
        // measured, both of them, on one reused host: after an observation-driven content
        // change and a `rootView` reassignment, `fittingSize` answered the previous width and
        // only the layout pass above moved it. Neither read may be hoisted above that call.
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
