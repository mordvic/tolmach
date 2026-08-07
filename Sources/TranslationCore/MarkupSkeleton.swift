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
        var fenceBuffer: [String] = []
        var fenceLang = ""
        var insideFence = false
        var previousWasBlank = true // document start counts as after-a-blank
        var previousLineHadText = false
        var indentedBuffer: [String] = []
        func flushIndented() {
            guard !indentedBuffer.isEmpty else { return }
            // Same shape as a fenced block with no info string: the reader of a diff
            // is told "a code block was dropped/added" either way, and folding the two
            // spellings together is exactly how CommonMark treats them.
            tokens.append(.codeBlock(hash: indentedBuffer.joined(separator: "\n").hashValue,
                                     lang: ""))
            indentedBuffer = []
        }

        // Lines are scanned the way `Chunker` scans them, not with
        // `components(separatedBy: .newlines)`. That character set splits on unicode
        // scalars, so "\r\n" came out as two breaks with an empty line between them
        // and fabricated a `.paragraphBreak` — a CRLF source diffed against its LF
        // translation reported «потеряно: граница абзаца» on a perfect translation.
        // U+000B, U+000C, U+2028 and U+2029 had the same effect. The chunker treats
        // all of them as ordinary in-line whitespace; the two layers must read the
        // same document or the diff reports structure the chunker never saw.
        for line in Chunker.scanLines(text).map({ String(text[$0.content]) }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideFence {
                if trimmed.hasPrefix("```") {
                    tokens.append(.codeBlock(hash: fenceBuffer.joined(separator: "\n").hashValue, lang: fenceLang))
                    fenceBuffer = []; fenceLang = ""; insideFence = false
                } else { fenceBuffer.append(line) }
                previousWasBlank = false
                previousLineHadText = false
                continue
            }
            let isIndented = line.hasPrefix("    ") || line.hasPrefix("\t")
            // An indented run, once started, CONTINUES on every indented non-blank
            // line — fence markers included. Checked ahead of the fence-open rule
            // below because `Chunker`'s indented continuation looks only at
            // blankness and indentation: a ``` inside an indented block is code
            // bytes to it. With the fence check first, such a line opened a
            // never-closed fence that swallowed the rest of the document into a code
            // block the chunker never saw. The run's START keeps the opposite order
            // (the fence check below still wins after a blank line), because that is
            // also the order `Chunker.blocks` uses.
            if !indentedBuffer.isEmpty, isIndented, !trimmed.isEmpty {
                indentedBuffer.append(line)
                previousWasBlank = false
                previousLineHadText = false
                continue
            }
            if trimmed.hasPrefix("```") {
                // Reaching here with a pending run means this line is neither
                // indented nor blank, so the run ended on the line before — and the
                // chunker emits that indented block *before* the fenced one. Without
                // this flush the pending block came out last, after the fence.
                flushIndented()
                insideFence = true
                fenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                previousWasBlank = false
                previousLineHadText = false
                continue
            }
            if trimmed.isEmpty {
                flushIndented()
                tokens.append(.paragraphBreak)
                previousWasBlank = true
                previousLineHadText = false
                continue
            }
            if !indentedBuffer.isEmpty {
                // Non-indented, non-blank: the run ends here (an indented
                // continuation already `continue`d above, a blank line already
                // flushed).
                flushIndented()
            } else if previousWasBlank, isIndented {
                indentedBuffer.append(line)
                previousWasBlank = false
                previousLineHadText = false
                continue
            }
            previousWasBlank = false
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
            if trimmed.hasPrefix("|") { tokens.append(.tableRow) }
            if let level = headingLevel(trimmed) { tokens.append(.heading(level: level)) }
            if trimmed.hasPrefix(">") { tokens.append(.blockquote) }
            if let depth = listDepth(line) { tokens.append(.listItem(depth: depth)) }
            tokens.append(contentsOf: inlineTokens(in: line))
            // Markdown hard break: two or more trailing spaces on a non-blank line.
            if line.hasSuffix("  ") { tokens.append(.hardLineBreak) }
            previousLineHadText = !isUnderlineShape
        }
        if insideFence { tokens.append(.codeBlock(hash: fenceBuffer.joined(separator: "\n").hashValue, lang: fenceLang)) }
        flushIndented()
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
