// Sources/TranslatorApp/BoundedByHeight.swift
import SwiftUI

/// Shows a block whole while it fits and scrolls it once it does not, never taller than
/// `limit`.
///
/// Two surfaces need exactly this and for the same reason: a list of warnings has no length of
/// its own, and an unbounded one takes the space beside it. The window's disclosure and the
/// ⌥⌘T panel's pinned block were the same four lines twice, with only the ceiling different —
/// 200 in a window the user sized, 160 in a panel already capped at 0.6 of the screen.
///
/// `ViewThatFits` and not a bare `ScrollView`, and that is the part worth keeping together: a
/// `ScrollView` is greedy in its scroll axis, so it would sit at the full ceiling under a
/// two-line warning and leave the rest blank.
struct BoundedByHeight: ViewModifier {
    let limit: CGFloat

    func body(content: Content) -> some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxHeight: limit)
    }
}

extension View {
    /// See `BoundedByHeight`.
    func bounded(byHeight limit: CGFloat) -> some View { modifier(BoundedByHeight(limit: limit)) }
}
