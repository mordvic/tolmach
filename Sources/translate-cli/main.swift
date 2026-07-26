// Sources/translate-cli/main.swift
import Foundation
import OllamaKit
import TranslationCore

/// Parse failure reason, kept distinct from `Options.text` values so a plain `String`
/// doesn't need a retroactive `Error` conformance just to ride inside a `Result`.
struct ParseFailure: Error { let message: String }

struct Options {
    var to: String?
    var from: String?
    var tone = "neutral"
    var model: String?
    var chunk = 900
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

let usage = "usage: translate-cli --to <ru|en|de|fr|es|pt|it|zh|ja> [--from L] [--tone neutral|formal|casual|technical|literal] [--model NAME] [--chunk N] [text]\n"

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

guard let toRaw = parsed.to, let target = Language(rawValue: toRaw) else {
    fail(parsed.to == nil ? "--to is required" : "--to needs one of ru|en|de|fr|es|pt|it|zh|ja, got \"\(parsed.to!)\"")
}
let source = parsed.from.flatMap(Language.init(rawValue:))
guard let tone = Tone(rawValue: parsed.tone) else {
    fail("--tone needs one of neutral|formal|casual|technical|literal, got \"\(parsed.tone)\"")
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

let translator = Translator(client: OllamaClient())
let chatOptions = ChatOptions(model: model, temperature: 0.2, keepAlive: "30m")

do {
    let outcome = try await translator.translate(
        text: text, target: target, tone: tone, userGlossary: nil,
        options: chatOptions, maxChunkCharacters: chunk,
        onToken: { FileHandle.standardOutput.write(Data($0.utf8)) })
    FileHandle.standardOutput.write(Data("\n".utf8))
    var footer = "\n— \(Int(outcome.timeToFirstTokenMS))ms TTFT · \(Int(outcome.totalMS))ms total · \(outcome.chunks.count) chunk(s)"
    if !outcome.documentGlossary.isEmpty { footer += " · \(outcome.documentGlossary.count) document terms" }
    let missing = outcome.checks.filter { $0.status == .missing }
    if !missing.isEmpty { footer += " · glossary misses: \(missing.map(\.term).joined(separator: ", "))" }
    if !outcome.markupDiffs.isEmpty { footer += " · \(outcome.markupDiffs.count) markup diff(s)" }
    FileHandle.standardError.write(Data((footer + "\n").utf8))
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1)
}
