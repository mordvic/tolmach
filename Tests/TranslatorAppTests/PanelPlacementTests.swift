import Testing
import CoreGraphics
@testable import TranslatorApp

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let size = CGSize(width: 360, height: 240)

@Test func thePanelSitsBelowAndRightOfTheCursorWhenThereIsRoom() {
    // Below-right is where a macOS pointer's own shadow falls, so the panel does not cover
    // the text the user just selected.
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 400, y: 600), size: size, screen: screen)
    #expect(frame.minX == 414)                 // cursor.x + gap
    #expect(frame.maxY == 586)                 // cursor.y - gap, panel hanging downwards
    #expect(frame.size == size)
}

@Test func itFlipsToTheLeftRatherThanHangingOffTheRightEdge() {
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 1400, y: 600), size: size, screen: screen)
    #expect(frame.maxX == 1386)                // cursor.x - gap
    #expect(frame.minX >= screen.minX)
}

@Test func itFlipsUpwardRatherThanHangingOffTheBottom() {
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 400, y: 100), size: size, screen: screen)
    #expect(frame.minY == 114)                 // cursor.y + gap, panel standing upwards
    #expect(frame.maxY <= screen.maxY)
}

@Test func aPanelTallerThanTheScreenIsClampedRatherThanPlacedOffIt() {
    // A long translation with warnings can outgrow a small display. Clamping keeps the
    // controls reachable; flipping alone would just move the overflow to the other edge.
    let tall = CGSize(width: 360, height: 1200)
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 400, y: 450), size: tall, screen: screen)
    #expect(frame.minY >= screen.minY)
    #expect(frame.minX >= screen.minX)
    #expect(frame.maxX <= screen.maxX)
}

@Test func aScreenWithANonZeroOriginIsRespected() {
    // A second display sits at an offset, and often a negative one. Assuming an origin of
    // zero puts the panel on the wrong monitor — or nowhere.
    let secondary = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
    let frame = PanelPlacement.frame(cursor: CGPoint(x: -1900, y: 1250), size: size, screen: secondary)
    #expect(frame.minX >= secondary.minX)
    #expect(frame.maxY <= secondary.maxY)
    // Both bounds above are one-sided, so a placement shoved *inward* satisfies them while
    // being badly wrong — hardcoding the clamp's lower bound to 0 parks this panel at x = 0,
    // 1886pt from the pointer at the far edge of the display, and `minX >= -1920` still
    // holds. Pin the frame itself so the test checks what its name claims.
    #expect(frame.origin == CGPoint(x: -1886, y: 996))   // cursor + gap, hanging downwards
}

// MARK: - Inputs the prescribed cases do not reach

@Test func aPanelWhoseSizeHasNotBeenMeasuredYetIsStillPlacedOnScreen() {
    // A SwiftUI panel asked for its fitting size before the first layout pass reports
    // `.zero`. That must produce a degenerate rect at the anchor point, not a NaN one:
    // an NSWindow moved to a NaN origin is unrecoverable, and the arithmetic here divides
    // nothing but does subtract, so a bad size propagates silently.
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 400, y: 600), size: .zero, screen: screen)
    #expect(frame.origin == CGPoint(x: 414, y: 586))   // still gap-offset from the cursor
    #expect(frame.size == .zero)
    #expect(screen.contains(frame.origin))
}

@Test func aCursorLeftBehindOnADetachedDisplayIsPulledBackOntoTheGivenScreen() {
    // `NSEvent.mouseLocation` is global, so it can name a point on a display that has just
    // been unplugged — or simply one the caller did not pass as `screen`. Every such point
    // must still yield a frame wholly on the screen we were given, or the panel opens
    // where nobody can see it and the app looks hung.
    for cursor in [CGPoint(x: 5000, y: 5000), CGPoint(x: -5000, y: -5000),
                   CGPoint(x: 5000, y: -5000), CGPoint(x: -5000, y: 5000)] {
        let frame = PanelPlacement.frame(cursor: cursor, size: size, screen: screen)
        #expect(frame.minX >= screen.minX, "\(cursor)")
        #expect(frame.maxX <= screen.maxX, "\(cursor)")
        #expect(frame.minY >= screen.minY, "\(cursor)")
        #expect(frame.maxY <= screen.maxY, "\(cursor)")
    }
}

@Test func aScreenWithNoAreaParksThePanelAtItsOwnOriginNotAtGlobalZero() {
    // `NSScreen.visibleFrame` can degenerate while displays are being reconfigured. The
    // clamp's own lower bound has to win over its upper bound then, otherwise the two
    // bounds cross and `min(max(…))` lands the panel a full panel-width to the left of the
    // screen. Pinned with a negative origin so passing the test also requires reading the
    // screen's origin rather than assuming zero.
    let degenerate = CGRect(x: -50, y: -50, width: 0, height: 0)
    let frame = PanelPlacement.frame(cursor: CGPoint(x: 400, y: 600), size: size, screen: degenerate)
    #expect(frame.origin == CGPoint(x: -50, y: -50))
    #expect(frame.size == size)
}

@Test func aPanelThatFitsTheScreenIsNeverParkedOnTopOfTheCursor() {
    // The whole point of flipping before clamping is that the panel sits *beside* the
    // pointer rather than over the selection under it. A single hand-picked cursor cannot
    // show that, because the failure is a narrow band near each edge where the flip
    // overflows and the clamp drags the panel back across the pointer. Sweeping well past
    // every edge covers those bands and the four corners at once.
    //
    // The guarantee is conditional on the panel fitting: a panel larger than about half the
    // screen in *both* axes has no on-screen placement that misses the pointer at all, and
    // is clamped over it by necessity rather than by a flaw in the order of operations.
    var covered: [String] = []
    var offScreen: [String] = []
    for stepX in stride(from: CGFloat(-600), through: 2040, by: 13) {
        for stepY in stride(from: CGFloat(-600), through: 1500, by: 13) {
            let cursor = CGPoint(x: stepX, y: stepY)
            let frame = PanelPlacement.frame(cursor: cursor, size: size, screen: screen)
            if frame.contains(cursor) { covered.append("\(cursor) → \(frame)") }
            let inside = frame.minX >= screen.minX && frame.maxX <= screen.maxX
                && frame.minY >= screen.minY && frame.maxY <= screen.maxY
            if !inside { offScreen.append("\(cursor) → \(frame)") }
        }
    }
    // Compare the counts, not the arrays: `#expect` renders whichever expression it is
    // given, and a sweep this size renders thousands of entries into one unreadable line.
    #expect(covered.count == 0, "panel covered the pointer at \(covered.prefix(3).joined(separator: "; "))")
    #expect(offScreen.count == 0, "panel left the screen at \(offScreen.prefix(3).joined(separator: "; "))")
}
