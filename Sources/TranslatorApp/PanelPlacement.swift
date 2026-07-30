// Sources/TranslatorApp/PanelPlacement.swift
import CoreGraphics

/// The corner a panel grows from.
///
/// Not decoration and not symmetry: the panel resizes while the user is reading it, and a
/// resize that moves the corner nearest the pointer drags every line of already-read text
/// with it. The corner nearest the pointer is whichever one the placement arithmetic below
/// put there, so the two decisions are made in one place and cannot disagree.
///
/// "Top" is `maxY`: AppKit screen coordinates have their origin bottom-left.
enum PanelAnchor: Equatable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isTop: Bool { self == .topLeading || self == .topTrailing }
}

/// Where the floating panel goes, given where the pointer is.
///
/// Extracted from the panel controller because it is the only part of the panel that is
/// arithmetic rather than AppKit, and the corner cases — the pointer near an edge, a second
/// display at a negative origin, a panel taller than the screen — are exactly the ones
/// nobody exercises by hand.
///
/// AppKit screen coordinates: origin bottom-left, y increasing upwards.
enum PanelPlacement {
    struct Placement: Equatable {
        let frame: CGRect
        let anchor: PanelAnchor
    }

    static func place(cursor: CGPoint, size: CGSize, screen: CGRect,
                      gap: CGFloat = 14) -> Placement {
        // Preferred: to the right of the pointer, hanging downwards from it.
        var x = cursor.x + gap
        var y = cursor.y - gap - size.height
        var leading = true
        var top = true

        // Flip before clamping. Clamping alone would slide the panel along the edge and
        // park it on top of the selection the user is trying to read.
        if x + size.width > screen.maxX { x = cursor.x - gap - size.width; leading = false }
        if y < screen.minY { y = cursor.y + gap; top = false }

        let anchor: PanelAnchor = switch (top, leading) {
        case (true, true): .topLeading
        case (true, false): .topTrailing
        case (false, true): .bottomLeading
        case (false, false): .bottomTrailing
        }
        return Placement(frame: clamp(CGRect(origin: CGPoint(x: x, y: y), size: size), in: screen),
                         anchor: anchor)
    }

    /// The frame alone, without the anchor.
    ///
    /// **No production caller.** It was written for callers that do not resize, and once the
    /// panel started resizing there were none left — `PanelController` needs the anchor and so
    /// calls `place` directly. What keeps it is the thirteen tests that use it as an oracle:
    /// they assert a frame and have nothing to say about the corner, and `place(…).frame` at
    /// every one of them would be noise. It delegates rather than reimplementing, so it cannot
    /// drift from the rule it is checking.
    static func frame(cursor: CGPoint, size: CGSize, screen: CGRect,
                      gap: CGFloat = 14) -> CGRect {
        place(cursor: cursor, size: size, screen: screen, gap: gap).frame
    }

    /// A resized panel, with `anchor`'s corner left exactly where it was.
    static func reframe(current: CGRect, newSize: CGSize, anchor: PanelAnchor,
                        screen: CGRect) -> CGRect {
        let x = anchor.isLeading ? current.minX : current.maxX - newSize.width
        let y = anchor.isTop ? current.maxY - newSize.height : current.minY
        return clamp(CGRect(origin: CGPoint(x: x, y: y), size: newSize), in: screen)
    }

    /// Clamp last, for the cases flipping cannot solve: a panel wider or taller than the
    /// screen, or a pointer close enough to a corner that both sides overflow. It is also
    /// the only thing that pulls a *grown* panel back on screen — `constrainFrameRect` is
    /// overridden to return frames untouched, so AppKit will not do it.
    private static func clamp(_ rect: CGRect, in screen: CGRect) -> CGRect {
        let x = min(max(rect.minX, screen.minX), max(screen.minX, screen.maxX - rect.width))
        let y = min(max(rect.minY, screen.minY), max(screen.minY, screen.maxY - rect.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: rect.size)
    }
}
