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

    /// `allowFenceUnwrap` defaults to true and every caller in the tree now passes nothing.
    ///
    /// It used to say «`Translator` always passes `!chunk.passthrough`», and that stopped being
    /// true on 2026-08-18: `streamChunkReply` passes the constant `true`, which is safe only
    /// because `Chunker`'s all-or-nothing fence rule keeps a passthrough chunk out of that
    /// function entirely. The parameter stays because the false-positive case below is real and
    /// a future caller may have to suppress it — but a contract nobody keeps is worse than no
    /// contract, so this now describes what happens rather than what used to.
    ///
    /// **Lines are `LineScanner`'s throughout.** Two different disciplines lived in this
    /// function and neither was the engine's: `firstIndex(of: "\n")` is a grapheme search that
    /// never matches the single `Character` `"\r\n"`, so a CRLF reply's preamble was never
    /// stripped and shipped in `final`; and `components(separatedBy: .newlines)` splits on
    /// unicode *scalars*, so `"\r\n"` became two breaks with an empty line between them and the
    /// fence unwrap turned ```` ```\r\na\r\nb\r\n``` ```` into `"a\n\nb"` — a paragraph break
    /// that existed nowhere, plus a phantom «added» diff on a faithful translation.
    /// `LineScanner` exists precisely so the layers cannot disagree; this one was not using it.
    public static func clean(_ raw: String, allowFenceUnwrap: Bool = true) -> CleanedResponse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped: String? = nil
        var unwrapped = false

        // A single-line reply is never a preamble — the same condition the `firstIndex` search
        // expressed by failing to find a newline, said out loud.
        if let (firstLine, rest) = LineScanner.firstCompleteLine(text), isPreambleLine(firstLine) {
            stripped = firstLine
            text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let lines = LineScanner.pieces(text)
        if allowFenceUnwrap, lines.count >= 2,
           lines[0].content.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           lines[lines.count - 1].content.trimmingCharacters(in: .whitespaces) == "```",
           !lines[1..<(lines.count - 1)].contains(where: {
               $0.content.trimmingCharacters(in: .whitespaces).hasPrefix("```")
           }) {
            // The interior lines with their own terminators, except the last one's — that
            // terminator separated the content from the closing fence, not two lines of content.
            let inner = Array(lines[1..<(lines.count - 1)])
            text = inner.enumerated()
                .map { $0.offset == inner.count - 1 ? $0.element.content
                                                    : $0.element.content + $0.element.terminator }
                .joined()
            unwrapped = true
        }

        // A whole-answer `<text>…</text>` unwrap lived here from 2026-08-10 to 2026-08-18.
        // It guarded an echo of the user prompt's own markers (aya-expanse:8b, sampling
        // noise, 13 clean probes; translategemma:27b, 7/15 replies), and both user prompts
        // stopped carrying markers on 2026-08-18 for the measured reason in
        // `PromptBuilder.userPrompt(for:)`. A reply can no longer echo what it was never
        // shown, so the guard is gone rather than dead-coded — the same call
        // `Translator.streamChunkReply` records for `allowFenceUnwrap: false`. A reply
        // that opens with a literal `<text>` line is content now, and a test pins that.

        return CleanedResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               strippedPreamble: stripped, unwrappedCodeFence: unwrapped)
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
