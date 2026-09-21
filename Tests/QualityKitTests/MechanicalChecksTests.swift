import Testing
import Foundation
import TranslationCore
@testable import QualityKit

// MARK: digits

@Test func aNumberThatSurvivesOnlyInsideALongerNumberIsReportedMissing() {
    // The defect a substring search has: «15» is "found" inside «2015».
    let missing = MechanicalChecks.missingNumbers(source: "Сдать до 15 марта.",
                                                  reply: "Сдать в 2015 году.")
    #expect(missing == ["15"])
}

@Test func aRegroupedThousandIsTheSameNumber() {
    // «10 000» → «10,000» is what a translation into English does, and «1 500» → «1500» is
    // what a rewrite may do; neither lost anything.
    #expect(MechanicalChecks.missingNumbers(source: "Бюджет 10 000 рублей и 1 500 штук.",
                                            reply: "A budget of 10,000 roubles and 1500 units.") == [])
}

@Test func aDroppedNumberIsNamedOnceHoweverOftenTheSourceSaidIt() {
    let missing = MechanicalChecks.missingNumbers(source: "Версия 3, снова версия 3, порт 8080.",
                                                  reply: "Порт 8080.")
    #expect(missing == ["3"])
}

// MARK: literal facts

private let facts = [
    ItemMeta.Fact(id: "deadline", kind: .literal, note: "the deadline", anyOf: ["15 марта", "March 15"]),
    ItemMeta.Fact(id: "owner", kind: .literal, note: "who owns it", anyOf: ["Анна Серова", "Anna Serova"]),
    ItemMeta.Fact(id: "reason", kind: .semantic, note: "why it slipped", anyOf: []),
]

@Test func aLiteralFactIsPresentInAnyOfItsSpellingsWhateverTheCase() {
    let reply = "The report is due on march 15; Anna Serova owns it."
    #expect(MechanicalChecks.missingFacts(facts, in: reply) == [])
}

@Test func aLiteralFactAbsentInEverySpellingIsNamedByItsID() {
    #expect(MechanicalChecks.missingFacts(facts, in: "The report is due soon; Anna Serova owns it.")
            == ["deadline"])
}

@Test func aSemanticFactIsNeverJudgedByMechanics() {
    // It has no spellings to look for; reporting it missing would put a judge's question
    // into a column that claims to be deterministic.
    #expect(!MechanicalChecks.missingFacts(facts, in: "").contains("reason"))
}

@Test func aNoBreakSpaceInTheReplyDoesNotHideAFact() {
    #expect(MechanicalChecks.missingFacts(facts, in: "Срок — 15\u{00A0}марта, отвечает Анна Серова.") == [])
}

// MARK: the whole evaluation

@Test func aReplyEqualToItsSourceTokenForTokenIsIdle() {
    // A collapsed double space is not a change — `TextTokenizer`'s rule, which is the pane's.
    let m = MechanicalChecks.evaluate(source: "Привет,  как дела у команды сегодня?",
                                      reply: "Привет, как дела у команды сегодня?",
                                      expectedLanguage: .ru, sameLanguage: true, facts: [])
    #expect(m.idle)
    #expect(m.shift == 0)
}

@Test func aRewordedReplyIsNotIdleAndItsShiftIsChangedTokensOverAllTokens() throws {
    // One word of four replaced: one removed plus one inserted, over four plus four.
    let m = MechanicalChecks.evaluate(source: "Мы получили ваше письмо",
                                      reply: "Мы прочитали ваше письмо",
                                      expectedLanguage: .ru, sameLanguage: true, facts: [])
    #expect(!m.idle)
    #expect(try #require(m.shift) == 0.25)
}

@Test func aTranslationHasNoShiftAndIsIdleOnlyWhenItCameBackUntranslated() {
    let translated = MechanicalChecks.evaluate(source: "Мы получили ваше письмо и ответим завтра.",
                                               reply: "We received your letter and will reply tomorrow.",
                                               expectedLanguage: .en, sameLanguage: false, facts: [])
    #expect(translated.shift == nil)
    #expect(!translated.idle)
    #expect(translated.languageOK)

    let untouched = MechanicalChecks.evaluate(source: "Мы получили ваше письмо и ответим завтра.",
                                              reply: "Мы получили ваше письмо и ответим завтра.",
                                              expectedLanguage: .en, sameLanguage: false, facts: [])
    #expect(untouched.idle)
    #expect(!untouched.languageOK)
    #expect(untouched.replyLanguage == "ru")
}

@Test func aQuestionAnsweredInsteadOfKeptShowsAsALostQuestionMark() {
    let m = MechanicalChecks.evaluate(source: "Сможете ли вы прислать отчёт до пятницы?",
                                      reply: "Да, конечно, я пришлю отчёт до пятницы.",
                                      expectedLanguage: .ru, sameLanguage: true, facts: [])
    #expect(m.sourceQuestions == 1)
    #expect(m.replyQuestions == 0)
    #expect(m.flags.contains(.lostQuestion))
}

@Test func aReplyHalfAsLongOrTwiceAsLongIsFlaggedAndOneInBetweenIsNot() {
    let source = "один два три четыре пять шесть семь восемь"
    let short = MechanicalChecks.evaluate(source: source, reply: "один два три",
                                          expectedLanguage: .ru, sameLanguage: true, facts: [])
    #expect(short.flags.contains(.lengthOutOfRange))
    let fine = MechanicalChecks.evaluate(source: source, reply: "один два три четыре пять шесть",
                                         expectedLanguage: .ru, sameLanguage: true, facts: [])
    #expect(!fine.flags.contains(.lengthOutOfRange))
}

@Test func anEmptyReplyIsItsOwnFlagAndNotAShortOne() {
    let m = MechanicalChecks.evaluate(source: "Текст, который модель не вернула вовсе.", reply: "  \n",
                                      expectedLanguage: .ru, sameLanguage: true, facts: [])
    #expect(m.flags == [.emptyReply])
}

@Test func aCleanReplyCarriesNoFlags() {
    let m = MechanicalChecks.evaluate(source: "Отчёт за 2026 год готов, его подготовила Анна Серова.",
                                      reply: "Анна Серова подготовила отчёт за 2026 год — он готов.",
                                      expectedLanguage: .ru, sameLanguage: true, facts: facts.filter { $0.id == "owner" })
    #expect(m.flags == [])
}
