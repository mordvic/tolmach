import Testing
import Foundation
import TranslationCore
@testable import QualityKit

/// The committed corpus, read from the package root — `swift test`'s working directory, the
/// same assumption `DocumentationTests` makes.
private func styleCorpus() throws -> [CorpusItem] {
    try CorpusLoader.load(directory: URL(fileURLWithPath: "quality-corpus/style"))
}

@Test func theStyleCorpusIsTenMirroredPairsAndEveryMirrorExists() throws {
    let items = try styleCorpus()
    #expect(items.count == 20)
    #expect(items.filter { $0.language == .ru }.count == 10)
    let names = Set(items.map(\.name))
    for item in items {
        let mirror = try #require(item.meta?.mirror, "\(item.name) has no sidecar or names no mirror")
        #expect(names.contains(mirror), "\(item.name) names a mirror that is not in the corpus: \(mirror)")
    }
}

@Test func everyLiteralFactIsPresentInItsOwnSourceText() throws {
    // A literal fact the source itself does not contain would be reported lost by every reply
    // there will ever be — a sidecar typo that reads as a model's failure.
    for item in try styleCorpus() {
        #expect(MechanicalChecks.missingFacts(item.facts, in: item.text) == [],
                "\(item.name): its own text lacks a literal fact its sidecar lists")
        for fact in item.facts where fact.kind == .literal {
            #expect(!fact.anyOf.isEmpty, "\(item.name): literal fact \(fact.id) has no spellings")
        }
    }
}

@Test func everyCorpusTextPassesItsOwnMechanicsWhenReturnedUntouched() throws {
    // The source, handed back as the reply, must be idle and carry no flag: whatever this
    // reports is a defect in the text, the sidecar or a check — not in a model.
    for item in try styleCorpus() {
        let m = MechanicalChecks.evaluate(source: item.text, reply: item.text, expectedLanguage: item.language,
                                          sameLanguage: true, facts: item.facts)
        #expect(m.idle, "\(item.name) is not idle against itself")
        #expect(m.flags == [], "\(item.name) flags itself: \(m.flags)")
    }
}

@Test func theProofreadingGateLoadsAsItIsWithoutSidecars() throws {
    let items = try CorpusLoader.load(directory: URL(fileURLWithPath: "docs/proofreading-gate"))
    #expect(items.count == 12)
    #expect(items.allSatisfy { $0.meta == nil })
}
