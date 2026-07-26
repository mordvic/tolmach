// Sources/translate-cli/main.swift
import Foundation
import OllamaKit
import TranslationCore

func value(for flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard let toRaw = value(for: "--to", in: args), let target = Language(rawValue: toRaw) else {
    FileHandle.standardError.write(Data("usage: translate-cli --to <ru|en|de|fr|es|pt|it|zh|ja> [--from L] [--tone neutral|formal|casual|technical|literal] [--model NAME] [--chunk N] [text]\n".utf8))
    exit(2)
}
let source = value(for: "--from", in: args).flatMap(Language.init(rawValue:))
let tone = value(for: "--tone", in: args).flatMap(Tone.init(rawValue:)) ?? .neutral
let model = value(for: "--model", in: args) ?? ModelPolicy.defaultModel(for: .interactive)
// No --two-pass flag: the second pass is cut from v1 (see Global Constraints).
let chunk = value(for: "--chunk", in: args).flatMap(Int.init) ?? 900

let positional = args.filter { !$0.hasPrefix("--") }
    .filter { arg in ![toRaw, source?.rawValue, tone.rawValue, model, String(chunk)].compactMap { $0 }.contains(arg) }
let text = positional.last ?? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write(Data("no input text\n".utf8)); exit(2)
}

if let reason = ModelPolicy.blacklistReason(for: model) {
    FileHandle.standardError.write(Data("warning: model \(model) is blacklisted — \(reason)\n".utf8))
}

let translator = Translator(client: OllamaClient())
let options = ChatOptions(model: model, temperature: 0.2, keepAlive: "30m")

do {
    let outcome = try await translator.translate(
        text: text, target: target, tone: tone, userGlossary: nil,
        options: options, maxChunkCharacters: chunk,
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
