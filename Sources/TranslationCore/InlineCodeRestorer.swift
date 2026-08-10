// Sources/TranslationCore/InlineCodeRestorer.swift
import Foundation

/// Restores inline-code span contents from the source after a model reply — the inline
/// half of «protection by construction» (spec §2.2; the fenced half is pass-through
/// chunks in `Chunker`). Restore fires only when the reply's span count equals the
/// source's: the measured failure mode is exactly the equal-count case (delimiters
/// kept, content edited — 3/3 on every failing calibration file), and under any
/// mismatch a positional alignment could inject source bytes into the wrong span,
/// which is worse than no restore. Span definition: `MarkupSkeleton.inlineCodeSpans`,
/// per line, shared with the skeleton diff.
enum InlineCodeRestorer {
    static func restore(reply: String, source: String) -> String {
        let sourceSpans = spans(of: source)
        guard !sourceSpans.isEmpty else { return reply }
        let replyLines = reply.components(separatedBy: "\n")
        let replySpanCount = replyLines.reduce(0) {
            $0 + MarkupSkeleton.inlineCodeSpans(in: $1).count
        }
        guard replySpanCount == sourceSpans.count else { return reply }
        var next = 0
        var rebuilt: [String] = []
        rebuilt.reserveCapacity(replyLines.count)
        for line in replyLines {
            let lineSpans = MarkupSkeleton.inlineCodeSpans(in: line)
            guard !lineSpans.isEmpty else { rebuilt.append(line); continue }
            let ns = NSMutableString(string: line)
            // Right-to-left, so the earlier spans' NSRanges stay valid while later
            // ones are replaced; `next + offset` pairs this line's spans with the
            // source's, in document order.
            for (offset, span) in lineSpans.enumerated().reversed() {
                ns.replaceCharacters(in: span.range, with: sourceSpans[next + offset])
            }
            next += lineSpans.count
            rebuilt.append(ns as String)
        }
        return rebuilt.joined(separator: "\n")
    }

    private static func spans(of text: String) -> [String] {
        text.components(separatedBy: "\n")
            .flatMap { MarkupSkeleton.inlineCodeSpans(in: $0) }
            .map(\.content)
    }
}
