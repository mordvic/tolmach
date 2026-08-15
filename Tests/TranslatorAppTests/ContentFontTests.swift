import Testing
import AppKit
@testable import TranslatorApp

/// The default has to be what the app rendered before the setting existed — not «about that».
///
/// Measured with `Scripts/content-font.swift`: `Text.font(.body)` and
/// `Text.font(.system(size: 13))` lay the same string out to an identical 375.0 × 16.0, and
/// `NSFont.preferredFont(forTextStyle: .body).pointSize` is 13.0. `ContentFont.defaultSize` is
/// a literal so an install cannot have it move underneath it; this is the canary that says so
/// the day the system disagrees, instead of every existing user's window re-flowing quietly.
@Test func theDefaultSizeStillMatchesTheSystemsBodyStyle() {
    #expect(ContentFont.defaultSize == NSFont.preferredFont(forTextStyle: .body).pointSize)
    #expect(ContentFont.default.typeface == .system)
    #expect(ContentFont.default.size == ContentFont.defaultSize)
}

/// The floor is not a taste: below it the user's own text is set finer than the words labelling
/// it.
///
/// Measured: every caption in this app is `.caption`, which is 10 pt. 11 is the first size that
/// keeps the translation larger than the word «Перевод» above it, and that is the whole
/// argument for the number.
@Test func theSmallestSizeStaysAboveTheInterfacesOwnCaptions() {
    #expect(ContentFont.sizes.lowerBound > NSFont.preferredFont(forTextStyle: .caption1).pointSize)
}

/// A size from outside the range is clamped rather than trusted or trapped on.
///
/// The stored value comes from a plist a person can edit by hand — `AppSettings.hotkey` gives
/// the same reasoning for re-checking `isValid` on the way out. A 400 pt pane is not a state
/// this app should be able to reach, and a `NaN` reaches `NSWindow.setFrame` through the
/// panel's measurement, where it is unrecoverable.
@Test func anImpossibleSizeIsBroughtBackIntoRange() {
    #expect(ContentFont(typeface: .system, size: 400).size == ContentFont.sizes.upperBound)
    #expect(ContentFont(typeface: .system, size: 2).size == ContentFont.sizes.lowerBound)
    #expect(ContentFont(typeface: .system, size: -0).size == ContentFont.sizes.lowerBound)
    #expect(ContentFont(typeface: .system, size: .nan).size == ContentFont.defaultSize)
    #expect(ContentFont(typeface: .system, size: .infinity).size == ContentFont.sizes.upperBound)
}

/// «Крупнее» and «Мельче» move by one point and stop at the ends — they do not wrap, and they
/// do not carry on returning a value the range forbids.
@Test func growingAndShrinkingStopAtTheEndsOfTheRange() {
    let normal = ContentFont.default
    #expect(normal.larger().size == ContentFont.defaultSize + ContentFont.step)
    #expect(normal.smaller().size == ContentFont.defaultSize - ContentFont.step)

    let largest = ContentFont(typeface: .system, size: ContentFont.sizes.upperBound)
    #expect(!largest.canGrow)
    #expect(largest.larger() == largest)
    #expect(largest.canShrink)

    let smallest = ContentFont(typeface: .system, size: ContentFont.sizes.lowerBound)
    #expect(!smallest.canShrink)
    #expect(smallest.smaller() == smallest)
    #expect(smallest.canGrow)
}

/// «Обычный размер» is named for the size and touches nothing else.
///
/// The гарнитура was chosen once, deliberately, in a different control; a menu item that reset
/// it as well would be undoing a decision it does not name.
@Test func theResetReturnsTheSizeAndLeavesTheTypefaceAlone() {
    let chosen = ContentFont(typeface: .serif, size: 27)
    let reset = chosen.atDefaultSize()
    #expect(reset.size == ContentFont.defaultSize)
    #expect(reset.typeface == .serif)
}

/// Every face has a Russian name, and the switch that provides them is exhaustive — a fourth
/// case fails to compile rather than rendering an empty row in the picker.
///
/// The names are also checked for the one word this project has ruled out: «начертание» names
/// bold or italic within a family, and what is chosen here is the family. See `CONTEXT.md`.
@Test func everyTypefaceIsNamedInRussian() {
    for typeface in ContentTypeface.allCases {
        #expect(!typeface.russianName.isEmpty)
        #expect(typeface.russianName.range(of: "[A-Za-z]", options: .regularExpression) == nil)
    }
    #expect(ContentTypeface.allCases.count == 3)
    #expect(ContentTypeface.system.design == .default)
    #expect(ContentTypeface.monospaced.design == .monospaced)
    #expect(ContentTypeface.serif.design == .serif)
}
