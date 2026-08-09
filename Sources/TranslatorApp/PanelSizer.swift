// Sources/TranslatorApp/PanelSizer.swift
import CoreGraphics

/// How big the floating panel should be, given how big its content wants to be.
///
/// A type of its own, with no AppKit in it, because this is the part of "the panel fits its
/// content" that can be checked: the ceilings, the frozen width, the monotonic height and
/// the decision to start scrolling are rules, and rules stated in a controller alongside
/// `setFrame` calls can only be read, not tested.
///
/// The panel was a fixed 380 × 260 until this existed, and the reason it was fixed is worth
/// keeping in view: a panel that changes size while text streams into it moves under the
/// reader's eyes. That objection is answered by the anchor (`PanelAnchor` — growth leaves
/// the corner nearest the pointer alone) and by the two rules below, not by ignoring it.
enum PanelSizer {
    /// Below this a panel is narrower than its own button row.
    static let minWidth: CGFloat = 300
    /// Above this the panel stops being a panel. A translation is read, not scanned, and a
    /// 900pt line is worse to read than a 560pt one.
    static let maxWidth: CGFloat = 560
    /// Enough for everything the panel pins, at its narrowest.
    ///
    /// 120 while this region held the header, one line and the buttons. The panel is three
    /// sections now and the status row is pinned too, so the floor has to clear that as well
    /// — measured on the real view at each width, in the states that pin the most:
    ///
    ///     width  idle+empty  running  failed  finished, one line
    ///       300      92        118      130          94
    ///       560      92        118      120          94
    ///
    /// 130 is a failure message wrapping to two lines in a 300 pt panel, which is the widest
    /// the pinned block ever gets. At 120 it overflowed by 10, and since the translation is
    /// the section that stretches, the overflow came out of it: dragged to the floor with a
    /// failure showing, the pane went to nothing while the buttons stayed.
    ///
    /// **Not** raised to clear the pinned block *plus* a line of translation, which the same
    /// table puts at ~148. The floor is what a settled short reply is padded to — a one-line
    /// translation wants 94 — so every point above the content is a hole between the text and
    /// the button row, which is the defect this panel was rebuilt to remove. 12 pt of that is
    /// a trade; 54 is the thing itself.
    static let minHeight: CGFloat = 132
    /// The panel floats over the work the user is reading; taking more than this much of
    /// the screen makes it a window with no way to move it aside.
    static let maxHeightFraction: CGFloat = 0.6

    struct Fit: Equatable {
        let size: CGSize
        /// The content is taller than the size granted, so the caller must install the
        /// scrolling variant of the content view.
        let scrolls: Bool
    }

    /// - Parameters:
    ///   - ideal: what the content measured to, unconstrained. `.zero` before the first
    ///     layout pass; may be infinite if a subview hands an unbounded proposal back.
    ///   - frozenWidth: the width this presentation has finally settled on, or nil while it is
    ///     still being chosen. Until it is set the width tracks the content and may only grow;
    ///     the width rule below carries the measurement behind that.
    ///   - previous: the panel's current size. `.zero` before it is first shown.
    ///   - screen: the `visibleFrame` of the screen the panel is on.
    ///   - userSized: the user has dragged the panel's edge, so it is theirs until it hides.
    ///   - settling: the run has just ended, so this is the last size this presentation will
    ///     be asked for. It is the one call allowed to make the panel *smaller*.
    static func fit(ideal: CGSize, frozenWidth: CGFloat?, previous: CGSize,
                    screen: CGRect, userSized: Bool, settling: Bool = false) -> Fit {
        let wanted = CGSize(width: measured(ideal.width, unmeasured: minWidth, unbounded: maxWidth),
                            height: measured(ideal.height, unmeasured: minHeight,
                                             unbounded: .greatestFiniteMagnitude))

        // The user's choice wins outright on both axes — but never produces a degenerate
        // frame. `maxWidth` and the height ceiling both exist to hold a preference the app
        // keeps on the user's behalf (a narrower reading line, a panel that leaves room to see
        // the work underneath), and an explicit drag overrules a preference; that is why
        // neither ceiling is applied here. `minWidth` and `minHeight` are a different kind of
        // limit — a panel smaller than its own button row is unusable, not merely unpreferred
        // — so the floors still apply even to a hand-chosen size.
        //
        // Consequence, not a defect to hide: with no height ceiling here, a hand-dragged panel
        // can end up taller than the screen — `PanelPlacement.clamp` only moves the origin, and
        // `TranslationPanel.constrainFrameRect` returns frames untouched by design, so nothing
        // pulls an over-tall frame back. The one mitigation is that `show(at:)` clears
        // `userSized`, so the *next* press sizes itself fresh rather than inheriting it. See
        // `docs/OPEN-ITEMS.md` §1 for the standing question of whether that mitigation is
        // enough.
        guard !userSized else {
            let userWidth = max(previous.width, minWidth)
            let userHeight = max(previous.height, minHeight)
            return Fit(size: CGSize(width: userWidth, height: userHeight), scrolls: wanted.height > userHeight)
        }

        // Until `frozenWidth` is set, the width is the widest this presentation's content has
        // *ever* asked to be, not the widest it is asking for now — so it grows with the reply
        // and never shrinks under the reader. That it cannot simply be chosen once at the
        // start is measured, not preferred. The real `PanelView`, through the same two calls
        // `PanelController.measure` makes, at each phase of one run — ideal width first, then
        // the height that width yields:
        //
        //     running, no text yet    347 →  116 at 560
        //     running, one token      347 →  118 at 560
        //     running, first line     370 →  134 at 330, 118 at 560
        //     running, whole reply   6929 →  486 at 330, 326 at 560
        //     finished, whole reply  6929 →  462 at 330, 302 at 560
        //     finished, one word      274 →   94 at 560
        //
        // There is no early moment at which the final width is knowable: the panel asks for
        // 347 pt before a single character has arrived — that is its button row, which is also
        // what `minWidth` is — and stays under 400 until one line of the reply is longer than
        // the panel itself. Freezing at any of those points gives the wrong shape: an
        // independent probe of the real `PanelView` measured a forty-sentence translation
        // frozen at 330/347 pt as 462 pt tall, against 560 × 302 correct — a much worse shape,
        // not (as an earlier version of this comment claimed) a case that crosses the 0.6
        // height ceiling on a laptop display: that probe's own numbers need visibleFrame.height
        // ≤ 770 pt to scroll at 330/347, and a 14-inch MacBook Pro reports ≈ 875, a 13-inch Air
        // ≈ 850 — well clear. The only width that scrolls on every current laptop is 300 pt,
        // which is the pre-fix defect's frozen width, not a candidate freeze point. Growing
        // instead costs a handful of re-wraps while the reply is still short — measured per
        // streaming run: 4–5 width changes for fast prose (~125 chars/s), 8 for slow prose
        // (~25 chars/s), 12 for hard-broken short lines (a list, a poem, dialogue), and the
        // first change always lands with zero characters on screen. Flowing prose pins at
        // `maxWidth` once its longest unwrapped line passes ~80 characters, so most of a long
        // reply arrives at a fixed width; the bad case is content whose lines are
        // individually short.
        //
        // **Those change counts are the worst case now, not the usual one.** `PanelView`
        // reserves the reply's room from the selection it is about to translate — an
        // invisible copy of the source, while the run is in flight — so the panel opens at
        // the width and height the reply will need and the growth rule below has nothing left
        // to do. Measured on the real panel: opening 560 × 198 against a settled 560 × 174 for
        // a six-sentence paragraph, against 347 × 120 opening and 560 × 174 settled without
        // the reservation. The rule stays because it is what still catches a reply longer than
        // its source, and because it is the only thing holding the width when there is no
        // source to reserve from.
        // `frozenWidth` pins the width for the rest of the presentation at the settle, which
        // is when reading starts. `PanelController` is what decides that moment — see
        // `applyFit`.
        let width = frozenWidth ?? min(max(max(wanted.width, previous.width), minWidth), maxWidth)
        // `max(minHeight, …)` and not the fraction alone: on a very short screen — a strip
        // display, or a `visibleFrame` squeezed by a tall menu bar — the fraction falls
        // below the floor, and a panel shorter than its own buttons is the worse failure.
        let ceiling = max(minHeight, screen.height * maxHeightFraction)
        let fitted = min(max(wanted.height, minHeight), ceiling)
        // Monotonic within a presentation — **except at the settle**. The caller resets
        // `previous` by hiding the panel.
        //
        // The exception is what keeps the panel's three sections honest. The reservation in
        // `PanelView` holds the panel at the height the reply was expected to need, and the
        // «Перевожу…» row is 24 pt of that; when the run ends both go, and a strictly
        // monotonic height would keep the space as a hole between the text and the buttons.
        // Shrinking there costs one movement, at one moment, in the direction of less. The
        // rule it bends exists to stop the panel moving while the reader reads — and the
        // settle is **not** reliably before reading starts: a long reply has been on screen
        // for seconds by then. What makes the exception safe is not timing but direction.
        // `PanelController` reframes a shrink by `PanelAnchor.holdingTheTop`, so the top edge
        // never comes down and no line already on screen moves; what moves is the bottom edge
        // and the button row pinned to it. That was not true when this exception was written:
        // a bottom-anchored panel brought its top edge down and took every read line with it.
        //
        // Growth at the settle still goes through the same expression, because `fitted` is
        // simply used as-is: a run that ends with warnings is taller, not shorter.
        let height = settling ? min(fitted, ceiling) : min(max(fitted, previous.height), ceiling)
        return Fit(size: CGSize(width: width, height: height), scrolls: wanted.height > height)
    }

    /// Three cases, and they mean different things. A finite positive number is a real
    /// measurement. Zero is a view asked for its size before its first layout pass, which
    /// means "no idea" — take the floor. Infinity is a greedy subview handing an unbounded
    /// proposal straight back, which means "as much as you will give me" — take the ceiling.
    /// Both non-numbers reach `NSWindow.setFrame`, where they are unrecoverable.
    private static func measured(_ value: CGFloat, unmeasured: CGFloat,
                                 unbounded: CGFloat) -> CGFloat {
        if value.isFinite && value > 0 { return value }
        return value == .infinity ? unbounded : unmeasured
    }
}
