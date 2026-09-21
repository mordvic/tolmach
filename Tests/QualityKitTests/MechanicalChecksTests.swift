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

// MARK: what the first live run taught the number check (2026-09-22, stage 1, 48 cells)

@Test func aSmallNumberSpelledOutInWordsIsNotLost() {
    // «extended by 1 month» → «by one month» was flagged 20 times in 20 replies; a rewrite
    // into a friendlier register does exactly this, and it loses nothing.
    #expect(MechanicalChecks.missingNumbers(source: "Extended by 1 month, up to 5 working days.",
                                            reply: "Extended by one month, up to five business days.") == [])
    #expect(MechanicalChecks.missingNumbers(source: "Продлена на 1 месяц, до 5 рабочих дней, 3 попытки.",
                                            reply: "Продлена на один месяц, до пяти рабочих дней, три попытки.") == [])
    // Twelve is where the words stop: «27 сделок» has no spelling anyone would write.
    #expect(MechanicalChecks.missingNumbers(source: "Все 27 сделок.", reply: "Все сделки.") == ["27"])
}

@Test func anAfternoonHourRewrittenOnTheTwelveHourClockIsNotLost() {
    // «10:00 to 19:00» → «10 a.m. to 7 p.m.», «16:30» → «4:30»: flagged 18 of 18.
    #expect(MechanicalChecks.missingNumbers(source: "Open from 10:00 to 19:00, club at 16:30.",
                                            reply: "Open from 10 a.m. to 7 p.m., club at 4:30.") == [])
    // Only an hour reads that way: «19 заявок» → «7 заявок» is a loss.
    #expect(MechanicalChecks.missingNumbers(source: "Пришло 19 заявок.", reply: "Пришло 7 заявок.") == ["19"])
}

@Test func aListOfThreeDigitNumbersIsNotOneLongNumber() {
    // The grouping reader fused «101,102,103» into 101102103 and then missed it in a reply
    // that kept all three.
    #expect(MechanicalChecks.missingNumbers(source: "Кабинеты 101,102,103 закрыты.",
                                            reply: "Закрыты кабинеты 101, 102 и 103.") == [])
    #expect(MechanicalChecks.missingNumbers(source: "Кабинеты 101,102,103 закрыты.",
                                            reply: "Закрыты кабинеты 101 и 103.") == ["101102103"])
}

@Test func aNumericFactIsAWholeNumberAndNotASubstring() {
    // The same defect `missingNumbers` was written to avoid, one function over: «64» inside
    // «1964», «500» inside «5000».
    let facts = [ItemMeta.Fact(id: "seats", kind: .literal, note: "64 workstations", anyOf: ["64"]),
                 ItemMeta.Fact(id: "line", kind: .literal, note: "a 500 Mbit line", anyOf: ["500"])]
    #expect(MechanicalChecks.missingFacts(facts, in: "Офис 1964 года, канал 5000 Мбит.") == ["seats", "line"])
    #expect(MechanicalChecks.missingFacts(facts, in: "64 места, канал 500 Мбит.") == [])
}

@Test func aReplyThatDiffersOnlyInsideAFenceIsNotIdle() {
    // `TextDiff` never compares code, so «no changes» was true of a reply that appended a
    // whole SQL block — the answered-instruction shape, reported as the model doing nothing.
    let source = "Напишите запрос, который вернёт всех клиентов."
    let reply = source + "\n\n```sql\nSELECT * FROM clients;\n```"
    let m = MechanicalChecks.evaluate(source: source, reply: reply, expectedLanguage: .ru,
                                      sameLanguage: true, facts: [])
    #expect(!m.idle)
}
