import Foundation

public struct ChatMessage: Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct TranslationRequest: Sendable {
    public let text: String
    public let source: Language?
    public let target: Language
    public let tone: Tone
    public let glossaryEntries: [GlossaryEntry]
    /// Already-translated preceding chunk, supplied for continuity only — never re-translated.
    public let precedingContext: String?

    public init(
        text: String,
        source: Language?,
        target: Language,
        tone: Tone,
        glossaryEntries: [GlossaryEntry] = [],
        precedingContext: String? = nil
    ) {
        self.text = text
        self.source = source
        self.target = target
        self.tone = tone
        self.glossaryEntries = glossaryEntries
        self.precedingContext = precedingContext
    }
}

public enum PromptBuilder {
    public static func messages(for request: TranslationRequest) -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: systemPrompt(for: request)),
            ChatMessage(role: "user", content: userPrompt(for: request)),
        ]
    }

    public static func systemPrompt(for request: TranslationRequest) -> String {
        var lines: [String] = []

        let sourceClause = request.source.map { "from \($0.englishName) " } ?? ""
        lines.append("You are a professional translator. Translate the user's text \(sourceClause)into \(request.target.englishName).")
        lines.append("")
        lines.append("Rules:")
        lines.append("- Output ONLY the translation. No preamble, no notes, no explanation, no quotes around it.")
        lines.append("- Preserve the original structure exactly: line breaks, blank lines, list markers, heading levels.")
        lines.append("- Never translate the contents of fenced code blocks (```) or inline code (`like this`). Reproduce them byte for byte.")
        lines.append("- Never translate URLs, email addresses, file paths, CLI flags, or identifiers such as function and variable names.")
        lines.append("- Keep numbers, units, and dates in their original values.")
        lines.append("- \(request.tone.instruction)")

        if !request.glossaryEntries.isEmpty {
            lines.append("")
            lines.append("Terminology you MUST follow:")
            for entry in request.glossaryEntries {
                if entry.doNotTranslate {
                    lines.append("- \"\(entry.term)\" — leave untranslated, exactly as written.")
                } else if let required = entry.translations[request.target.rawValue] {
                    lines.append("- \"\(entry.term)\" — translate as \"\(required)\".")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    public static func userPrompt(for request: TranslationRequest) -> String {
        var parts: [String] = []

        if let context = request.precedingContext, !context.isEmpty {
            parts.append("""
            Here is the end of the preceding section, already translated. It is CONTEXT ONLY — \
            do not translate it and do not repeat it in your output. Use it to keep terminology \
            and tone consistent:
            <context>
            \(context)
            </context>
            """)
        }

        parts.append("""
        Translate the text between the markers into \(request.target.englishName).

        <text>
        \(request.text)
        </text>
        """)

        return parts.joined(separator: "\n\n")
    }

    /// Pass 2: the model reviews its own output against the source and returns a corrected version.
    public static func refineMessages(
        original: String,
        translation: String,
        request: TranslationRequest
    ) -> [ChatMessage] {
        var system = """
        You are a translation reviewer. You are given a source text and its translation into \
        \(request.target.englishName). Find mistranslations, awkward literalisms, dropped content, \
        broken markup, and terminology inconsistencies, then output the corrected translation.

        Rules:
        - Output ONLY the corrected translation. No commentary, no list of changes.
        - If the translation is already correct, output it unchanged.
        - \(request.tone.instruction)
        - Preserve structure, code blocks, inline code, URLs and identifiers exactly as in the source.
        """

        if !request.glossaryEntries.isEmpty {
            system += "\n\nTerminology that MUST appear as specified:"
            for entry in request.glossaryEntries {
                if entry.doNotTranslate {
                    system += "\n- \"\(entry.term)\" — leave untranslated."
                } else if let required = entry.translations[request.target.rawValue] {
                    system += "\n- \"\(entry.term)\" — must be \"\(required)\"."
                }
            }
        }

        let user = """
        <source>
        \(original)
        </source>

        <translation>
        \(translation)
        </translation>
        """

        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user),
        ]
    }
}
