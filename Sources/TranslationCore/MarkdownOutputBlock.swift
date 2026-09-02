// Sources/TranslationCore/MarkdownOutputBlock.swift
import Foundation

/// One finished block on its way into a Markdown document, and whether it belongs to a run of
/// blocks of its own kind.
///
/// Every converter in this target ends up assembling blocks into one string, and the rule for the
/// separator between two of them is the same rule three times over — so it is written once, here.
/// It was three copies for one afternoon and the third was already wrong: a list item joined to
/// the *paragraph* above it with a single newline, because «tight» had been made a property of the
/// block rather than of the pair.
///
/// The rule: two blocks of the same run kind are adjacent lines; everything else is separated by a
/// blank line. That is what keeps a list a list — `MarkdownBlockScanner` reads three items
/// separated by blank lines as three lists of one — while keeping a paragraph a paragraph.
///
/// In `TranslationCore` since 2026-09-02, because `MarkdownPlainText` moved here to serve the
/// «Оформить» gate and this is the joiner it writes with; `MarkupKit`'s two capture converters
/// keep using it from here. Foundation only, like everything else in this module.
public struct MarkdownOutputBlock: Sendable, Equatable {
    public enum Run: Sendable, Equatable { case listItem, tableRow, other }

    public let text: String
    public let run: Run

    public init(text: String, run: Run) {
        self.text = text
        self.run = run
    }
}

extension Array where Element == MarkdownOutputBlock {
    /// The document. Empty blocks contribute nothing at all, not a blank line.
    public func joinedAsMarkdown() -> String {
        var result = ""
        var previous: MarkdownOutputBlock.Run?
        for block in self where !block.text.isEmpty {
            if let previous {
                result += (previous == block.run && block.run != .other) ? "\n" : "\n\n"
            }
            result += block.text
            previous = block.run
        }
        return result
    }
}
