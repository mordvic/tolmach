// Tests/TranslatorAppTests/AccentLabelTests.swift
import Testing
import AppKit
import SwiftUI
@testable import TranslatorApp

/// The rule `AccentLabel` exists for, checked against every accent macOS offers.
///
/// The type's own decision is a pure function of a fill, deliberately: the accent is a system
/// setting and no test can select one, so `onAccent` is unreachable here while
/// `label(on:in:)` is checkable against all eight.
@MainActor
struct AccentLabelTests {
    static let aqua = NSAppearance(named: .aqua)!
    static let darkAqua = NSAppearance(named: .darkAqua)!

    /// The eight accents System Settings offers, by their system colours.
    static let accents: [(String, NSColor)] = [
        ("синий", .systemBlue), ("фиолетовый", .systemPurple), ("розовый", .systemPink),
        ("красный", .systemRed), ("оранжевый", .systemOrange), ("жёлтый", .systemYellow),
        ("зелёный", .systemGreen), ("графит", .systemGray),
    ]

    static func contrast(_ a: NSColor, _ b: NSColor, in appearance: NSAppearance) -> Double {
        var out = 0.0
        appearance.performAsCurrentDrawingAppearance {
            guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return }
            func luminance(_ c: NSColor) -> Double {
                func linear(_ v: CGFloat) -> Double {
                    let v = Double(v)
                    return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
                     + 0.0722 * linear(c.blueComponent)
            }
            let (p, q) = (luminance(x), luminance(y))
            out = (max(p, q) + 0.05) / (min(p, q) + 0.05)
        }
        return out
    }

    /// The claim in one line: no accent the user can pick leaves the label under Apple's own
    /// bar for a control. White on the yellow accent measures 1.41:1 — this is what that
    /// becomes.
    @Test func noAccentLeavesTheLabelBelowTheThreshold() {
        for appearance in [Self.aqua, Self.darkAqua] {
            for (name, fill) in Self.accents {
                let chosen = AccentLabel.label(on: fill, in: appearance)
                let got = Self.contrast(chosen, fill, in: appearance)
                #expect(got >= AccentLabel.switchBelow,
                        "\(name): \(got)")
            }
        }
    }

    /// And the other half, which is what keeps the app looking like a Mac app: where the
    /// platform's own white *is* readable, it is left alone. Blue, purple, pink and red all
    /// clear 3:1 with white, so all four must keep it — flipping them to black would be more
    /// contrast and the wrong answer.
    @Test func anAccentThePlatformCanCarryKeepsThePlatformsOwnWhite() {
        for appearance in [Self.aqua, Self.darkAqua] {
            for (name, fill) in Self.accents {
                let white = Self.contrast(.white, fill, in: appearance)
                let chosen = AccentLabel.label(on: fill, in: appearance)
                if white >= AccentLabel.switchBelow {
                    #expect(chosen == .white, "\(name) should have kept white at \(white)")
                } else {
                    #expect(chosen == .black, "\(name) should have switched at \(white)")
                }
            }
        }
    }

    /// The four that actually motivated the type, named so a future reader can see which
    /// cases the threshold is protecting rather than inferring it from a loop.
    @Test func theFourAccentsThatCannotCarryWhiteAreTheOnesThatSwitch() {
        let switched = Self.accents.filter { _, fill in
            AccentLabel.label(on: fill, in: Self.darkAqua) == .black
        }.map(\.0)
        #expect(Set(switched) == ["оранжевый", "жёлтый", "зелёный", "графит"])
    }
}

/// The three things a fill for «Перевести» has to satisfy, checked against the one chosen.
///
/// The colour is the app's own rather than the system accent, so unlike `controlAccentColor`
/// it is fully reachable from here — which makes this the rare visual property that can be
/// pinned instead of owed to a pair of eyes.
@MainActor
struct PrimaryButtonColourTests {
    static let aqua = NSAppearance(named: .aqua)!
    static let darkAqua = NSAppearance(named: .darkAqua)!

    /// The two fills are not interchangeable, and which is which is the fix for «плохо читаем».
    ///
    /// A single `#15807E` put the label at 4.75:1 — past WCAG's 4.5 and still reported as hard
    /// to read, which is that formula's known blind spot for light text on a saturated
    /// mid-tone. The light appearance can afford a deeper fill because its ground is white and
    /// separation comes free there; the dark one cannot, because the same depth disappears into
    /// a `#1e1e1e` window. Stated as «light is the darker of the two» rather than as a ratio,
    /// because it is the *structure* that a well-meant simplification back to one value would
    /// destroy — and the plain 4.5 bar above would not notice.
    @Test func theLightAppearanceTakesTheDeeperFill() {
        func luminance(_ appearance: NSAppearance) -> Double {
            var out = 0.0
            appearance.performAsCurrentDrawingAppearance {
                guard let c = PrimaryButtonColour.fillColour.usingColorSpace(.sRGB) else { return }
                func linear(_ v: CGFloat) -> Double {
                    let v = Double(v)
                    return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                out = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
                    + 0.0722 * linear(c.blueComponent)
            }
            return out
        }
        #expect(luminance(Self.aqua) < luminance(Self.darkAqua))
    }

    /// A 13 pt label wants 4.5:1. The system accent manages 4.02 at best, which is why this
    /// button stopped using it.
    @Test func theLabelIsReadableOnTheFill() {
        for appearance in [Self.aqua, Self.darkAqua] {
            let label = AccentLabel.label(on: PrimaryButtonColour.fillColour, in: appearance)
            let got = AccentLabelTests.contrast(label, PrimaryButtonColour.fillColour,
                                                in: appearance)
            #expect(got >= 4.5, "\(got)")
        }
    }

    /// A control has to be visible against the surface behind it — and this fill is one value
    /// for two very different surfaces, which is what ruled out every darker candidate.
    @Test func theFillSeparatesFromTheWindowInBothAppearances() {
        for appearance in [Self.aqua, Self.darkAqua] {
            let got = AccentLabelTests.contrast(PrimaryButtonColour.fillColour,
                                                .windowBackgroundColor, in: appearance)
            #expect(got >= 3, "\(got)")
        }
    }

    /// And it must not be mistaken for something the app already says in colour. Two fills
    /// closer than about 60 in sRGB read as the same one: the icon's cinnabar was 27 from
    /// `failure`, which is what took it out of the running.
    @Test func theFillIsNotConfusableWithTheAppsSemanticColours() {
        func distance(_ a: NSColor, _ b: NSColor, in appearance: NSAppearance) -> Double {
            var out = 0.0
            appearance.performAsCurrentDrawingAppearance {
                guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return }
                let dr = (x.redComponent - y.redComponent) * 255
                let dg = (x.greenComponent - y.greenComponent) * 255
                let db = (x.blueComponent - y.blueComponent) * 255
                out = Double(dr * dr + dg * dg + db * db).squareRoot()
            }
            return out
        }
        // Both appearances: the fill is two values now, and the deeper one is the one that
        // creeps towards the success green — `#0C6060` was rejected at 55.
        for appearance in [Self.aqua, Self.darkAqua] {
            for (name, semantic) in [("warning", StatusColour.warning),
                                     ("success", StatusColour.success),
                                     ("failure", StatusColour.failure)] {
                let got = distance(PrimaryButtonColour.fillColour, NSColor(semantic),
                                   in: appearance)
                #expect(got >= 60, "\(name): \(got)")
            }
        }
    }
}
