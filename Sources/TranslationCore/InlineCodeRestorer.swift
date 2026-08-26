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
    /// **Lines are `LineScanner`'s, not `"\n"`'s, and the terminators are put back as found.**
    ///
    /// Splitting on `"\n"` alone made a chunk whose interior break is a lone CR (or NEL, or
    /// U+2028 — all of which `Chunker` can leave inside a chunk, since only a blank line ends
    /// one) read as a single long line, and backticks then paired *across* that break into a
    /// span that exists in no layer but this one. If the model's reply happened to carry a
    /// matching count, the equal-count gate passed and `restore` spliced those wrong source
    /// bytes — line terminator included — over a real code span: the code destroyed and a CR
    /// injected into `final`. `MarkupSkeleton`, which shares the scanner, counted zero spans in
    /// the same bytes, so the two layers disagreed about the document they were both reading.
    ///
    /// Rejoining with each piece's own terminator is the other half, and it is not optional: a
    /// reply carrying a lone `"\r"` survived the old code only because the CR stayed inside a
    /// line's content. Scanning properly and rejoining with `"\n"` would have normalised it,
    /// which is a byte change in `final` — and `final` is what gets written to the user's disk.
    static func restore(reply: String, source: String) -> String {
        let sourceSpans = spans(of: source)
        guard !sourceSpans.isEmpty else { return reply }
        let replyPieces = LineScanner.pieces(reply)
        let replySpanCount = replyPieces.reduce(0) {
            $0 + MarkupSkeleton.inlineCodeSpans(in: $1.content).count
        }
        guard replySpanCount == sourceSpans.count else { return reply }
        var next = 0
        var rebuilt = ""
        for piece in replyPieces {
            let lineSpans = MarkupSkeleton.inlineCodeSpans(in: piece.content)
            guard !lineSpans.isEmpty else {
                rebuilt += piece.content + piece.terminator
                continue
            }
            let ns = NSMutableString(string: piece.content)
            // Right-to-left, so the earlier spans' NSRanges stay valid while later
            // ones are replaced; `next + offset` pairs this line's spans with the
            // source's, in document order.
            for (offset, span) in lineSpans.enumerated().reversed() {
                ns.replaceCharacters(in: span.range, with: sourceSpans[next + offset])
            }
            next += lineSpans.count
            rebuilt += (ns as String) + piece.terminator
        }
        return rebuilt
    }

    /// The source's spans, in document order. Shares `LineScanner` with `MarkupSkeleton`, so
    /// «what is a line» cannot differ between the layer that counts spans and the layer that
    /// restores them.
    static func spans(of text: String) -> [String] {
        LineScanner.pieces(text)
            .flatMap { MarkupSkeleton.inlineCodeSpans(in: $0.content) }
            .map(\.content)
    }
}
