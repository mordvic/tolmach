// Sources/acceptance/main.swift
import Foundation
import OllamaKit
import LMStudioKit
import TranslationCore

/// What one run measures. Both fields were hard-coded until 2026-08-18 — `aya-expanse:8b`, the
/// model `ModelPolicy` pins for the interactive path, and 900 characters, the app's default
/// chunk budget — so this harness could certify exactly one configuration. An install running
/// another model had no baseline at all: measured 2026-08-18, a machine with `translategemma:12b`
/// in `interactiveModel` and `chunkSize` 4000 was described by not one number in BASELINE.md.
struct RunConfiguration {
    let model: String
    let maxChunkCharacters: Int
    /// Which server this run measured. Both gates below are properties of one model **on one
    /// server**, so a run against the other engine is measured and never certified — the same
    /// rule `--model` already established, extended by one dimension.
    var engine = "ollama"
    /// The 1000 ms TTFT ceiling is a property of the *interactive path*, and it was measured on
    /// the model `ModelPolicy` pins for that path. Another model passed through `--model` is
    /// being measured, not certified: its single-chunk TTFT is printed and recorded, never
    /// failed. A gate that is red on every run of a configuration is a gate people learn to
    /// ignore, and the number itself is what a BASELINE.md entry needs — measured 2026-08-18,
    /// `translategemma:12b` pays 634 ms of prefill alone on a cold prefix for the app's
    /// translation prompt (`translategemma:27b`: 1382 ms), so the ceiling would fail on
    /// prefill before the model had produced a token.
    var gatesTTFT: Bool {
        engine == "ollama" && model == ModelPolicy.defaultModel(for: .interactive)
    }
    /// The `known` / `known-limitation` sets below were each measured on `measuredOn` and name
    /// it in their reasons. For any other model every diff is reported as unaccepted, so a
    /// new model's first entry shows what it actually does — accepting a limitation is a
    /// decision recorded in BASELINE.md, not something a reason string written about a
    /// different model can confer.
    var appliesKnownLimitations: Bool { engine == "ollama" && model == Self.measuredOn }
    static let measuredOn = "aya-expanse:8b"
}

func usage(_ message: String) -> Never {
    print("acceptance: \(message)")
    print("usage: swift run acceptance [--engine ollama|lmstudio] [--model <model>] [--chunk <characters>]")
    print("  --engine defaults to ollama; the two gates apply to ollama only")
    print("  --model  defaults to ModelPolicy's interactive model (\(ModelPolicy.defaultModel(for: .interactive)))")
    print("  --chunk  maxChunkCharacters, defaults to 900 — the app's own default")
    exit(2)
}

func parseConfiguration(_ arguments: ArraySlice<String>) -> RunConfiguration {
    var model = ModelPolicy.defaultModel(for: .interactive)
    var chunk = 900
    var engine = "ollama"
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--model":
            guard let value = iterator.next(), !value.isEmpty else { usage("--model needs a value") }
            model = value
        case "--chunk":
            guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                usage("--chunk needs a positive integer")
            }
            chunk = parsed
        case "--engine":
            guard let value = iterator.next(), value == "ollama" || value == "lmstudio" else {
                usage("--engine needs ollama or lmstudio")
            }
            engine = value
        default:
            usage("unknown argument \"\(argument)\"")
        }
    }
    return RunConfiguration(model: model, maxChunkCharacters: chunk, engine: engine)
}

let config = parseConfiguration(CommandLine.arguments.dropFirst())
let model = config.model
// One client, chosen by `--engine`. `any LLMClient` rather than a concrete type: this harness
// only ever calls `chat`, and the two transports differ in nothing else it uses.
let client: any LLMClient = config.engine == "lmstudio" ? LMStudioClient() : OllamaClient()
let translator = Translator(client: client)
// The first line of every run names what it measured, so a BASELINE.md entry pasted from the
// output cannot silently describe a different configuration than its heading claims.
print("acceptance: engine \(config.engine) · model \(config.model) · " +
      "chunk \(config.maxChunkCharacters) chars · " +
      "TTFT gate \(config.gatesTTFT ? "enforced" : "info only — not Ollama's interactive-policy model") · " +
      "known-limitation set \(config.appliesKnownLimitations ? "applied" : "not applied — measured on \(RunConfiguration.measuredOn)")")
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

/// Only the drop direction (`.blockquote` expected, nothing rendered) — a diff where the
/// model *adds* a `>` the source never had is a different, unaccepted defect and must not
/// match here.
func isBlockquoteDropDiff(_ diff: MarkupDiff) -> Bool {
    diff.expected == .blockquote && diff.actual == nil
}

/// Identity for deduplicating unaccepted markup diffs across a file's repeated runs.
/// `MarkupDiff.note` is derived entirely from which side is nil, so the
/// (expected, actual) pair alone is the diff's identity.
struct MarkupDiffKey: Hashable {
    let expected: MarkupToken?
    let actual: MarkupToken?
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

// Measured 2026-08-10 (BASELINE.md, "after pass-through chunks and inline restore
// (re-basing)"): once a file's fenced block became its own standalone passthrough chunk,
// the chunk immediately after it recomposed, and aya-expanse:8b began stochastically
// dropping the leading ">" on the blockquote in that chunk — 2/3 runs per file. Two
// dedicated-rule attempts to fix it (BASELINE.md, "blockquote rule after the re-basing
// failure" and its revert) both made the model's structure preservation worse elsewhere
// (spurious ">" insertion on lines with no source blockquote at all, a new deterministic
// drop of the level-2 heading before the fence) without reliably stopping the drop itself.
// Accepted by the user 2026-08-10: a stochastic marker loss that `WarningsView` already
// surfaces to the user is the better trade against the deterministic code corruption the
// same pass-through/inline-restore change fixed 4/4 (the codeBlock limitation this dict's
// other entry used to record, and which no longer occurs).
let knownBlockquoteDropReason = "aya-expanse:8b stochastically drops the leading \">\" on the "
    + "blockquote that follows a fenced code block, now that the fence is a standalone "
    + "passthrough chunk and the following chunk recomposed. Two prompt-rule attempts to "
    + "fix it made the model's structure preservation worse elsewhere and were reverted. "
    + "Accepted by the user 2026-08-10 as a stochastic marker loss WarningsView already "
    + "surfaces, traded against the deterministic code corruption the same change fixed 4/4."
let knownBlockquoteDropLimitations: [String: String] = [
    "techdoc-en.md": knownBlockquoteDropReason,
    "techdoc-ru.md": knownBlockquoteDropReason,
]

func target(for name: String) -> Language { name.hasSuffix("-ru.md") ? .en : .ru }

/// "N chunks" when every chunk reached the model, else "N chunks (M model-bound)" —
/// the re-basing format the brief asks the entry to record per file. A raw chunk
/// count alone no longer says how many model calls a code-bearing file paid for,
/// now that a fenced block is a standalone passthrough chunk the model never sees.
func chunkSummary(_ outcome: TranslationOutcome) -> String {
    let raw = outcome.chunks.count
    let noun = raw == 1 ? "chunk" : "chunks"
    return raw == outcome.modelChunkCount
        ? "\(raw) \(noun)"
        : "\(raw) \(noun) (\(outcome.modelChunkCount) model-bound)"
}

func translate(_ text: String, to target: Language) async throws -> TranslationOutcome {
    try await translator.translate(
        text: text, target: target, tone: .technical, userGlossary: nil,
        options: ChatOptions(model: model), maxChunkCharacters: config.maxChunkCharacters)
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
    // Model-bound, not raw: this asks "did the model see more than one chunk of this
    // document?" — the same question the engine itself gates the document-glossary
    // stage on (`Translator.translate`'s `modelChunks.count > 1`). A passthrough
    // (fenced-code) chunk never gets a glossary-consistency check because it never
    // reaches the model — so the loop below excludes them too, or a term that only
    // ever appears inside fenced code would count as `applicable` while being
    // structurally unhonourable, penalising the metric for the protection itself
    // (measured: techdoc-en's `applicable` moved 49→51 with `honoured` unchanged at
    // 42–44, once inline/fenced protection started matching this document's code).
    if outcome.modelChunkCount > 1, let source = outcome.detectedSource {
        for entry in outcome.documentGlossary {
            guard let expected = entry.requiredTranslation(for: target) else { continue }
            for (index, chunk) in outcome.chunks.enumerated() where !chunk.passthrough {
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

    // A defect the model reproduces reliably shows up identically in every run of a
    // repeated file — the normal case, as the recorded code-block limitation
    // demonstrates by appearing identically across all three runs. Counting
    // occurrences here (per file) and flushing once, after every run has been
    // checked, turns N identical FAILED entries for one defect into a single entry
    // noting how many of the file's runs it appeared in: "(3/3 runs)" is materially
    // different information from "(1/3 runs)" — a defect that appears in only some
    // runs is intermittent, not a reliably-reproduced one, and collapsing the two
    // together would hide that.
    var unacceptedDiffCounts: [MarkupDiffKey: Int] = [:]

    func checkMarkup(_ outcome: TranslationOutcome, label: String) {
        for diff in outcome.markupDiffs {
            let expected = String(describing: diff.expected), actual = String(describing: diff.actual)
            if config.appliesKnownLimitations, isKnownModelBehaviour(diff) {
                print("    known\(label): expected \(expected) actual \(actual)")
            } else if config.appliesKnownLimitations, isCodeBlockDiff(diff),
                      let reason = knownFileLimitations[name] {
                print("    known-limitation\(label): \(reason) (expected \(expected) actual \(actual))")
            } else if config.appliesKnownLimitations, isBlockquoteDropDiff(diff),
                      let reason = knownBlockquoteDropLimitations[name] {
                print("    known-limitation\(label): \(reason) (expected \(expected) actual \(actual))")
            } else {
                print("    markup\(label): expected \(expected) actual \(actual)")
                let key = MarkupDiffKey(expected: diff.expected, actual: diff.actual)
                unacceptedDiffCounts[key, default: 0] += 1
            }
        }
    }

    // Deduplicated, one FAILED entry per distinct diff, noting how many of the
    // file's `totalRuns` runs it showed up in. Called once per file, after every
    // run of that file has gone through `checkMarkup`.
    func flushMarkupFailures(totalRuns: Int) {
        let entries = unacceptedDiffCounts.sorted {
            (String(describing: $0.key.expected), String(describing: $0.key.actual)) <
            (String(describing: $1.key.expected), String(describing: $1.key.actual))
        }
        for (key, count) in entries {
            let expected = String(describing: key.expected), actual = String(describing: key.actual)
            failures.append("\(name): unaccepted markup diff — expected \(expected) actual \(actual) " +
                             "(\(count)/\(totalRuns) runs)")
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
        //
        // Gated on model-bound chunks, not raw chunks: a code-bearing file can now
        // have more than one raw chunk (prose plus a standalone passthrough fenced
        // block) while still paying for only one model call, in which case it is
        // "hotkey-shaped" — TTFT-gated, not adherence-measured — exactly like a file
        // with one raw chunk always was.
        if first.modelChunkCount > 1 {
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
                  "\(chunkSummary(first)) · \(first.documentGlossary.count) terms · " +
                  "TTFT \(ttftDescription) ms (info only — multi-chunk, not asserted)")
            for (i, outcome) in outcomes.enumerated() { checkMarkup(outcome, label: " run\(i + 1)") }
            flushMarkupFailures(totalRuns: outcomes.count)

            // A chunked text with nothing to measure is a silent failure, not a pass: it
            // means the glossary was empty or no term recurred, so the mechanism did
            // nothing at all — checked on every run, not just the first. This is the
            // failure that covers the every-run-nil case below, not a division by zero.
            for (i, m) in measurements.enumerated() where m.applicable == 0 {
                failures.append("\(name) run\(i + 1): chunked into \(chunkSummary(outcomes[i])) but no term was measurable — document glossary did nothing")
            }
            if let average, average < 80 {
                failures.append("\(name): average adherence \(String(format: "%.1f%%", average)) < 80%")
            }
        } else if first.modelChunkCount == 0 {
            // The whole document is code: every chunk is a standalone passthrough
            // fenced block, so no model call happened at all. `timeToFirstTokenMS`
            // is nil here WITHOUT meaning "empty reply" — see
            // `TranslationOutcome.modelChunkCount`'s doc comment, which names this
            // exact case as the one a naive consumer misreads as a failure.
            print("\(name): adherence n/a (no model-bound chunk — the whole document is code) · " +
                  "\(chunkSummary(first)) · \(first.documentGlossary.count) terms · " +
                  "TTFT — ms (no model call, not gated)")
            checkMarkup(first, label: "")
            flushMarkupFailures(totalRuns: 1)
        } else {
            // Single model-bound chunk: TTFT-gated, whether or not the document also
            // carried a passthrough chunk alongside it (chunkSummary reports both
            // counts when they differ).
            let ttftDescription = first.timeToFirstTokenMS.map { String(Int($0)) } ?? "—"
            // The line keeps its exact shape for the gated model, so entries stay comparable
            // across BASELINE.md; the suffix appears only where the number is not a gate.
            let ttftSuffix = config.gatesTTFT ? "" : " (info only — TTFT not gated for this model)"
            print("\(name): adherence n/a (single model-bound chunk, document glossary not applicable) · " +
                  "\(chunkSummary(first)) · \(first.documentGlossary.count) terms · TTFT \(ttftDescription) ms\(ttftSuffix)")
            checkMarkup(first, label: "")
            flushMarkupFailures(totalRuns: 1)
            // Absent and slow are different failures. Before, a nil TTFT was measured
            // as elapsed-time-so-far (roughly equal to totalMS), so an empty model
            // reply was reported as ">= 1000 ms" — blaming latency for what was
            // actually no response at all. Only a real, non-nil TTFT is judged
            // against the latency threshold.
            if let ttft = first.timeToFirstTokenMS {
                if ttft >= 1000, config.gatesTTFT {
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
