import AppKit
import Testing
@testable import MarkupKit

// `ChangeMarks.markColour`'s doc comment carries a contrast table; this is what keeps it true —
// the same arithmetic and the same discipline as `SyntaxPaletteTests` and `StatusColourTests`.
// The mark is a hairline in the accent on the pane's own ground, so the floor is WCAG's 3:1 for
// a non-text indicator, not the 4.5:1 text takes; the eight accents are the presets macOS lets
// a user choose between, walked by their system colours the way `Scripts/accent-contrast.swift`
// walks them, because `controlAccentColor` in a test process is only ever the one this machine
// is set to.

private func luminance(_ colour: NSColor) -> Double {
    let c = colour.usingColorSpace(.sRGB)!
    func channel(_ v: CGFloat) -> Double {
        let v = Double(v)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
        + 0.0722 * channel(c.blueComponent)
}

private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let (l1, l2) = (luminance(a), luminance(b))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

private let accents: [(String, NSColor)] = [
    ("синий", .systemBlue), ("фиолетовый", .systemPurple), ("розовый", .systemPink),
    ("красный", .systemRed), ("оранжевый", .systemOrange), ("жёлтый", .systemYellow),
    ("зелёный", .systemGreen), ("графит", .systemGray),
]

private func resolved(_ colour: NSColor, in appearance: NSAppearance.Name) -> NSColor {
    var out = colour
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        out = colour.usingColorSpace(.sRGB) ?? colour
    }
    return out
}

@Test func everyAccentClearsTheNonTextFloorAsALightMark() {
    // The white pane. Bare, three accents are under 3:1 (жёлтый 1.51); blended by
    // `lightBlend` every one is over it. Both halves are asserted so that dropping the blend
    // — or setting it to a fraction that only saves the blue this machine happens to use —
    // fails here rather than on a user's yellow accent.
    let pane = NSColor.white
    var bareFailures = 0
    for (name, accent) in accents {
        let bare = resolved(accent, in: .aqua)
        if contrast(bare, pane) < 3 { bareFailures += 1 }
        let mark = ChangeMarks.blendedTowardBlack(bare, by: ChangeMarks.lightBlend)
        #expect(contrast(mark, pane) >= 3, "\(name): \(contrast(mark, pane))")
    }
    #expect(bareFailures == 3, "the blend exists because three bare accents fail; \(bareFailures) did")
}

@Test func everyAccentClearsTheNonTextFloorAsADarkMarkUnblended() {
    // The dark pane is the preview's 0.12 grey. No blend is applied there and none is needed:
    // the worst accent measured 4.59:1. Pinned so that a future «blend both appearances» does
    // not quietly dim the marks where they were already fine.
    let pane = NSColor(calibratedWhite: 0.12, alpha: 1)
    for (name, accent) in accents {
        let mark = resolved(accent, in: .darkAqua)
        #expect(contrast(mark, pane) >= 3, "\(name): \(contrast(mark, pane))")
    }
}

@Test func theLightBlendIsTheFirstStepWithMarginPastTheFloor() {
    // 0.30 is the first fraction that clears 3:1 for every accent (жёлтый 3.08:1) and 0.35 is
    // one step of margin. Asserting the neighbour below fails keeps the constant from drifting
    // *down* while staying green: a smaller fraction that still passed the previous test would
    // mean the accents moved, and the comment would be wrong.
    let pane = NSColor.white
    let yellow = resolved(.systemYellow, in: .aqua)
    #expect(contrast(ChangeMarks.blendedTowardBlack(yellow, by: 0.25), pane) < 3)
    #expect(contrast(ChangeMarks.blendedTowardBlack(yellow, by: ChangeMarks.lightBlend), pane) >= 3.4)
}

@Test func theMarkColourResolvesToTheAccentInDarkAndToTheBlendInLight() {
    // `markColour` is dynamic; resolve it under each appearance and compare against the rule
    // applied to the same accent by hand. Whatever this machine's accent is, the two must agree.
    let light = resolved(ChangeMarks.markColour, in: .aqua)
    let expectedLight = ChangeMarks.blendedTowardBlack(resolved(.controlAccentColor, in: .aqua),
                                                       by: ChangeMarks.lightBlend)
    #expect(abs(luminance(light) - luminance(expectedLight)) < 0.001)
    let dark = resolved(ChangeMarks.markColour, in: .darkAqua)
    let expectedDark = resolved(.controlAccentColor, in: .darkAqua)
    #expect(abs(luminance(dark) - luminance(expectedDark)) < 0.001)
}
