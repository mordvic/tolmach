// Sources/TranslatorApp/RussianCopy.swift
import Foundation
import TranslationCore

extension Tone {
    /// `Tone`'s raw values are English identifiers that belong in the prompt, not on a
    /// Russian screen. The label lives here rather than in TranslationCore because the
    /// core is UI-agnostic, and here rather than inline in a view because the main
    /// window's picker and the settings pane must not drift apart.
    ///
    /// Exhaustive with no `default:` on purpose: a sixth `Tone` case should fail to
    /// compile here instead of quietly showing the user nothing.
    var russianName: String {
        switch self {
        case .neutral: "нейтральный"
        case .formal: "деловой"
        case .casual: "разговорный"
        case .technical: "технический"
        case .literal: "буквальный"
        }
    }
}

enum RussianCopy {
    /// Russian nouns after a number take one of three forms, chosen by the last two
    /// digits of the count:
    ///
    /// - `many` when the last two digits are 11-14 — these end in 1-4 but behave like
    ///   5-20, and are the case a naive last-digit rule gets wrong;
    /// - otherwise `one` when the last digit is 1 (1, 21, 101, 121…);
    /// - otherwise `few` when the last digit is 2-4 (2, 23, 104…);
    /// - otherwise `many` (0, 5-20, 25-30…).
    ///
    /// The count's sign is irrelevant to the grammar, so the magnitude decides. Taking
    /// `% 100` before `abs` keeps `Int.min` from overflowing.
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let lastTwo = abs(count % 100)
        if (11...14).contains(lastTwo) { return many }
        switch lastTwo % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    /// "3 фрагмента" — the hint the main window shows over the source pane when the text
    /// will be translated in more than one piece.
    static func chunkCount(_ count: Int) -> String {
        "\(count) \(plural(count, "фрагмент", "фрагмента", "фрагментов"))"
    }
}
