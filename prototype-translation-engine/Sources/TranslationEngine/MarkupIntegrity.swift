import Foundation

public struct IntegrityReport: Sendable {
    public let missingCodeBlocks: [String]
    public let missingInlineCode: [String]
    public let missingURLs: [String]

    public var isClean: Bool {
        missingCodeBlocks.isEmpty && missingInlineCode.isEmpty && missingURLs.isEmpty
    }
}

/// Checks that the things the prompt told the model not to touch actually survived.
/// This is the objective half of translation quality — no human judgement needed.
public enum MarkupIntegrity {
    public static func report(source: String, translation: String) -> IntegrityReport {
        IntegrityReport(
            missingCodeBlocks: missing(codeBlocks(in: source), from: translation),
            missingInlineCode: missing(inlineCode(in: source), from: translation),
            missingURLs: missing(urls(in: source), from: translation)
        )
    }

    public static func codeBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var buffer: [String] = []
        var inside = false

        for line in text.components(separatedBy: .newlines) {
            let isMarker = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if inside {
                if isMarker {
                    blocks.append(buffer.joined(separator: "\n"))
                    buffer = []
                    inside = false
                } else {
                    buffer.append(line)
                }
            } else if isMarker {
                inside = true
            }
        }
        return blocks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func inlineCode(in text: String) -> [String] {
        // Deliberately skips fenced blocks so their backticks don't confuse the scan.
        let withoutFences = text
            .components(separatedBy: "```")
            .enumerated()
            .filter { $0.offset % 2 == 0 }
            .map(\.element)
            .joined(separator: " ")

        var results: [String] = []
        var current: String? = nil
        for character in withoutFences {
            if character == "`" {
                if let open = current {
                    let trimmed = open.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { results.append(trimmed) }
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(character)
            }
        }
        return results
    }

    public static func urls(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            match.url?.absoluteString
        }
    }

    static func missing(_ needles: [String], from haystack: String) -> [String] {
        let normalizedHaystack = normalize(haystack)
        return needles.filter { !normalizedHaystack.contains(normalize($0)) }
    }

    static func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
