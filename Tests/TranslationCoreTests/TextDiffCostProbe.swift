import Foundation
import Testing
@testable import TranslationCore

/// Measurement protocol item 2 of the change-marks spec: what `TextDiff.changes` costs at the
/// sizes the app can hand it, so `inspectionLimit` and `blockTokenLimit` are set from a figure
/// rather than from the *start* values they shipped with.
///
/// **Not a test, and off unless asked for.** Its outcome is a number a person reads and writes
/// into `docs/reference/MEASUREMENTS.md` and into the two constants' comments; an assertion on
/// wall-clock time is a test that passes on a fast machine and fails on a slow one. Same
/// contract as `renderPreview`. Run it alone, on a quiet machine — not while Ollama is busy:
///
///     TEXT_DIFF_COST=1 swift test --filter textDiffCost
///
/// A standalone `Scripts/*.swift` probe cannot import the package's modules, which is why this
/// lives in the test target the way the render preview does.
///
/// The four shapes are the spec's: the 256 KB `DroppedDocument` ceiling of prose with 1 % of the
/// words changed; the same with every other word changed; one paragraph of 4 000 tokens reordered;
/// and 200 paragraphs each rewritten past the threshold. Each is timed five times and the
/// median is printed with the change set's outcome, so a bound that was hit is visible beside
/// the time it saved.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TEXT_DIFF_COST"] != nil))
func textDiffCost() {
    let words = ["отчёт", "август", "регион", "план", "выполнен", "таблица", "итог", "пятница",
                 "комментарии", "внизу", "вопросы", "напишите", "связи", "север", "юг", "данные"]
    func paragraph(_ n: Int, seed: Int) -> String {
        (0..<n).map { words[($0 * 7 + seed) % words.count] }.joined(separator: " ") + "."
    }
    // ~256 KB of prose: paragraphs of 60 words, until the byte ceiling.
    var source = ""
    var i = 0
    while source.utf8.count < 256 * 1024 {
        source += paragraph(60, seed: i) + "\n\n"
        i += 1
    }
    let sourceWords = source.split(separator: " ").count

    func changed(every step: Int) -> String {
        var k = 0
        return source.split(separator: " ", omittingEmptySubsequences: false).map { word in
            k += 1
            return k % step == 0 ? String(word) + "ъ" : String(word)
        }.joined(separator: " ")
    }

    let long = paragraph(4_000, seed: 3)
    let reordered = long.split(separator: " ").reversed().joined(separator: " ")
    let many = (0..<200).map { paragraph(40, seed: $0) }.joined(separator: "\n\n")
    let manyRewritten = (0..<200).map { paragraph(40, seed: $0 + 100) }.joined(separator: "\n\n")

    let cases: [(String, String, String)] = [
        ("256 KB prose, 1 % of words changed", source, changed(every: 100)),
        ("256 KB prose, every other word changed", source, changed(every: 2)),
        ("one 4 000-token paragraph, reordered", long, reordered),
        ("200 paragraphs, each rewritten", many, manyRewritten),
    ]
    print("TextDiff cost — \(sourceWords) words in the 256 KB fixture; median of 5 runs")
    for (name, a, b) in cases {
        var times: [Double] = []
        var outcome = ""
        for _ in 0..<5 {
            let started = ContinuousClock.now
            let set = TextDiff.changes(source: a, result: b)
            times.append(Double((ContinuousClock.now - started).components.attoseconds) / 1e15
                         + Double((ContinuousClock.now - started).components.seconds) * 1000)
            outcome = set.notCompared.map { "not compared (\($0))" }
                ?? "\(set.count) changes over \(set.blocks.count) block pairs"
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "  %@: %.1f ms — %@", name, median, outcome))
    }
}
