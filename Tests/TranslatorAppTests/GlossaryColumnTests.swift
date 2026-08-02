import Testing
@testable import TranslatorApp
@testable import TranslationCore

private func entry(_ term: String, _ translations: [String: String] = [:],
                   doNotTranslate: Bool = false) -> GlossaryEntry {
    GlossaryEntry(term: term, doNotTranslate: doNotTranslate, translations: translations)
}

// MARK: - The defect this exists for

/// The case that was actually on screen, and the reason this type exists.
///
/// A default install is `primaryLanguage = ru`, `workingLanguage = en`. Point the app at
/// English text and `targetLanguage(forDetected:)` translates it **into** Russian, so the
/// glossary fills up with `translations["ru"]`. The pane defaulted to `workingLanguage`, i.e.
/// the `en` column, and every «перевод» field rendered blank — with no indication why, since
/// the language picker is `.labelsHidden()`.
@Test func aGlossaryWrittenIntoTheUsersOwnLanguageShowsThatLanguage() {
    let entries = [entry("profile server", ["ru": "сервер профилей"]),
                   entry("endpoint", ["ru": "конечная точка"]),
                   entry("payload", ["ru": "полезная нагрузка"])]
    #expect(GlossaryColumn.language(for: entries, fallback: .ru) == .ru)
}

/// The other direction, and the reason the rule reads the glossary rather than swapping one
/// hardcoded setting for another. A user who writes Russian and translates it to English
/// accumulates `en` entries; naming `primaryLanguage` as the default outright would have shown
/// them a blank `ru` column — the same defect, mirrored.
@Test func aGlossaryWrittenIntoTheSecondLanguageShowsThatOneInstead() {
    let entries = [entry("сервер профилей", ["en": "profile server"]),
                   entry("конечная точка", ["en": "endpoint"])]
    #expect(GlossaryColumn.language(for: entries, fallback: .ru) == .en)
}

/// A third language nobody configured. The rule is «what the glossary is written in», not
/// «one of the two languages in settings», and a user translating into German should see the
/// German column without touching the picker.
@Test func aLanguageOutsideTheSettingsStillWins() {
    let entries = [entry("endpoint", ["de": "Endpunkt"]), entry("payload", ["de": "Nutzlast"])]
    #expect(GlossaryColumn.language(for: entries, fallback: .ru) == .de)
}

// MARK: - When the glossary cannot decide

/// An empty glossary is the first-launch case. The fallback is the language the app translates
/// into by default, so the first term a user adds has its field under the right column.
@Test func anEmptyGlossaryTakesTheFallback() {
    #expect(GlossaryColumn.language(for: [], fallback: .ru) == .ru)
    #expect(GlossaryColumn.language(for: [], fallback: .en) == .en)
}

/// Terms with no translations at all — «Добавить термин» appends exactly this.
@Test func entriesWithNoTranslationsTakeTheFallback() {
    #expect(GlossaryColumn.language(for: [entry(""), entry("endpoint")], fallback: .ru) == .ru)
}

/// A tie goes to the fallback, and this is the case that decides it: one entry each way on a
/// default install is a user who mostly translates into their own language and has one entry
/// going the other direction.
@Test func aTieGoesToTheFallback() {
    let entries = [entry("endpoint", ["ru": "конечная точка"]),
                   entry("сервер", ["en": "server"])]
    #expect(GlossaryColumn.language(for: entries, fallback: .ru) == .ru)
    // And the fallback genuinely decides it rather than `ru` merely winning by luck.
    #expect(GlossaryColumn.language(for: entries, fallback: .en) == .en)
}

/// A tie between languages that are *none* of them the fallback still has to answer the same
/// way every time — `Dictionary` has no defined order, so an unsorted pick renders differently
/// between runs. Same trap `WarningsView.rendered` documents.
///
/// **This test is probabilistic and that is recorded rather than hidden.** Swift seeds its
/// hashing per process, so `leaders.first` returns some element of the tied set — which is the
/// correct one by luck. Measured against the mutation that replaces `leaders.min(by:)` with
/// `leaders.first`, eight languages tied, one fresh `swift test` process per run:
/// **caught 16 times out of 20**. What the four escapes had in common was not established;
/// the naive expectation is one escape in eight, and four in twenty is worse than that, so
/// the hash order is evidently not uniform over this input. Do not read the 16 as a rate to
/// rely on — read it as «usually, not always».
///
/// The same shape as `GlossaryOrder`'s own tiebreaker, whose comment records that no black-box
/// test catches its absence at all. This one at least usually does, and the reason it cannot
/// be made certain is a property of the language rather than of the assertion.
@Test func aTieWithNoFallbackAmongTheLeadersIsStillDeterministic() {
    // Every language except the fallback, one entry each, so nothing can win on count.
    let tied: [Language] = Language.allCases.filter { $0 != .ru }
    let entries = tied.map { entry("term-\($0.rawValue)", [$0.rawValue: "x"]) }
    let answers = (0..<50).map { _ in GlossaryColumn.language(for: entries, fallback: .ru) }
    // Within one process the answer must never vary — that much is certain either way.
    #expect(Set(answers).count == 1)
    // Lexicographically first of the tied set. This is the assertion the mutation has to beat.
    #expect(answers[0] == tied.min { $0.rawValue < $1.rawValue })
}

// MARK: - What a hand-edited file can contain

/// `glossary.json` is hand-editable and git-tracked by design, so it can hold a language code
/// this app has no column for. An unknown code must not win, and must not crash.
@Test func anUnknownLanguageCodeDoesNotVote() {
    let entries = [entry("a", ["klingon": "x", "tlh": "y"]), entry("b", ["ru": "б"])]
    #expect(GlossaryColumn.language(for: entries, fallback: .en) == .ru)
}

/// A blank translation is the absence of one. `GlossaryEntryRow` removes the key rather than
/// storing `""`, so a blank value can only have come from outside the app — and counting it
/// would let a column of empty fields win.
@Test func aBlankTranslationDoesNotVote() {
    let entries = [entry("a", ["en": "  ", "ru": "а"]), entry("b", ["en": ""])]
    #expect(GlossaryColumn.language(for: entries, fallback: .en) == .ru)
}

/// A «не переводить» entry is not evidence about which language the user works in: the engine
/// never consults its translations and the row's field is disabled. Ten disabled rows carrying
/// a leftover value must not hide the one live entry.
@Test func aDoNotTranslateEntryDoesNotVoteWithItsStaleTranslations() {
    var entries = (0..<10).map { entry("term\($0)", ["en": "stale"], doNotTranslate: true) }
    entries.append(entry("endpoint", ["ru": "конечная точка"]))
    #expect(GlossaryColumn.language(for: entries, fallback: .en) == .ru)
}
