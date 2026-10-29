import AppKit
import Testing
@testable import MarkupKit

// `ChangeMarks.markColour(increasedContrast:)` and `removedColour(increasedContrast:)` carry a
// contrast table in their doc comments; this is what keeps it true — the same arithmetic and the
// same discipline as `SyntaxPaletteTests` and `StatusColourTests`. The grounds are the screen's
// own (`Scripts/change-grounds.swift`): the window's pane, the hotkey panel's material and the
// change card, per appearance. The mark is a hairline, so its floor is a non-text one (3:1 plus a
// step, 3.5); removed text is text, so its floor is 4.5:1. The eight accents are the presets macOS
// lets a user choose between, walked by their system colours the way `Scripts/accent-contrast.swift`
// walks them, because `controlAccentColor` in a test process is only ever this machine's.

private typealias RGB = (CGFloat, CGFloat, CGFloat)

private func rgb(_ colour: NSColor) -> RGB {
    let c = colour.usingColorSpace(.sRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent)
}

private func composite(_ colour: NSColor, over ground: RGB) -> RGB {
    let c = colour.usingColorSpace(.sRGB)!
    let a = c.alphaComponent
    return (c.redComponent * a + ground.0 * (1 - a), c.greenComponent * a + ground.1 * (1 - a),
            c.blueComponent * a + ground.2 * (1 - a))
}

private let accents: [(String, NSColor)] = [
    ("синий", .systemBlue), ("фиолетовый", .systemPurple), ("розовый", .systemPink),
    ("красный", .systemRed), ("оранжевый", .systemOrange), ("жёлтый", .systemYellow),
    ("зелёный", .systemGreen), ("графит", .systemGray),
]

private func resolved(_ colour: NSColor, dark: Bool) -> NSColor {
    var out = colour
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        out = colour.usingColorSpace(.sRGB) ?? colour
    }
    return out
}

private func grounds(dark: Bool) -> [RGB] {
    (dark ? ChangeMarks.darkGrounds : ChangeMarks.lightGrounds).map(ChangeMarks.srgb)
}

private func worst(_ colour: RGB, dark: Bool) -> Double {
    grounds(dark: dark).map { ChangeMarks.contrast(colour, $0) }.min()!
}

// MARK: - The mark

@Test func everyAccentClearsThreePointFiveAgainstEveryGroundOfItsAppearance() {
    for dark in [false, true] {
        for (name, accent) in accents {
            let mark = ChangeMarks.floored(resolved(accent, dark: dark), dark: dark,
                                           increasedContrast: false)
            let ratio = worst(rgb(mark), dark: dark)
            #expect(ratio >= 3.5, "\(name), dark \(dark): \(ratio)")
        }
    }
}

@Test func underIncreaseContrastEveryAccentClearsFourPointFive() {
    for dark in [false, true] {
        for (name, accent) in accents {
            let mark = ChangeMarks.floored(resolved(accent, dark: dark), dark: dark,
                                           increasedContrast: true)
            let ratio = worst(rgb(mark), dark: dark)
            #expect(ratio >= 4.5, "\(name), dark \(dark): \(ratio)")
        }
    }
}

@Test func theFloorMovesEachAccentNoFurtherThanItNeeds() {
    // One step short of the chosen fraction must fail somewhere: a rule that added margin of its
    // own would pass every floor test above and still darken синий back toward the text, which is
    // the defect the floor replaced.
    for dark in [false, true] {
        for (name, accent) in accents {
            let bare = resolved(accent, dark: dark)
            let fraction = ChangeMarks.floorFraction(bare, dark: dark, increasedContrast: false)
            guard fraction > 0 else { continue }
            let short = ChangeMarks.moved(bare, dark: dark, by: fraction - 0.01)
            #expect(worst(short, dark: dark) < 3.5, "\(name), dark \(dark)")
        }
    }
}

@Test func anAccentThatAlreadyClearsTheFloorIsDrawnUnchanged() {
    // фиолетовый on the light grounds is 3.51:1 bare (`Scripts/accent-contrast.swift`).
    let purple = resolved(.systemPurple, dark: false)
    #expect(ChangeMarks.floorFraction(purple, dark: false, increasedContrast: false) == 0)
    let mark = rgb(ChangeMarks.floored(purple, dark: false, increasedContrast: false))
    let bare = rgb(purple)
    #expect(abs(mark.0 - bare.0) < 0.001 && abs(mark.1 - bare.1) < 0.001
            && abs(mark.2 - bare.2) < 0.001)
}

@Test func theBareDarkAccentsFailedOnThePanelAndTheCard() {
    // Why the dark marks are moved at all: against the screen's dark grounds five of the eight
    // presets are under 3:1 bare (синий 2.66, фиолетовый 2.37, розовый 2.44, красный 2.50,
    // графит 2.99). Pinned so that a re-measured ground that made this untrue is noticed, and
    // the doc comment's figures with it.
    let failing = accents.filter { worst(rgb(resolved($0.1, dark: true)), dark: true) < 3 }
    #expect(failing.map(\.0) == ["синий", "фиолетовый", "розовый", "красный", "графит"])
}

@Test func theLightMarkSitsAsFarFromTheTextAsFromTheGround() {
    // The 35 % blend left синий 2.12:1 from the text over it; the floor rule puts every preset
    // at ≥ 3.5:1 from `labelColor` (black at 0.85) on every light ground.
    for (name, accent) in accents {
        let mark = rgb(ChangeMarks.floored(resolved(accent, dark: false), dark: false,
                                           increasedContrast: false))
        let ink = grounds(dark: false).map { ground in
            ChangeMarks.contrast(mark, composite(NSColor(white: 0, alpha: 0.85), over: ground))
        }.min()!
        #expect(ink >= 3.5, "\(name): \(ink)")
    }
}

@Test func theMarkColourResolvesToTheFloorRuleOverThisMachinesAccent() {
    for dark in [false, true] {
        for high in [false, true] {
            let mark = rgb(resolved(ChangeMarks.markColour(increasedContrast: high), dark: dark))
            let expected = rgb(ChangeMarks.floored(resolved(.controlAccentColor, dark: dark),
                                                   dark: dark, increasedContrast: high))
            #expect(abs(mark.0 - expected.0) < 0.001 && abs(mark.1 - expected.1) < 0.001
                    && abs(mark.2 - expected.2) < 0.001, "dark \(dark), high \(high)")
        }
    }
}

// MARK: - Removed text

@Test func removedTextClearsFourPointFiveOnEveryGround() {
    for dark in [false, true] {
        let colour = resolved(ChangeMarks.removedColour(), dark: dark)
        for ground in grounds(dark: dark) {
            let ratio = ChangeMarks.contrast(composite(colour, over: ground), ground)
            #expect(ratio >= 4.5, "dark \(dark): \(ratio)")
        }
    }
}

@Test func underIncreaseContrastRemovedTextClearsSix() {
    for dark in [false, true] {
        let colour = resolved(ChangeMarks.removedColour(increasedContrast: true), dark: dark)
        for ground in grounds(dark: dark) {
            let ratio = ChangeMarks.contrast(composite(colour, over: ground), ground)
            #expect(ratio >= 6, "dark \(dark): \(ratio)")
        }
    }
}

@Test func theRemovedAlphasAreTheSmallestStepThatClearsWithHeadroom() {
    // Each alpha clears its floor by 0.2 on the worst ground, and 0.05 less does not — or the
    // comment's «smallest» is wrong and the removed text is darker than it needs to be, closer to
    // the body text it has to stay under.
    for dark in [false, true] {
        for high in [false, true] {
            let alpha = ChangeMarks.removedAlpha(dark: dark, increasedContrast: high)
            let floor = high ? 6.0 : 4.5
            func worstRatio(_ a: CGFloat) -> Double {
                let ink = NSColor(white: dark ? 1 : 0, alpha: a)
                return grounds(dark: dark).map { ChangeMarks.contrast(composite(ink, over: $0), $0) }.min()!
            }
            #expect(worstRatio(alpha) >= floor + 0.2, "dark \(dark), high \(high)")
            #expect(worstRatio(alpha - 0.05) < floor + 0.2, "dark \(dark), high \(high)")
            #expect(alpha < 0.85, "removed text must stay lighter than the body text")
        }
    }
}
