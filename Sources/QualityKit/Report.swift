import Foundation
import TranslationCore

/// One line of the mechanics table: every successful cell of one model × temperature ×
/// language × level × style.
public struct ReportRow: Sendable, Equatable {
    public let model: String
    public let temperature: Double
    public let language: String
    public let level: String
    public let style: String
    /// Answered cells. Every rate below is over these; a failed cell is in `errors` only.
    public let cells: Int
    public let errors: Int
    /// «Холостой ход» against the source: the reply changed nothing.
    public let idleSource: Int
    /// The reply is, token for token, the reply under «как в оригинале» at the same run index
    /// — **the style was not applied**. nil on the control's own row.
    public let idleControl: Int?
    /// How many cells had an answered control to be compared with.
    public let comparedWithControl: Int
    public let shiftSource: Double?
    public let shiftControl: Double?
    /// On the control's row only: the median shift between two control runs of the same text.
    /// A style's `shiftControl` means something only above this.
    public let noiseFloor: Double?
    public let flagCounts: [Mechanics.Flag: Int]
    public let medianTotalMS: Double?
}

public enum Report {
    public static func rows(_ records: [CellRecord]) -> [ReportRow] {
        struct Key: Hashable { let model: String; let temperature: Double; let language, level, style: String }
        struct ControlKey: Hashable { let item: String; let configuration: Configuration; let run: Int }

        // Recomputed, never read back: see `CellRecord.mechanics`.
        let mechanics = Dictionary(records.filter { $0.error == nil }.map { (Self.id($0), $0.currentMechanics) },
                                   uniquingKeysWith: { first, _ in first })
        let answered = records.filter { $0.error == nil }
        let controls = Dictionary(answered.filter(\.configuration.isControl)
            .map { (ControlKey(item: $0.item, configuration: $0.configuration, run: $0.run), $0) },
                                  uniquingKeysWith: { first, _ in first })

        let groups = Dictionary(grouping: records) {
            Key(model: $0.configuration.model, temperature: $0.configuration.temperature, language: $0.language,
                level: $0.configuration.level ?? "-", style: $0.configuration.style ?? "-")
        }

        let rows = groups.map { key, members -> ReportRow in
            let ok = members.filter { $0.error == nil }
            let isControl = members.first?.configuration.isControl ?? false

            var controlShifts: [Double] = []
            var idleControl = 0, compared = 0
            if !isControl {
                for record in ok {
                    guard let control = controls[ControlKey(item: record.item,
                                                            configuration: record.configuration.control,
                                                            run: record.run)] else { continue }
                    compared += 1
                    let changes = TextDiff.changes(source: control.reply, result: record.reply)
                    if changes.notCompared == nil && changes.count == 0 { idleControl += 1 }
                    if let shift = MechanicalChecks.shift(of: changes) { controlShifts.append(shift) }
                }
            }

            var noise: [Double] = []
            if isControl {
                for (_, runs) in Dictionary(grouping: ok, by: \.item) {
                    let sorted = runs.sorted { $0.run < $1.run }
                    for i in sorted.indices {
                        for j in sorted.indices where j > i {
                            if let shift = MechanicalChecks.shift(between: sorted[i].reply, and: sorted[j].reply) {
                                noise.append(shift)
                            }
                        }
                    }
                }
            }

            var flags: [Mechanics.Flag: Int] = [:]
            for flag in ok.flatMap({ mechanics[Self.id($0)]?.flags ?? [] }) { flags[flag, default: 0] += 1 }

            return ReportRow(model: key.model, temperature: key.temperature, language: key.language,
                             level: key.level, style: key.style, cells: ok.count,
                             errors: members.count - ok.count,
                             idleSource: ok.filter { mechanics[Self.id($0)]?.idle == true }.count,
                             idleControl: isControl ? nil : idleControl, comparedWithControl: compared,
                             shiftSource: median(ok.compactMap { mechanics[Self.id($0)]?.shift }),
                             shiftControl: isControl ? nil : median(controlShifts),
                             noiseFloor: isControl ? median(noise) : nil,
                             flagCounts: flags, medianTotalMS: median(ok.map(\.totalMS)))
        }

        let levelOrder = ProofreadingLevel.allCases.map(\.rawValue), styleOrder = RewriteStyle.allCases.map(\.rawValue)
        func rank(_ value: String, in order: [String]) -> Int { order.firstIndex(of: value) ?? order.count }
        return rows.sorted {
            ($0.model, $0.temperature, $0.language, rank($0.level, in: levelOrder), rank($0.style, in: styleOrder))
            < ($1.model, $1.temperature, $1.language, rank($1.level, in: levelOrder), rank($1.style, in: styleOrder))
        }
    }

    private static func id(_ record: CellRecord) -> String {
        Cell.fileName(item: record.item, configuration: record.configuration, run: record.run)
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// One line per answered cell that carries a flag — the diagnostic half: not «how often»,
    /// but which text, under which configuration, lost what.
    public static func failures(_ records: [CellRecord]) -> [String] {
        records.filter { $0.error == nil }.compactMap { record -> String? in
            let c = record.configuration, m = record.currentMechanics
            guard !m.flags.isEmpty else { return nil }
            let details = m.flags.map { flag -> String in
                switch flag {
                case .missingNumber: "missingNumber: \(m.missingNumbers.joined(separator: ", "))"
                case .missingFact: "missingFact: \(m.missingFacts.joined(separator: ", "))"
                case .wrongLanguage: "wrongLanguage: \(m.replyLanguage ?? "undetected")"
                case .lostQuestion: "lostQuestion: \(m.sourceQuestions) → \(m.replyQuestions)"
                case .lengthOutOfRange: "lengthOutOfRange: ×\(String(format: "%.2f", m.lengthRatio))"
                case .emptyReply: "emptyReply"
                }
            }
            return "\(record.item) · \(c.model) · t\(String(format: "%.2f", c.temperature)) · " +
                   "\(c.level ?? "-") · \(c.style ?? "-") · r\(record.run) — \(details.joined(separator: "; "))"
        }
    }

    public static func render(manifest: RunManifest, records: [CellRecord]) -> String {
        var out = manifest.headline + "\n"
        // The way `acceptance` prints `info only`: a reader must not take the absence of a
        // judged column for a judgement that found nothing.
        out += "mechanics only — no judge has read these replies; смысл, стиль and естественность are not in this table\n\n"

        let header = ["model", "t", "lang", "level", "style", "n", "err", "idle/src", "idle/ctl",
                      "shift/src", "shift/ctl", "noise", "lang✗", "num✗", "fact✗", "q✗", "len✗", "empty", "ms"]
        func ratio(_ part: Int, _ whole: Int) -> String { whole == 0 ? "–" : "\(part)/\(whole)" }
        func share(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "–" }
        let body = rows(records).map { row -> [String] in
            func flag(_ f: Mechanics.Flag) -> String { String(row.flagCounts[f] ?? 0) }
            return [row.model, String(format: "%.2f", row.temperature), row.language, row.level, row.style,
                    String(row.cells), String(row.errors), ratio(row.idleSource, row.cells),
                    row.idleControl.map { ratio($0, row.comparedWithControl) } ?? "–",
                    share(row.shiftSource), share(row.shiftControl), share(row.noiseFloor),
                    flag(.wrongLanguage), flag(.missingNumber), flag(.missingFact), flag(.lostQuestion),
                    flag(.lengthOutOfRange), flag(.emptyReply),
                    row.medianTotalMS.map { String(Int($0.rounded())) } ?? "–"]
        }
        let widths = header.indices.map { column in ([header] + body).map { $0[column].count }.max() ?? 0 }
        for line in [header] + body {
            out += zip(line, widths).map { $0 + String(repeating: " ", count: $1 - $0.count) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces) + "\n"
        }

        let failed = records.filter { $0.error != nil }
        if !failed.isEmpty {
            out += "\nerrors (\(failed.count)) — not answered, in no rate above, retried on resume:\n"
            for record in failed {
                out += "  \(record.item) · \(record.configuration.model) · \(record.configuration.style ?? "-") · r\(record.run) — \(record.error ?? "")\n"
            }
        }
        let flagged = failures(records)
        if !flagged.isEmpty {
            out += "\nflagged (\(flagged.count)) — for a reader, not verdicts:\n"
            for line in flagged { out += "  \(line)\n" }
        }
        return out
    }
}
