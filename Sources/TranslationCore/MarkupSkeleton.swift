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
            let isUnderlineShape = !trimmed.isEmpty
                && (trimmed.allSatisfy { $0 == "=" }
                    || (trimmed.count >= 2 && trimmed.allSatisfy { $0 == "-" }))
            if previousLineHadText && isUnderlineShape {
                tokens.append(.heading(level: trimmed.first == "=" ? 1 : 2))
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
    public static func diff(source: String, translation: String) -> [MarkupDiff] {
        // A trailing newline is not structure. Source files end with one and
        // ResponseCleaner trims it from the model's reply, so comparing them raw
        // reports a phantom paragraph break on almost every real document.
        let want = tokens(of: source.trimmingCharacters(in: .whitespacesAndNewlines))
        let got = tokens(of: translation.trimmingCharacters(in: .whitespacesAndNewlines))

        // Longest common subsequence lengths.
        var lcs = Array(repeating: Array(repeating: 0, count: got.count + 1), count: want.count + 1)
        if !want.isEmpty && !got.isEmpty {
            for i in stride(from: want.count - 1, through: 0, by: -1) {
                for j in stride(from: got.count - 1, through: 0, by: -1) {
                    lcs[i][j] = want[i] == got[j] ? lcs[i + 1][j + 1] + 1
                                                  : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var diffs: [MarkupDiff] = []
        var i = 0, j = 0
        while i < want.count && j < got.count {
            if want[i] == got[j] { i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] {
                diffs.append(MarkupDiff(expected: want[i], actual: nil, note: "dropped in translation"))
                i += 1
            } else {
                diffs.append(MarkupDiff(expected: nil, actual: got[j], note: "added in translation"))
                j += 1
            }
        }
        while i < want.count {
            diffs.append(MarkupDiff(expected: want[i], actual: nil, note: "dropped in translation")); i += 1
        }
        while j < got.count {
            diffs.append(MarkupDiff(expected: nil, actual: got[j], note: "added in translation")); j += 1
        }
        return diffs
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
        if let linkRegex = try? NSRegularExpression(pattern: #"\[[^\]]*\]\(\s*([^)\s]+)(?:\s+["'][^"']*["'])?\s*\)"#) {
            for match in linkRegex.matches(in: line, range: whole) {
                linkRanges.append(match.range)
                let target = ns.substring(with: match.range(at: 1))
                // A relative or anchor target is a link but not a URL.
                if targetIsURL(target) { found.append((match.range.location, .url(bare: false))) }
            }
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
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
        var openAt: Int? = nil
        for index in 0..<ns.length where ns.character(at: index) == 0x60 /* "`" */ {
            if let start = openAt {
                if index > start + 1 { // non-empty span
                    let span = ns.substring(with: NSRange(location: start + 1, length: index - start - 1))
                    found.append((start, .inlineCode(span)))
                }
                openAt = nil
            } else {
                openAt = index
            }
        }
        // An unterminated span (openAt still set here) emits no token, same as before.

        return found.sorted { $0.location < $1.location }.map(\.token)
    }

    // A link target counts as a URL when the detector recognises the whole of it.
    // This accepts "https://x.org" and "www.example.com" while rejecting
    // "./file.md" and "#section", which are links but not URLs.
    static func targetIsURL(_ target: String) -> Bool {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return target.contains("://") }
        let ns = target as NSString
        let whole = NSRange(location: 0, length: ns.length)
        return detector.matches(in: target, range: whole).contains { $0.range == whole }
    }
}
