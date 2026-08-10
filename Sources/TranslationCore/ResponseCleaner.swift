// Sources/TranslationCore/ResponseCleaner.swift
import Foundation

public struct CleanedResponse: Sendable, Equatable {
    public let text: String
    public let strippedPreamble: String?
    public let unwrappedCodeFence: Bool
    public let unwrappedTextMarkers: Bool
}

public enum ResponseCleaner {
    static let preamblePatterns: Set<String> = [
        "here is the translation", "here's the translation", "here is the translated text",
        "translation", "translated text",
        "вот перевод", "перевод", "übersetzung",
        "voici la traduction", "traduction", "aquí está la traducción", "traducción",
    ]

    /// `allowFenceUnwrap` defaults to true for standalone callers (e.g. tests probing
    /// `clean` in isolation), but `Translator` always passes `!chunk.containsCodeFence`
    /// explicitly — see the false-positive case below. `allowMarkerUnwrap` follows the
    /// same shape for the same reason: the caller knows whether the source itself
    /// opened with the marker line, and this function does not.
    public static func clean(_ raw: String, allowFenceUnwrap: Bool = true,
                             allowMarkerUnwrap: Bool = true) -> CleanedResponse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped: String? = nil
        var unwrapped = false
        var unwrappedMarkers = false

        if let newline = text.firstIndex(of: "\n") {
            let firstLine = String(text[text.startIndex..<newline])
            if isPreambleLine(firstLine) {
                stripped = firstLine
                text = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // The whole-answer-fence unwrap assumes the model over-wrapped a plain-prose
        // reply in a spurious code fence. That assumption is wrong when the chunk it
        // was asked to translate was ITSELF a fenced code block in its entirety —
        // Chunker can and does produce such chunks (a fence flushed alone because the
        // preceding prose would have overflowed the budget), and the model reproducing
        // that chunk verbatim looks identical, at this layer, to the over-wrapping
        // case. Erring toward *not* unwrapping is deliberate: a stray leftover pair of
        // fence markers is cosmetic, silently destroying a real code block is not.
        // `allowFenceUnwrap` lets the caller — who knows whether the source chunk was
        // fenced — suppress the unwrap in exactly that case, while preamble stripping
        // above still applies either way.
        let lines = text.components(separatedBy: .newlines)
        if allowFenceUnwrap, lines.count >= 2,
           lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```",
           !lines[1..<(lines.count - 1)].contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            text = lines[1..<(lines.count - 1)].joined(separator: "\n")
            unwrapped = true
        }

        // The same failure one wrapper over: both user prompts hand the model its text
        // between <text>…</text> markers, and the model intermittently echoes them back
        // around the reply — observed live on правка (aya-expanse:8b, temperature 0.2,
        // 2026-08-10; 13 identical direct probes came back clean, so the echo is
        // sampling noise the prompt can discourage but never rule out). The same
        // erring-toward-not-unwrapping rules as the fence above: whole-answer wrapper
        // only, nothing that looks like a marker in the interior, and the caller
        // suppresses the unwrap when the source itself opened with the marker line.
        let markerLines = text.components(separatedBy: .newlines)
        if allowMarkerUnwrap, markerLines.count >= 2,
           markerLines[0].trimmingCharacters(in: .whitespaces) == "<text>",
           markerLines[markerLines.count - 1].trimmingCharacters(in: .whitespaces) == "</text>",
           !markerLines[1..<(markerLines.count - 1)].contains(where: {
               let line = $0.trimmingCharacters(in: .whitespaces)
               return line == "<text>" || line == "</text>"
           }) {
            text = markerLines[1..<(markerLines.count - 1)].joined(separator: "\n")
            unwrappedMarkers = true
        }

        return CleanedResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               strippedPreamble: stripped, unwrappedCodeFence: unwrapped,
                               unwrappedTextMarkers: unwrappedMarkers)
    }

    /// The longest normalised length `isPreambleLine` will ever accept — anything
    /// past this is rejected before patterns are even considered. Exposed
    /// (alongside `normalizedForPreambleCheck`) so a caller reasoning about the
    /// *shape* of that decision — e.g. `Translator`'s incremental buffering,
    /// which wants to know once a partially-received line has permanently ruled
    /// itself out as a preamble — can reuse the exact same rule instead of
    /// recreating it. Two copies of this threshold would be a defect waiting to
    /// happen.
    static let preambleLineMaxLength = 60

    /// The normalisation `isPreambleLine` applies before measuring length or
    /// matching against `preamblePatterns`: strip `*`, `#`, `_`, then trim and
    /// lowercase. Normalisation only ever removes characters, so its output
    /// length is monotonically non-decreasing as more raw text is appended to
    /// `line` — which is what makes "normalised length exceeds
    /// `preambleLineMaxLength`" a permanent, one-way decision a caller can act
    /// on before a line is even complete.
    static func normalizedForPreambleCheck(_ line: String) -> String {
        line.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func isPreambleLine(_ line: String) -> Bool {
        let normalized = normalizedForPreambleCheck(line)
        guard normalized.count <= preambleLineMaxLength else { return false }
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
