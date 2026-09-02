import Testing
import Foundation
@testable import TranslationCore

// The gate is what makes the «Оформить» pass safe to run on a local model: the model may add
// structure and may change nothing else. Every expected value here is a hand-written pair —
// what a flat text looked like, what a model might send back — never something computed the
// way the gate computes it.

/// The case the whole step exists for: a table that reached the app one cell per line comes
/// back as rows. Line breaks are whitespace to the gate, so cells that stood on their own lines
/// may join into a row.
@Test func aTableReconstructedFromOneCellPerLineIsAccepted() {
    let source = "Folder\nSource repository\n/nova\nprofile-nova\n/server\nprofile-server"
    let formatted = """
        | Folder | Source repository |
        | --- | --- |
        | /nova | profile-nova |
        | /server | profile-server |
        """
    #expect(FormattingGate.verify(source: source, formatted: formatted) == nil)
}

@Test func headingsListsAndCodeMarkersAreStructureAndAreAccepted() {
    let source = "What is proposed\nPut the repos in one place.\nThe steps:\nstop the workers\nrun deploy.sh\nprofile-k8s-tests is excluded."
    let formatted = """
        # What is proposed

        Put the repos in one place.

        The steps:

        - stop the workers
        - run `deploy.sh`

        `profile-k8s-tests` is excluded.
        """
    #expect(FormattingGate.verify(source: source, formatted: formatted) == nil)
}

@Test func aFencedBlockAddedAroundVerbatimLinesIsAccepted() {
    let source = "Run this:\nswift build\nswift test\nThen commit."
    let formatted = "Run this:\n\n```\nswift build\nswift test\n```\n\nThen commit."
    #expect(FormattingGate.verify(source: source, formatted: formatted) == nil)
}

/// One changed letter is a rewrite, and a rewrite is refused however good the table is.
@Test func aChangedWordIsRejected() {
    let source = "The build is unchanged.\nProfile still ships with Server."
    let formatted = "# The build is unchanged.\n\nProfile still ships with Servers."
    #expect(FormattingGate.verify(source: source, formatted: formatted) == .wordsChanged)
}

@Test func anAddedWordIsRejected() {
    let source = "Folder\n/nova"
    #expect(FormattingGate.verify(source: source, formatted: "| Folder | Trunk |\n| --- | --- |\n| /nova | main |")
            == .wordsChanged)
}

@Test func aDroppedLineIsRejected() {
    let source = "One\nTwo\nThree"
    #expect(FormattingGate.verify(source: source, formatted: "- One\n- Three") == .wordsChanged)
}

@Test func reorderedLinesAreRejected() {
    let source = "One\nTwo\nThree"
    #expect(FormattingGate.verify(source: source, formatted: "- One\n- Three\n- Two") == .wordsChanged)
}

/// Punctuation is a word here: a model that «fixes» a full stop has edited the text.
@Test func aChangedPunctuationMarkIsRejected() {
    let source = "Is it ready\nYes"
    #expect(FormattingGate.verify(source: source, formatted: "Is it ready?\n\nYes") == .wordsChanged)
}

/// Half a table is worse than none — the pane would draw a row with cells missing.
@Test func aTableWithUnevenRowsIsRejected() {
    let source = "Folder\nTrunk\n/nova\nmain\n/server"
    let formatted = "| Folder | Trunk |\n| --- | --- |\n| /nova | main |\n| /server |"
    #expect(FormattingGate.verify(source: source, formatted: formatted) == .unevenTable)
}

@Test func anEmptyReplyIsRejected() {
    #expect(FormattingGate.verify(source: "Some text", formatted: "   \n") == .empty)
}

// MARK: - The forbidden forms are taken off before the gate, not failed on

/// Emphasis is the form these models are measurably worst with (design §2, series B), so the
/// pass is not allowed it — but a model that adds a `**` anyway has not changed a word, and the
/// user should not lose a good table over it. The markers come off; the words stay.
@Test func emphasisTheModelAddedIsStrippedAndTheWordsSurvive() {
    #expect(FormattingGate.stripForbidden("Out of **scope**: the *release* calendar and __deployment__.")
            == "Out of scope: the release calendar and deployment.")
}

@Test func aLinkTheModelAddedIsReducedToItsText() {
    #expect(FormattingGate.stripForbidden("See [the repo](https://example.org) today.")
            == "See the repo today.")
}

/// Code is one of the four allowed forms; its backticks stay exactly where the model put them.
@Test func inlineCodeAndFencesSurviveTheStrip() {
    let text = "Run `swift build` first.\n\n```sh\n**not emphasis** inside code\n```\n\nDone."
    #expect(FormattingGate.stripForbidden(text) == text)
}

/// Block syntax is not the strip's business: headings, pipes and list markers pass through as
/// characters, so the table the gate is about to check is still a table.
@Test func blockMarkersAreUntouchedByTheStrip() {
    let text = "# Title\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n- item\n\n> quote"
    #expect(FormattingGate.stripForbidden(text) == text)
}
