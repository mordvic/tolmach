// Sources/TranslationCore/ResponseCleaner.swift
import Foundation

public struct CleanedResponse: Sendable, Equatable {
    public let text: String
    public let strippedPreamble: String?
    public let unwrappedCodeFence: Bool
}

public enum ResponseCleaner {
    static let preamblePatterns: Set<String> = [
        "here is the translation", "here's the translation", "here is the translated text",
        "translation", "translated text",
        "вот перевод", "перевод", "übersetzung",
        "voici la traduction", "traduction", "aquí está la traducción", "traducción",
    ]

    public static func clean(_ raw: String) -> CleanedResponse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped: String? = nil
        var unwrapped = false

        if let newline = text.firstIndex(of: "\n") {
            let firstLine = String(text[text.startIndex..<newline])
            if isPreambleLine(firstLine) {
                stripped = firstLine
                text = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lines = text.components(separatedBy: .newlines)
        if lines.count >= 2,
           lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```",
           !lines[1..<(lines.count - 1)].contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            text = lines[1..<(lines.count - 1)].joined(separator: "\n")
            unwrapped = true
        }

        return CleanedResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               strippedPreamble: stripped, unwrappedCodeFence: unwrapped)
    }

    static func isPreambleLine(_ line: String) -> Bool {
        let normalized = line.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard normalized.count <= 60 else { return false }
        let preamblePunctuation = CharacterSet(charactersIn: ":.!— -")
        // Check punctuation against the line before the trailing characters are trimmed
        // away, since that trailing punctuation (e.g. a colon) is the signal we key on.
        let endsInPreamblePunctuation = normalized.unicodeScalars.last.map(preamblePunctuation.contains) ?? false
        let core = normalized.trimmingCharacters(in: preamblePunctuation)
        guard preamblePatterns.contains(core) else { return false }
        // A bare single word with no trailing punctuation reads as genuine content
        // (e.g. a document heading), not as a model's preamble. Only strip when the
        // line is multi-word or carries an explicit preamble punctuation marker.
        let isMultiWord = core.contains(" ")
        return isMultiWord || endsInPreamblePunctuation
    }
}
