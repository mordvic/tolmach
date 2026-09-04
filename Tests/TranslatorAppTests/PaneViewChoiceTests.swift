// Tests/TranslatorAppTests/PaneViewChoiceTests.swift
import Testing
@testable import TranslationCore
@testable import TranslatorApp

// MARK: - Which segments exist

@Test func aTranslationWithMarkupOffersTheTwoSegmentsItAlwaysHad() {
    #expect(PaneViewChoice.segments(hasChanges: false, offersSource: true) == [.rendered, .source])
}

@Test func aProofreadWithMarkupOffersAllThreeSegments() {
    #expect(PaneViewChoice.segments(hasChanges: true, offersSource: true)
            == [.rendered, .changes, .source])
}

@Test func aPlainProseProofreadOffersResultAndChangesButNoSourceView() {
    // No markup anywhere, so «Исходник» would show the same characters as «Результат» minus
    // the underlines — a segment that does nothing. Mutation: dropping the `offersSource` guard
    // puts `.source` back and this fails.
    #expect(PaneViewChoice.segments(hasChanges: true, offersSource: false) == [.rendered, .changes])
}

// MARK: - Which segment the settings describe

@Test func theCurrentSegmentFollowsBothSettingsAndTheChangeSet() {
    // Six cells, each asserted on its own (TESTING.md shape 2): the combined assertion of a
    // table hides which cell moved.
    #expect(PaneViewChoice.current(showsRenderedMarkup: true, showsChangeDetail: false,
                                   hasChanges: true) == .rendered)
    #expect(PaneViewChoice.current(showsRenderedMarkup: true, showsChangeDetail: true,
                                   hasChanges: true) == .changes)
    #expect(PaneViewChoice.current(showsRenderedMarkup: false, showsChangeDetail: true,
                                   hasChanges: true) == .source)
    #expect(PaneViewChoice.current(showsRenderedMarkup: false, showsChangeDetail: false,
                                   hasChanges: true) == .source)
    // Without a change set the detail setting is ignored, whatever a previous правка left it
    // at: a перевод pane never draws «Изменения». Mutation: reading `showsChangeDetail` alone
    // answers `.changes` here and points the picker at a segment it does not offer.
    #expect(PaneViewChoice.current(showsRenderedMarkup: true, showsChangeDetail: true,
                                   hasChanges: false) == .rendered)
    #expect(PaneViewChoice.current(showsRenderedMarkup: true, showsChangeDetail: false,
                                   hasChanges: false) == .rendered)
}

// MARK: - What a segment writes

@Test func resultWritesRenderedOnAndDetailOff() {
    let writes = PaneViewChoice.rendered.writes
    #expect(writes.showsRenderedMarkup == true)
    #expect(writes.showsChangeDetail == false)
}

@Test func changesWritesRenderedOnAndDetailOn() {
    let writes = PaneViewChoice.changes.writes
    #expect(writes.showsRenderedMarkup == true)
    #expect(writes.showsChangeDetail == true)
}

@Test func sourceWritesRenderedOffAndLeavesTheDetailAlone() {
    // The spec's one non-obvious write: a reader on «Изменения» who peeks at «Исходник» and
    // comes back must land on «Изменения» again. Mutation: writing `false` here passes the
    // first assertion and fails the second.
    let writes = PaneViewChoice.source.writes
    #expect(writes.showsRenderedMarkup == false)
    #expect(writes.showsChangeDetail == nil)
}

@Test func everySegmentRoundTripsThroughTheSettingsItWrites() {
    // Apply each segment's writes to a pair of settings that started elsewhere, then read the
    // segment back: what the picker writes is what it then shows selected.
    for choice in PaneViewChoice.allCases {
        var rendered = choice == .source   // start on the other side
        var detail = choice != .changes
        let writes = choice.writes
        rendered = writes.showsRenderedMarkup
        if let value = writes.showsChangeDetail { detail = value }
        #expect(PaneViewChoice.current(showsRenderedMarkup: rendered, showsChangeDetail: detail,
                                       hasChanges: true) == choice,
                "\(choice) did not read back as itself")
    }
}

// MARK: - Labels

@Test func theFirstSegmentIsCalledResultOverAProofreadAndMarkupOverATranslation() {
    #expect(PaneViewChoice.rendered.label(hasChanges: true) == "Результат")
    #expect(PaneViewChoice.rendered.label(hasChanges: false) == "Разметка")
    #expect(PaneViewChoice.changes.label(hasChanges: true) == "Изменения")
    #expect(PaneViewChoice.source.label(hasChanges: true) == "Исходник")
}

// MARK: - The menu's rule

@Test func changeNavigationIsLiveOnlyInTextModeWithANonEmptySet() {
    let one = ChangeSet(changes: [TextChange(scope: .words, block: 0, insertedTokens: 0..<1,
                                             removed: "а", inserted: "б")],
                        blocks: [], notCompared: nil)
    let none = ChangeSet(changes: [], blocks: [], notCompared: nil)
    #expect(ChangeNavigation.isAvailable(mode: .text, changes: one))
    // Each false cause on its own line, so a mutation that drops one conjunct is seen.
    #expect(!ChangeNavigation.isAvailable(mode: .files, changes: one))
    #expect(!ChangeNavigation.isAvailable(mode: .text, changes: none))
    #expect(!ChangeNavigation.isAvailable(mode: .text, changes: nil))
}
