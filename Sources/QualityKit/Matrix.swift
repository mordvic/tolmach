import Foundation
import TranslationCore

/// One request's worth of configuration. Strings rather than the domain enums so the type is
/// `Codable` without a retroactive conformance on `TranslationCore`'s types, and so an
/// artifact written today still decodes after a case is renamed.
public struct Configuration: Codable, Sendable, Hashable {
    public let model: String
    public let temperature: Double
    /// `proofread` today; `translate` arrives with the translation corpus, which is why
    /// `target` and `tone` are already here — one artifact format for both routes.
    public let operation: String
    public let level: String?
    public let style: String?
    public let target: String?
    public let tone: String?

    public static func proofread(model: String, temperature: Double,
                                 level: ProofreadingLevel, style: RewriteStyle) -> Configuration {
        Configuration(model: model, temperature: temperature, operation: "proofread",
                      level: level.rawValue, style: style.rawValue, target: nil, tone: nil)
    }

    /// Where a named style's control lives: the same request under «как в оригинале».
    public var control: Configuration {
        Configuration(model: model, temperature: temperature, operation: operation,
                      level: level, style: RewriteStyle.original.rawValue, target: target, tone: tone)
    }

    public var isControl: Bool { style == RewriteStyle.original.rawValue }
}

/// What `quality run` was asked to cover. Written into the manifest, because a table from a
/// narrowed matrix is only comparable with a table narrowed the same way.
public struct MatrixFilter: Codable, Sendable, Equatable {
    public var models: [String]
    public var levels: [String]
    public var styles: [String]
    /// Item names; empty means every item.
    public var only: [String]
    public var runs: Int

    public init(models: [String], levels: [ProofreadingLevel], styles: [RewriteStyle],
                only: [String] = [], runs: Int) {
        self.models = models
        self.levels = levels.map(\.rawValue)
        self.styles = styles.map(\.rawValue)
        self.only = only
        self.runs = runs
    }
}

/// Text × configuration × run index — «ячейка».
public struct Cell: Sendable, Equatable {
    public let item: CorpusItem
    public let configuration: Configuration
    /// 1-based, so a file name reads the way a person counts runs.
    public let run: Int

    public var fileName: String { Self.fileName(item: item.name, configuration: configuration, run: run) }

    static func fileName(item: String, configuration c: Configuration, run: Int) -> String {
        let model = String(c.model.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        let parts = [item, model, String(format: "t%.2f", c.temperature),
                     c.level ?? c.target ?? "-", c.style ?? c.tone ?? "-", "r\(run)"]
        return parts.joined(separator: "__") + ".json"
    }
}

public enum Matrix {
    /// Model first, so one model stays resident for its whole share of the night — a switch
    /// is a cold load, ~2000 ms against ~155 ms warm, and under memory pressure an eviction.
    ///
    /// **«Как в оригинале» is added whenever a named style is asked for**: it is the control
    /// each of them is measured against. A level that allows no style
    /// (`ProofreadingLevel.allowsRewriteStyle`) runs the control alone.
    public static func cells(items: [CorpusItem], filter: MatrixFilter, temperature: Double) -> [Cell] {
        let levels = filter.levels.compactMap(ProofreadingLevel.init(rawValue:))
        var styles = filter.styles.compactMap(RewriteStyle.init(rawValue:))
        if !styles.contains(.original) { styles.insert(.original, at: 0) }
        let chosen = filter.only.isEmpty ? items : items.filter { filter.only.contains($0.name) }

        var cells: [Cell] = []
        for model in filter.models {
            for item in chosen {
                for level in levels {
                    for style in level.allowsRewriteStyle ? styles : [.original] {
                        for run in 1...max(1, filter.runs) {
                            cells.append(Cell(item: item,
                                              configuration: .proofread(model: model, temperature: temperature,
                                                                        level: level, style: style),
                                              run: run))
                        }
                    }
                }
            }
        }
        return cells
    }
}
