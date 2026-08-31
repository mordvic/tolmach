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
    /// `.titled` is back, and `.resizable` only means anything because of it.
    ///
    /// It was dropped on the reasoning that a titled panel cannot be given a corner radius
    /// without its square background showing through. That reasoning was never checked on a
    /// screen, and the lines below — `isOpaque = false` and a clear `backgroundColor` — were
    /// added afterwards and are the standard answer to exactly that problem.
    ///
    /// What the drop did cost was the whole hand-resize feature, silently. Reported by the
    /// user: the panel does not drag. Measured here, on stock `NSPanel`s with no overrides:
    ///
    ///     no `.titled`, `.resizable`     isResizable true    frame view NSNextStepFrame
    ///     `.titled` + `.resizable`       isResizable true    frame view NSThemeFrame
    ///     `.titled`, no `.resizable`     isResizable false   frame view NSThemeFrame
    ///
    /// Edge and corner drag tracking lives in `NSThemeFrame`. A borderless window gets
    /// `NSNextStepFrame`, which has none — so `isResizable` answered `true`, `setFrame` worked,
    /// and nothing happened when the user pulled an edge. `.resizable` sat in this mask from
    /// the day the panel started sizing itself and never did anything at all.
    ///
    /// The cost of taking `.titled` back is 22pt of titlebar over a readout with no title,
    /// which `titlebarAppearsTransparent` and `.fullSizeContentView` between them make invisible
    /// and let the content draw under, and three standard buttons that are hidden below.
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                   styleMask: [.nonactivatingPanel, .titled, .resizable,
                               .fullSizeContentView, .utilityWindow],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // The titlebar comes back with `.titled` and must not be seen: this panel has no
        // title, and `PanelView` draws its own ⨯ and its own header in that space.
        // `.fullSizeContentView` in the mask is what lets the content extend under it.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
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
        // corners are listed in `docs/reference/OPEN-ITEMS.md` §1 as owed to a human.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Follows the user across desktops and sits over full-screen apps, because the
        // selection it is translating came from one.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // The same floors `PanelSizer` enforces, told to AppKit so the drag stops at them
        // rather than being pulled back from beyond them.
        //
        // Without this the two disagreed while the mouse was still down: `PanelSizer.fit`'s
        // `userSized` branch answers `max(previous, floor)`, so dragging past 300 × 132 made
        // it return a size that was *not* the panel's, and `applyFit` reframed and re-anchored
        // underneath the drag ten times a second. Stating the minimum here removes the
        // disagreement at its source — there is no size below the floor for the two to
        // disagree about.
        // `dragMinHeight` and not `minHeight`: the two answer different questions and the
        // difference is measured — see `PanelSizer`.
        contentMinSize = NSSize(width: PanelSizer.minWidth, height: PanelSizer.dragMinHeight)
    }

    /// Belt and braces again, now that `.titled` is back — and worth stating rather than
    /// deleting, because which of those two it is has flipped twice.
    ///
    /// Measured in this process on stock `NSPanel`s with no override: `.titled` answers `true`
    /// by itself, and the same mask minus `.titled` answers **`false`**, after which
    /// `makeKeyAndOrderFront` leaves `isKeyWindow` false. So this line was decorative while the
    /// panel was titled, became load-bearing when `.titled` was dropped, and is decorative
    /// again now — but only for as long as `.titled` stays in the mask, which is what it
    /// guards. `theUntitledPanelStillTakesKeyStatusWithoutItsProcessBecomingActive` still
    /// covers it; its name now describes a mask the panel no longer has, and the test itself
    /// is unchanged because what it asserts — key without active — is unchanged.
    ///
    /// What it does *not* do, under either mask, is make the panel key while the app is
    /// inactive; only `.nonactivatingPanel` does that. `canBecomeKey` is permission,
    /// `.nonactivatingPanel` is the grant, and confusing the two is how a panel ends up
    /// looking correct and never receiving Esc.
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
            // ⌘⇧↩ is «Заменить»'s shortcut (issue #27), declared through SwiftUI's own
            // `.keyboardShortcut`. While the button is disabled — the run has not settled —
            // SwiftUI declines that equivalent and the key reaches here instead, same as bare
            // Enter always has. Masked the same way `HotkeyCombo` masks a recorded
            // combination, so the numeric-pad and caps-lock bits this event may also carry
            // cannot turn a false match into a true one.
            // Deliberately narrower than before this check existed: every modified Return
            // used to reach `onEnter()` regardless of which modifiers it carried, because
            // nothing here looked. That was never a documented shortcut — no spec names ⇧↩,
            // ⌥↩ or bare ⌘↩ as meaning «copy and close» — it was just what an unguarded
            // keyCode match did by accident. Only the two combinations this app actually
            // declares are handled now; everything else on Return falls through to `super`
            // and does nothing, matching how every other shortcut in this app is a single
            // declared combination rather than a keycode matched loosely. Pinned by
            // `commandShiftReturnIsSwallowedRatherThanMisreadAsPlainEnter` and
            // `otherModifiedReturnsAreNoLongerMisreadAsPlainEnterEither`.
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == [.command, .shift] {
                // Swallowed rather than falling through to plain Enter's «copy and close»:
                // that cancels whatever is still running, which is the opposite of the no-op
                // a disabled button's shortcut is supposed to be.
                return
            }
            if modifiers.isEmpty {
                onEnter()
                return
            }
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

    /// Never true while measuring, and the reason is the opposite of what this comment used to
    /// say. It claimed a `ScrollView` «compresses to nothing, so the measured copy would report
    /// a tiny ideal height». Measured, on the real `PanelView` through the same two calls
    /// `PanelController.measure` makes: a `ScrollView` is **greedy**, not compressible.
    ///
    ///     flat        fittingSize 6901 × 64   sizeThatFits@400  368
    ///     scrolling   fittingSize 6901 × 64   sizeThatFits@400  greatestFiniteMagnitude
    ///
    /// So the width pass is unaffected — `fittingSize` ignores the scroll view entirely — and
    /// the height pass answers the whole unbounded proposal. `PanelSizer.measured` reads
    /// `greatestFiniteMagnitude` as a real measurement, because it is finite, and clamps it to
    /// the ceiling: every panel would come out at 0.6 × the screen and `scrolls` would be true
    /// for a one-word result. Measured by mutating this case to `true` and running the suite —
    /// every panel settled at 774 pt on this display, short and long alike.
    ///
    /// Same failure shape as `fillsPanel` below, which is why the two sit together, and the
    /// same three tests catch both: `theRealPanelViewIsMeasuredRatherThanEchoingTheProposal…`,
    /// `aReusedControllerMeasuresThePressItIsShowing…` and
    /// `aShortTranslationInTheRealPanelViewDoesNotAskToScroll`.
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
    /// Whether the reply is being drawn as a rendered document rather than as characters — the
    /// panel's half of Phase 4.
    ///
    /// **Held here rather than as `@State` inside `PanelHost`, for the reason `scrolls` is.**
    /// The controller builds *two* live hosts from one builder — the installed one and the
    /// detached one the size comes from — and a `@State` would give each of them its own copy,
    /// which is how the panel comes to be sized for plain text while showing a document, or the
    /// reverse. `private(set)` because the builder reads it and only `setRendersFinalReply(_:)`
    /// may move it.
    private(set) var rendersFinalReply = false
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
        // Neither condition still holds: there is no fixed size to come back to, and the
        // titlebar — still there, `.titled` having been reinstated in `a57efa1` — is drawn under
        // rather than removed, so it is no longer a separate 22 pt to decompose. (This comment
        // said «the title bar is gone with `.titled`» until 2026-08-26, contradicting the
        // `safeAreaRegions` comment fifteen lines below it and `styleMask` above.) Nobody
        // can re-take that measurement from here — it needs the assembled bundle on a screen —
        // so the line stays on the strength of the mechanism above, and re-measuring it is
        // listed in `docs/reference/OPEN-ITEMS.md` §1 with everything else this task owes a human.
        //
        // **No test in this file can hold it either, and one was written and deleted rather
        // than kept.** The shrink does not reproduce in the test process: a `PanelController`
        // built with a `ScrollView`, shown, and laid out reported the same content view size
        // with these three lines *and without them* — all three removals were applied and all
        // three passed.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        // **The installed view must measure the same as the copy the size came from.**
        //
        // It does not by default, and the difference is a whole edge of padding. This view is
        // the content view of a `.titled` window carrying `.fullSizeContentView`, so AppKit
        // hands it a safe area for the title bar it is drawing under — measured on the running
        // bundle: `safeAreaInsets` is `top: 24`. The `NSHostingController` in `measure` is
        // detached, has no window and therefore no safe area, so it reports the height of the
        // content alone.
        //
        // The panel is then set to that height and the installed view insets its content by
        // 24 pt anyway. Everything shifts down and the bottom edge is what runs out: measured
        // before this line, a settled panel had 28 pt above its content and **2 pt** below,
        // against the uniform 14 the view asks for — and after a settle, which is the one fit
        // allowed to shrink, −2, with the buttons overhanging the frame. Laid out at its own
        // ideal height with no window, the same view measures 14 and 14, at every reply length
        // from 65 to 1040 characters.
        //
        // Ignoring the region is right rather than merely convenient: the title bar is hidden
        // (`titleVisibility`), the close button is hidden, and `PanelView` draws its own ⨯ —
        // there is nothing up there to stay clear of.
        hosting.safeAreaRegions = []
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
        // A presentation begins on plain characters: there is no run yet to have settled.
        rendersFinalReply = false
        // **Rebuilt unconditionally, where this used to call `setScrolling(false)`.** That
        // method returns early when `scrolls` is already false — which it usually is — so it
        // could not be relied on to carry a *second* piece of per-presentation view state out
        // of the builder. With the flag reset and no rebuild, the installed host went on
        // drawing the previous presentation's rendered document while `measure`, which
        // reassigns the detached host's `rootView` on every pass, sized the panel for plain
        // characters; and `setRendersFinalReply(false)` when the next run started returned
        // early from its own guard, because the controller's flag already said false. The
        // panel would have stayed wrong for the whole of that presentation.
        scrolls = false
        hosting.rootView = build(.installed(scrolls: false))

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
        // **That is no longer the whole story for a `.text` press, and the difference is the
        // point of this paragraph.** `PanelView` reserves the reply's room from `selection`,
        // and what tells it a reply is still to come is `HotkeyCoordinator.isStartingRun` —
        // set before `afterCapture()` precisely so it is true at this instant. Nothing about
        // the model is: `translate()` has not run, so its state and its pane still describe
        // the previous press. Measured through this call: it opened at 300 × 120, the floor on
        // both axes, against content needing up to 486 pt; it now opens covering what the run
        // needs, and `applyFit` has nothing to correct.
        //
        // The gate was first written as «`model.sourceText` differs from this selection», and
        // that is wrong twice over — it is false for a second press over the same text, and
        // making it true by blanking the model turned this measurement into a settle. See
        // `PanelView.awaitingReply` and `HotkeyCoordinator.isStartingRun`.
        //
        // What survives unchanged is the reasoning above for *why* this cannot simply read the
        // model: it still cannot, and the answer was to be told rather than to reorder the
        // press.
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
    /// - Parameter ignoringLiveResize: run even though AppKit may still report a live
    ///   resize. Passed only by `windowDidEndLiveResize`, and it is what keeps the recovery
    ///   from depending on an unverified fact: whether `inLiveResize` has already flipped
    ///   false inside that callback is not something this project has probed, and if it has
    ///   not, the fit that puts the panel right after a drag would decline itself.
    private func applyFit(settling: Bool = false, ignoringLiveResize: Bool = false) {
        // `contentDidChange` has always gated on this; `windowDidEndLiveResize` is a second
        // entry point and needs the same. A drag released after the panel was dismissed —
        // Esc with the other hand, or the ⨯ — would otherwise lay out the measuring host and
        // animate a frame onto a window nobody is looking at.
        guard panel.isVisible else { return }
        lastFit = CFAbsoluteTimeGetCurrent()
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // **Nothing at all happens under a moving hand.** This guard used to sit below
        // `setScrolling`, which let the installed root view be swapped mid-drag: crossing the
        // point where the content stops fitting replaced the `ScrollView` with a plain stack
        // and back again, so a reader part-way through a long translation was thrown to the
        // top and lost the selection they were about to copy — up to ten times a second for
        // as long as the edge kept moving near the threshold.
        //
        // A settle that lands in that window has nothing to deliver, and the first version of
        // this guard tried to save one. It recorded the settle and re-ran it on release —
        // dead machinery: `windowDidResize` has already set `userSized`, and `PanelSizer.fit`
        // returns from its own `guard !userSized` before it ever consults `settling`. That is
        // the right answer rather than a bug to route around: once a hand has moved an edge,
        // the size is the user's until the panel hides, and a settle is not entitled to take
        // it back. The cost is real and accepted — nudge only the *left* edge mid-run and the
        // height keeps the slack the reservation won — and `show(at:)` clears `userSized`, so
        // it lasts one presentation.
        guard !panel.inLiveResize || ignoringLiveResize else { return }
        let fit = measure(previous: panel.frame.size, screen: visible, settling: settling)
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
        // A shrink holds the top whatever corner the panel was anchored by. Growth keeps the
        // corner nearest the pointer — that is what stops the panel expanding over the text
        // being read — but a bottom-anchored panel that *shrinks* brings its top edge down,
        // and with top-aligned content every line already on screen comes down with it. The
        // settle is the only fit that can shrink, and it is exactly the moment a reader is
        // most likely to be part-way through.
        // …and the record follows the edge, because the next fit reads it. Holding the top
        // for one shrink and then growing from the bottom the shrink had just moved would
        // push the top edge up over the text being read — the movement `PanelAnchor` exists
        // to prevent — and «Повторить» on the same presentation does exactly that: it runs a
        // new translation without a new `show(at:)`, so whatever is stored here is what the
        // growth uses.
        // The top is held **for this reframe**, and the record is not rewritten. Storing it
        // was deliberate once — the next fit reads it — and it is the wrong deliberate: a
        // panel placed by a bottom corner, shrunk at the settle, then grown again by
        // «Повторить» in the same presentation would grow from the bottom edge the shrink had
        // just moved, pushing its top up over the text being read and, near the screen edge,
        // sliding the whole panel when the clamp catches it. `show(at:)` is what chooses a
        // corner; nothing else should.
        let holding = fit.size.height < panel.frame.height ? anchor.holdingTheTop : anchor
        let frame = PanelPlacement.reframe(current: panel.frame, newSize: fit.size,
                                           anchor: holding, screen: visible)
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

    private func measure(previous: CGSize, screen: CGRect,
                         settling: Bool = false) -> PanelSizer.Fit {
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
                                   screen: screen, userSized: userSized,
                                   settling: settling).size.width
        let idealHeight = measuring.sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        return PanelSizer.fit(ideal: CGSize(width: idealWidth, height: idealHeight),
                              frozenWidth: frozenWidth ?? width, previous: previous,
                              screen: screen, userSized: userSized, settling: settling)
    }

    private func setScrolling(_ wanted: Bool) {
        guard wanted != scrolls else { return }
        scrolls = wanted
        hosting.rootView = build(.installed(scrolls: wanted))
    }

    /// The reply becomes — or stops being — a rendered document, and the panel takes whatever
    /// size that costs.
    ///
    /// **Called after the settle, never instead of it, and the fit it asks for is deliberately
    /// not a settling one.** The two moments do different work and must not be merged:
    ///
    /// - The settle (`contentDidChange(settling: true)`, from `PanelHost`'s state hook) is the
    ///   one fit allowed to make the panel *smaller*, and what it gives back is furniture — the
    ///   «Перевожу…» row and whatever height the reservation won over the reply's real length.
    ///   That is measured against the plain characters, exactly as it was before Phase 4,
    ///   because this flag has not moved yet when it runs.
    /// - This is the swap, and it may only *grow*. A rendered document is usually taller than
    ///   its own source — headings scale, tables gain borders and cell padding, code blocks gain
    ///   spacing — but not always: markers disappear and a table row that wrapped as raw
    ///   `| a | b |` text can come back as one line. `PanelSizer`'s height is monotonic outside
    ///   the settle, so a rendered document that measures shorter leaves the panel where it is
    ///   rather than pulling the frame in under a reader who has already started reading. The
    ///   width does not move either: the settle above has just frozen it.
    ///
    /// `applyFit()` directly rather than `contentDidChange()`, and that is the one thing here
    /// that is about timing: `contentDidChange` is throttled to ten fits a second and the settle
    /// has just consumed the current window, so going through it would put the swap up to 100 ms
    /// behind — long enough to read as a second, separate jump. Called in the same turn of the
    /// main actor as the settle, the frame AppKit ends up displaying is the rendered one.
    /// Whether that reads as one movement is `docs/reference/OPEN-ITEMS.md`'s to answer; nothing
    /// in this environment can see it.
    func setRendersFinalReply(_ wanted: Bool) {
        // The guard is also what makes the doubling harmless: `PanelHost`'s hooks live on the
        // view, and *both* hosts are live, so this is called twice per settle — the same
        // tolerated doubling `onContentChange` has, and for the same reason. Unlike
        // `onRunFinished`, there is nothing here to restrict to the installed variant: the
        // second call is a comparison and a return.
        guard wanted != rendersFinalReply else { return }
        rendersFinalReply = wanted
        hosting.rootView = build(.installed(scrolls: scrolls))
        applyFit()
    }

    /// The user is dragging an edge right now.
    ///
    /// `inLiveResize` is the only thing separating a drag from `applyFit`'s own `setFrame`,
    /// and the distinction is load-bearing rather than tidy: without it every programmatic
    /// resize would be read as a drag, set `userSized`, and freeze the panel's automatic
    /// sizing for the rest of the presentation — after the very first fit.
    ///
    /// It sets the flag and does nothing else. Re-fitting from here is what tore the content
    /// view down under the drag; the fit that puts the panel right happens once, on release.
    ///
    /// **`applyFit` cannot fight the drag, and the reason is not the one first written here.**
    /// That said «with `userSized` set, `PanelSizer.fit` returns the size the panel already
    /// has» — true only above the floors. The `userSized` branch answers
    /// `max(previous, floor)`, so a drag past 300 × 132 produced a size that was *not* the
    /// panel's and reframed it under the hand still moving it. Two things hold it now:
    /// `contentMinSize` stops the drag reaching below the floors at all, and `applyFit`
    /// declines to write a frame during a live resize whatever the sizer says.
    func windowDidResize(_ notification: Notification) {
        guard panel.inLiveResize else { return }
        // The flag, and only the flag. Re-fitting from here is what tore the content view down
        // under the drag, and the fit that matters happens once, on release. Setting
        // `userSized` this early still earns its place: a token arriving mid-drag drives a fit
        // of its own, and without this it would be measured against the automatic rules and
        // fight the hand.
        userSized = true
    }

    /// The user dragged an edge. That is an instruction, and it holds until the panel hides.
    func windowDidEndLiveResize(_ notification: Notification) {
        userSized = true
        // **Not just the flag.** Nothing else re-fits after a drag — `contentDidChange` is
        // driven by the run, and a finished translation has nothing more to say — so a panel
        // dragged shorter than its content kept the flat variant and left its bottom section,
        // the status row and the warnings and both buttons, below the window's edge. Measured:
        // dragged 150 pt shorter, the panel was 560 × 120 holding 270 pt of unscrollable
        // content, and any refit at all put it right.
        applyFit(ignoringLiveResize: true)
    }
}
