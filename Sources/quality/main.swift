import Foundation
import TranslationCore
import OllamaKit
import QualityKit

// The `quality` harness: a comparison stand and a diagnostic for what `acceptance` cannot see —
// whether a style was applied at all, and what a reply lost. Everything that decides anything
// is in `QualityKit`, where a test can reach it; this file parses arguments, talks to the
// engine and the file system, and prints. Like `acceptance` it needs a live engine, is not in
// CI, and must run from the package root. Ollama only: the campaign it was built for is
// (`docs/design/specs/2026-09-22-quality-harness-design.md` §6), and the transport is
// `OllamaClient`, so the harness is loopback-only by construction rather than by agreement.

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
usage:
  quality run --corpus <dir> --models <a,b> [--levels errorsAndStyle,rewrite]
              [--styles friendly,business,professional,plain] [--only <item,item>] [--runs 3]
              [--temperature 0.2] [--chunk 4000] [--label <word>] [--into <run-dir>]
  quality report <run-dir> [<run-dir> …]
  quality blind <run-a> <run-b> --into <comparison-dir> [--model-a <m>] [--model-b <m>]
                [--sample <pairs>] [--seed <n>]
  quality judge --human <comparison-dir>
  quality judged <comparison-dir>

run writes build/quality-runs/<stamp>-<label>/ and is resumable: --into an existing run
directory calls only the cells it does not already hold. «original» is always run beside a
named style — it is the control.

blind pairs the two runs' answered cells (same text, level, style, run index) into packets a
judge can be handed: packets/ holds them, key.json says which side each X was and is NOT for
the judge. Give the same run twice with --model-a/--model-b to compare two of its models.
A run over a corpus that is not committed is refused. Verdicts go to verdicts/claude/ (a fresh
sub-agent, docs/agents/quality-judge.md) and verdicts/human/ (judge --human); judged prints
the tallies, with the calibration status on its first line.
"""

let prettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// A comparison directory as `blind` wrote it and the judges filled it.
func readComparison(_ path: String) -> (key: PacketKey, packets: [Packet], verdicts: [Verdict]) {
    let url = URL(fileURLWithPath: path)
    func names(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }
    do {
        let key = try JSONDecoder().decode(PacketKey.self, from: Data(contentsOf: url.appendingPathComponent("key.json")))
        let packetsURL = url.appendingPathComponent("packets")
        let packets = try names(packetsURL).map {
            try JSONDecoder().decode(Packet.self, from: Data(contentsOf: packetsURL.appendingPathComponent($0)))
        }
        var verdicts: [Verdict] = []
        for judge in ["claude", "human"] {
            let directory = url.appendingPathComponent("verdicts").appendingPathComponent(judge)
            for name in names(directory) {
                // A verdict a judge wrote badly is that verdict's problem, named, and not the
                // end of the report: the file is the work of a model or of a tired person.
                guard var verdict = try? JSONDecoder().decode(Verdict.self, from: Data(contentsOf: directory.appendingPathComponent(name))) else {
                    FileHandle.standardError.write(Data("unreadable verdict, skipped: verdicts/\(judge)/\(name)\n".utf8))
                    continue
                }
                // The directory is the judge: a file under verdicts/human is a person's
                // whatever its own field says.
                verdict.judge = judge
                verdicts.append(verdict)
            }
        }
        return (key, packets, verdicts)
    } catch {
        fail("cannot read comparison directory \(path) — \(error)", code: 1)
    }
}

// A night's progress is read with `tail -f` on a redirected log, and redirected stdout is
// block-buffered: the first run of this harness wrote nothing to its log for ten minutes.
setvbuf(stdout, nil, _IOLBF, 0)

/// A tool's trimmed stdout, **nil when it is absent or exits non-zero** — so the manifest says
/// «unknown» rather than recording the empty string a failed `git rev-parse` prints, which
/// would describe a clean, known commit that does not exist.
func capture(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    // Discarded, not piped: an undrained pipe blocks its writer once it fills.
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func list<T: RawRepresentable & CaseIterable>(_ value: String, _ flag: String) -> [T] where T.RawValue == String {
    value.split(separator: ",").map { raw in
        guard let parsed = T(rawValue: String(raw)) else {
            fail("\(flag): \"\(raw)\" is not one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return parsed
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()

switch command {
case "report":
    guard !arguments.isEmpty else { fail(usage) }
    for (index, path) in arguments.enumerated() {
        do {
            let run = try RunDirectory.read(at: URL(fileURLWithPath: path))
            let read = try run.read()
            if index > 0 { print("\n" + String(repeating: "─", count: 72) + "\n") }
            print(Report.render(manifest: run.manifest, records: read.records), terminator: "")
            if !read.unreadable.isEmpty {
                print("\nunreadable (\(read.unreadable.count)) — in no row above, called again on resume: " +
                      read.unreadable.joined(separator: ", "))
            }
        } catch {
            fail("cannot read run directory \(path) — \(error)", code: 1)
        }
    }

case "run":
    var corpusPath: String?
    var models: [String] = []
    var levels: [ProofreadingLevel] = [.errorsAndStyle, .rewrite]
    var styles: [RewriteStyle] = [.friendly, .business, .professional, .plain]
    var only: [String] = []
    var runs = 3, chunk = 4000
    var temperature = 0.2
    var label = "run"
    var into: String?

    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        // An inapplicable or mistyped flag is refused, never ignored — `translate-cli`'s rule,
        // for its reason: a mistyped measurement must not look like a result.
        guard let value = iterator.next() else { fail("\(argument) needs a value\n\n\(usage)") }
        switch argument {
        case "--corpus": corpusPath = value
        case "--models": models = value.split(separator: ",").map(String.init)
        case "--levels": levels = list(value, argument)
        case "--styles": styles = list(value, argument)
        case "--only": only = value.split(separator: ",").map(String.init)
        case "--runs":
            guard let parsed = Int(value), parsed > 0 else { fail("--runs needs a positive integer") }
            runs = parsed
        case "--chunk":
            guard let parsed = Int(value), parsed > 0 else { fail("--chunk needs a positive integer") }
            chunk = parsed
        case "--temperature":
            guard let parsed = Double(value), (0...2).contains(parsed) else { fail("--temperature needs 0…2") }
            temperature = parsed
        case "--label": label = value
        case "--into": into = value
        default: fail("unknown argument \"\(argument)\"\n\n\(usage)")
        }
    }
    guard let corpusPath, !models.isEmpty else { fail("run needs --corpus and --models\n\n\(usage)") }

    let items: [CorpusItem]
    do { items = try CorpusLoader.load(directory: URL(fileURLWithPath: corpusPath)) } catch {
        fail("\(error)", code: 1)
    }
    let filter = MatrixFilter(models: models, levels: levels, styles: styles, only: only, runs: runs)
    let unknown = only.filter { name in !items.contains { $0.name == name } }
    guard unknown.isEmpty else { fail("--only names no such item: \(unknown.joined(separator: ", "))") }
    let cells = Matrix.cells(items: items, filter: filter, temperature: temperature)

    // «Not external» means the bytes the model was given are the bytes on GitHub: every text
    // and every sidecar tracked **at this path**, and nothing under the corpus directory
    // modified or untracked. A tracked file with working text pasted over it is still listed
    // by `ls-files`, which is why `status` is asked as well; and any doubt — no git, an error —
    // reads as external, because the flag guards texts that must not be handed to a cloud judge.
    let corpusURL = URL(fileURLWithPath: corpusPath).standardizedFileURL
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    let tracked = capture(["git", "ls-files", "--", corpusPath]).map {
        Set($0.split(separator: "\n").map { root.appendingPathComponent(String($0)).standardizedFileURL.path })
    }
    let untouched = capture(["git", "status", "--porcelain", "--", corpusPath])?.isEmpty
    let external: Bool
    if let tracked, untouched == true {
        external = !items.allSatisfy { item in
            let text = corpusURL.appendingPathComponent("\(item.name).txt").path
            let sidecar = corpusURL.appendingPathComponent("\(item.name).meta.json").path
            return tracked.contains(text) && (item.meta == nil || tracked.contains(sidecar))
        }
    } else {
        external = true
    }

    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmm"
    let manifest = RunManifest(
        label: label, createdAt: ISO8601DateFormatter().string(from: Date()),
        commit: capture(["git", "rev-parse", "--short", "HEAD"]) ?? "unknown",
        dirty: !(capture(["git", "status", "--porcelain", "--untracked-files=no"]) ?? "?").isEmpty,
        engine: "ollama",
        // The line that says so, not the first line: with the daemon down `ollama --version`
        // opens with a warning, and the last word of a warning is not a version.
        engineVersion: capture(["ollama", "--version"])?.split(separator: "\n")
            .first { $0.contains("version is") }?.split(separator: " ").last.map(String.init),
        chunk: chunk, temperature: temperature, corpusPath: corpusPath,
        corpusHash: CorpusLoader.hash(of: items), external: external, filter: filter)

    let directory: RunDirectory
    do {
        directory = try RunDirectory.open(
            at: URL(fileURLWithPath: into ?? "build/quality-runs/\(stamp.string(from: Date()))-\(label)"),
            manifest: manifest)
    } catch {
        fail("\(error)", code: 1)
    }

    print(directory.manifest.headline)
    let pending = cells.filter { !directory.has($0) }
    print("\(cells.count) cells, \(cells.count - pending.count) already answered → \(directory.url.path)")

    let runner = Runner(translator: Translator(client: OllamaClient()), chunk: chunk)
    var failures = 0
    for (index, cell) in pending.enumerated() {
        let record = try await runner.run(cell)
        do { try directory.write(record) } catch { fail("cannot write \(cell.fileName) — \(error)", code: 1) }
        let c = cell.configuration
        let tail: String
        if let error = record.error {
            failures += 1
            tail = "FAILED — \(error)"
        } else {
            let m = record.currentMechanics
            tail = "\(String(format: "%.1f", record.totalMS / 1000)) s · " +
                   "shift \(m.shift.map { String(format: "%.2f", $0) } ?? "–")\(m.idle ? " · IDLE" : "")" +
                   (record.currentAddedBlocks ? " · ADDED BLOCKS" : "") +
                   (m.flags.isEmpty ? "" : " · \(m.flags.map(\.rawValue).joined(separator: ", "))")
        }
        print("[\(index + 1)/\(pending.count)] \(cell.item.name) · \(c.model) · \(c.level ?? "-") · " +
              "\(c.style ?? "-") · r\(cell.run) — \(tail)")
        // A dead engine fails every cell in milliseconds; forty of those in a row is not a
        // night's work worth finishing, and the directory resumes from here.
        if failures >= 40 && failures == index + 1 {
            fail("the first \(failures) cells all failed — is the engine running? Resume with the same command " +
                 "plus --into \(directory.url.path) (--label need not be repeated; everything else must match)", code: 1)
        }
    }
    print("\ndone: \(pending.count - failures) answered, \(failures) failed · quality report \(directory.url.path)")

case "blind":
    var positional: [String] = []
    var into: String?, modelA: String?, modelB: String?
    var sample: Int?
    var seed: UInt64 = 1
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        guard argument.hasPrefix("--") else { positional.append(argument); continue }
        guard let value = iterator.next() else { fail("\(argument) needs a value\n\n\(usage)") }
        switch argument {
        case "--into": into = value
        case "--model-a": modelA = value
        case "--model-b": modelB = value
        case "--sample":
            guard let parsed = Int(value), parsed > 0 else { fail("--sample needs a positive integer") }
            sample = parsed
        case "--seed":
            guard let parsed = UInt64(value) else { fail("--seed needs a non-negative integer") }
            seed = parsed
        default: fail("unknown argument \"\(argument)\"\n\n\(usage)")
        }
    }
    guard positional.count == 2, let into else { fail("blind needs two run directories and --into\n\n\(usage)") }
    do {
        let sides = try zip(positional, [modelA, modelB]).map { path, model in
            let run = try RunDirectory.read(at: URL(fileURLWithPath: path))
            return Packets.Side(manifest: run.manifest, records: try run.records(), model: model)
        }
        let built = try Packets.build(a: sides[0], b: sides[1], sample: sample, seed: seed)
        let url = URL(fileURLWithPath: into)
        guard !FileManager.default.fileExists(atPath: url.appendingPathComponent("key.json").path) else {
            fail("\(into) already holds a comparison — packets rebuilt under verdicts already given would orphan them", code: 1)
        }
        for sub in ["packets", "verdicts/claude", "verdicts/human"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try prettyEncoder.encode(built.key).write(to: url.appendingPathComponent("key.json"), options: .atomic)
        for packet in built.packets {
            try prettyEncoder.encode(packet).write(to: url.appendingPathComponent("packets/\(packet.id).json"), options: .atomic)
        }
        print("\(built.key.pairs.count) pairs → \(built.packets.count) packets in \(into)/packets " +
              "(\(built.key.identicalPairs) identical pairs need no judge). key.json is not for the judge.")
    } catch {
        fail("\(error)", code: 1)
    }

case "judge":
    guard arguments.count == 2, arguments[0] == "--human" else { fail(usage) }
    let comparison = readComparison(arguments[1])
    let directory = URL(fileURLWithPath: arguments[1]).appendingPathComponent("verdicts/human")
    let done = Set(comparison.verdicts.filter { $0.judge == "human" }.map(\.packet))
    let pending = comparison.packets.filter { !done.contains($0.id) }
    print("\(pending.count) packets to judge, \(done.count) already judged. For each: three letters — " +
          "смысл, стиль, естественность — each x, y or = (e.g. «x y =»). «q» stops; what is judged is kept.\n")
    for (index, packet) in pending.enumerated() {
        print(String(repeating: "═", count: 72))
        print("[\(index + 1)/\(pending.count)] \(packet.id) · asked for: \(packet.level ?? "-") · стиль «\(packet.requestedStyle ?? "-")»")
        print("\n── ИСХОДНИК ──\n\(packet.source)\n\n── X ──\n\(packet.x)\n\n── Y ──\n\(packet.y)\n")
        if !packet.facts.isEmpty {
            print("факты, которые обязаны выжить: " + packet.facts.map(\.note).joined(separator: " · ") + "\n")
        }
        var answer: HumanAnswer?
        while answer == nil {
            print("смысл стиль естественность > ", terminator: "")
            guard let line = readLine() else { exit(0) }
            if line.trimmingCharacters(in: .whitespaces).lowercased() == "q" { exit(0) }
            answer = HumanAnswer.parse(line)
            if answer == nil { print("  three of x / y / =, please") }
        }
        guard let answer else { continue }
        let verdict = Verdict(packet: packet.id, rubric: Rubric.version, judge: "human", meaning: answer.meaning,
                              style: answer.style, naturalness: answer.naturalness,
                              lostFacts: .init(x: [], y: []), failures: [], note: nil)
        do { try prettyEncoder.encode(verdict).write(to: directory.appendingPathComponent("\(packet.id).json"), options: .atomic) } catch {
            fail("cannot write the verdict — \(error)", code: 1)
        }
    }
    print("\nall judged · quality judged \(arguments[1])")

case "judged":
    guard arguments.count == 1 else { fail(usage) }
    let comparison = readComparison(arguments[0])
    print(JudgedReport.render(key: comparison.key, packets: comparison.packets, verdicts: comparison.verdicts), terminator: "")

default:
    fail(usage)
}
