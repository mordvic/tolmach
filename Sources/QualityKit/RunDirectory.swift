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
    public let mechanics: Mechanics
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
                source: String, reply: String, facts: [ItemMeta.Fact], mechanics: Mechanics,
                ttftMS: Double?, totalMS: Double,
                modelChunkCount: Int, markupDiffs: Int, markupNotCompared: Bool, error: String?) {
        self.item = item; self.language = language; self.configuration = configuration; self.run = run
        self.source = source; self.reply = reply; self.facts = facts; self.mechanics = mechanics
        self.ttftMS = ttftMS; self.totalMS = totalMS; self.modelChunkCount = modelChunkCount
        self.markupDiffs = markupDiffs; self.markupNotCompared = markupNotCompared; self.error = error
    }
}

extension CellRecord {
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
    /// The corpus is not committed to this repository. **`quality blind` refuses such a run**:
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

    /// What must match for a directory to be resumed. Not the date, and not the engine's
    /// version string — an Ollama update overnight is worth a line, not a refusal.
    fileprivate var identity: RunManifest {
        var copy = self
        copy.createdAt = ""; copy.engineVersion = nil
        return copy
    }
}

/// `build/quality-runs/<stamp>-<label>/` — `manifest.json` and `cells/*.json`.
public struct RunDirectory: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case differentConfiguration(path: String)
        public var description: String {
            switch self {
            case let .differentConfiguration(path):
                "\(path) was created under a different configuration (model list, filter, temperature, " +
                "chunk, corpus or commit) — two experiments in one directory would be one table describing both"
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
            guard existing.identity == manifest.identity else {
                throw Failure.differentConfiguration(path: url.path)
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

    public func records() throws -> [CellRecord] {
        try FileManager.default.contentsOfDirectory(atPath: cells.path)
            .filter { $0.hasSuffix(".json") }.sorted()
            .map { try JSONDecoder().decode(CellRecord.self, from: Data(contentsOf: cells.appendingPathComponent($0))) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
