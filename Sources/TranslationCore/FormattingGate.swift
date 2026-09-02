// Sources/TranslationCore/FormattingGate.swift
import Foundation

/// Why a reconstructed text was refused. Each case is a sentence the app can say.
public enum FormattingRejection: Sendable, Equatable {
    /// The model returned nothing, or only whitespace.
    case empty
    /// With the markup taken back off, the text is not the text it was given — a word
    /// changed, added, dropped or moved.
    case wordsChanged
    /// A table whose rows do not all have the same number of cells.
    case unevenTable
}

/// What makes the «Оформить» pass safe to run on a local model.
///
/// The pass asks a model to add structure to a flat text: headings, tables, lists, code. The
/// design's own measurement (`docs/design/specs/2026-08-31-formatting-design.md` §2, series B)
/// is that these models, once asked about markers, degrade bold to italic 5/5 and invent
/// emphasis 2/3 — so nothing the pass returns is trusted for its *content*. This gate is the
/// whole of that distrust, in one place: **the model may change the structure and may change
/// nothing else**. A result that fails it is thrown away and the text is processed as it was,
/// which is exactly what happened before the pass existed.
///
/// «Nothing else» is spelled out as: with every marker taken off, and every run of whitespace
/// read as one space, the two texts are byte-identical. Line terminators are whitespace here on
/// purpose — the case the pass exists for is a table that reached the app one cell per line,
/// and those cells join into a row. Punctuation is not whitespace: a model that «fixes» a full
/// stop has edited the text.
///
/// The markers come off through `MarkdownPlainText`, the one renderer of «the words without
/// the syntax» this module has, so the gate and «Заменить» cannot come to disagree about what a
/// heading's words are. Two adjustments on top of it, applied to **both** sides so neither can
/// leak a difference: a list marker at the start of a line is not a word (a flat «1) stop the
/// workers» may legitimately come back as «1. stop the workers», and an unmarked line as
/// «- …»), and the horizontal rule's plain spelling is not a word either, because the pass is
/// not allowed to add one and a rule it adds anyway is structure rather than content.
public enum FormattingGate {
    /// Nil when `formatted` may replace `source`; otherwise why not.
    public static func verify(source: String, formatted: String) -> FormattingRejection? {
        guard !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        for block in MarkdownBlockScanner.blocks(of: formatted) {
            guard case let .table(header, rows, alignments) = block else { continue }
            var widths = Set(rows.map(\.count))
            if !header.isEmpty { widths.insert(header.count) }
            if !alignments.isEmpty { widths.insert(alignments.count) }
            if widths.count > 1 { return .unevenTable }
        }
        let expected = words(of: source)
        let actual = words(of: MarkdownPlainText.render(formatted))
        return expected == actual ? nil : .wordsChanged
    }

    /// The text with the forms the pass is not allowed to produce taken off: emphasis markers
    /// removed, a link reduced to its text. Block syntax and code are left exactly as they are.
    ///
    /// Removed rather than refused: a model that adds one `**` has not changed a word, and the
    /// user should not lose a good table over it. Done through Foundation's inline parser — the
    /// same parser `MarkdownToAttributed` and `MarkdownPlainText` read emphasis with, so «what
    /// counts as emphasis» is one answer across the module — run per line, never on a fence
    /// line or inside a fenced block, because `inlineOnlyPreservingWhitespace` reads a fence
    /// line as an inline code run (measured, `Scripts/markup-render.swift` §4). Code runs are
    /// re-wrapped in their backticks so inline code, one of the four allowed forms, survives.
    public static func stripForbidden(_ text: String) -> String {
        let lines = LineScanner.scanLines(text)
        var result = ""
        var inFence = false
        for line in lines {
            let content = String(text[line.content])
            let terminator = String(text[line.content.upperBound..<line.end])
            if LineScanner.isFenceMarker(line, in: text) {
                inFence.toggle()
                result += content + terminator
                continue
            }
            result += (inFence ? content : stripInline(content)) + terminator
        }
        return result
    }

    // MARK: - Words

    /// Every run of whitespace as one space, list markers at line starts dropped, the plain
    /// rule's spelling dropped.
    static func words(of text: String) -> String {
        var pieces: [String] = []
        for line in LineScanner.pieces(text) {
            var content = line.content.trimmingCharacters(in: .whitespaces)
            content = droppingListMarker(content)
            if content == "———" { content = "" }
            pieces.append(content)
        }
        return pieces.joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// `- `, `* `, `+ `, `• `, `– `, `— `, `12. `, `12) ` — and nothing else — at the start of
    /// a trimmed line. The bullet set is the plain-text bullets a flat document arrives with,
    /// plus the three Markdown spellings; the numbered forms are the two a person types.
    static func droppingListMarker(_ line: String) -> String {
        guard let first = line.first else { return line }
        if "-*+•–—".contains(first) {
            let rest = line.dropFirst()
            guard let next = rest.first, next == " " || next == "\t" else { return line }
            return String(rest.drop(while: { $0 == " " || $0 == "\t" }))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return line }
        var rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return line }
        rest = rest.dropFirst()
        guard let next = rest.first, next == " " || next == "\t" else { return line }
        return String(rest.drop(while: { $0 == " " || $0 == "\t" }))
    }

    // MARK: - Inline

    private static func stripInline(_ line: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard !line.isEmpty, let parsed = try? AttributedString(markdown: line, options: options)
        else { return line }
        var result = ""
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            if run.inlinePresentationIntent?.contains(.code) == true {
                result += "`" + text + "`"
            } else {
                result += text
            }
        }
        return result
    }
}
