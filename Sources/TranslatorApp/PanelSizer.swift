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
    /// Enough for the header, one line and the buttons.
    static let minHeight: CGFloat = 120
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
    ///   - frozenWidth: the width already chosen for this presentation, or nil if none has
    ///     been chosen yet.
    ///   - previous: the panel's current size. `.zero` before it is first shown.
    ///   - screen: the `visibleFrame` of the screen the panel is on.
    ///   - userSized: the user has dragged the panel's edge, so it is theirs until it hides.
    static func fit(ideal: CGSize, frozenWidth: CGFloat?, previous: CGSize,
                    screen: CGRect, userSized: Bool) -> Fit {
        let wanted = CGSize(width: measured(ideal.width, unmeasured: minWidth, unbounded: maxWidth),
                            height: measured(ideal.height, unmeasured: minHeight,
                                             unbounded: .greatestFiniteMagnitude))

        // The user's choice wins outright. Not "wins until the content grows past it":
        // resizing a panel is an instruction, and taking the size back the moment another
        // line arrives would make the handle useless exactly when it is reached for.
        guard !userSized else {
            return Fit(size: previous, scrolls: wanted.height > previous.height)
        }

        let width = frozenWidth ?? min(max(wanted.width, minWidth), maxWidth)
        // `max(minHeight, …)` and not the fraction alone: on a very short screen — a strip
        // display, or a `visibleFrame` squeezed by a tall menu bar — the fraction falls
        // below the floor, and a panel shorter than its own buttons is the worse failure.
        let ceiling = max(minHeight, screen.height * maxHeightFraction)
        let fitted = min(max(wanted.height, minHeight), ceiling)
        // Monotonic within a presentation. The caller resets `previous` by hiding the panel.
        let height = min(max(fitted, previous.height), ceiling)
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
