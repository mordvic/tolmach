import Foundation
import OllamaClient
import TranslationEngine

// PROTOTYPE — throwaway shell. The logic lives in TranslationEngine; this file
// only exposes it to a keyboard so the behaviour can be driven by hand.

let bold = "\u{1B}[1m"
let dim = "\u{1B}[2m"
let reset = "\u{1B}[0m"
let green = "\u{1B}[32m"
let yellow = "\u{1B}[33m"
let red = "\u{1B}[31m"
let cyan = "\u{1B}[36m"

func clearScreen() { print("\u{1B}[2J\u{1B}[H", terminator: "") }

let chunkSizes = [600, 900, 1500, 4000]
let targets: [Language] = [.ru, .en, .de, .fr, .es, .pt, .it, .zh, .ja]

struct RunState {
    var sampleIndex = 0
    var targetIndex = 0
    var toneIndex = 3  // .technical
    var modelIndex = 0
    var twoPass = false
    var glossaryEnabled = true
    var chunkSizeIndex = 1
    var outcome: TranslationOutcome? = nil
    var status = "ready"
    var lastError: String? = nil
    var showPrompt = false

    var sample: Sample { Samples.all[sampleIndex] }
    var target: Language { targets[targetIndex] }
    var tone: Tone { Tone.allCases[toneIndex] }
    var chunkSize: Int { chunkSizes[chunkSizeIndex] }
}

let client = OllamaClient()
var availableModels: [String] = []

do {
    availableModels = try await client.models().map(\.name).sorted()
} catch {
    print("\(red)\(error.localizedDescription)\(reset)")
    exit(1)
}
guard !availableModels.isEmpty else {
    print("\(red)No models installed. Run `ollama pull aya-expanse:8b` first.\(reset)")
    exit(1)
}

var state = RunState()
if let index = availableModels.firstIndex(where: { $0.hasPrefix("aya-expanse") }) {
    state.modelIndex = index
}

func field(_ label: String, _ value: String) -> String {
    let padded = label.padding(toLength: 12, withPad: " ", startingAt: 0)
    return " \(dim)\(padded)\(reset)\(value)"
}

func renderMetrics(_ outcome: TranslationOutcome) {
    print("")
    print(" \(bold)── LAST RUN \(String(repeating: "─", count: 50))\(reset)")

    let speed = outcome.stats.map(\.tokensPerSecond).max() ?? 0
    let load = outcome.stats.first?.loadDurationMS ?? 0
    let promptTokens = outcome.stats.reduce(0) { $0 + $1.promptEvalCount }
    let outputTokens = outcome.stats.reduce(0) { $0 + $1.evalCount }

    print(field("TTFT", "\(Int(outcome.timeToFirstTokenMS)) ms"))
    print(field("Total", "\(Int(outcome.totalMS)) ms"))
    print(field("Speed", String(format: "%.1f tok/s", speed)
        + "  \(dim)load \(Int(load)) ms · prompt \(promptTokens) tok · out \(outputTokens) tok\(reset)"))
    print(field("Chunks", "\(outcome.chunks.count)"
        + (outcome.chunks.contains(where: \.containsCodeFence) ? "  \(dim)(one holds a code fence)\(reset)" : "")))

    if outcome.strippedPreambles.isEmpty {
        print(field("Preamble", "\(green)none\(reset)"))
    } else {
        let list = outcome.strippedPreambles.map { "\"\($0)\"" }.joined(separator: ", ")
        print(field("Preamble", "\(yellow)stripped \(outcome.strippedPreambles.count)×\(reset) \(dim)\(list)\(reset)"))
    }

    if outcome.unwrappedFences > 0 {
        print(field("Fence wrap", "\(yellow)unwrapped \(outcome.unwrappedFences)×\(reset)"))
    }

    let integrity = outcome.integrity
    if integrity.isClean {
        print(field("Integrity", "\(green)✓ code blocks, inline code and URLs all survived\(reset)"))
    } else {
        var problems: [String] = []
        if !integrity.missingCodeBlocks.isEmpty { problems.append("\(integrity.missingCodeBlocks.count) code block(s)") }
        if !integrity.missingInlineCode.isEmpty { problems.append("\(integrity.missingInlineCode.count) inline code") }
        if !integrity.missingURLs.isEmpty { problems.append("\(integrity.missingURLs.count) URL(s)") }
        print(field("Integrity", "\(red)✗ altered: \(problems.joined(separator: ", "))\(reset)"))
        for item in integrity.missingInlineCode.prefix(4) {
            print("             \(dim)inline lost: `\(item)`\(reset)")
        }
        for item in integrity.missingURLs.prefix(2) {
            print("             \(dim)url lost: \(item)\(reset)")
        }
    }

    if outcome.relevantGlossary.isEmpty {
        print(field("Glossary", "\(dim)no terms matched this text\(reset)"))
    } else if outcome.glossaryViolations.isEmpty {
        print(field("Glossary", "\(green)✓ all \(outcome.relevantGlossary.count) matched term(s) honoured\(reset)"))
    } else {
        let list = outcome.glossaryViolations
            .map { "\"\($0.term)\" → expected \"\($0.expected)\"" }
            .joined(separator: "; ")
        print(field("Glossary", "\(red)✗ \(outcome.glossaryViolations.count) violation(s)\(reset) \(dim)\(list)\(reset)"))
    }
}

func render() {
    clearScreen()
    print("\(bold)\(cyan)LOCAL TRANSLATOR — LOGIC PROTOTYPE\(reset)")
    print("\(dim)Question: are local models good enough for our content, and is the engine shaped right?\(reset)")
    print("")

    let sample = state.sample
    print(field("Sample", "\(bold)[\(state.sampleIndex + 1)]\(reset) \(sample.title)  \(dim)\(sample.kind) · \(sample.text.count) chars\(reset)"))

    let detected = LanguageDetector.detect(sample.text)
    let detectedLabel = detected.map { "\($0.flag)" } ?? "?"
    print(field("Direction", "\(detectedLabel) → \(bold)\(state.target.flag)\(reset) \(dim)(\(state.target.englishName), source auto-detected)\(reset)"))
    print(field("Tone", state.tone.rawValue))
    print(field("Model", availableModels[state.modelIndex]))
    print(field("Two-pass", state.twoPass ? "\(yellow)on\(reset) \(dim)(translate, then self-review)\(reset)" : "off"))

    let relevant = state.glossaryEnabled ? Samples.glossary.relevantEntries(for: sample.text) : []
    print(field("Glossary", state.glossaryEnabled
        ? "on  \(dim)\(relevant.count) of \(Samples.glossary.entries.count) terms match this text\(reset)"
        : "off"))

    let chunks = Chunker.chunk(sample.text, maxCharacters: state.chunkSize)
    print(field("Chunk size", "\(state.chunkSize) chars \(dim)→ \(chunks.count) chunk(s)\(reset)"))

    if let error = state.lastError {
        print("")
        print(" \(red)error: \(error)\(reset)")
    }

    if let outcome = state.outcome {
        renderMetrics(outcome)

        print("")
        print(" \(bold)── OUTPUT \(String(repeating: "─", count: 52))\(reset)")
        let lines = outcome.final.components(separatedBy: .newlines)
        for line in lines.prefix(14) { print(" \(line)") }
        if lines.count > 14 {
            print(" \(dim)… +\(lines.count - 14) more lines — press [f] for the full text\(reset)")
        }
    }

    if state.showPrompt {
        let request = TranslationRequest(
            text: chunks.first?.text ?? sample.text,
            source: detected,
            target: state.target,
            tone: state.tone,
            glossaryEntries: relevant
        )
        print("")
        print(" \(bold)── SYSTEM PROMPT \(String(repeating: "─", count: 45))\(reset)")
        for line in PromptBuilder.systemPrompt(for: request).components(separatedBy: .newlines) {
            print(" \(dim)\(line)\(reset)")
        }
    }

    print("")
    print(" \(dim)status: \(state.status)\(reset)")
    print(" \(bold)[1-5]\(reset)\(dim) sample \(reset) \(bold)[t]\(reset)\(dim) target \(reset) \(bold)[o]\(reset)\(dim) tone \(reset) \(bold)[m]\(reset)\(dim) model \(reset) \(bold)[p]\(reset)\(dim) two-pass \(reset) \(bold)[g]\(reset)\(dim) glossary\(reset)")
    print(" \(bold)[c]\(reset)\(dim) chunk size \(reset) \(bold)[r]\(reset)\(dim) run \(reset) \(bold)[f]\(reset)\(dim) full output \(reset) \(bold)[s]\(reset)\(dim) toggle prompt \(reset) \(bold)[q]\(reset)\(dim) quit\(reset)")
    print("")
    print("> ", terminator: "")
}

@MainActor
func runTranslation() async {
    state.lastError = nil
    state.status = "translating…"
    render()
    print("")
    print("\(dim)streaming:\(reset)")

    let translator = Translator(client: client)
    let options = ChatOptions(model: availableModels[state.modelIndex], temperature: 0.2, keepAlive: "30m")

    do {
        let outcome = try await translator.translate(
            text: state.sample.text,
            target: state.target,
            tone: state.tone,
            glossary: state.glossaryEnabled ? Samples.glossary : nil,
            options: options,
            twoPass: state.twoPass,
            maxChunkCharacters: state.chunkSize,
            onToken: { token in
                FileHandle.standardOutput.write(Data(token.utf8))
            }
        )
        state.outcome = outcome
        state.status = "done"
    } catch {
        state.lastError = error.localizedDescription
        state.status = "failed"
    }
}

@MainActor
func showFullOutput() {
    guard let outcome = state.outcome else { return }
    clearScreen()
    print("\(bold)FULL OUTPUT\(reset) \(dim)(\(state.sample.title) → \(state.target.flag))\(reset)")
    print("")
    print(outcome.final)
    if let pass2 = outcome.pass2 {
        print("")
        print("\(bold)── PASS 1, before self-review \(String(repeating: "─", count: 30))\(reset)")
        print(outcome.pass1)
        _ = pass2
    }
    print("")
    print("\(dim)press enter to go back\(reset)")
    _ = readLine()
}

render()

loop: while let line = readLine() {
    let key = line.trimmingCharacters(in: .whitespaces).lowercased()

    switch key {
    case "q":
        break loop
    case "t":
        state.targetIndex = (state.targetIndex + 1) % targets.count
    case "o":
        state.toneIndex = (state.toneIndex + 1) % Tone.allCases.count
    case "m":
        state.modelIndex = (state.modelIndex + 1) % availableModels.count
    case "p":
        state.twoPass.toggle()
    case "g":
        state.glossaryEnabled.toggle()
    case "c":
        state.chunkSizeIndex = (state.chunkSizeIndex + 1) % chunkSizes.count
    case "s":
        state.showPrompt.toggle()
    case "f":
        showFullOutput()
    case "r", "":
        await runTranslation()
    default:
        if let number = Int(key), (1...Samples.all.count).contains(number) {
            state.sampleIndex = number - 1
            state.outcome = nil
        }
    }
    render()
}

clearScreen()
print("bye")
