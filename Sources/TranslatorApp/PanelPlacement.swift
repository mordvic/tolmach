// Sources/TranslatorApp/PanelPlacement.swift
import CoreGraphics

/// Where the floating panel goes, given where the pointer is.
///
/// Extracted from the panel controller because it is the only part of the panel that is
/// arithmetic rather than AppKit, and the corner cases — the pointer near an edge, a second
/// display at a negative origin, a panel taller than the screen — are exactly the ones
/// nobody exercises by hand.
///
/// AppKit screen coordinates: origin bottom-left, y increasing upwards.
enum PanelPlacement {
    static func frame(cursor: CGPoint, size: CGSize, screen: CGRect, gap: CGFloat = 14) -> CGRect {
        // Preferred: to the right of the pointer, hanging downwards from it.
        var x = cursor.x + gap
        var y = cursor.y - gap - size.height

        // Flip before clamping. Clamping alone would slide the panel along the edge and
        // park it on top of the selection the user is trying to read.
        if x + size.width > screen.maxX { x = cursor.x - gap - size.width }
        if y < screen.minY { y = cursor.y + gap }

        // Clamp last, for the cases flipping cannot solve: a panel wider or taller than the
        // screen, or a pointer close enough to a corner that both sides overflow.
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width))
        y = min(max(y, screen.minY), max(screen.minY, screen.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
