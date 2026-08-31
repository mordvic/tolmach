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
    /// `**strong**` / `*italic*` and their underscore spellings — see `emphasisSpans`.
    case emphasis(strong: Bool)
    /// How many cells the `.tableRow` beside it carried — see `tableCellCount`.
    case tableCells(count: Int)
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
            if trimmed.hasPrefix("|") {
                tokens.append(.tableRow)
                tokens.append(.tableCells(count: tableCellCount(trimmed)))
                emittedBlockToken = true
            }
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
        // merges two source lines into one). Emphasis joined the same array rather than
        // getting a list of its own for that reason and no other.
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
        let codeSpans = inlineCodeSpans(in: line)
        for span in codeSpans {
            found.append((span.range.location - 1, .inlineCode(span.content)))
        }

        // Emphasis, in the same UTF-16 coordinates and sorted into the same array. The
        // code spans found above are handed over rather than re-scanned, both to keep this
        // at one scan per kind per line and because a marker inside backticks is code: the
        // model never sees a protected span, so it cannot lose the emphasis inside one.
        for span in emphasisSpans(in: line, excluding: codeSpans) {
            found.append((span.location, .emphasis(strong: span.strong)))
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

    /// Emphasis spans, per line: `**strong**`, `*italic*`, `__strong__`, `_italic_`.
    ///
    /// Found the way `inlineCodeSpans` finds code — markers parity-paired left to right in
    /// UTF-16 coordinates — and merged into `inlineTokens`' one `found` array, so document
    /// order between emphasis, inline code and URLs holds on a line carrying more than one
    /// kind. The discipline is that function's, exactly: an unterminated marker emits
    /// nothing, and an empty pair (`****`) consumes both markers and emits nothing.
    ///
    /// **Why the verifier learns emphasis at all**, since the alternative looks easier from
    /// here: `MarkupToken` had no case for it, so a model that dropped a `**` was reported
    /// by nothing — `WarningsView` said the structure survived and `acceptance`'s markup
    /// gate passed. The loss to be seen is ~1 inline span per document, systematically the
    /// *same* span per model, and the obvious cure — a prompt rule asking for the markers
    /// back — was measured harmful on this install's own models: bold degraded to italic
    /// 5/5 on `translategemma:12b`, emphasis fabricated 2/3 on `aya-expanse:32b`
    /// (§2 series B of `docs/design/specs/2026-08-31-formatting-design.md`). Detection is
    /// the whole intervention here; nothing in this file may grow into an instruction.
    ///
    /// **The subset of CommonMark implemented, and the licence for stopping there.** The
    /// same function reads the source and the translation, and `compare` reports only where
    /// the two readings differ — so a simplification that reads both sides the same way
    /// cancels out and costs nothing, while an *asymmetric* one invents a diff. That is the
    /// licence, and it is why this stays a single linear pass per line (`tokens(of:)` runs
    /// on both sides of the queue's 2 MB files) instead of becoming a parser. What it gives
    /// up:
    ///
    /// - No delimiter-run arithmetic. `**` is a strong marker, a lone `*` an italic one,
    ///   and each kind pairs only with its own spelling, so `***x***` reads as
    ///   [strong, italic] — which is the same pair of tokens CommonMark's em-inside-strong
    ///   would yield, arrived at by accident rather than by rule.
    /// - No nesting or ordering rules between the two kinds: `*a **b** c*` reads as one
    ///   italic and one strong at their openers, and a faithful translation keeps both.
    /// - Nothing but backticks is protected. Inline code is the one form the pipeline keeps
    ///   by construction, so it is the one exclusion that is about correctness rather than
    ///   fidelity; brackets, pipes and HTML entities mean nothing here.
    ///
    /// **What it must not give up — the flanking gate.** A marker opens only when a
    /// non-space follows it and closes only when a non-space precedes it; `_` additionally
    /// may not touch a letter or digit on its outer side. Both halves are edge safety, not
    /// fidelity, and both are pinned by tests:
    ///
    /// - Without the outer-alphanumeric rule for `_`, the filename `a_b_c.txt` written in
    ///   prose parity-pairs into an italic. Intraword underscores are identifiers in this
    ///   project's own documents, never emphasis — that is CommonMark's rule too, and it is
    ///   the one part of flanking worth keeping in full.
    /// - Without the space rule, a bullet written `* item` offers a stray asterisk that
    ///   parity-pairs with the *opening* marker of a real italic further along the same
    ///   line: the real span is then mis-located and its closer left dangling.
    ///
    /// `codeSpans` are `inlineCodeSpans`' own *content* ranges, taken from the caller
    /// rather than re-scanned here; the backticks around each are excluded too, not only
    /// what they hold. There is no convenience overload that scans them itself, because
    /// the one caller has them already and a second entry point is how two readings of
    /// one line come to disagree.
    static func emphasisSpans(in line: String,
                              excluding codeSpans: [(range: NSRange, content: String)])
    -> [(location: Int, strong: Bool)] {
        let ns = line as NSString
        let length = ns.length
        // One marker cannot make a span, so nothing shorter than two units can carry one.
        guard length >= 2 else { return [] }

        var markers: [EmphasisMarker] = []
        // `codeSpans` are ascending and disjoint, so one cursor walking alongside `index`
        // keeps the exclusion linear rather than a membership test per character.
        var codeCursor = 0
        var index = 0
        while index < length {
            while codeCursor < codeSpans.count,
                  NSMaxRange(codeSpans[codeCursor].range) + 1 <= index { codeCursor += 1 }
            if codeCursor < codeSpans.count, index >= codeSpans[codeCursor].range.location - 1 {
                index = NSMaxRange(codeSpans[codeCursor].range) + 1
                continue
            }
            let unit = ns.character(at: index)
            guard unit == 0x2A || unit == 0x5F else { index += 1; continue }   // "*" or "_"
            let markerLength = index + 1 < length && ns.character(at: index + 1) == unit ? 2 : 1
            let before: unichar? = index > 0 ? ns.character(at: index - 1) : nil
            let after: unichar? = index + markerLength < length
                ? ns.character(at: index + markerLength) : nil
            let underscore = unit == 0x5F
            markers.append(EmphasisMarker(
                location: index,
                length: markerLength,
                strong: markerLength == 2,
                unit: unit,
                canOpen: (after.map { !isSpaceUnit($0) } ?? false)
                    && (!underscore || (before.map { !isWordUnit($0) } ?? true)),
                canClose: (before.map { !isSpaceUnit($0) } ?? false)
                    && (!underscore || (after.map { !isWordUnit($0) } ?? true))))
            index += markerLength
        }

        // Four independent parity walks — one per (spelling, strength) — because a `**`
        // may not be closed by a `*` and an asterisk may not be closed by an underscore.
        // Four passes over a per-line marker list, so still linear in the line.
        var spans: [(location: Int, strong: Bool)] = []
        for unit in [unichar(0x2A), unichar(0x5F)] {
            for strong in [true, false] {
                var openAt: Int? = nil
                for marker in markers where marker.unit == unit && marker.strong == strong {
                    guard let start = openAt else {
                        if marker.canOpen { openAt = marker.location }
                        continue
                    }
                    guard marker.canClose else { continue }
                    // An empty pair consumes both markers and emits nothing — the same
                    // answer `inlineCodeSpans` gives to ``.
                    if marker.location > start + marker.length {
                        spans.append((location: start, strong: strong))
                    }
                    openAt = nil
                }
                // An unterminated opener emits nothing, and its markers are not
                // reconsidered as anything else.
            }
        }
        return spans.sorted { $0.location < $1.location }
    }

    /// One `*`, `**`, `_` or `__` on a line, with the two flanking answers already taken —
    /// see `emphasisSpans(in:excluding:)` for what they mean and why they exist.
    private struct EmphasisMarker {
        let location: Int
        let length: Int
        let strong: Bool
        let unit: unichar
        let canOpen: Bool
        let canClose: Bool
    }

    /// A letter or a digit, for the underscore rule. Half of a surrogate pair answers true:
    /// it is part of some character, and «part of a word» is the question being asked.
    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return Character(scalar).isLetter || Character(scalar).isNumber
    }

    /// Whitespace, for the flanking gate. Half of a surrogate pair answers false, for the
    /// same reason it answers true above.
    private static func isSpaceUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return Character(scalar).isWhitespace
    }

    /// How many cells a `|`-prefixed row carries. Emitted as `.tableCells` *alongside* the
    /// `.tableRow` that line already produces, not instead of it.
    ///
    /// `.tableRow` alone could not see the loss a reader is most likely to ask about — a row
    /// that came back with two of its four cells — because a row is a row however many pipes
    /// are left in it. **The cost is that a wholly dropped row now reports two diffs rather
    /// than one**, and that is accepted: no consumer treats the number of diffs as a
    /// threshold (`acceptance` aggregates by the `(expected, actual)` pair and counts runs;
    /// `WarningsView` and `JobResult` show a count and a list), so one extra line about a row
    /// that is genuinely gone is a cosmetic price for a whole class of loss that was
    /// previously invisible.
    ///
    /// Counted by splitting on `|`: the leading pipe's empty field is always dropped, and a
    /// whitespace-only last field is dropped as the closing pipe's. A pipe inside an inline
    /// code span counts as a separator — covered by `emphasisSpans`' licence, since both
    /// sides are read the same way — and the delimiter row (`|---|---|`) is a row like any
    /// other and gets its own count.
    static func tableCellCount(_ trimmed: String) -> Int {
        var fields = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        if fields.first?.isEmpty == true { fields.removeFirst() }
        if let last = fields.last, last.allSatisfy(\.isWhitespace) { fields.removeLast() }
        return fields.count
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
