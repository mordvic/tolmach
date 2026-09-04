import Testing
import Foundation
@testable import TranslationCore

// `ExplanationGate` is the whole of the trust placed in an explanation reply — the
// `FormattingGate` pattern, applied to a much smaller and much more structured reply. Every
// expected value here is hand-written, never something computed the way the gate computes it.

@Test func aWellFormedReplyIsAcceptedWithEveryIndex() {
    let reply = "1: Fixed a missing comma.\n2: Corrected the verb form."
    let result = ExplanationGate.parse(reply, changeCount: 2)
    #expect(result == .success([1: "Fixed a missing comma.", 2: "Corrected the verb form."]))
}

/// Blank lines between entries are tolerated — the rule is "one line per change", and spacing
/// between them has not added prose.
@Test func blankLinesBetweenEntriesAreTolerated() {
    let reply = "1: Fixed a missing comma.\n\n2: Corrected the verb form.\n"
    let result = ExplanationGate.parse(reply, changeCount: 2)
    #expect(result == .success([1: "Fixed a missing comma.", 2: "Corrected the verb form."]))
}

@Test func anEmptyReplyIsRejectedAsEmpty() {
    #expect(ExplanationGate.parse("   \n\n  ", changeCount: 2) == .failure(.empty))
}

/// Only one of the two indices came back — the model dropped a line.
@Test func aMissingIndexIsRejected() {
    let reply = "1: Fixed a missing comma."
    #expect(ExplanationGate.parse(reply, changeCount: 2) == .failure(.missingIndex))
}

@Test func aDuplicateIndexIsRejected() {
    let reply = "1: Fixed a missing comma.\n1: Said it again."
    #expect(ExplanationGate.parse(reply, changeCount: 2) == .failure(.duplicateIndex))
}

@Test func anOutOfRangeIndexIsRejected() {
    let reply = "1: Fixed a missing comma.\n3: This index does not exist."
    #expect(ExplanationGate.parse(reply, changeCount: 2) == .failure(.outOfRangeIndex))
}

/// The reply is asked for plain prose; markup is read as content, not rendered, so a sentence
/// carrying it is refused rather than silently stripped — unlike `FormattingGate`, which strips
/// forbidden forms from a *document* the app still wants. There is no document to salvage here.
@Test func aSentenceCarryingMarkdownEmphasisIsRejected() {
    let reply = "1: Fixed **a missing comma**.\n2: Corrected the verb form."
    #expect(ExplanationGate.parse(reply, changeCount: 2) == .failure(.markdownMarkers))
}

@Test func anOverLongSentenceIsRejected() {
    let long = String(repeating: "a", count: ExplanationGate.maxSentenceLength + 1)
    let reply = "1: \(long)\n2: Corrected the verb form."
    #expect(ExplanationGate.parse(reply, changeCount: 2) == .failure(.sentenceTooLong))
}

/// A sentence sitting exactly at the cap is not rejected — only strictly past it is.
@Test func aSentenceExactlyAtTheCapIsAccepted() {
    let exact = String(repeating: "a", count: ExplanationGate.maxSentenceLength)
    let reply = "1: \(exact)\n2: Corrected the verb form."
    #expect(ExplanationGate.parse(reply, changeCount: 2).isSuccess)
}

@Test func anEmptySentenceIsRejected() {
    let reply = "1:\n2: Corrected the verb form."
    #expect(ExplanationGate.parse(reply, changeCount: 2) == .failure(.emptySentence))
}

/// A line that is not blank and does not parse as "N: sentence" — a stray remark the reply was
/// told not to add.
@Test func anExtraProseLineIsRejected() {
    let reply = "1: Fixed a missing comma.\n2: Corrected the verb form.\nHope this helps!"
    #expect(ExplanationGate.parse(reply, changeCount: 2) == .failure(.extraProse))
}

/// A partial-looking failure must still fail the *whole* reply — the gate never returns a
/// dictionary on any rejection path. Mutating any one `.failure` branch above into
/// `.success(accepted)` (returning what had been parsed so far) is exactly the defect this
/// pins: the return type itself does not prevent it, only every branch actually doing it does.
@Test func aRejectedReplyNeverCarriesAPartialResult() {
    let reply = "1: Fixed a missing comma.\nsome stray remark\n2: Corrected the verb form."
    guard case let .failure(reason) = ExplanationGate.parse(reply, changeCount: 2) else {
        Issue.record("expected a rejection"); return
    }
    #expect(reason == .extraProse)
}

// MARK: - skipReason

@Test func zeroChangesSkipsBeforeAnyCallWouldBeMade() {
    #expect(ExplanationGate.skipReason(changeCount: 0, materialCharacters: 0) == .noChanges)
}

@Test func moreChangesThanTheCapSkips() {
    let reason = ExplanationGate.skipReason(changeCount: ExplanationGate.maxChangeCount + 1,
                                            materialCharacters: 10)
    #expect(reason == .tooManyChanges(count: ExplanationGate.maxChangeCount + 1,
                                      cap: ExplanationGate.maxChangeCount))
}

/// The cap itself is not "too many" — only strictly past it is.
@Test func exactlyTheCapDoesNotSkip() {
    #expect(ExplanationGate.skipReason(changeCount: ExplanationGate.maxChangeCount,
                                       materialCharacters: 10) == nil)
}

@Test func materialOverTheCharacterBudgetSkips() {
    let reason = ExplanationGate.skipReason(changeCount: 3,
                                            materialCharacters: ExplanationGate.maxMaterialCharacters + 1)
    #expect(reason == .tooLongForOneRequest(characters: ExplanationGate.maxMaterialCharacters + 1,
                                            limit: ExplanationGate.maxMaterialCharacters))
}

@Test func aSmallChangeSetWellUnderBudgetDoesNotSkip() {
    #expect(ExplanationGate.skipReason(changeCount: 3, materialCharacters: 200) == nil)
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
