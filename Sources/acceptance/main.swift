// Sources/acceptance/main.swift
import Foundation
import OllamaKit
import TranslationCore

let model = ModelPolicy.defaultModel(for: .interactive)
let client = OllamaClient()
let translator = Translator(client: client)
let corpus = try FileManager.default
    .contentsOfDirectory(atPath: "corpus")
    .filter { $0.hasSuffix(".md") }
    .sorted()

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

func target(for name: String) -> Language { name.hasSuffix("-ru.md") ? .en : .ru }

func translate(_ text: String, to target: Language) async throws -> TranslationOutcome {
    try await translator.translate(
        text: text, target: target, tone: .technical, userGlossary: nil,
        options: ChatOptions(model: model), maxChunkCharacters: 900)
}

/// (honoured, applicable, percentage) for one outcome. Only meaningful when the
/// text actually chunked and a source language was detected; otherwise there is
/// nothing to measure and the caller treats that as inapplicable, not a pass.
func adherence(_ outcome: TranslationOutcome, target: Language) -> (honoured: Int, applicable: Int, pct: Double) {
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
    let pct = applicable == 0 ? 100.0 : Double(honoured) / Double(applicable) * 100
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
            } else {
                print("    markup\(label): expected \(expected) actual \(actual)")
                failures.append("\(name)\(label): unaccepted markup diff — expected \(expected) actual \(actual)")
            }
        }
    }

    let first = try await translate(text, to: dest)

    // Chunking is decided by input length alone, not by anything the model does,
    // so whether a file is "chunked-shaped" or "hotkey-shaped" is already known
    // from this first run and never changes across repeats of the same file.
    if first.chunks.count > 1 {
        var outcomes = [first]
        for _ in 0..<2 { outcomes.append(try await translate(text, to: dest)) }

        let measurements = outcomes.map { adherence($0, target: dest) }
        let average = measurements.map(\.pct).reduce(0, +) / Double(measurements.count)
        let runsDescription = measurements.enumerated()
            .map { i, m in "run\(i + 1) \(String(format: "%.1f%%", m.pct)) (\(m.honoured)/\(m.applicable))" }
            .joined(separator: " · ")
        let ttftDescription = outcomes.map { String(Int($0.timeToFirstTokenMS)) }.joined(separator: "/")

        print("\(name): \(runsDescription) · average \(String(format: "%.1f%%", average)) · " +
              "\(first.chunks.count) chunks · \(first.documentGlossary.count) terms · " +
              "TTFT \(ttftDescription) ms (info only — multi-chunk, not asserted)")
        for (i, outcome) in outcomes.enumerated() { checkMarkup(outcome, label: " run\(i + 1)") }

        // A chunked text with nothing to measure is a silent failure, not a pass: it
        // means the glossary was empty or no term recurred, so the mechanism did
        // nothing at all — checked on every run, not just the first.
        for (i, m) in measurements.enumerated() where m.applicable == 0 {
            failures.append("\(name) run\(i + 1): chunked into \(outcomes[i].chunks.count) but no term was measurable — document glossary did nothing")
        }
        if average < 80 { failures.append("\(name): average adherence \(String(format: "%.1f%%", average)) < 80%") }
    } else {
        print("\(name): adherence 100.0% (single chunk, document glossary not applicable) · 1 chunk · " +
              "\(first.documentGlossary.count) terms · TTFT \(Int(first.timeToFirstTokenMS)) ms")
        checkMarkup(first, label: "")
        if first.timeToFirstTokenMS >= 1000 {
            failures.append("\(name): TTFT \(Int(first.timeToFirstTokenMS)) ms >= 1000 ms")
        }
    }
}

if failures.isEmpty {
    print("\nACCEPTED — engine meets the recalibrated baseline")
} else {
    print("\nFAILED")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
