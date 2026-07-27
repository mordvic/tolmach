import Testing
import Foundation
@testable import TranslatorApp
@testable import TranslationCore

@Test func everyToneHasANonEmptyRussianName() {
    for tone in Tone.allCases {
        #expect(!tone.russianName.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(tone.rawValue) has no Russian name")
    }
}

@Test func toneNamesAreDistinct() {
    let names = Tone.allCases.map(\.russianName)
    #expect(Set(names).count == Tone.allCases.count)
}

/// The picker sits in a Russian UI, so `Text($0.rawValue)` — «neutral», «formal» — is the
/// bug this guards against. Latin letters anywhere in a tone name mean the raw value, or
/// part of it, leaked into the label.
@Test func toneNamesContainNoLatinLetters() {
    let latin = CharacterSet(charactersIn: "a"..."z").union(CharacterSet(charactersIn: "A"..."Z"))
    for tone in Tone.allCases {
        #expect(tone.russianName.rangeOfCharacter(from: latin) == nil,
                "\(tone.rawValue) → «\(tone.russianName)» contains Latin letters")
    }
}

/// Russian picks one of three forms from the last two digits, and 11-14 are the trap: they
/// end in 1-4 but take the same form as 5-20. The whole 11-14 span is listed rather than
/// just its ends, because the branch is a range test and an off-by-one at either edge
/// would still satisfy 11 and 14 alone.
///
/// 0 and 100 are here because they are the two counts whose last digit is 0 — the branch
/// no other case in this list reaches — and because the helper's doc comment names them.
@Test(arguments: [
    (0, "0 фрагментов"),
    (1, "1 фрагмент"),
    (2, "2 фрагмента"),
    (4, "4 фрагмента"),
    (5, "5 фрагментов"),
    (11, "11 фрагментов"),
    (12, "12 фрагментов"),
    (13, "13 фрагментов"),
    (14, "14 фрагментов"),
    (21, "21 фрагмент"),
    (22, "22 фрагмента"),
    (25, "25 фрагментов"),
    (100, "100 фрагментов"),
    (101, "101 фрагмент"),
    (111, "111 фрагментов"),
])
func chunkCountUsesTheRightPluralForm(count: Int, expected: String) {
    #expect(RussianCopy.chunkCount(count) == expected)
}

/// The helper documents itself as general over sign — the magnitude picks the form. A
/// chunk count is never negative, so nothing in the app exercises this; the assertion is
/// what stops the doc comment and the code drifting apart.
@Test(arguments: [
    (1, "фрагмент"),
    (2, "фрагмента"),
    (4, "фрагмента"),
    (5, "фрагментов"),
    (11, "фрагментов"),
    (13, "фрагментов"),
    (21, "фрагмент"),
    (22, "фрагмента"),
    (100, "фрагментов"),
])
func negativeCountsTakeTheSameFormAsTheirMagnitude(magnitude: Int, expected: String) {
    #expect(RussianCopy.plural(-magnitude, "фрагмент", "фрагмента", "фрагментов") == expected)
    // Paired with the positive twin in the same test, so the claim under scrutiny is
    // "sign does not matter" rather than two independent tables that could both be wrong.
    #expect(RussianCopy.plural(magnitude, "фрагмент", "фрагмента", "фрагментов") == expected)
}

/// `abs(Int.min)` traps, which is why the helper takes `% 100` *before* `abs`. Reordering
/// those two operations turns a hint into a crash, and this is the only thing that would
/// notice.
@Test func extremeCountsDoNotTrap() {
    // Int.min ends in …08 and Int.max in …07; both land in the "many" branch.
    #expect(RussianCopy.plural(Int.min, "один", "два", "много") == "много")
    #expect(RussianCopy.plural(Int.max, "один", "два", "много") == "много")
}

@Test func pluralHelperIsNotTiedToOneNoun() {
    #expect(RussianCopy.plural(1, "термин", "термина", "терминов") == "термин")
    #expect(RussianCopy.plural(13, "термин", "термина", "терминов") == "терминов")
    #expect(RussianCopy.plural(22, "термин", "термина", "терминов") == "термина")
}
