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
/// end in 1-4 but take the same form as 5-20.
@Test(arguments: [
    (1, "1 фрагмент"),
    (2, "2 фрагмента"),
    (4, "4 фрагмента"),
    (5, "5 фрагментов"),
    (11, "11 фрагментов"),
    (14, "14 фрагментов"),
    (21, "21 фрагмент"),
    (22, "22 фрагмента"),
    (25, "25 фрагментов"),
    (101, "101 фрагмент"),
    (111, "111 фрагментов"),
])
func chunkCountUsesTheRightPluralForm(count: Int, expected: String) {
    #expect(RussianCopy.chunkCount(count) == expected)
}

@Test func pluralHelperIsNotTiedToOneNoun() {
    #expect(RussianCopy.plural(1, "термин", "термина", "терминов") == "термин")
    #expect(RussianCopy.plural(13, "термин", "термина", "терминов") == "терминов")
    #expect(RussianCopy.plural(22, "термин", "термина", "терминов") == "термина")
}
