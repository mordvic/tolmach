import Foundation

public struct CleanedResponse: Sendable, Equatable {
    public let text: String
    /// What was removed, if anything — surfaced so the prototype can show how
    /// often the prompt alone fails to suppress preambles.
    public let strippedPreamble: String?
    public let unwrappedCodeFence: Bool
}

/// Small models add preambles and wrap whole answers in code fences no matter how
/// firmly the prompt forbids it. Post-processing is not optional.
public enum ResponseCleaner {
    static let preamblePatterns: [String] = [
        "here is the translation",
        "here's the translation",
        "here is the translated text",
        "translation",
        "translated text",
        "вот перевод",
        "перевод",
        "übersetzung",
        "voici la traduction",
        "traduction",
        "aquí está la traducción",
        "traducción",
    ]

    public static func clean(_ raw: String) -> CleanedResponse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped: String? = nil
        var unwrapped = false

        // A leading line that is just a preamble label, with or without markdown emphasis.
        if let newlineIndex = text.firstIndex(of: "\n") {
            let firstLine = String(text[text.startIndex..<newlineIndex])
            if isPreambleLine(firstLine) {
                stripped = firstLine
                text = String(text[text.index(after: newlineIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Whole answer wrapped in a fence that was not in the source.
        let lines = text.components(separatedBy: .newlines)
        if lines.count >= 2,
           lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```",
           !lines[1..<(lines.count - 1)].contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            text = lines[1..<(lines.count - 1)].joined(separator: "\n")
            unwrapped = true
        }

        return CleanedResponse(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            strippedPreamble: stripped,
            unwrappedCodeFence: unwrapped
        )
    }

    static func isPreambleLine(_ line: String) -> Bool {
        let normalized = line
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard normalized.count <= 60 else { return false }
        let withoutPunctuation = normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: ":.!— -"))
        return preamblePatterns.contains(withoutPunctuation)
    }
}
