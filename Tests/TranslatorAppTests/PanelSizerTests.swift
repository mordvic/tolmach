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

@Test func theWidthIsFrozenOnceTheRunHasSettled() {
    // A width that moved after the settle would re-wrap every line under a reader who has
    // started reading. `frozenWidth` is non-nil only from the settle onwards.
    let fit = PanelSizer.fit(ideal: CGSize(width: 520, height: 300), frozenWidth: 380,
                             previous: CGSize(width: 380, height: 200), screen: screen,
                             userSized: false)
    #expect(fit.size.width == 380)
}

@Test func theWidthGrowsWithTheContentUntilItIsFrozen() {
    // The panel is shown before the text it will show exists, so the width has to be able to
    // catch up. Without this a first press comes up at the floor and stays there — see
    // `aPanelShownBeforeItsTranslationArrivesEndsUpAsWideAsThatTranslationNeeds`.
    let fit = PanelSizer.fit(ideal: CGSize(width: 520, height: 300), frozenWidth: nil,
                             previous: CGSize(width: 300, height: 120), screen: screen,
                             userSized: false)
    #expect(fit.size.width == 520)
}

@Test func theWidthNeverShrinksBackWhileTheRunIsStillGoing() {
    // The other direction, and it is not symmetrical with the height: the panel's ideal width
    // drops when the status row's «Перевожу…» goes away at the settle, and a panel that
    // narrowed at that exact moment would re-wrap the whole result just as it became readable.
    let fit = PanelSizer.fit(ideal: CGSize(width: 340, height: 300), frozenWidth: nil,
                             previous: CGSize(width: 500, height: 200), screen: screen,
                             userSized: false)
    #expect(fit.size.width == 500)
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

    // NaN, which nothing asserted until now and which the `isFinite` half of the guard is the
    // only thing catching. It matters because the obvious simplification is wrong in a way
    // that reads as equivalent: weakening the test to `value != 0` lets NaN through, since
    // IEEE says NaN compares unequal to everything including zero — and a NaN frame reaches
    // `NSWindow.setFrame`, where it is unrecoverable. That mutation was run; these four lines
    // are what fails on it.
    let notANumber = PanelSizer.fit(ideal: CGSize(width: CGFloat.nan, height: CGFloat.nan),
                                    frozenWidth: nil, previous: .zero, screen: screen,
                                    userSized: false)
    #expect(notANumber.size == CGSize(width: 300, height: 120))
    #expect(notANumber.size.width.isFinite)
    #expect(notANumber.size.height.isFinite)
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

@Test func aHandWidenedPanelKeepsWidthPastTheNormalCeiling() {
    // maxWidth (560) is a preference the app holds on the user's behalf; an explicit drag
    // overrules it. Only the floor still applies on this axis.
    let fit = PanelSizer.fit(ideal: CGSize(width: 500, height: 200), frozenWidth: 380,
                             previous: CGSize(width: 700, height: 200), screen: screen,
                             userSized: true)
    #expect(fit.size.width == 700)
}

@Test func aHandHeightenedPanelKeepsHeightPastTheNormalCeiling() {
    // The height ceiling (0.6 of the screen here: 540) is the same kind of preference as
    // maxWidth, not the same kind of limit as minHeight — an explicit drag overrules it too,
    // so a hand-dragged panel can end up taller than the ceiling would otherwise allow.
    let fit = PanelSizer.fit(ideal: CGSize(width: 380, height: 200), frozenWidth: 380,
                             previous: CGSize(width: 380, height: 700), screen: screen,
                             userSized: true)
    #expect(fit.size.height == 700)
}

@Test func aUserResizedPanelCannotProduceADegenerateZeroSizeFrame() {
    // Before the first show, previous is .zero. If userSized is true on that call,
    // returning previous unguarded would hand NSWindow.setFrame a non-window-compatible
    // size. The user's choice still wins, but floors are applied.
    let fit = PanelSizer.fit(ideal: CGSize(width: 500, height: 900), frozenWidth: nil,
                             previous: .zero, screen: screen, userSized: true)
    #expect(fit.size == CGSize(width: 300, height: 120))
}

/// The settle is the one fit allowed to make the panel smaller, and the three sections need
/// it to be.
///
/// The middle section stretches, so anything the height keeps after the content has given it
/// back sits as a hole between the translation and the buttons. Two things hand space back at
/// the settle — `PanelView`'s reservation lifts, and the «Перевожу…» row goes — and a strictly
/// monotonic height would keep both.
///
/// Asserted here rather than against a real panel deliberately. The settle is the **one**
/// resize `PanelController` animates, so a panel-level test has to wait for
/// `panel.animator()` and then reads a frame that is only sometimes there: written that way
/// first, it passed alone and failed in the full suite, twice for «no change at all» and once
/// for a single point of rounding. That is what this type exists for — the rule is a value,
/// and a value can be checked without a clock.
@Test func theSettleIsTheOneFitAllowedToMakeThePanelSmaller() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let previous = CGSize(width: 560, height: 300)
    // The content has given space back: the reply is shorter than what was reserved for it.
    let ideal = CGSize(width: 560, height: 160)

    let during = PanelSizer.fit(ideal: ideal, frozenWidth: 560, previous: previous,
                                screen: screen, userSized: false)
    let settling = PanelSizer.fit(ideal: ideal, frozenWidth: 560, previous: previous,
                                  screen: screen, userSized: false, settling: true)

    #expect(during.size.height == 300)
    #expect(settling.size.height == 160)
}

/// The exception is narrow: it lets the height follow the content down, not out of bounds.
@Test func theSettleStillRespectsTheFloorAndTheCeiling() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let previous = CGSize(width: 560, height: 400)

    let tiny = PanelSizer.fit(ideal: CGSize(width: 560, height: 10), frozenWidth: 560,
                              previous: previous, screen: screen, userSized: false,
                              settling: true)
    #expect(tiny.size.height == PanelSizer.minHeight)

    // A run that ends with warnings is taller, not shorter, and goes through the same rule.
    let huge = PanelSizer.fit(ideal: CGSize(width: 560, height: 5000), frozenWidth: 560,
                              previous: previous, screen: screen, userSized: false,
                              settling: true)
    #expect(huge.size.height == screen.height * PanelSizer.maxHeightFraction)
    #expect(huge.scrolls)
}
