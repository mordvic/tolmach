// Sources/acceptance/main.swift
import Foundation
import OllamaKit
import TranslationCore

let model = ModelPolicy.defaultModel(for: .interactive)
let client = OllamaClient()
let translator = Translator(client: client)
// A missing or unreadable corpus directory must become a legible line naming the
// cause and the expected working directory, not an uncaught throw that dies with
// "Fatal error: Error raised at top level" and says nothing about why — the same
// convention the per-file transport-error handling below already follows.
let corpus: [String]
do {
    corpus = try FileManager.default
        .contentsOfDirectory(atPath: "corpus")
        .filter { $0.hasSuffix(".md") }
        .sorted()
} catch {
    print("Cannot list corpus directory — \(error)")
    print("Expected a \"corpus\" directory under the current working directory " +
          "(currently \(FileManager.default.currentDirectoryPath)) — run this from the package root.")
    exit(1)
}

/// Model behaviours already measured and accepted. A diff outside this set is a
/// regression; a diff inside it is the checker correctly reporting something we
/// already know aya-expanse:8b does.
func isKnownModelBehaviour(_ diff: MarkupDiff) -> Bool {
    // Rewrites a bare URL as a markdown link — recorded in the prototype README.
    if diff.expected == .url(bare: true) && diff.actual == .url(bare: false) { return true }
    if diff.expected == nil && diff.actual == .url(bare: false) { return true }
    if diff.expected == .url(bare: true) && diff.actual == nil { return true }
    return false
}

func isCodeBlockDiff(_ diff: MarkupDiff) -> Bool {
    if let expected = diff.expected, case .codeBlock = expected { return true }
    if let actual = diff.actual, case .codeBlock = actual { return true }
    return false
}

/// Files with a measured, accepted model limitation, and the reason.
/// Scoped per file rather than per token kind on purpose: a codeBlock token
/// carries only a content hash, so tolerating hash mismatches generally would
/// also tolerate the model rewriting a command outright — and the hashes cannot
/// be pinned, since String.hashValue is seeded per process.
let knownFileLimitations: [String: String] = [
    "techdoc-en.md": "aya-expanse:8b translates human-readable strings inside a code block — "
        + "the commit message in `git tag -m \"See CHANGELOG.md\"` comes back translated. "
        + "Sharpening the prompt rule was attempted and did not change it.",
]

func target(for name: String) -> Language { name.hasSuffix("-ru.md") ? .en : .ru }

func translate(_ text: String, to target: Language) async throws -> TranslationOutcome {
    try await translator.translate(
        text: text, target: target, tone: .technical, userGlossary: nil,
        options: ChatOptions(model: model), maxChunkCharacters: 900)
}

/// (honoured, applicable, percentage) for one outcome. Only meaningful when the
/// text actually chunked and a source language was detected; otherwise there is
/// nothing to measure and the caller treats that as inapplicable, not a pass.
/// `pct` is nil in exactly that inapplicable case — NOT a 100.0 sentinel. A
/// sentinel silently averages alongside real measurements from the other runs of
/// the same file and can lift a genuinely failing average up to (or above) the
/// pass threshold; nil forces the caller to exclude it from that average instead.
func adherence(_ outcome: TranslationOutcome, target: Language) -> (honoured: Int, applicable: Int, pct: Double?) {
    var honoured = 0, applicable = 0
    if outcome.chunks.count > 1, let source = outcome.detectedSource {
        for entry in outcome.documentGlossary {
            guard let expected = entry.requiredTranslation(for: target) else { continue }
            for (index, chunk) in outcome.chunks.enumerated() {
                guard LemmaMatcher.matches(expected: entry.term, in: chunk.text, language: source) == true
                else { continue }
                applicable += 1
                if LemmaMatcher.matches(expected: expected, in: outcome.translatedChunks[index],
                                        language: target) == true { honoured += 1 }
            }
        }
    }
    let pct: Double? = applicable == 0 ? nil : Double(honoured) / Double(applicable) * 100
    return (honoured, applicable, pct)
}

var failures: [String] = []

// The real hotkey path keeps the model resident via `keep_alive`; measuring a cold
// load would test disk I/O, not translation latency. One throwaway call against
// the warmup snippet puts the model into the same warm state before anything here
// is measured, and its result is discarded.
if let warmupText = try? String(contentsOfFile: "corpus/snippet-en.md", encoding: .utf8) {
    _ = try? await translate(warmupText, to: .ru)
}

for name in corpus {
    let text = try String(contentsOfFile: "corpus/\(name)", encoding: .utf8)
    let dest = target(for: name)

    func checkMarkup(_ outcome: TranslationOutcome, label: String) {
        for diff in outcome.markupDiffs {
            let expected = String(describing: diff.expected), actual = String(describing: diff.actual)
            if isKnownModelBehaviour(diff) {
                print("    known\(label): expected \(expected) actual \(actual)")
            } else if isCodeBlockDiff(diff), let reason = knownFileLimitations[name] {
                print("    known-limitation\(label): \(reason) (expected \(expected) actual \(actual))")
            } else {
                print("    markup\(label): expected \(expected) actual \(actual)")
                failures.append("\(name)\(label): unaccepted markup diff — expected \(expected) actual \(actual)")
            }
        }
    }

    // A transport failure (a timed-out or dropped request to Ollama, mid-file) must
    // become a legible failure line naming the file and the error, not an uncaught
    // throw that kills the whole run — a crash tells the reader nothing about how
    // far the harness got or which file was in flight when it happened.
    do {
        let first = try await translate(text, to: dest)

        // Chunking is decided by input length alone, not by anything the model does,
        // so whether a file is "chunked-shaped" or "hotkey-shaped" is already known
        // from this first run and never changes across repeats of the same file.
        if first.chunks.count > 1 {
            var outcomes = [first]
            for _ in 0..<2 { outcomes.append(try await translate(text, to: dest)) }

            let measurements = outcomes.map { adherence($0, target: dest) }
            // Average only the runs that actually measured something. A run with
            // applicable == 0 contributes no pct at all now (see `adherence`), so it
            // can no longer masquerade as a perfect 100% inside this average.
            let measuredPcts = measurements.compactMap(\.pct)
            let average = measuredPcts.isEmpty ? nil : measuredPcts.reduce(0, +) / Double(measuredPcts.count)
            let runsDescription = measurements.enumerated()
                .map { i, m in
                    let pctDescription = m.pct.map { String(format: "%.1f%%", $0) } ?? "n/a"
                    return "run\(i + 1) \(pctDescription) (\(m.honoured)/\(m.applicable))"
                }
                .joined(separator: " · ")
            let ttftDescription = outcomes.map { $0.timeToFirstTokenMS.map { String(Int($0)) } ?? "—" }.joined(separator: "/")
            let averageDescription = average.map { String(format: "%.1f%%", $0) } ?? "n/a"

            print("\(name): \(runsDescription) · average \(averageDescription) · " +
                  "\(first.chunks.count) chunks · \(first.documentGlossary.count) terms · " +
                  "TTFT \(ttftDescription) ms (info only — multi-chunk, not asserted)")
            for (i, outcome) in outcomes.enumerated() { checkMarkup(outcome, label: " run\(i + 1)") }

            // A chunked text with nothing to measure is a silent failure, not a pass: it
            // means the glossary was empty or no term recurred, so the mechanism did
            // nothing at all — checked on every run, not just the first. This is the
            // failure that covers the every-run-nil case below, not a division by zero.
            for (i, m) in measurements.enumerated() where m.applicable == 0 {
                failures.append("\(name) run\(i + 1): chunked into \(outcomes[i].chunks.count) but no term was measurable — document glossary did nothing")
            }
            if let average, average < 80 {
                failures.append("\(name): average adherence \(String(format: "%.1f%%", average)) < 80%")
            }
        } else {
            let ttftDescription = first.timeToFirstTokenMS.map { String(Int($0)) } ?? "—"
            print("\(name): adherence n/a (single chunk, document glossary not applicable) · 1 chunk · " +
                  "\(first.documentGlossary.count) terms · TTFT \(ttftDescription) ms")
            checkMarkup(first, label: "")
            // Absent and slow are different failures. Before, a nil TTFT was measured
            // as elapsed-time-so-far (roughly equal to totalMS), so an empty model
            // reply was reported as ">= 1000 ms" — blaming latency for what was
            // actually no response at all. Only a real, non-nil TTFT is judged
            // against the latency threshold.
            if let ttft = first.timeToFirstTokenMS {
                if ttft >= 1000 {
                    failures.append("\(name): TTFT \(Int(ttft)) ms >= 1000 ms")
                }
            } else {
                failures.append("\(name): model returned no tokens")
            }
        }
    } catch {
        print("\(name): TRANSPORT ERROR — \(error)")
        failures.append("\(name): transport error — \(error)")
    }
}

if failures.isEmpty {
    print("\nACCEPTED — engine meets the recalibrated baseline")
} else {
    print("\nFAILED")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
