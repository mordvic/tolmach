// Sources/TranslationCore/MarkupSkeleton.swift
import Foundation

public enum MarkupToken: Sendable, Equatable, Hashable {
    case heading(level: Int)
    case listItem(depth: Int)
    case blockquote
    case codeBlock(hash: Int, lang: String)
    case inlineCode(String)
    case url(bare: Bool)
    case paragraphBreak
    case hardLineBreak
    case tableRow
}

public struct MarkupDiff: Sendable, Equatable {
    public let expected: MarkupToken?
    public let actual: MarkupToken?
    public let note: String
}

/// The result of comparing two skeletons — including the case where the comparison was not made.
///
/// A plain `[MarkupDiff]` could not express that: an empty array means «the structure survived»,
/// and a check that answered the same thing for «this was too large to look at» would be lying
/// in the quietest possible way.
public struct MarkupComparison: Sendable, Equatable {
    public let diffs: [MarkupDiff]
    /// Nil when the comparison ran. Otherwise the two token counts that were too large to align,
    /// *after* the common prefix and suffix had already been trimmed away.
    public let notCompared: NotCompared?

    public struct NotCompared: Sendable, Equatable {
        public let sourceTokens: Int
        public let translationTokens: Int
    }

    public init(diffs: [MarkupDiff], notCompared: NotCompared?) {
        self.diffs = diffs
        self.notCompared = notCompared
    }
}

public enum MarkupSkeleton {
    public static func tokens(of text: String) -> [MarkupToken] {
        var tokens: [MarkupToken] = []
        // Lines, not strings, so blankness stays `LineScanner`'s one definition when the
        // EOF flush trims the tail — see `flushFence`.
        var fenceBuffer: [LineScanner.Line] = []
        var fenceLang = ""
        var insideFence = false
        var previousLineHadText = false

        /// `trimmingTail` is the unterminated-fence case: the chunker's fenced block
        /// runs to the end of the document with its trailing blank lines trimmed off —
        /// they are document whitespace, not code. Hashing them in made the same code
        /// with and without a blank tail two different blocks, so a faithful
        /// translation that dropped the tail read as a changed one. A *closed* fence
        /// keeps its blank lines: they are inside the block by the author's own marks.
        func flushFence(_ buffer: [LineScanner.Line], trimmingTail: Bool) -> MarkupToken {
            var lines = buffer[...]
            if trimmingTail {
                while let last = lines.last, LineScanner.isBlank(last, in: text) {
                    lines = lines.dropLast()
                }
            }
            let content = lines.map { String(text[$0.content]) }.joined(separator: "\n")
            return .codeBlock(hash: content.hashValue, lang: fenceLang)
        }

        // An indented run is NOT tokenised as a code block here, and must not be: the
        // chunker reads indented text as prose and translates it, and the two layers
        // must see the same document or the diff reports structure the chunker never
        // saw. Fenced code is the only block form either layer protects.
        //
        // Line discipline is `LineScanner`'s, the very same code the chunker runs, and
        // not `components(separatedBy: .newlines)`: that character set splits on unicode
        // scalars, so "\r\n" came out as two breaks with an empty line between them and
        // fabricated a `.paragraphBreak` — a CRLF source diffed against its LF
        // translation reported «потеряно: граница абзаца» on a perfect translation.
        // Sharing the scanner is what makes the parity above structural rather than a
        // promise two files keep in parallel.
        for scanned in LineScanner.scanLines(text) {
            let line = String(text[scanned.content])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBlankLine = LineScanner.isBlank(scanned, in: text)
            if insideFence {
                if LineScanner.isFenceMarker(scanned, in: text) {
                    tokens.append(flushFence(fenceBuffer, trimmingTail: false))
                    fenceBuffer = []; fenceLang = ""; insideFence = false
                } else { fenceBuffer.append(scanned) }
                previousLineHadText = false
                continue
            }
            if LineScanner.isFenceMarker(scanned, in: text) {
                insideFence = true
                fenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                previousLineHadText = false
                continue
            }
            if isBlankLine {
                tokens.append(.paragraphBreak)
                previousLineHadText = false
                continue
            }
            // Setext underline: a line of only "=" (any count) or only "-" (two or
            // more — a lone "-" is closer to a stray bullet than to an underline)
            // directly under a non-blank line. CommonMark reads "---" after a
            // paragraph as a setext H2, not a thematic break. The shape check is
            // computed independently of `previousLineHadText` because a dash/equals
            // run that FAILS the gate (no paragraph text above it — e.g. it follows
            // another thematic break) is not paragraph text either: it must not let
            // the *next* line pass the gate. Two consecutive "---" after a blank line
            // used to tokenise the second as a heading — confirmed by probe — because
            // the first, despite being read correctly as a thematic break, still set
            // `previousLineHadText = true` on the ordinary-line path below.
            let underlineLevel = isSetextUnderline(trimmed)
            let isUnderlineShape = underlineLevel != nil
            if previousLineHadText, let underlineLevel {
                tokens.append(.heading(level: underlineLevel))
                previousLineHadText = false
                continue
            }
            // Whether this line emitted a *block* token is what arms the setext gate
            // for the next one — see below. Inline tokens do not count: a paragraph
            // carrying a URL is still paragraph text.
            var emittedBlockToken = false
            if trimmed.hasPrefix("|") { tokens.append(.tableRow); emittedBlockToken = true }
            if let level = headingLevel(trimmed) {
                tokens.append(.heading(level: level)); emittedBlockToken = true
            }
            if trimmed.hasPrefix(">") { tokens.append(.blockquote); emittedBlockToken = true }
            if let depth = listDepth(line) {
                tokens.append(.listItem(depth: depth)); emittedBlockToken = true
            }
            tokens.append(contentsOf: inlineTokens(in: line))
            // Markdown hard break: two or more trailing spaces on a non-blank line.
            if line.hasSuffix("  ") { tokens.append(.hardLineBreak) }
            // Only plain paragraph prose can be underlined. A setext underline needs a
            // paragraph above it, and an ATX heading, a list item, a blockquote and a
            // table row are each a block of their own — CommonMark reads a "---" under
            // any of them as a thematic break. Arming on «any non-blank line» instead
            // made "# Title\n---" tokenise as [heading(1), heading(2)] and
            // "- item\n---" as [listItem, heading(2)] — both confirmed by probe — so a
            // translation that rendered the break faithfully read as a dropped
            // heading. An underline shape that FAILED the gate is excluded for the
            // same reason it always was: it is not paragraph text either.
            previousLineHadText = !isUnderlineShape && !emittedBlockToken
        }
        if insideFence { tokens.append(flushFence(fenceBuffer, trimmingTail: true)) }
        return tokens
    }

    /// Aligns the two token sequences and reports the minimal edit script. Index-wise
    /// comparison is wrong here: one dropped token would shift every later position and
    /// bury a single real defect under a cascade of false ones.
    ///
    /// The `[MarkupDiff]` face of `compare(source:translation:)`, kept because most callers only
    /// ever want the script. **A caller that renders «no problems» from an empty result must use
    /// `compare` instead**: an empty array means «no difference» here, and cannot also mean «not
    /// looked at».
    public static func diff(source: String, translation: String) -> [MarkupDiff] {
        compare(source: source, translation: translation).diffs
    }

    /// The comparison, including the case where it was not made.
    public static func compare(source: String, translation: String) -> MarkupComparison {
        // A trailing newline is not structure. Source files end with one and
        // ResponseCleaner trims it from the model's reply, so comparing them raw
        // reports a phantom paragraph break on almost every real document.
        compare(want: tokens(of: source.trimmingCharacters(in: .whitespacesAndNewlines)),
                got: tokens(of: translation.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// The most `(want × got)` matrix cells this will allocate, and the reason it has a ceiling
    /// at all.
    ///
    /// The dense `(want+1) × (got+1)` matrix below is quadratic in token count, and the queue
    /// accepts 2 MB files: a fully-bulleted 2 MB changelog emits on the order of 100 000 tokens
    /// a side, which is ~80 GB of `Int` and ~10¹⁰ iterations, on a 48 GB machine, at the very
    /// end of an otherwise successful run. The old code had no ceiling and its only guard sat
    /// *after* the allocation. Even the window's 256 KB path reached ~1.3 GB transient.
    ///
    /// 16 million cells is 128 MB and, measured on this machine, well under a tenth of a second
    /// — and it is reached only *after* the common prefix and suffix are trimmed away, which on
    /// a faithful translation removes everything. A document that still needs more than this
    /// after trimming has diverged from its source across thousands of structural tokens, and
    /// what it needs is not a longer edit script.
    static let maximumComparisonCells = 16_000_000

    static func compare(want: [MarkupToken], got: [MarkupToken]) -> MarkupComparison {
        // The overwhelmingly common case, and the one worth spending nothing on: a faithful
        // translation preserves the skeleton exactly.
        if want == got { return MarkupComparison(diffs: [], notCompared: nil) }

        // Trim what is already aligned. This is what keeps the quadratic part below
        // proportional to the *divergence* rather than to the document: on a translation that
        // changed one heading in a hundred thousand tokens it leaves one against one.
        //
        // **It is not output-preserving, and that was checked rather than assumed.** The first
        // version of this said it was, reasoning that `MarkupDiff` carries no positions so a
        // matched token contributes nothing wherever it sits. Measured against the untrimmed
        // algorithm over 4000 generated pairs, 427 produce a *different* script. What does hold,
        // in all 4000: the same number of diffs, and the same multiset of them — only the order
        // in which equally-minimal edits are listed can change. Both consumers are indifferent
        // to that (`acceptance` aggregates by `(expected, actual)` and counts; `WarningsView`
        // shows a count and a list) and neither is indifferent to count or content, which is why
        // the distinction is pinned by a test rather than left in this comment.
        var head = 0
        while head < want.count, head < got.count, want[head] == got[head] { head += 1 }
        var wantEnd = want.count, gotEnd = got.count
        while wantEnd > head, gotEnd > head, want[wantEnd - 1] == got[gotEnd - 1] {
            wantEnd -= 1; gotEnd -= 1
        }
        let want = Array(want[head..<wantEnd])
        let got = Array(got[head..<gotEnd])

        // One side empty is a pure insertion or deletion; no alignment is needed to describe it.
        if want.isEmpty || got.isEmpty {
            return MarkupComparison(diffs: want.map { MarkupDiff(expected: $0, actual: nil, note: droppedNote) }
                                        + got.map { MarkupDiff(expected: nil, actual: $0, note: addedNote) },
                                    notCompared: nil)
        }

        guard want.count * got.count <= maximumComparisonCells else {
            // **Not an empty result.** Reporting `[]` here would say «structure preserved» about
            // a document nobody looked at, which is the one answer this check must never give.
            return MarkupComparison(diffs: [],
                                    notCompared: .init(sourceTokens: want.count,
                                                       translationTokens: got.count))
        }

        // Longest common subsequence lengths.
        var lcs = Array(repeating: Array(repeating: 0, count: got.count + 1), count: want.count + 1)
        for i in stride(from: want.count - 1, through: 0, by: -1) {
            for j in stride(from: got.count - 1, through: 0, by: -1) {
                lcs[i][j] = want[i] == got[j] ? lcs[i + 1][j + 1] + 1
                                              : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var diffs: [MarkupDiff] = []
        var i = 0, j = 0
        while i < want.count && j < got.count {
            if want[i] == got[j] { i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] {
                diffs.append(MarkupDiff(expected: want[i], actual: nil, note: droppedNote))
                i += 1
            } else {
                diffs.append(MarkupDiff(expected: nil, actual: got[j], note: addedNote))
                j += 1
            }
        }
        while i < want.count {
            diffs.append(MarkupDiff(expected: want[i], actual: nil, note: droppedNote)); i += 1
        }
        while j < got.count {
            diffs.append(MarkupDiff(expected: nil, actual: got[j], note: addedNote)); j += 1
        }
        return MarkupComparison(diffs: diffs, notCompared: nil)
    }

    static let droppedNote = "dropped in translation"
    static let addedNote = "added in translation"

    /// The heading level a setext underline confers, or nil for a line that is not one.
    ///
    /// A line of `=` of any length is an H1 underline; a line of `-` **two or more** long is an
    /// H2 one, because a lone `-` is closer to a stray bullet than to an underline. Extracted
    /// from the loop above with no change of behaviour so `MarkdownBlockScanner` can call the
    /// same predicate: the renderer must read a setext heading exactly where the diff reads
    /// one, and the shape was previously spelled inside a loop nothing else could reach.
    static func isSetextUnderline(_ trimmed: String) -> Int? {
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) ? hashes : nil
    }

    static func listDepth(_ line: String) -> Int? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
        // The period must follow the leading digits immediately ("1. ", "12. "), not
        // merely appear somewhere later in the line. `trimmed.contains(". ")` used to
        // match prose like "3 files changed. See the report." — first character a
        // digit, ". " present mid-sentence — and misread it as an ordered list item.
        // A faithful translation of that same sentence starting with a letter (e.g.
        // Russian "Изменено 3 файла...") then reads as a dropped list marker that
        // never existed.
        let leadingDigits = trimmed.prefix(while: \.isNumber)
        let isOrdered = !leadingDigits.isEmpty
            && trimmed.dropFirst(leadingDigits.count).hasPrefix(". ")
        guard isBullet || isOrdered else { return nil }
        return leading / 2
    }

    static func inlineTokens(in line: String) -> [MarkupToken] {
        // Every kind of inline token below is collected into one `found` array and
        // sorted together by position at the end. Previously inline code appended
        // straight into the result while URLs accumulated separately and were only
        // sorted among themselves — document order between the two kinds was lost
        // whenever both appeared on the same line (routinely true after the model
        // merges two source lines into one).
        var found: [(location: Int, token: MarkupToken)] = []
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var linkRanges: [NSRange] = []

        // Markdown links are located first so a URL sitting inside one is never also
        // counted as a bare URL. A URL merely wrapped in parentheses is NOT a link.
        if let linkRegex = Self.linkRegex {
            for match in linkRegex.matches(in: line, range: whole) {
                linkRanges.append(match.range)
                let target = ns.substring(with: match.range(at: 1))
                // A relative or anchor target is a link but not a URL.
                if targetIsURL(target) { found.append((match.range.location, .url(bare: false))) }
            }
        }

        if let detector = Self.linkDetector {
            for match in detector.matches(in: line, range: whole) {
                let insideLink = linkRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
                if !insideLink { found.append((match.range.location, .url(bare: true))) }
            }
        }

        // Inline code spans. Scanned over UTF-16 code units of the same `ns` string
        // that produced the URL positions above — NSRange.location is a UTF-16
        // offset, so sharing that coordinate system here (instead of iterating
        // Swift `Character`s, which are grapheme clusters) is what keeps the merged
        // sort correct on a line containing an emoji or any other non-BMP character.
        // The token's sort position is the OPENING backtick, one before the
        // content range `inlineCodeSpans` returns — hence `range.location - 1`.
        for span in inlineCodeSpans(in: line) {
            found.append((span.range.location - 1, .inlineCode(span.content)))
        }

        return found.sorted { $0.location < $1.location }.map(\.token)
    }

    /// The one definition of an inline code span — shared by the skeleton diff and
    /// `InlineCodeRestorer`, so the two can never disagree about what a span is
    /// (spec §2.2). Per line: parity pairs backticks left to right; an unterminated
    /// opener emits nothing; an empty pair (``) emits nothing but consumes both.
    /// NSRange coordinates are UTF-16, matching the rest of `inlineTokens`.
    /// This scan is fence-blind — it does not know a ``` line from any other — and
    /// that is safe only because `Chunker`'s all-or-nothing fence rule guarantees a
    /// model-bound chunk never contains a fence line at all (a fenced block is its
    /// own passthrough chunk). If that rule is ever relaxed to let fence markers
    /// reach a chunk this function scans, this scan must learn to recognise fences too.
    static func inlineCodeSpans(in line: String) -> [(range: NSRange, content: String)] {
        let ns = line as NSString
        var spans: [(NSRange, String)] = []
        var openAt: Int? = nil
        for index in 0..<ns.length where ns.character(at: index) == 0x60 {
            if let start = openAt {
                if index > start + 1 {
                    let content = NSRange(location: start + 1, length: index - start - 1)
                    spans.append((content, ns.substring(with: content)))
                }
                openAt = nil
            } else {
                openAt = index
            }
        }
        return spans.map { (range: $0.0, content: $0.1) }
    }

    /// Built once for the process, not once per line.
    ///
    /// These three were constructed inside `inlineTokens` and `targetIsURL`, which run on every
    /// non-blank line of the source *and* of the translation, on the unconditional tail of both
    /// routes — so a 2 MB run paid roughly 2 × 100 000 regex compilations and as many detector
    /// constructions to answer questions whose answers never change. `NSRegularExpression` and
    /// `NSDataDetector` are documented thread-safe for matching, which is what makes one shared
    /// instance correct as well as cheaper.
    ///
    /// Optional rather than force-unwrapped: the pattern is a literal and cannot fail today, and
    /// a nil here degrades to «no markdown links found» exactly as the old `try?` did, rather
    /// than trapping in the middle of someone's translation.
    static let linkRegex = try? NSRegularExpression(
        pattern: #"\[[^\]]*\]\(\s*([^)\s]+)(?:\s+["'][^"']*["'])?\s*\)"#)

    /// See `linkRegex`. Used by `inlineTokens` for bare URLs and by `targetIsURL` for a link's
    /// target, which is why it is one instance and not two.
    static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    // A link target counts as a URL when the detector recognises the whole of it.
    // This accepts "https://x.org" and "www.example.com" while rejecting
    // "./file.md" and "#section", which are links but not URLs.
    //
    // `public` since 2026-08-31 and for one caller: `MarkupKit`'s capture converters have to
    // decide whether an `href` out of an application's HTML or an `.link` attribute out of its
    // RTF is worth spelling as a Markdown link, and that is the same question this asks. A
    // second copy of it in `MarkupKit` is how the diff and the converter come to disagree about
    // what a URL is — the failure `LineScanner` exists to prevent one layer down.
    public static func targetIsURL(_ target: String) -> Bool {
        guard let detector = Self.linkDetector
        else { return target.contains("://") }
        let ns = target as NSString
        let whole = NSRange(location: 0, length: ns.length)
        return detector.matches(in: target, range: whole).contains { $0.range == whole }
    }
}
