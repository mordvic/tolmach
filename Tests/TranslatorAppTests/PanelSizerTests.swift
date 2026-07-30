import Testing
import CoreGraphics
@testable import TranslatorApp

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)   // ceiling: 540pt

@Test func aShortResultGetsAPanelTheSizeOfItsContent() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 420, height: 180), frozenWidth: nil,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.size == CGSize(width: 420, height: 180))
    #expect(fit.scrolls == false)
}

@Test func aNarrowResultIsWidenedToTheFloorRatherThanLeftAsASliver() {
    // A one-word translation would otherwise open a panel too narrow for its own buttons.
    let fit = PanelSizer.fit(ideal: CGSize(width: 90, height: 60), frozenWidth: nil,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.size == CGSize(width: 300, height: 120))
}

@Test func aWideResultIsCappedRatherThanSpanningTheDisplay() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 1300, height: 200), frozenWidth: nil,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.size.width == 560)
}

@Test func theWidthIsFrozenOnceARunHasStarted() {
    // A width that moved while tokens arrived would re-wrap every line on every token.
    let fit = PanelSizer.fit(ideal: CGSize(width: 520, height: 300), frozenWidth: 380,
                             previous: CGSize(width: 380, height: 200), screen: screen,
                             userSized: false)
    #expect(fit.size.width == 380)
}

@Test func theHeightNeverDecreasesWhileMoreTextArrives() {
    // Monotonic within a run. A cleaner that shortens the reply mid-stream, or a chunk
    // boundary that briefly measures small, must not make the panel jump shut.
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 200), frozenWidth: 380,
                             previous: CGSize(width: 380, height: 340), screen: screen,
                             userSized: false)
    #expect(fit.size.height == 340)
}

@Test func theHeightStopsAtSixtyPercentOfTheScreenAndScrollsInstead() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 2000), frozenWidth: 380,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.size.height == 540)
    #expect(fit.scrolls)
}

@Test func contentThatFitsDoesNotAskForAScrollView() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 539), frozenWidth: 380,
                             previous: .zero, screen: screen, userSized: false)
    #expect(fit.scrolls == false)
}

@Test func aHandResizedPanelKeepsTheSizeTheUserGaveIt() {
    let fit = PanelSizer.fit(ideal: CGSize(width: 500, height: 900), frozenWidth: 380,
                             previous: CGSize(width: 300, height: 200), screen: screen,
                             userSized: true)
    #expect(fit.size == CGSize(width: 300, height: 200))
    #expect(fit.scrolls)   // the content no longer fits what the user chose
}

@Test func anUnmeasuredContentSizeProducesTheFloorRatherThanANaNFrame() {
    // A SwiftUI view asked for its fitting size before the first layout pass reports
    // `.zero`, and an `NSWindow` moved to a NaN origin is unrecoverable. Infinity is the
    // same hazard from the other direction: `sizeThatFits` is asked with an unbounded
    // proposal, and a greedy subview can hand the proposal straight back.
    let zero = PanelSizer.fit(ideal: .zero, frozenWidth: nil, previous: .zero,
                              screen: screen, userSized: false)
    #expect(zero.size == CGSize(width: 300, height: 120))

    let infinite = PanelSizer.fit(ideal: CGSize(width: CGFloat.infinity, height: CGFloat.infinity),
                                  frozenWidth: nil, previous: .zero, screen: screen,
                                  userSized: false)
    #expect(infinite.size == CGSize(width: 560, height: 540))
    #expect(infinite.size.width.isFinite)
    #expect(infinite.size.height.isFinite)
}

@Test func aScreenTooShortForTheHeightFloorStillYieldsTheFloor() {
    // 60% of a 150pt strip is 90pt, below the 120pt floor. A panel smaller than its own
    // buttons is worse than one that overhangs a freak display.
    let strip = CGRect(x: 0, y: 0, width: 1440, height: 150)
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 400), frozenWidth: nil,
                             previous: .zero, screen: strip, userSized: false)
    #expect(fit.size.height == 120)
    #expect(fit.scrolls)
}
