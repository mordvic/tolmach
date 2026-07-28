import Testing
import Foundation

/// Documentation drift, made to fail the way everything else in this project fails.
///
/// Two rules here are obeyed without exception — zero warnings and green tests — because both
/// fail loudly. Nothing else is. `CLAUDE.md` and the design spec each said "five SwiftPM
/// targets" and named `AppSettings` as one of them; there is no such target, and the error
/// survived in two documents at once because nothing could notice it.
///
/// Deliberately narrow: **names and numbers only, never prose.** A test that checks whether a
/// paragraph is still true rots, gets deleted the first time it is inconvenient, and takes the
/// mechanism with it.
enum RepoRoot {
    /// Derived from `#filePath`, not `currentDirectoryPath`. `swift run acceptance` already has
    /// a working-directory dependency that caught someone out; a test that only passes when run
    /// from one place would be a second instance of the same trap.
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DocumentationTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    static func read(_ relative: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }
}

/// The non-test targets `Package.swift` declares, in declaration order.
private func declaredTargets() throws -> [String] {
    let manifest = try RepoRoot.read("Package.swift")
    var names: [String] = []
    for line in manifest.split(separator: "\n") {
        // `.testTarget` is excluded on purpose: the architecture block documents the shipping
        // targets, and listing test targets there would make the documentation churn whenever
        // a test target is added.
        guard line.contains(".target(name:") || line.contains(".executableTarget(name:") else { continue }
        guard let open = line.range(of: "name: \""),
              let close = line[open.upperBound...].firstIndex(of: "\"") else { continue }
        names.append(String(line[open.upperBound..<close]))
    }
    return names
}

@Test func claudeMdNamesEveryTargetPackageSwiftDeclares() throws {
    let claude = try RepoRoot.read("CLAUDE.md")
    let targets = try declaredTargets()
    #expect(targets.count >= 6, "the manifest parser found \(targets.count) targets, which is too few to be right")

    for target in targets {
        #expect(claude.contains(target),
                "CLAUDE.md's architecture section does not mention the `\(target)` target")
    }
}

@Test func claudeMdStatesTheRightNumberOfTargets() throws {
    // The specific error that occurred, twice: a hand-written count that nothing recomputed.
    // Written as a digit rather than a word so this comparison is unambiguous.
    let claude = try RepoRoot.read("CLAUDE.md")
    let count = try declaredTargets().count
    #expect(claude.contains("\(count) SwiftPM targets"),
            "CLAUDE.md does not say «\(count) SwiftPM targets»; Package.swift declares \(count)")
}

@Test func claudeMdInventsNoTargetsOfItsOwn() throws {
    // The other half of the same error: `AppSettings` was named as a target for weeks. It is a
    // file inside `TranslatorApp`. Anything in backticks in the architecture block that looks
    // like a target name must actually be one.
    let claude = try RepoRoot.read("CLAUDE.md")
    let targets = Set(try declaredTargets())
    guard let start = claude.range(of: "## Architecture"),
          let end = claude.range(of: "\n## ", range: start.upperBound..<claude.endIndex)
    else {
        Issue.record("could not locate the Architecture section in CLAUDE.md")
        return
    }
    let section = String(claude[start.upperBound..<end.lowerBound])

    // Only the lines that read as a target roster — the fenced diagram — are checked. Prose in
    // the section names types and files too, and those are not targets.
    guard let fenceStart = section.range(of: "```"),
          let fenceEnd = section.range(of: "```", range: fenceStart.upperBound..<section.endIndex)
    else {
        Issue.record("the Architecture section has no fenced diagram to check")
        return
    }
    let diagram = section[fenceStart.upperBound..<fenceEnd.lowerBound]

    // A token is target-shaped if it is a bare identifier at the start of a diagram entry.
    let suspects = diagram
        .split(whereSeparator: { " \t\n↑·()".contains($0) })
        .map(String.init)
        .filter { $0.first?.isLetter == true && $0.allSatisfy { $0.isLetter || $0 == "-" } }
        .filter { $0.first?.isUppercase == true || $0.contains("-") }

    for suspect in Set(suspects) where !targets.contains(suspect) {
        // Words that are plainly prose rather than a roster entry.
        let prose = ["SwiftUI", "Foundation", "NaturalLanguage", "Ollama", "pure", "domain",
                     "depends", "on", "nothing", "but", "independent", "no"]
        guard !prose.contains(suspect) else { continue }
        Issue.record("the architecture diagram names `\(suspect)`, which is not a target in Package.swift")
    }
}

/// The two numbers the acceptance harness gates on, read out of the harness itself.
private func gateConstants() throws -> (ttftMS: Int, adherencePercent: Int) {
    let source = try RepoRoot.read("Sources/acceptance/main.swift")
    // Matched against the comparison, not a bare literal, so an unrelated 80 or 1000 elsewhere
    // in the file cannot satisfy this.
    func number(after needle: String) -> Int? {
        guard let range = source.range(of: needle) else { return nil }
        let digits = source[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
    guard let ttft = number(after: "ttft >= "), let adherence = number(after: "average < ") else {
        Issue.record("""
            could not find the gate comparisons in Sources/acceptance/main.swift; \
            if the harness was rewritten, teach this test the new shape
            """)
        return (0, 0)
    }
    return (ttft, adherence)
}

@Test func theBaselineLogQuotesTheThresholdsTheHarnessActuallyUses() throws {
    // A baseline that names a ceiling the harness no longer enforces is worse than one that
    // names none: it invites a reader to compare a run against a number nothing checks.
    let (ttft, adherence) = try gateConstants()
    let baseline = try RepoRoot.read("docs/BASELINE.md")
    #expect(baseline.contains("\(ttft) ms"),
            "docs/BASELINE.md does not mention the \(ttft) ms TTFT ceiling the harness gates on")
    #expect(baseline.contains("\(adherence) %") || baseline.contains("\(adherence)%"),
            "docs/BASELINE.md does not mention the \(adherence)% adherence floor the harness gates on")
}
