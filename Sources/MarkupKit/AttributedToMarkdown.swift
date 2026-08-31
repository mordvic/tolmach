// Sources/MarkupKit/AttributedToMarkdown.swift
import AppKit
import Foundation
import TranslationCore

/// The `public.rtf` flavour of a capture, turned into Markdown by reading what it *looks* like.
///
/// **Used only when there is no HTML flavour.** HTML carries semantics — a `<h2>` says «heading,
/// level two» — and RTF carries a font, a size and a weight. So `HTMLToMarkdown` is preferred
/// wherever both are on the board, and this is the honest second best: every rule below is a
/// heuristic over visual attributes, because visual attributes are all RTF has. They are listed
/// in one place, with their limits, rather than spread as comments over the code that applies
/// them:
///
/// - **Bold and italic** come from the font's symbolic traits, per run. Reliable: these *are*
///   what the markers mean.
/// - **Inline code** is a run whose font is fixed-pitch; **a code block** is a paragraph all of
///   whose runs are, and consecutive such paragraphs become one fence. Reliable in the same way,
///   with one known miss: prose someone set in a monospaced face comes out as code. The
///   alternative — never reading a monospaced run as code — loses every code span in a document
///   whose author used one, which is the more common case by far.
/// - **A list item** is a paragraph whose `paragraphStyle.textLists` is non-empty, its depth the
///   nesting count, and its marker — bullet or number — read from the literal marker characters
///   AppKit's own importers put in the text (`"\t•\t"`, `"\t1.\t"`; `MarkdownToAttributed` writes
///   the same pairing from the other direction). Those characters are then stripped, because they
///   are the marker rather than the item's text.
/// - **A table** is a run of paragraphs whose `paragraphStyle.textBlocks` hold an
///   `NSTextTableBlock`; row and column come from the block, and a cell holding two paragraphs
///   has them joined with a space. **No delimiter row is emitted**: RTF carries no header flag,
///   and `MarkdownBlockScanner`'s own rule is that inventing one «would render the first row of
///   data in semibold». So the table arrives headerless, which is what it honestly is.
/// - **A heading's level comes from its point size relative to the document's own body size** —
///   the size covering the most characters, since a document is mostly body text. The ladder is
///   ×1.8 → h1, ×1.4 → h2, ×1.15 → h3, and anything larger than body *and* bold → h4. Two limits
///   follow and neither is fixable from RTF: a selection that is *only* a heading has no body
///   size to be relative to and comes out as a paragraph; and h4…h6, which AppKit's own HTML
///   import renders at or below body size, are indistinguishable from bold prose — so a bold
///   body-size paragraph stays a bold paragraph. That is the safe direction: the acceptance gate
///   (`RichMarkdown`) refuses a conversion that only added inline markers, so a missed heading
///   costs the capture its rich reading, while a fabricated one would ride into every chunk's
///   prompt.
/// - **A long paragraph is never a heading**, however large: `headingCharacterLimit` characters.
///   A pull quote set at 1.5× body is a paragraph, and `# ` in front of four lines of prose is a
///   worse error than a lost heading.
/// - **Blockquotes are deliberately not derived.** Their only trace in RTF is indentation, and
///   indentation is *prose* everywhere in this pipeline — `PromptBuilder.protectionRules` carries
///   that rule with its history, and `MarkdownBlockScanner` repeats it. Reading an indent as a
///   quote would fabricate exactly the kind of block token the gate accepts on.
/// - **Nothing derives a thematic break**, for the same reason: a rule's trace is a border on a
///   paragraph style, which prose also carries.
public enum AttributedToMarkdown {
    /// The flavour as the application wrote it, through AppKit's own RTF importer.
    ///
    /// **This is the measured-expensive half of the capture path**: the design measured AppKit's
    /// HTML import at 216–262 ms cold / ~60 ms warm, and the RTF importer is the same text-system
    /// machinery. It runs off the main actor at its one call site (`HotkeyCoordinator`), after the
    /// panel is already on screen, and only when there is no HTML flavour to prefer.
    ///
    /// `nil` for data the importer refuses, which costs the capture its markup and nothing else.
    public static func markdown(fromRTF data: Data) -> String? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
        else { return nil }
        return markdown(from: attributed)
    }

    /// The conversion itself, over an attributed string — which is what the tests construct
    /// directly, so the heuristics above can be pinned without an importer in the way.
    public static func markdown(from attributed: NSAttributedString) -> String {
        let paragraphs = paragraphs(of: attributed)
        let body = bodySize(of: attributed)
        var blocks: [Block] = []
        var index = 0
        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            if let table = tableBlock(at: paragraph)?.table {
                // Every consecutive paragraph belonging to the same table is one block. The
                // comparison is against `.table` and not against the *block*: two cells of one
                // table are two different `NSTextTableBlock`s sharing one `NSTextTable`, and
                // comparing the blocks — which type-checks, since `===` takes `AnyObject` — put
                // every cell in a table of its own, one pipe row per cell.
                var last = index
                while last + 1 < paragraphs.count,
                      tableBlock(at: paragraphs[last + 1])?.table === table { last += 1 }
                blocks += rows(of: Array(paragraphs[index...last]), in: attributed)
                index = last + 1
                continue
            }
            if isCode(paragraph, in: attributed) {
                var last = index
                while last + 1 < paragraphs.count,
                      isCode(paragraphs[last + 1], in: attributed) { last += 1 }
                let code = paragraphs[index...last]
                    .map { plainText(of: $0, in: attributed) }
                    .joined(separator: "\n")
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(Block(text: "```\n" + code + "\n```", run: .other))
                }
                index = last + 1
                continue
            }
            if let item = listItem(paragraph, in: attributed) {
                blocks.append(item)
                index += 1
                continue
            }
            let level = headingLevel(paragraph, in: attributed, body: body)
            // **A heading's own bold is not emphasis inside it.** The weight is part of what made
            // it a heading in the first place, so `## **Отчёт**` says the same thing twice and
            // puts two markers where the document has one shape — and `MarkupSkeleton` would then
            // report an emphasis span the source never had a reason to carry.
            let text = inline(paragraph.content, in: attributed, ignoringBold: level != nil)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                index += 1
                continue
            }
            if let level {
                blocks.append(Block(text: String(repeating: "#", count: level) + " " + text,
                                    run: .other))
            } else {
                blocks.append(Block(text: text, run: .other))
            }
            index += 1
        }
        return blocks.joinedAsMarkdown()
    }

    // MARK: - Blocks

    /// The separator rule between two finished blocks is `MarkdownOutputBlock`'s, shared with the
    /// other converters here rather than restated.
    typealias Block = MarkdownOutputBlock

    /// One paragraph: the range AppKit calls a paragraph, and the range without its terminator.
    struct Paragraph {
        let whole: NSRange
        let content: NSRange
        let style: NSParagraphStyle?
    }

    static func paragraphs(of attributed: NSAttributedString) -> [Paragraph] {
        let string = attributed.string as NSString
        var result: [Paragraph] = []
        var location = 0
        while location < string.length {
            let whole = string.paragraphRange(for: NSRange(location: location, length: 0))
            // `paragraphRange(for:)` includes the terminator; the text of the paragraph does not.
            var content = whole
            while content.length > 0,
                  let last = string.substring(with: NSRange(location: content.location + content.length - 1,
                                                           length: 1)).first,
                  last == "\n" || last == "\r" {
                content.length -= 1
            }
            let style = content.length > 0
                ? attributed.attribute(.paragraphStyle, at: content.location,
                                       effectiveRange: nil) as? NSParagraphStyle
                : nil
            result.append(Paragraph(whole: whole, content: content, style: style))
            location = whole.location + whole.length
            // A zero-length paragraph range would spin; `paragraphRange` never returns one for a
            // location inside the string, and this is the guard that says so out loud.
            if whole.length == 0 { break }
        }
        return result
    }

    // MARK: - Fonts and sizes

    /// The point size covering the most characters, ignoring monospaced runs.
    ///
    /// «Most characters» rather than «the first run» or «the smallest»: a document is mostly body
    /// text, its first run may be its title, and its smallest size is a footnote. Ignoring
    /// monospaced runs keeps a page of code from setting the body size for the prose around it.
    /// 12 pt when there is nothing to count — a size no heading ladder can be built on, which is
    /// why a heading-only selection comes out as a paragraph rather than as a guess.
    static func bodySize(of attributed: NSAttributedString) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length),
                                      options: []) { value, range, _ in
            guard let font = value as? NSFont, !isFixedPitch(font) else { return }
            weights[font.pointSize, default: 0] += range.length
        }
        return weights.max { left, right in
            // Ties go to the smaller size: body text is smaller than headings.
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key ?? 12
    }

    static func isFixedPitch(_ font: NSFont) -> Bool {
        font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    /// The longest a paragraph may be and still be read as a heading. Four lines of prose set
    /// large is a pull quote; `# ` in front of it is a worse error than a lost heading.
    static let headingCharacterLimit = 120

    static func headingLevel(_ paragraph: Paragraph, in attributed: NSAttributedString,
                             body: CGFloat) -> Int? {
        guard paragraph.content.length > 0,
              paragraph.content.length <= headingCharacterLimit,
              !(attributed.string as NSString).substring(with: paragraph.content)
                  .contains("\n") else { return nil }
        var largest: CGFloat = 0
        var boldCharacters = 0
        attributed.enumerateAttribute(.font, in: paragraph.content, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            largest = max(largest, font.pointSize)
            if font.fontDescriptor.symbolicTraits.contains(.bold) { boldCharacters += range.length }
        }
        guard largest > 0, body > 0 else { return nil }
        let ratio = largest / body
        let bold = boldCharacters * 2 > paragraph.content.length
        if ratio >= 1.8 { return 1 }
        if ratio >= 1.4 { return 2 }
        if ratio >= 1.15 { return 3 }
        // Larger than body and bold: h4 in AppKit's own rendering of HTML, and the last level
        // that can be told from bold prose at all.
        if ratio > 1.0, bold { return 4 }
        return nil
    }

    // MARK: - Code

    static func isCode(_ paragraph: Paragraph, in attributed: NSAttributedString) -> Bool {
        guard paragraph.content.length > 0, tableBlock(at: paragraph) == nil,
              paragraph.style?.textLists.isEmpty ?? true else { return false }
        var monospaced = true
        var sawFont = false
        attributed.enumerateAttribute(.font, in: paragraph.content, options: []) { value, _, _ in
            guard let font = value as? NSFont else { return }
            sawFont = true
            if !isFixedPitch(font) { monospaced = false }
        }
        return sawFont && monospaced
    }

    /// A code block's characters, verbatim: no markers, no collapsing, no trimming. The one
    /// thing dropped is the attachment placeholder, which is an image and not text.
    static func plainText(of paragraph: Paragraph, in attributed: NSAttributedString) -> String {
        (attributed.string as NSString).substring(with: paragraph.content)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    // MARK: - Lists

    static func listItem(_ paragraph: Paragraph, in attributed: NSAttributedString) -> Block? {
        guard let lists = paragraph.style?.textLists, !lists.isEmpty,
              paragraph.content.length > 0 else { return nil }
        let raw = plainText(of: paragraph, in: attributed)
        let marker = markerPrefix(of: raw)
        let content = inline(NSRange(location: paragraph.content.location + marker.length,
                                     length: paragraph.content.length - marker.length),
                             in: attributed)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let depth = max(0, lists.count - 1)
        // The document's own number, read from the marker characters it carries, rather than a
        // counter kept here: an item numbered 4 in a list the user selected from the middle is
        // still item 4.
        let ordered = marker.text.first?.isNumber == true
            || (marker.text.isEmpty && isOrdered(lists.last))
        let label = ordered
            ? (marker.text.isEmpty ? "1." : marker.text) + " "
            : "- "
        return Block(text: String(repeating: "  ", count: depth) + label + content,
                     run: .listItem)
    }

    static func isOrdered(_ list: NSTextList?) -> Bool {
        switch list?.markerFormat {
        case .none, .some(.disc), .some(.circle), .some(.square), .some(.hyphen),
             .some(.box), .some(.check), .some(.diamond):
            return false
        default:
            return true
        }
    }

    /// The literal marker AppKit's importers put in the text — `"\t•\t"`, `"\t1.\t"` — measured
    /// from the other direction by `MarkdownToAttributed.listItem`, which writes exactly that
    /// pairing because the HTML import produces it.
    ///
    /// Only the first few characters are searched: a tab further into the line is the author's
    /// own tab and part of the item's text.
    static func markerPrefix(of raw: String) -> (length: Int, text: String) {
        let prefix = raw.prefix(8)
        guard prefix.contains("\t"), let lastTab = prefix.lastIndex(of: "\t") else {
            return (0, "")
        }
        let through = prefix.distance(from: prefix.startIndex, to: lastTab) + 1
        let marker = prefix.prefix(through)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        // A UTF-16 length, because every range in this file is one.
        return ((prefix.prefix(through) as NSString).length, marker)
    }

    // MARK: - Tables

    static func tableBlock(at paragraph: Paragraph) -> NSTextTableBlock? {
        paragraph.style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.first
    }

    static func rows(of paragraphs: [Paragraph],
                     in attributed: NSAttributedString) -> [Block] {
        // `[(row, [(column, text)])]` in the order the rows first appear, so a table whose
        // paragraphs arrive out of order still comes out in document order.
        var rows: [(row: Int, cells: [(column: Int, text: String)])] = []
        for paragraph in paragraphs {
            guard let block = tableBlock(at: paragraph) else { continue }
            let text = inline(paragraph.content, in: attributed)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
                .trimmingCharacters(in: .whitespaces)
            let rowIndex = rows.firstIndex { $0.row == block.startingRow }
                ?? { rows.append((block.startingRow, [])); return rows.count - 1 }()
            if let cell = rows[rowIndex].cells.firstIndex(where: { $0.column == block.startingColumn }) {
                // A cell holding more than one paragraph: joined with a space, because a pipe row
                // is one line by construction.
                let existing = rows[rowIndex].cells[cell].text
                rows[rowIndex].cells[cell].text =
                    existing.isEmpty ? text : (text.isEmpty ? existing : existing + " " + text)
            } else {
                rows[rowIndex].cells.append((block.startingColumn, text))
            }
        }
        return rows.map { row in
            let cells = row.cells.sorted { $0.column < $1.column }.map(\.text)
            return Block(text: "| " + cells.joined(separator: " | ") + " |", run: .tableRow)
        }
    }

    // MARK: - Inline runs

    /// One paragraph's runs, mapped onto markers.
    ///
    /// Runs are **merged by formatting first**: an importer splits a string at every attribute
    /// change of any kind, and two adjacent bold runs written separately would come out
    /// `**раз****два**` — four literal asterisks. What matters here is only whether a run is
    /// bold, italic, monospaced or linked, so that is what the grouping is on.
    ///
    /// Nesting order is code innermost (and exclusive — an emphasised code span is not something
    /// either parser reads back), then italic, then bold, then the link outermost.
    static func inline(_ range: NSRange, in attributed: NSAttributedString,
                       ignoringBold: Bool = false) -> String {
        guard range.length > 0 else { return "" }
        let string = attributed.string as NSString
        struct Format: Equatable {
            var bold = false
            var italic = false
            var monospaced = false
            var href: String?
        }
        var groups: [(format: Format, text: String)] = []
        attributed.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            var format = Format()
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                format.bold = traits.contains(.bold)
                format.italic = traits.contains(.italic)
                format.monospaced = isFixedPitch(font)
            }
            if let link = attributes[.link] {
                format.href = (link as? URL)?.absoluteString ?? (link as? String)
            }
            let text = string.substring(with: runRange)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !text.isEmpty else { return }
            if var last = groups.last, last.format == format {
                last.text += text
                groups[groups.count - 1] = last
            } else {
                groups.append((format, text))
            }
        }
        return groups.map { group -> String in
            var text = group.text
            if group.format.monospaced {
                text = MarkdownInline.wrapped(text, in: "`")
            } else {
                if group.format.italic { text = MarkdownInline.wrapped(text, in: "*") }
                if group.format.bold, !ignoringBold {
                    text = MarkdownInline.wrapped(text, in: "**")
                }
            }
            if let href = group.format.href {
                text = MarkdownInline.link(text: text, href: href)
            }
            return text
        }.joined()
    }
}
