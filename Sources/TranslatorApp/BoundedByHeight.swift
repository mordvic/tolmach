// Sources/TranslatorApp/BoundedByHeight.swift
import SwiftUI

/// Shows a block whole while it fits and scrolls it once it does not, never taller than
/// `limit`.
///
/// One surface needs it: the window's warnings disclosure, at 200 pt. A list of warnings has
/// no length of its own, and an unbounded one takes the space the editors need.
///
/// The ⌥⌘T panel was meant to be the second and is not, which is why the ceiling is a
/// parameter and not a constant here — and why this stays a type rather than four inline
/// lines. A ceiling there (160 pt) is larger than the panel's whole floor (132), so the block
/// it bounded outgrew the window at the smallest size the user may drag to; the panel's
/// warnings scroll with the translation instead. See `PanelView.translation`.
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
