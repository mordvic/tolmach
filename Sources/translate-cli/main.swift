// Sources/translate-cli/main.swift
import Foundation
import OllamaKit
import LMStudioKit
import TranslationCore

/// Parse failure reason, kept distinct from `Options.text` values so a plain `String`
/// doesn't need a retroactive `Error` conformance just to ride inside a `Result`.
struct ParseFailure: Error { let message: String }

struct Options {
    var to: String?
    var from: String?
    /// Optional with a late default rather than `= "neutral"`: «rejected under
    /// --proofread» is decidable only if an explicit value is distinguishable from the
    /// default — with an eager default the rejection would be unreachable and the flag
    /// would quietly do nothing, the `--from` defect's exact shape.
    var tone: String?
    var proofread = false
    var level: ProofreadingLevel?
    var style: RewriteStyle?
    var model: String?
    var chunk = 900
    var think: ThinkRequest?
    /// Which local server to talk to. Defaults to Ollama, like the app's own setting, so an
    /// existing invocation keeps working unchanged.
    var engine = "ollama"
    var text: [String] = []
}

func parse(_ args: [String]) -> Result<Options, ParseFailure> {
    var options = Options()
    var index = 0
    while index < args.count {
        let argument = args[index]
        // A flag needs a value; running off the end is an error, not a default.
        func takeValue() -> String? {
            guard index + 1 < args.count else { return nil }
            index += 1
            return args[index]
        }
        switch argument {
        case "--to":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--to needs a value")) }
            options.to = value
        case "--from":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--from needs a value")) }
            options.from = value
        case "--tone":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--tone needs a value")) }
            options.tone = value
        case "--model":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--model needs a value")) }
            options.model = value
        case "--chunk":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--chunk needs a value")) }
            guard let parsed = Int(value), parsed > 0 else {
                return .failure(ParseFailure(message: "--chunk needs a positive integer, got \"\(value)\""))
            }
            options.chunk = parsed
        case "--think":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--think needs a value")) }
            if value == "off" {
                options.think = .off
            } else if let level = ThinkRequest.Level(rawValue: value) {
                // Read through `Level(rawValue:)` rather than matching the three strings a
                // second time: a fourth level added to `ThinkRequest` is then accepted here
                // without an edit, and cannot be accepted by the enum but refused by the flag.
                options.think = .level(level)
            } else {
                // Rejected rather than defaulted, for `--chunk`'s reason: a silent fallback
                // would make a mistyped flag look like a measurement.
                return .failure(ParseFailure(message: "--think needs one of off|low|medium|high, got \"\(value)\""))
            }
        case "--proofread":
            options.proofread = true
        case "--level":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--level needs a value")) }
            // Read through `init(rawValue:)` with the choices listed from `allCases`, the
            // `--think` pattern: a level added to the enum is accepted and advertised here
            // without an edit, and cannot be accepted by the enum but refused by the flag.
            guard let level = ProofreadingLevel(rawValue: value) else {
                return .failure(ParseFailure(message: "--level needs one of \(ProofreadingLevel.allCases.map(\.rawValue).joined(separator: "|")), got \"\(value)\""))
            }
            options.level = level
        case "--style":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--style needs a value")) }
            guard let style = RewriteStyle(rawValue: value) else {
                return .failure(ParseFailure(message: "--style needs one of \(RewriteStyle.allCases.map(\.rawValue).joined(separator: "|")), got \"\(value)\""))
            }
            options.style = style
        case "--engine":
            guard let value = takeValue() else { return .failure(ParseFailure(message: "--engine needs a value")) }
            guard value == "ollama" || value == "lmstudio" else {
                return .failure(ParseFailure(message: "--engine needs ollama or lmstudio, got \"\(value)\""))
            }
            options.engine = value
        default:
            // Everything not consumed as a flag value is text — including a word
            // that happens to equal a default, and including text starting with "--".
            // An unrecognised "--foo"-shaped argument is deliberately treated as text
            // rather than rejected: a user pasting text that begins with a dash is far
            // likelier than a user inventing a flag.
            options.text.append(argument)
        }
        index += 1
    }
    return .success(options)
}

let usage = "usage: translate-cli --to <ru|en|de|fr|es|pt|it|zh|ja> [--from L] [--tone neutral|formal|casual|technical|literal] [--engine ollama|lmstudio] [--model NAME] [--chunk N] [--think off|low|medium|high] [text]\n"
    + "       translate-cli --proofread [--level errorsOnly|errorsAndStyle|rewrite] [--style original|friendly|business|professional|plain] [--from L] [--engine ollama|lmstudio] [--model NAME] [--chunk N] [--think off|low|medium|high] [text]\n"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
let parsed: Options
switch parse(args) {
case .success(let options): parsed = options
case .failure(let failure): fail(failure.message)
}

// The operation split. Each side's inapplicable flags are **rejected**, never ignored,
// for `--think`-on-LM-Studio's reason: a flag that quietly did nothing would make a
// mistyped measurement look like a result — and this tool exists to take measurements
// (the правка calibration gate, issue #40, runs through it).
var target: Language?
if parsed.proofread {
    if parsed.to != nil {
        fail("--to applies to translation only; a proofread stays in the text's own language")
    }
    if parsed.tone != nil {
        fail("--tone applies to translation only; under --proofread the register is --style")
    }
} else {
    if parsed.level != nil || parsed.style != nil {
        fail("--level and --style apply to --proofread only")
    }
    guard let toRaw = parsed.to, let parsedTarget = Language(rawValue: toRaw) else {
        fail(parsed.to == nil ? "--to is required" : "--to needs one of ru|en|de|fr|es|pt|it|zh|ja, got \"\(parsed.to!)\"")
    }
    target = parsedTarget
}
// Failed on loudly, exactly like `--to` above. `flatMap` alone turned a typo into
// «detect it», so `--from ge` translated from whatever the detector guessed and said
// nothing — a silent answer to a flag whose whole purpose is to overrule the detector.
var source: Language?
if let fromRaw = parsed.from {
    guard let parsedSource = Language(rawValue: fromRaw) else {
        fail("--from needs one of ru|en|de|fr|es|pt|it|zh|ja, got \"\(fromRaw)\"")
    }
    source = parsedSource
}
// The default lands here, not in `Options`: an explicit value had to stay
// distinguishable for the rejection above. "neutral" always parses, so the `!` in the
// message is reachable only with a user-supplied value to show.
guard let tone = Tone(rawValue: parsed.tone ?? "neutral") else {
    fail("--tone needs one of neutral|formal|casual|technical|literal, got \"\(parsed.tone!)\"")
}
// The defaults land late, like --tone's, and for the same reason: the presence of an
// explicit value drives the rejections here and in the operation split above.
let level = parsed.level ?? .errorsOnly
let style = parsed.style ?? .original
// The same availability rule every UI surface reads, applied as a rejection: the engine
// would drop the style silently under a level that forbids it (the prompt-builder guard),
// which is correct for the app and exactly the «quietly did nothing» shape here.
if parsed.style != nil, !level.allowsRewriteStyle {
    fail("--style needs a level whose wording may move, got --level \(level.rawValue)")
}
let model = parsed.model ?? ModelPolicy.defaultModel(for: .interactive)
// No --two-pass flag: the second pass is cut from v1 (see Global Constraints).
let chunk = parsed.chunk

let text = parsed.text.isEmpty
    ? (String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "")
    : parsed.text.joined(separator: " ")
guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write(Data("no input text\n".utf8)); exit(2)
}

if let reason = ModelPolicy.blacklistReason(for: model) {
    FileHandle.standardError.write(Data("warning: model \(model) is blacklisted — \(reason)\n".utf8))
}

// `--think` exists to force a bare value past `ModelPolicy` and re-take a measurement, and
// on LM Studio there is no bare value to force: `reasoning` is validated against the model's
// own `allowed_options`, and «off» on a model that cannot be silenced is HTTP 400 (measured
// 2026-08-21). Rejected rather than ignored, for `--chunk`'s reason — a flag that quietly did
// nothing would make a mistyped measurement look like a result.
if parsed.engine == "lmstudio", parsed.think != nil {
    fail("--think applies to Ollama only; LM Studio resolves reasoning from the model's own capabilities")
}
let translator = Translator(client: parsed.engine == "lmstudio"
                            ? LMStudioClient() as any LLMClient
                            : OllamaClient() as any LLMClient)
// Straight into `ChatOptions`, deliberately bypassing `ModelPolicy.thinkRequest`: this flag
// exists to reproduce measurements, and a harness that refused to send `false` to `qwen3:30b`
// could not reproduce the leak that policy is built around. The app is where a user is
// protected; this is where a measurement is taken.
let chatOptions = ChatOptions(model: model, temperature: 0.2, keepAlive: "30m", think: parsed.think)

do {
    let outcome: TranslationOutcome
    if parsed.proofread {
        outcome = try await translator.proofread(
            text: text, level: level, style: style, source: source,
            options: chatOptions, maxChunkCharacters: chunk,
            onToken: { FileHandle.standardOutput.write(Data($0.utf8)) })
    } else {
        // Non-nil by the operation split above; the guard keeps the unwrap honest.
        guard let target else { fail("--to is required") }
        outcome = try await translator.translate(
            text: text, target: target, tone: tone, userGlossary: nil,
            // Passed. It was parsed at the top and then never read again, so `--from` was
            // advertised in the usage string and did nothing at all: the prompt, the tagger
            // `TermExtractor` parses with and the footer's detected language all came from the
            // detector regardless. Before `translate(source:)` existed there was nowhere to put
            // it; there is now, and CLAUDE.md says every caller states its language.
            source: source,
            options: chatOptions, maxChunkCharacters: chunk,
            onToken: { FileHandle.standardOutput.write(Data($0.utf8)) })
    }
    FileHandle.standardOutput.write(Data("\n".utf8))
    let ttftDescription = outcome.timeToFirstTokenMS.map { "\(Int($0))ms" } ?? "—"
    var footer = "\n— \(ttftDescription) TTFT · \(Int(outcome.totalMS))ms total · \(outcome.chunks.count) chunk(s)"
    if !outcome.documentGlossary.isEmpty { footer += " · \(outcome.documentGlossary.count) document terms" }
    let missing = outcome.checks.filter { $0.status == .missing }
    if !missing.isEmpty { footer += " · glossary misses: \(missing.map(\.term).joined(separator: ", "))" }
    if !outcome.markupDiffs.isEmpty { footer += " · \(outcome.markupDiffs.count) markup diff(s)" }
    // The engine swallows a failed document-glossary call on purpose — it is an enhancement,
    // not the result — so without this line a multi-chunk run that lost its terminology pass
    // looks exactly like one that never needed it. The app records the same value through
    // `Log.engine`; this is the developer-facing half.
    if let failure = outcome.documentGlossaryFailure {
        footer += " · document glossary failed: \(failure)"
    }
    FileHandle.standardError.write(Data((footer + "\n").utf8))
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
}
