// Sources/TranslationCore/MarkdownPlainText.swift
import Foundation

/// Markdown with its markers taken back off, for the one path that must not carry them:
/// «Заменить», writing a translation back into the application the selection came from.
///
/// **It is used only when this app synthesised the Markdown itself.** A user whose own selection
/// genuinely contained `**` gets today's byte-plain replace — stripping their markers would
/// corrupt their document — and `HotkeyCoordinator` is where that provenance is kept. The rule is
/// stated there; this type is only the renderer.
///
/// Not an inverse of anything, and it cannot be: the pane's rendered mode and the rich copy
/// flavour both exist precisely because plain text cannot hold a heading. What it *is* is the
/// least-lossy plain spelling of each block, chosen once, here:
///
/// - **A heading** loses its `#`s and keeps its words. There is no plain spelling of «heading».
/// - **A paragraph** is its own inline text with the markers gone.
/// - **A list item** keeps a marker, because a list whose markers are gone reads as glued prose —
///   but «•» and not «-», with two spaces of indent per level. The destination is a rich document,
///   and a literal `-` reads there as Markdown syntax leaking; «•» is the character the user's own
///   list drew.
/// - **A blockquote** loses its `>` and keeps its words, for the heading's reason: the only other
///   plain spelling of a quote is `> `, which is the syntax being removed.
/// - **A code block** is its content, verbatim, fences gone. Its bytes are the one thing in a
///   translation that must not be reformatted.
/// - **A table row** is its cells joined by tabs — the plain-text spelling of a table everywhere:
///   what a spreadsheet puts on the pasteboard, and what Word's «преобразовать текст в таблицу»
///   reads. Pipes would be Markdown syntax again.
/// - **A thematic break** becomes «———», three em dashes: a divider a reader sees, in characters
///   rather than in syntax. Neither capture converter can produce one, so this is reachable only
///   from a model's own output.
/// - **A link** keeps its text and loses its URL. A plain write has nowhere to put a target, and
///   appending it in parentheses would edit the user's sentence. Stated as a loss, not hidden.
public enum MarkdownPlainText {
    /// The plain spelling of a thematic break. A named constant because `FormattingGate` has
    /// to recognise it on the way back, and a literal spelled twice is the shape this repo has
    /// already paid for.
    public static let thematicBreak = "———"

    public static func render(_ markdown: String) -> String {
        var blocks: [MarkdownOutputBlock] = []
        // Exhaustive with no `default:`, so a new `MarkdownBlock` case has to be given a plain
        // spelling here rather than silently disappearing out of someone's document.
        for block in MarkdownBlockScanner.blocks(of: markdown) {
            switch block {
            case let .heading(_, range):
                blocks.append(.init(text: inline(String(markdown[range])), run: .other))
            case let .paragraph(range):
                blocks.append(.init(text: inline(String(markdown[range])), run: .other))
            case let .listItem(depth, marker, range):
                let label: String
                switch marker {
                case .bullet: label = "• "
                case let .ordered(number): label = "\(number). "
                }
                blocks.append(.init(text: String(repeating: "  ", count: depth) + label
                                        + inline(String(markdown[range])), run: .listItem))
            case let .blockquote(_, range):
                blocks.append(.init(text: inline(String(markdown[range])), run: .other))
            case let .codeBlock(_, range, _):
                blocks.append(.init(text: String(markdown[range]), run: .other))
            case let .table(header, rows, _):
                for row in ([header] + rows) where !row.isEmpty {
                    blocks.append(.init(text: row.map { inline(String(markdown[$0])) }
                        .joined(separator: "\t"), run: .tableRow))
                }
            case .thematicBreak:
                blocks.append(.init(text: thematicBreak, run: .other))
            }
        }
        return blocks.joinedAsMarkdown()
    }

    /// One block's inline markers removed, by Foundation's own parse rather than by a second
    /// scanner.
    ///
    /// `inlineOnlyPreservingWhitespace` for the reason `MarkdownToAttributed.inline` documents
    /// with its measurement: `.full` is not byte-lossless (soft breaks collapse and a paragraph
    /// boundary disappears from the characters) and reads a four-space indent as code, which
    /// contradicts this pipeline's own rule. This option is lossless on the same string, and
    /// taking `.characters` off the result is exactly «the words without the syntax» — a link
    /// keeps its text, a code span keeps its content, emphasis keeps its word.
    ///
    /// A `try?` with the source as the fallback, so a string Foundation refuses is written back
    /// as it stands rather than costing the user their replacement.
    static func inline(_ source: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return source
        }
        return String(parsed.characters)
    }
}
