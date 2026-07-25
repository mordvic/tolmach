// Sources/TranslationCore/PromptBuilder.swift
import Foundation

public struct TranslationRequest: Sendable {
    public let text: String
    public let source: Language?
    public let target: Language
    public let tone: Tone
    public let glossaryEntries: [GlossaryEntry]
    public init(text: String, source: Language?, target: Language, tone: Tone, glossaryEntries: [GlossaryEntry] = []) {
        self.text = text; self.source = source; self.target = target; self.tone = tone; self.glossaryEntries = glossaryEntries
    }
}

public enum PromptBuilder {
    public static func messages(for request: TranslationRequest) -> [ChatMessage] {
        [ChatMessage(role: "system", content: systemPrompt(for: request)),
         ChatMessage(role: "user", content: userPrompt(for: request))]
    }

    public static func systemPrompt(for request: TranslationRequest) -> String {
        let sourceClause = request.source.map { "from \($0.englishName) " } ?? ""
        var lines = [
            "You are a professional translator. Translate the user's text \(sourceClause)into \(request.target.englishName).",
            "",
            "Rules:",
            "- Output ONLY the translation. No preamble, no notes, no explanation, no quotes around it.",
            "- Preserve the original structure exactly: line breaks, blank lines, list markers, heading levels.",
            "- Never translate the contents of fenced code blocks (```) or inline code (`like this`). Reproduce them byte for byte.",
            "- Never translate URLs, email addresses, file paths, CLI flags, or identifiers such as function and variable names.",
            "- Keep numbers, units, and dates in their original values.",
            "- \(request.tone.instruction)",
        ]
        if !request.glossaryEntries.isEmpty {
            var bullets: [String] = []
            for entry in request.glossaryEntries {
                if entry.doNotTranslate {
                    bullets.append("- \"\(entry.term)\" — leave untranslated, exactly as written.")
                } else if let required = entry.translations[request.target.rawValue] {
                    bullets.append("- \"\(entry.term)\" — translate as \"\(required)\".")
                }
            }
            if !bullets.isEmpty {
                lines.append("")
                lines.append("Terminology you MUST follow:")
                lines.append(contentsOf: bullets)
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func userPrompt(for request: TranslationRequest) -> String {
        """
        Translate the text between the markers into \(request.target.englishName).

        <text>
        \(request.text)
        </text>
        """
    }

    /// The `=>` echo contract is load-bearing: it lets the parser match by term instead
    /// of by line position, so a dropped line costs one entry rather than corrupting
    /// every later pairing. Verbatim from the validated experiment prompt.
    public static func termListMessages(terms: [String], target: Language) -> [ChatMessage] {
        let system = """
        You translate a list of glossary terms into \(target.englishName).

        Output one line per input term, in exactly this format:
        source term => translation

        Echo the source term exactly as given in English, then " => ", then the translation. \
        No numbering, no commentary, no extra lines. Do not translate anything except the terms. \
        Keep identifiers and product names untranslated when they have no established \
        target-language form.
        """
        let user = terms.joined(separator: "\n")
        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
    }
}
