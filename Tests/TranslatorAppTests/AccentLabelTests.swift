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
