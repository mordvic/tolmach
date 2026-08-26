import Testing
import Foundation
@testable import TranslationCore

/// The pre-2026-08-26 alignment, verbatim: a dense `(want+1) × (got+1)` matrix over the *whole*
/// sequences, with no early-out, no trimming and no ceiling. Kept here so the version that has
/// all three can be checked against the one this project's output was calibrated on, rather
/// than against a claim in a comment.
private func legacyDiff(_ want: [MarkupToken], _ got: [MarkupToken]) -> [MarkupDiff] {
    var lcs = Array(repeating: Array(repeating: 0, count: got.count + 1), count: want.count + 1)
    if !want.isEmpty && !got.isEmpty {
        for i in stride(from: want.count - 1, through: 0, by: -1) {
            for j in stride(from: got.count - 1, through: 0, by: -1) {
                lcs[i][j] = want[i] == got[j] ? lcs[i + 1][j + 1] + 1
                                              : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
    }
    var diffs: [MarkupDiff] = []
    var i = 0, j = 0
    while i < want.count && j < got.count {
        if want[i] == got[j] { i += 1; j += 1 }
        else if lcs[i + 1][j] >= lcs[i][j + 1] {
            diffs.append(MarkupDiff(expected: want[i], actual: nil, note: "dropped in translation")); i += 1
        } else {
            diffs.append(MarkupDiff(expected: nil, actual: got[j], note: "added in translation")); j += 1
        }
    }
    while i < want.count {
        diffs.append(MarkupDiff(expected: want[i], actual: nil, note: "dropped in translation")); i += 1
    }
    while j < got.count {
        diffs.append(MarkupDiff(expected: nil, actual: got[j], note: "added in translation")); j += 1
    }
    return diffs
}

/// A deterministic generator, so a failure is reproducible and CI cannot flake.
private struct Rng {
    var seed: UInt64 = 0x5DEECE66D
    mutating func next(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return n == 0 ? 0 : Int((seed >> 33) % UInt64(n))
    }
}

private func key(_ diff: MarkupDiff) -> String {
    "\(String(describing: diff.expected))→\(String(describing: diff.actual))"
}

/// **What trimming the common prefix and suffix does and does not preserve.**
///
/// The first version of this change asserted, in a comment, that trimming was output-preserving
/// because `MarkupDiff` carries no positions. Checked against the old algorithm over 4000
/// generated pairs, that is **false**: 427 of them produce a different script. What is true, and
/// is what this test pins, is that the script is always the same *length* and always the same
/// *multiset* — only the order in which equally-minimal edits are listed can change.
///
/// That distinction is the whole reason the check exists. `WarningsView` shows a count and a
/// list, and `acceptance` aggregates diffs into a dictionary keyed by `(expected, actual)` and
/// counts them — so both are indifferent to order and neither is indifferent to content or
/// count. A change that altered either would move this project's calibrated baseline silently.
@Test func trimmingChangesTheOrderOfEquallyMinimalEditsAndNothingElse() {
    let alphabet: [MarkupToken] = [
        .paragraphBreak, .heading(level: 1), .heading(level: 2), .listItem(depth: 0),
        .listItem(depth: 1), .blockquote, .tableRow, .hardLineBreak,
        .url(bare: true), .url(bare: false), .inlineCode("a"), .inlineCode("b"),
    ]
    var rng = Rng()
    var cases = 0, differentOrder = 0

    for _ in 0..<4000 {
        let want = (0..<rng.next(14)).map { _ in alphabet[rng.next(alphabet.count)] }
        var got = (0..<rng.next(14)).map { _ in alphabet[rng.next(alphabet.count)] }
        // Half the pairs are given a shared prefix and suffix, which is what the trim targets
        // and what a real translation of a real document overwhelmingly looks like.
        if rng.next(2) == 0 && !want.isEmpty {
            got = Array(want.prefix(rng.next(want.count + 1))) + got
                + Array(want.suffix(rng.next(want.count + 1)))
        }
        cases += 1

        let new = MarkupSkeleton.compare(want: want, got: got)
        let old = legacyDiff(want, got)

        #expect(new.notCompared == nil, "nothing this small may be refused")
        #expect(new.diffs.count == old.count,
                "the number of reported diffs changed for \(want) vs \(got)")
        #expect(new.diffs.map(key).sorted() == old.map(key).sorted(),
                "the reported diffs themselves changed for \(want) vs \(got)")
        if new.diffs != old { differentOrder += 1 }
    }

    #expect(cases == 4000)
    // Asserted, not merely observed: if this ever reaches zero the generator has stopped
    // producing the shared-prefix shapes, and the test above would be passing vacuously.
    #expect(differentOrder > 0, "the generator no longer exercises the case this test is about")
}

// MARK: - The ceiling

/// The defect. `diff()` allocated a dense `(want+1) × (got+1)` matrix of `Int` before its only
/// guard, with no early-out, no trimming and no ceiling — quadratic in token count, on the
/// unconditional tail of both routes, for a queue that accepts 2 MB files. A fully-bulleted 2 MB
/// changelog is on the order of 100 000 tokens a side: ~80 GB and ~10¹⁰ iterations, on a 48 GB
/// machine, at the very end of an otherwise successful run.
@Test func twoLargeAndWhollyDifferentSkeletonsAreRefusedRatherThanAligned() {
    let want = Array(repeating: MarkupToken.listItem(depth: 0), count: 6000)
    let got = Array(repeating: MarkupToken.tableRow, count: 6000)   // 36M cells > the ceiling

    let comparison = MarkupSkeleton.compare(want: want, got: got)

    #expect(comparison.notCompared?.sourceTokens == 6000)
    #expect(comparison.notCompared?.translationTokens == 6000)
    // **Not an empty diff list read as «no problems».** The whole point of the separate signal.
    #expect(comparison.diffs.isEmpty)
}

/// And the ceiling is reached only after trimming, so a large document whose structure the
/// translation *kept* costs nothing at all — which is the case that actually occurs.
@Test func twoLargeSkeletonsThatAgreeAreComparedNoMatterHowLongTheyAre() {
    let skeleton = Array(repeating: MarkupToken.listItem(depth: 0), count: 100_000)

    let identical = MarkupSkeleton.compare(want: skeleton, got: skeleton)
    #expect(identical.notCompared == nil)
    #expect(identical.diffs.isEmpty)

    // One token changed in the middle of a hundred thousand: after the prefix and suffix are
    // trimmed away this is a comparison of one against one.
    var edited = skeleton
    edited[50_000] = .blockquote
    let oneEdit = MarkupSkeleton.compare(want: skeleton, got: edited)
    #expect(oneEdit.notCompared == nil)
    #expect(oneEdit.diffs.count == 2)   // one dropped, one added
}

/// A pure insertion or deletion needs no alignment to describe, so it is answered without a
/// matrix at all — and must not be refused by the ceiling for being long.
@Test func awhollyMissingOrWhollyAddedSkeletonIsDescribedWithoutAMatrix() {
    let skeleton = Array(repeating: MarkupToken.listItem(depth: 0), count: 50_000)

    let dropped = MarkupSkeleton.compare(want: skeleton, got: [])
    #expect(dropped.notCompared == nil)
    #expect(dropped.diffs.count == 50_000)
    #expect(dropped.diffs.allSatisfy { $0.actual == nil })

    let added = MarkupSkeleton.compare(want: [], got: skeleton)
    #expect(added.notCompared == nil)
    #expect(added.diffs.count == 50_000)
    #expect(added.diffs.allSatisfy { $0.expected == nil })
}
