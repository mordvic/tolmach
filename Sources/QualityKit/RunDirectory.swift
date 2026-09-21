import Foundation
import TranslationCore

/// What one call produced — one JSON file under `cells/`.
public struct CellRecord: Codable, Sendable, Equatable {
    public let item: String
    public let language: String
    public let configuration: Configuration
    public let run: Int
    public let source: String
    public let reply: String
    /// The sidecar's facts as they were when the cell ran — with `source` and `reply` they make
    /// the record **self-contained**: everything the mechanical layer and the judge's checklist
    /// read is here, so neither needs the corpus directory to still exist or still match.
    public let facts: [ItemMeta.Fact]
    /// The mechanics **as computed when the cell ran** — a snapshot for whoever opens the JSON.
    /// `Report` never reads it: it recomputes from the bytes above (`currentMechanics`), so a
    /// check corrected after a night's run corrects that night's table too, without a re-run.
    public var mechanics: Mechanics?
    /// `TranslationOutcome.replyAddedBlocks` as the run saw it — the app's own «похоже, модель
    /// ответила на текст» signal. Recorded rather than recomputed: it is read off the run's
    /// markup diffs, which a record does not keep. nil in a record written before 2026-09-22.
    public var addedBlocks: Bool?
    /// nil when nothing was ever emitted — `TranslationOutcome`'s own contract, kept.
    public let ttftMS: Double?
    public let totalMS: Double
    public let modelChunkCount: Int
    public let markupDiffs: Int
    public let markupNotCompared: Bool
    /// A transport failure is **recorded, not thrown**: one refused connection at 03:00 must
    /// not cost the night. A record carrying one does not count as done (`RunDirectory.has`).
    public var error: String?

    public init(item: String, language: String, configuration: Configuration, run: Int,
                source: String, reply: String, facts: [ItemMeta.Fact], mechanics: Mechanics?,
                addedBlocks: Bool? = nil, ttftMS: Double?, totalMS: Double,
                modelChunkCount: Int, markupDiffs: Int, markupNotCompared: Bool, error: String?) {
        self.item = item; self.language = language; self.configuration = configuration; self.run = run
        self.source = source; self.reply = reply; self.facts = facts; self.mechanics = mechanics
        self.addedBlocks = addedBlocks
        self.ttftMS = ttftMS; self.totalMS = totalMS; self.modelChunkCount = modelChunkCount
        self.markupDiffs = markupDiffs; self.markupNotCompared = markupNotCompared; self.error = error
    }
}

extension CellRecord {
    /// **Lenient on purpose.** A run directory is a night of model time, and a decoder that
    /// refuses yesterday's file turns «a corrected check corrects last night's table» into «a
    /// new field deletes it». So what a later build added is optional here, and the mechanics
    /// snapshot — which nothing computes from — is dropped rather than fatal when it no longer
    /// decodes (a renamed `Mechanics.Flag` is enough).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(String.self, forKey: .item)
        language = try c.decode(String.self, forKey: .language)
        configuration = try c.decode(Configuration.self, forKey: .configuration)
        run = try c.decode(Int.self, forKey: .run)
        source = try c.decode(String.self, forKey: .source)
        reply = try c.decode(String.self, forKey: .reply)
        facts = try c.decodeIfPresent([ItemMeta.Fact].self, forKey: .facts) ?? []
        mechanics = try? c.decodeIfPresent(Mechanics.self, forKey: .mechanics)
        addedBlocks = try c.decodeIfPresent(Bool.self, forKey: .addedBlocks)
        ttftMS = try c.decodeIfPresent(Double.self, forKey: .ttftMS)
        totalMS = try c.decodeIfPresent(Double.self, forKey: .totalMS) ?? 0
        modelChunkCount = try c.decodeIfPresent(Int.self, forKey: .modelChunkCount) ?? 0
        markupDiffs = try c.decodeIfPresent(Int.self, forKey: .markupDiffs) ?? 0
        markupNotCompared = try c.decodeIfPresent(Bool.self, forKey: .markupNotCompared) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    /// The app's «похоже, модель ответила на текст» signal, asked of this record's own bytes by
    /// the app's own rule (`TranslationOutcome.addedBlocks(in:)`) — so a record written before
    /// the harness kept the signal answers like any other. A правка-only reading, as in the app.
    public var currentAddedBlocks: Bool {
        guard error == nil, configuration.operation == "proofread" else { return false }
        return TranslationOutcome.addedBlocks(in: MarkupSkeleton.compare(source: source, translation: reply).diffs)
    }

    /// The mechanics of this record under the checks as they are **now**.
    public var currentMechanics: Mechanics {
        let translated = configuration.operation == "translate"
        let expected = Language(rawValue: (translated ? configuration.target : nil) ?? language) ?? .en
        return MechanicalChecks.evaluate(source: source, reply: reply, expectedLanguage: expected,
                                         sameLanguage: !translated, facts: facts)
    }
}

/// Everything needed to know whether two прогона are comparable.
public struct RunManifest: Codable, Sendable, Equatable {
    public var label: String
    public var createdAt: String
    /// A prompt change is compared across two commits, so the commit *is* the configuration.
    public var commit: String
    public var dirty: Bool
    public var engine: String
    public var engineVersion: String?
    public var chunk: Int
    public var temperature: Double
    public var corpusPath: String
    public var corpusHash: String
    /// The corpus is not committed to this repository. `quality blind` — issue #94, PR 2, not
    /// in the code yet — keys its refusal on this flag:
    /// committed text is already public, a user's working texts are not
    /// (`docs/design/specs/2026-09-22-quality-harness-design.md` §3).
    public var external: Bool
    public var filter: MatrixFilter

    public init(label: String, createdAt: String, commit: String, dirty: Bool, engine: String,
                engineVersion: String?, chunk: Int, temperature: Double, corpusPath: String,
                corpusHash: String, external: Bool, filter: MatrixFilter) {
        self.label = label; self.createdAt = createdAt; self.commit = commit; self.dirty = dirty
        self.engine = engine; self.engineVersion = engineVersion; self.chunk = chunk
        self.temperature = temperature; self.corpusPath = corpusPath; self.corpusHash = corpusHash
        self.external = external; self.filter = filter
    }

    /// The first line of every report, pasted into `docs/reference/QUALITY.md` as it is — the
    /// rule `acceptance` follows, so an entry cannot describe a configuration it was not.
    public var headline: String {
        "quality: \(label) · engine \(engine)\(engineVersion.map { " \($0)" } ?? "") · " +
        "models \(filter.models.joined(separator: ", ")) · temperature \(String(format: "%.2f", temperature)) · " +
        "chunk \(chunk) · runs \(filter.runs) · corpus \(corpusPath) (\(corpusHash))" +
        "\(external ? " · EXTERNAL" : "") · commit \(commit)\(dirty ? "+dirty" : "")"
    }

    /// What differs between this manifest and the one a directory was created under, as
    /// «field (was → asked)» — empty means the directory may be resumed.
    ///
    /// Not the date; not the engine's version string (an Ollama update overnight is worth a
    /// line, not a refusal); and **not the label**, because the hint a dead run prints says
    /// «resume with --into <dir>» and nobody repeats `--label` from memory at that point.
    /// The corpus is compared by its hash and by its path without a trailing slash.
    func differences(from existing: RunManifest) -> [String] {
        func path(_ p: String) -> String { p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p }
        var found: [String] = []
        func check<T: Equatable>(_ name: String, _ was: T, _ asked: T) {
            if was != asked { found.append("\(name) (\(was) → \(asked))") }
        }
        check("commit", existing.commit, commit)
        check("uncommitted changes", existing.dirty, dirty)
        check("engine", existing.engine, engine)
        check("chunk", existing.chunk, chunk)
        check("temperature", existing.temperature, temperature)
        check("corpus path", path(existing.corpusPath), path(corpusPath))
        check("corpus hash", existing.corpusHash, corpusHash)
        check("external", existing.external, external)
        check("models", existing.filter.models, filter.models)
        check("levels", existing.filter.levels, filter.levels)
        check("styles", existing.filter.styles, filter.styles)
        check("only", existing.filter.only, filter.only)
        check("runs", existing.filter.runs, filter.runs)
        return found
    }
}

/// `build/quality-runs/<stamp>-<label>/` — `manifest.json` and `cells/*.json`.
public struct RunDirectory: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case differentConfiguration(path: String, differences: [String])
        public var description: String {
            switch self {
            case let .differentConfiguration(path, differences):
                "\(path) was created under a different configuration — \(differences.joined(separator: "; ")). " +
                "Two experiments in one directory would be one table describing both."
            }
        }
    }

    public let url: URL
    public let manifest: RunManifest
    private var cells: URL { url.appendingPathComponent("cells") }

    /// Creates the directory, or resumes it when its manifest is this one.
    public static func open(at url: URL, manifest: RunManifest) throws -> RunDirectory {
        let file = url.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: file) {
            let existing = try JSONDecoder().decode(RunManifest.self, from: data)
            let differences = manifest.differences(from: existing)
            guard differences.isEmpty else {
                throw Failure.differentConfiguration(path: url.path, differences: differences)
            }
            return RunDirectory(url: url, manifest: existing)
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("cells"),
                                                withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: file, options: .atomic)
        return RunDirectory(url: url, manifest: manifest)
    }

    /// An existing directory, for `quality report`.
    public static func read(at url: URL) throws -> RunDirectory {
        let data = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        return RunDirectory(url: url, manifest: try JSONDecoder().decode(RunManifest.self, from: data))
    }

    /// Done means *answered*: a record that carries a transport error is retried.
    public func has(_ cell: Cell) -> Bool {
        guard let data = try? Data(contentsOf: cells.appendingPathComponent(cell.fileName)),
              let record = try? JSONDecoder().decode(CellRecord.self, from: data) else { return false }
        return record.error == nil
    }

    public func write(_ record: CellRecord) throws {
        let name = Cell.fileName(item: record.item, configuration: record.configuration, run: record.run)
        try Self.encoder.encode(record).write(to: cells.appendingPathComponent(name), options: .atomic)
    }

    public func records() throws -> [CellRecord] { try read().records }

    /// Every record that reads, and the names of the files that do not — a torn write from a
    /// killed process is one lost cell, not a lost table.
    public func read() throws -> (records: [CellRecord], unreadable: [String]) {
        var records: [CellRecord] = [], unreadable: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: cells.path).sorted() where name.hasSuffix(".json") {
            if let data = try? Data(contentsOf: cells.appendingPathComponent(name)),
               let record = try? JSONDecoder().decode(CellRecord.self, from: data) {
                records.append(record)
            } else {
                unreadable.append(name)
            }
        }
        return (records, unreadable)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
