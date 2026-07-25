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

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideFence {
                if trimmed.hasPrefix("```") {
                    tokens.append(.codeBlock(hash: fenceBuffer.joined(separator: "\n").hashValue, lang: fenceLang))
                    fenceBuffer = []; fenceLang = ""; insideFence = false
                } else { fenceBuffer.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") {
                insideFence = true
                fenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty { tokens.append(.paragraphBreak); continue }
            if let level = headingLevel(trimmed) { tokens.append(.heading(level: level)) }
            if trimmed.hasPrefix(">") { tokens.append(.blockquote) }
            if let depth = listDepth(line) { tokens.append(.listItem(depth: depth)) }
            tokens.append(contentsOf: inlineTokens(in: line))
            // Markdown hard break: two or more trailing spaces on a non-blank line.
            if line.hasSuffix("  ") { tokens.append(.hardLineBreak) }
        }
        if insideFence { tokens.append(.codeBlock(hash: fenceBuffer.joined(separator: "\n").hashValue, lang: fenceLang)) }
        return tokens
    }

    /// Aligns the two token sequences and reports the minimal edit script. Index-wise
    /// comparison is wrong here: one dropped token would shift every later position and
    /// bury a single real defect under a cascade of false ones.
    public static func diff(source: String, translation: String) -> [MarkupDiff] {
        let want = tokens(of: source)
        let got = tokens(of: translation)

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
        let isOrdered = trimmed.first?.isNumber == true && trimmed.contains(". ")
        guard isBullet || isOrdered else { return nil }
        return leading / 2
    }

    static func inlineTokens(in line: String) -> [MarkupToken] {
        var tokens: [MarkupToken] = []

        // inline code spans
        var current: String? = nil
        for character in line {
            if character == "`" {
                if let open = current { if !open.isEmpty { tokens.append(.inlineCode(open)) }; current = nil }
                else { current = "" }
            } else if current != nil { current?.append(character) }
        }

        // Markdown links are located first so a URL sitting inside one is never also
        // counted as a bare URL. A URL merely wrapped in parentheses is NOT a link.
        var found: [(location: Int, token: MarkupToken)] = []
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var linkRanges: [NSRange] = []

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

        tokens.append(contentsOf: found.sorted { $0.location < $1.location }.map(\.token))
        return tokens
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
