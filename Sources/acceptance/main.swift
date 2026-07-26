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

var failures: [String] = []

for name in corpus {
    let text = try String(contentsOfFile: "corpus/\(name)", encoding: .utf8)
    let target: Language = name.hasSuffix("-ru.md") ? .en : .ru
    let outcome = try await translator.translate(
        text: text, target: target, tone: .technical, userGlossary: nil,
        options: ChatOptions(model: model), maxChunkCharacters: 900)

    // 1. Cross-chunk term adherence.
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
    let adherence = applicable == 0 ? 100.0 : Double(honoured) / Double(applicable) * 100

    // 2. Markup integrity on the technical documents.
    let markupOK = !name.hasPrefix("techdoc") || outcome.markupDiffs.isEmpty

    // 3. Latency.
    let ttft = outcome.timeToFirstTokenMS

    print("\(name): adherence \(String(format: "%.1f%%", adherence)) (\(honoured)/\(applicable)) · " +
          "\(outcome.chunks.count) chunks · \(outcome.documentGlossary.count) terms · " +
          "\(outcome.markupDiffs.count) markup diffs · TTFT \(Int(ttft)) ms")
    for diff in outcome.markupDiffs {
        print("    markup: expected \(String(describing: diff.expected)) actual \(String(describing: diff.actual))")
    }

    // A chunked text with nothing to measure is a silent failure, not a pass: it means
    // the glossary was empty or no term recurred, so the mechanism did nothing at all.
    if outcome.chunks.count > 1 && applicable == 0 {
        failures.append("\(name): chunked into \(outcome.chunks.count) but no term was measurable — document glossary did nothing")
    }
    if applicable > 0 && adherence < 85 { failures.append("\(name): adherence \(String(format: "%.1f%%", adherence)) < 85%") }
    if !markupOK { failures.append("\(name): \(outcome.markupDiffs.count) markup diffs, expected 0") }
    if ttft >= 1000 { failures.append("\(name): TTFT \(Int(ttft)) ms >= 1000 ms") }
}

if failures.isEmpty {
    print("\nACCEPTED — engine meets the prototype baseline")
} else {
    print("\nFAILED")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
