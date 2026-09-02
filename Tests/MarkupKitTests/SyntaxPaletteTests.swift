import AppKit
import Testing
@testable import MarkupKit

// `SyntaxPalette`'s doc comment carries a contrast table; this is what keeps it true. The
// arithmetic is WCAG's relative-luminance formula, the same one `Scripts/colour-contrast.swift`
// and `StatusColourTests` use for the app's status colours, and the background is the code
// card's actual fill — `quaternaryLabelColor` composited over the pane's paper — in each
// appearance, resolved the way the view resolves it.

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

private func composite(_ top: NSColor, over base: NSColor) -> NSColor {
    let t = top.usingColorSpace(.sRGB)!, b = base.usingColorSpace(.sRGB)!
    let a = t.alphaComponent
    return NSColor(srgbRed: t.redComponent * a + b.redComponent * (1 - a),
                   green: t.greenComponent * a + b.greenComponent * (1 - a),
                   blue: t.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
}

private let kinds: [SyntaxHighlighter.Kind] = [.keyword, .string, .comment, .number, .key, .type]

/// Every token colour clears WCAG AA for body text on the card it is drawn on, in both
/// appearances. The system accent colours did not (`systemPurple` 3.34:1, `systemTeal`
/// 1.73:1 in the light appearance — measured 2026-09-02), which is why this palette exists.
@Test func everyTokenColourClearsAAOnTheCodeCardInBothAppearances() {
    for (appearance, paper) in [(NSAppearance.Name.aqua, NSColor.white),
                                (.darkAqua, NSColor(calibratedWhite: 0.12, alpha: 1))] {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let card = composite(.quaternaryLabelColor, over: paper)
            for kind in kinds {
                let (light, dark) = SyntaxPalette.values(for: kind)
                let ink = SyntaxPalette.hex(appearance == .aqua ? light : dark)
                let ratio = contrast(ink, card)
                #expect(ratio >= 4.5, "\(kind) in \(appearance.rawValue): \(ratio)")
            }
        }
    }
}

/// The dynamic colour resolves to the light value under Aqua and the dark value under Dark
/// Aqua — the whole reason it is one `NSColor` and not two code paths.
@Test func theDynamicColourFollowsTheAppearance() {
    let colour = SyntaxPalette.color(for: .keyword)
    let (light, dark) = SyntaxPalette.values(for: .keyword)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        #expect(colour.usingColorSpace(.sRGB)?.redComponent
                == SyntaxPalette.hex(light).usingColorSpace(.sRGB)?.redComponent)
    }
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        #expect(colour.usingColorSpace(.sRGB)?.redComponent
                == SyntaxPalette.hex(dark).usingColorSpace(.sRGB)?.redComponent)
    }
}
