// Sources/TranslationCore/MarkdownBlocks.swift
import Foundation

/// One block of a Markdown document, as a **range into the document** rather than a copy of it.
///
/// The ranges are the whole point of the type, and there are two reasons for them:
///
/// - «Скопировать» on a code block must hand over the source bytes *exactly*. A re-serialised
///   tree cannot promise that; a `Range` into the string the user is looking at can.
/// - «Исходник» (the pane's second mode) is the same string, not a round trip through a tree.
///   Nothing in this file can lose a byte, because nothing in this file holds one.
///
/// The reading is deliberately the same reading `Chunker` and `MarkupSkeleton` already have:
/// fenced code is all-or-nothing, **indented text is prose and never code**, a table row is a
/// `|`-prefixed line, and headings, list items and quotes are recognised by
/// `MarkupSkeleton.headingLevel` / `listDepth` / `isSetextUnderline` — the same code, called,
/// not restated. A renderer that saw a different document from the chunker would draw a table
/// where the markup diff saw a paragraph.
public enum MarkdownBlock: Sendable, Equatable {
    /// `range` is the heading's text: the `#`s and the spaces after them are excluded, the
    /// line's terminator is excluded. A setext heading's range is the underlined paragraph,
    /// which is why this is a range and not a line index.
    case heading(level: Int, range: Range<String.Index>)
    /// Consecutive non-blank lines that start no other block. Interior line terminators are
    /// inside the range — the source's own bytes, whatever their spelling.
    case paragraph(range: Range<String.Index>)
    /// `content` excludes the marker and the space after it; a lazy continuation line is part
    /// of it, terminator included.
    case listItem(depth: Int, marker: ListMarker, content: Range<String.Index>)
    /// `content` excludes the `>` markers of every line it spans.
    case blockquote(depth: Int, content: Range<String.Index>)
    /// `content` is the code, verbatim, between the fence lines — neither fence line is in it.
    /// `closed` is false for a fence that ran to the end of the document, which is both the
    /// unterminated-fence case and the normal state of a stream mid-arrival.
    case codeBlock(lang: String, content: Range<String.Index>, closed: Bool)
    /// `header` is empty for a table written without a delimiter row. Cell ranges are trimmed
    /// of the spaces around them, so a renderer neither has to trim nor may forget to.
    case table(header: [Range<String.Index>], rows: [[Range<String.Index>]],
               alignments: [Alignment])
    case thematicBreak(range: Range<String.Index>)

    public enum ListMarker: Sendable, Equatable {
        case bullet
        case ordered(Int)
    }

    /// A table column's alignment, as the delimiter row spelled it. Nested rather than
    /// top-level: `Alignment` unqualified is SwiftUI's in the app layer, and a public
    /// `TranslationCore.Alignment` would shadow it at every call site that imports both.
    public enum Alignment: Sendable, Equatable {
        case unspecified, leading, center, trailing
    }
}

public enum MarkdownBlockScanner {
    /// Every block of `text`, in document order.
    public static func blocks(of text: String) -> [MarkdownBlock] {
        scan(text).blocks
    }

    /// The prefix whose shape can no longer change however the document grows, and the rest.
    ///
    /// This is the streaming rule (design §7). A block is settled when no later byte can
    /// change what it *is*:
    ///
    /// - a fenced block when its closing marker has arrived;
    /// - every other block when at least one **terminated** line follows its last line.
    ///
    /// The second half is stricter than «a blank line follows» and it has to be. A dash run
    /// grows: after `"Абзац\n-"` the next byte can produce `"--"`, which
    /// `MarkupSkeleton.isSetextUnderline` reads as an H2 underline and turns the paragraph
    /// above it into a heading. A table is the same shape in the other direction — it stops
    /// being a table only when a non-`|` line lands. Requiring the *following* line to be
    /// terminated is what makes «this line's role is decided» true rather than likely.
    ///
    /// Two properties follow, and both are pinned by tests: the returned prefix never shrinks
    /// as the document grows, and a block once in it never changes kind or range. They are
    /// what lets the window's pane append settled blocks to a text storage and keep only the
    /// tail as plain characters — a block drawn as itself is never redrawn as something else.
    ///
    /// `tail` starts at the first character of the first unsettled block's first line, so
    /// `text[..<tail.lowerBound]` is exactly what the settled blocks account for, blank
    /// separators included. It is `endIndex..<endIndex` when everything is settled.
    public static func settledPrefix(of text: String)
        -> (blocks: [MarkdownBlock], tail: Range<String.Index>) {
        let scanned = scan(text)
        let settled = Array(scanned.blocks.prefix(scanned.settledCount))
        return (settled, scanned.tail)
    }

    // MARK: - The scan

    struct Scan {
        let blocks: [MarkdownBlock]
        /// How many leading blocks are settled. Settledness is monotone by construction —
        /// an unsettled block is always the last one, because «no terminated line follows»
        /// can only be true at the end of the document — so a count is the whole answer.
        let settledCount: Int
        let tail: Range<String.Index>
    }

    static func scan(_ text: String) -> Scan {
        let lines = LineScanner.scanLines(text)
        var blocks: [MarkdownBlock] = []
        /// The line each block starts on, and the line it ends on. Kept beside the blocks
        /// rather than inside them: `MarkdownBlock`'s ranges are what callers need, and line
        /// indices are what settledness is decided on.
        var spans: [(start: Int, end: Int, settled: Bool)] = []
        var index = 0

        /// A block ending on `line` is settled once the line after it exists **and carries its
        /// own terminator** — see `settledPrefix` for why the terminator is load-bearing.
        func hasTerminatedLine(after line: Int) -> Bool {
            let next = line + 1
            guard next < lines.count else { return false }
            return lines[next].end > lines[next].content.upperBound
        }

        func content(of line: Int) -> String { String(text[lines[line].content]) }
        func trimmed(_ line: Int) -> String {
            content(of: line).trimmingCharacters(in: .whitespaces)
        }
        /// True for a line that opens a block of its own, so a paragraph or a list item knows
        /// where to stop. Deliberately the same set of predicates the loop below dispatches
        /// on, in the same order.
        func startsAnotherBlock(_ line: Int) -> Bool {
            if LineScanner.isFenceMarker(lines[line], in: text) { return true }
            let trimmedLine = trimmed(line)
            if trimmedLine.hasPrefix("|") { return true }
            if MarkupSkeleton.headingLevel(trimmedLine) != nil { return true }
            if trimmedLine.hasPrefix(">") { return true }
            if MarkupSkeleton.listDepth(content(of: line)) != nil { return true }
            if isThematicBreak(trimmedLine) { return true }
            // A dash or equals run is not a *block* start — it is an underline for whatever
            // sits above it — but a paragraph gathering lines must still stop at it, and it
            // is the one caller that has to tell the two apart. `MarkupSkeleton`'s reading of
            // a run that fails its gate is «not paragraph text either», so stopping here
            // keeps the two layers seeing one document.
            if MarkupSkeleton.isSetextUnderline(trimmedLine) != nil { return true }
            return false
        }

        while index < lines.count {
            if LineScanner.isBlank(lines[index], in: text) { index += 1; continue }
            let line = lines[index]
            let trimmedLine = trimmed(index)

            // Fences first, and all-or-nothing, because that is the one rule every layer of
            // this pipeline already shares: a fenced block never reaches the model at all.
            if LineScanner.isFenceMarker(line, in: text) {
                let lang = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var closing = index + 1
                while closing < lines.count,
                      !LineScanner.isFenceMarker(lines[closing], in: text) { closing += 1 }
                let closed = closing < lines.count
                let lastCodeLine = (closed ? closing : lines.count) - 1
                // The code's own bytes and nothing else: from the start of the line after the
                // opening fence to the end of the last code line's *content*, so neither the
                // fence lines nor the terminator in front of the closing one are inside it.
                let range: Range<String.Index> = lastCodeLine >= index + 1
                    ? lines[index + 1].content.lowerBound..<lines[lastCodeLine].content.upperBound
                    : line.end..<line.end
                blocks.append(.codeBlock(lang: lang, content: range, closed: closed))
                let endLine = closed ? closing : lines.count - 1
                // Settled the moment it is closed, and never before: an unclosed fence keeps
                // swallowing whatever arrives next.
                spans.append((index, endLine, closed))
                index = endLine + 1
                continue
            }

            if trimmedLine.hasPrefix("|") {
                var last = index
                while last + 1 < lines.count,
                      trimmed(last + 1).hasPrefix("|") { last += 1 }
                blocks.append(table(rows: index...last, in: text, lines: lines))
                spans.append((index, last, hasTerminatedLine(after: last)))
                index = last + 1
                continue
            }

            if let level = MarkupSkeleton.headingLevel(trimmedLine) {
                blocks.append(.heading(level: level,
                                       range: headingContent(of: line, in: text)))
                spans.append((index, index, hasTerminatedLine(after: index)))
                index += 1
                continue
            }

            if trimmedLine.hasPrefix(">") {
                let opening = quoteMarker(of: line, in: text)
                var last = index
                while last + 1 < lines.count,
                      trimmed(last + 1).hasPrefix(">"),
                      quoteMarker(of: lines[last + 1], in: text).depth == opening.depth {
                    last += 1
                }
                let contentEnd = quoteMarker(of: lines[last], in: text).content.upperBound
                blocks.append(.blockquote(depth: opening.depth,
                                          content: opening.content.lowerBound..<contentEnd))
                spans.append((index, last, hasTerminatedLine(after: last)))
                index = last + 1
                continue
            }

            if let depth = MarkupSkeleton.listDepth(content(of: index)) {
                let item = listContent(of: line, in: text)
                // Lazy continuation: a following non-blank line that opens no block of its own
                // belongs to this item. Its own indentation is not a signal — indented text is
                // prose everywhere in this pipeline — it is simply the rest of the sentence.
                var last = index
                while last + 1 < lines.count,
                      !LineScanner.isBlank(lines[last + 1], in: text),
                      !startsAnotherBlock(last + 1) { last += 1 }
                let itemContent = item.content.lowerBound..<lines[last].content.upperBound
                blocks.append(.listItem(depth: depth, marker: item.marker,
                                        content: itemContent))
                spans.append((index, last, hasTerminatedLine(after: last)))
                index = last + 1
                continue
            }

            if isThematicBreak(trimmedLine) {
                blocks.append(.thematicBreak(range: line.content))
                spans.append((index, index, hasTerminatedLine(after: index)))
                index += 1
                continue
            }

            // A dash or equals run with no paragraph above it. `MarkupSkeleton` emits nothing
            // for it and reads it as «not paragraph text either»; here it is a paragraph of
            // its own, which is the only honest thing to draw for a line that decorates
            // nothing. (`isThematicBreak` has already claimed the 3-or-more case.)
            var last = index
            while last + 1 < lines.count,
                  !LineScanner.isBlank(lines[last + 1], in: text),
                  !startsAnotherBlock(last + 1) { last += 1 }
            // Setext: the line that stopped the gathering is an underline, so what was
            // gathered is a heading rather than a paragraph. The same rule
            // `MarkupSkeleton.tokens` applies, through the same predicate.
            let gathered = line.content.lowerBound..<lines[last].content.upperBound
            if last + 1 < lines.count,
               let level = MarkupSkeleton.isSetextUnderline(trimmed(last + 1)) {
                blocks.append(.heading(level: level, range: gathered))
                // The underline is part of the heading, so settledness is decided from *it*.
                spans.append((index, last + 1, hasTerminatedLine(after: last + 1)))
                index = last + 2
                continue
            }
            blocks.append(.paragraph(range: gathered))
            spans.append((index, last, hasTerminatedLine(after: last)))
            index = last + 1
        }

        let settledCount = spans.prefix { $0.settled }.count
        let tail: Range<String.Index> = settledCount < spans.count
            ? lines[spans[settledCount].start].content.lowerBound..<text.endIndex
            : text.endIndex..<text.endIndex
        return Scan(blocks: blocks, settledCount: settledCount, tail: tail)
    }

    // MARK: - Line shapes

    /// Three or more of `-`, `*` or `_` and nothing else. A `---` line **above** a paragraph;
    /// the one below a paragraph is a setext underline and `scan` deals with it there, in the
    /// same order `MarkupSkeleton.tokens` does.
    static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return trimmed.allSatisfy { $0 == first }
    }

    /// The heading's text: past the `#`s and the whitespace after them, to the end of the
    /// line's content.
    static func headingContent(of line: LineScanner.Line, in text: String) -> Range<String.Index> {
        var start = line.content.lowerBound
        while start < line.content.upperBound, text[start] == " " || text[start] == "\t" {
            start = text.index(after: start)
        }
        while start < line.content.upperBound, text[start] == "#" {
            start = text.index(after: start)
        }
        while start < line.content.upperBound, text[start] == " " || text[start] == "\t" {
            start = text.index(after: start)
        }
        return start..<line.content.upperBound
    }

    /// How deep the quote is and where its text starts. Depth counts `>` markers, so
    /// `"> > цитата"` is depth 2 — the same counting a reader does.
    static func quoteMarker(of line: LineScanner.Line, in text: String)
        -> (depth: Int, content: Range<String.Index>) {
        var cursor = line.content.lowerBound
        var depth = 0
        while cursor < line.content.upperBound {
            if text[cursor] == " " || text[cursor] == "\t" {
                cursor = text.index(after: cursor)
            } else if text[cursor] == ">" {
                depth += 1
                cursor = text.index(after: cursor)
            } else {
                break
            }
        }
        return (depth, cursor..<line.content.upperBound)
    }

    /// The marker a list line carries and where its text starts. `MarkupSkeleton.listDepth`
    /// has already said this *is* a list line; this only reads which kind.
    static func listContent(of line: LineScanner.Line, in text: String)
        -> (marker: MarkdownBlock.ListMarker, content: Range<String.Index>) {
        var cursor = line.content.lowerBound
        while cursor < line.content.upperBound, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        var marker = MarkdownBlock.ListMarker.bullet
        if cursor < line.content.upperBound, "-*+".contains(text[cursor]) {
            cursor = text.index(after: cursor)
        } else {
            var digits = ""
            while cursor < line.content.upperBound, text[cursor].isNumber {
                digits.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            marker = .ordered(Int(digits) ?? 1)
            // The "." of "1." — `listDepth` guaranteed it is there.
            if cursor < line.content.upperBound, text[cursor] == "." {
                cursor = text.index(after: cursor)
            }
        }
        while cursor < line.content.upperBound, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        return (marker, cursor..<line.content.upperBound)
    }

    // MARK: - Tables

    static func table(rows: ClosedRange<Int>, in text: String,
                      lines: [LineScanner.Line]) -> MarkdownBlock {
        var parsed: [[Range<String.Index>]] = []
        for index in rows { parsed.append(cells(of: lines[index], in: text)) }
        // A delimiter row is what tells a header from a first row, and it carries the
        // alignments. Without one there is no header — inventing one would render the first
        // row of data in semibold.
        var header: [Range<String.Index>] = []
        var alignments: [MarkdownBlock.Alignment] = []
        if parsed.count >= 2, isDelimiterRow(parsed[1], in: text) {
            header = parsed[0]
            alignments = parsed[1].map { alignment(of: String(text[$0])) }
            parsed.removeFirst(2)
        }
        let columns = max(header.count, parsed.map(\.count).max() ?? 0)
        if alignments.count < columns {
            alignments += Array(repeating: .unspecified, count: columns - alignments.count)
        }
        return .table(header: header, rows: parsed, alignments: alignments)
    }

    /// The cells of one `|`-delimited row, each trimmed of the spaces around it.
    ///
    /// The empty segments a leading and a trailing `|` produce are dropped; an empty cell
    /// *between* two pipes is kept, because a table with a blank cell has that cell.
    static func cells(of line: LineScanner.Line, in text: String) -> [Range<String.Index>] {
        var pipes: [String.Index] = []
        var cursor = line.content.lowerBound
        while cursor < line.content.upperBound {
            if text[cursor] == "|" { pipes.append(cursor) }
            cursor = text.index(after: cursor)
        }
        guard !pipes.isEmpty else { return [trim(line.content, in: text)] }
        var result: [Range<String.Index>] = []
        var start = line.content.lowerBound
        for pipe in pipes {
            if start != line.content.lowerBound || start < pipe {
                let candidate = trim(start..<pipe, in: text)
                // The segment in front of a leading pipe is not a cell.
                if !(start == line.content.lowerBound && candidate.isEmpty) {
                    result.append(candidate)
                }
            }
            start = text.index(after: pipe)
        }
        let last = trim(start..<line.content.upperBound, in: text)
        if !last.isEmpty { result.append(last) }
        return result
    }

    static func trim(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while lower < upper, text[text.index(before: upper)].isWhitespace {
            upper = text.index(before: upper)
        }
        return lower..<upper
    }

    static func isDelimiterRow(_ cells: [Range<String.Index>], in text: String) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { range in
            let cell = String(text[range])
            guard cell.contains("-") else { return false }
            return cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func alignment(of delimiter: String) -> MarkdownBlock.Alignment {
        let leading = delimiter.hasPrefix(":")
        let trailing = delimiter.hasSuffix(":")
        switch (leading, trailing) {
        case (true, true): return .center
        case (true, false): return .leading
        case (false, true): return .trailing
        case (false, false): return .unspecified
        }
    }
}

/// Lines that begin with a plain-text bullet — «•» or «–» followed by a space — as a list
/// **for display only**.
///
/// The commonest flat list a selection arrives with is exactly this shape, and drawing it as
/// prose was the one heuristic the 2026-09-02 grilling kept (Q8, Q24). It is deliberately not
/// a block kind: `MarkdownBlockScanner` goes on reading the paragraph as a paragraph, so the
/// chunker, `MarkupSkeleton` and the model see the user's bytes, and «Заменить» never has a
/// «- » to strip that would have replaced the user's own «•». Only the renderer and
/// `MarkdownPresence` — so the toggle appears and «Исходник» is one click away when the guess
/// is wrong — read this.
///
/// Every line must carry a marker for the paragraph to be a list. A paragraph with one unmarked
/// line is prose that happens to mention a bullet, and drawing half of it as a list would be a
/// guess about the other half.
public enum PlainBulletList {
    static let markers: Set<Character> = ["•", "–"]

    /// The items' content ranges (the text after the marker and its space), or nil unless
    /// every line of `paragraph` carries a marker. Ranges index the paragraph's base string.
    public static func items(of paragraph: Substring) -> [Range<String.Index>]? {
        var items: [Range<String.Index>] = []
        var lineStart = paragraph.startIndex
        var index = paragraph.startIndex
        func take(_ line: Substring) -> Bool {
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = content.first, markers.contains(first) else { return false }
            let afterMarker = content.dropFirst()
            guard let space = afterMarker.first, space == " " || space == "\t" else { return false }
            let body = afterMarker.drop(while: { $0 == " " || $0 == "\t" })
            items.append(body.startIndex..<body.endIndex)
            return true
        }
        while index < paragraph.endIndex {
            // `Character.isNewline` reads "\r\n" as the one character it is, and a lone CR as
            // a break too — the discipline `LineScanner` keeps for the rest of the module.
            if paragraph[index].isNewline {
                guard take(paragraph[lineStart..<index]) else { return nil }
                lineStart = paragraph.index(after: index)
            }
            index = paragraph.index(after: index)
        }
        if lineStart < paragraph.endIndex {
            guard take(paragraph[lineStart..<paragraph.endIndex]) else { return nil }
        }
        return items.isEmpty ? nil : items
    }
}

/// Whether a string carries anything a renderer could draw differently from plain prose.
///
/// The pane's «Разметка | Исходник» toggle appears only when this answers true, and with no
/// markup the pane is exactly what it was before this existed — one `Text`, no toggle, no text
/// view. So a false positive costs a control nobody asked for on a plain translation, and the
/// three signals below are each chosen to be hard to trip by accident:
///
/// - **any block that is not a paragraph** — the design's own rule (§8);
/// - **an inline code span**, found by `MarkupSkeleton.inlineCodeSpans`, the repo's one
///   definition of a span, so this cannot come to disagree with what the pipeline protects;
/// - **paired `*` emphasis** whose opener is not followed by whitespace and whose closer is
///   not preceded by it. Measured against the design's own probe string,
///   `"Цена 5 * 3 = 15, файл a_b_c.txt и #хэштег"`: its single `*` is followed by a space, so
///   it can open nothing and the string reads as plain prose. `_` is deliberately **not** a
///   signal — `a_b_c.txt` pairs under a naive reading, and the flanking rules that would
///   exclude it are a parser this project is not writing.
public enum MarkdownPresence {
    /// How much of the document this looks at, and why there is a limit at all.
    ///
    /// The answer is asked for on **every** redraw of the pane, which during a run means once
    /// per streamed token, and the queue accepts 2 MB files: an unbounded scan is quadratic in
    /// exactly the case that hurts — a long document of plain prose, where there is no markup
    /// to exit early on. For scale, this repo has measured a 2.06 MB language-detection scan of
    /// the same shape at ~48 ms, which per token is not a cost the pane can pay.
    ///
    /// 128 000 characters is far past where a Markdown document announces itself: a heading, a
    /// list or a fence in the *first* 128 KB is what every real one has. The limitation is
    /// real and stated plainly — a translation whose only markup begins after that shows no
    /// toggle — and it errs in the safe direction, because truncating a document can only
    /// remove markers, never pair two that were not paired.
    public static let inspectionLimit = 128_000

    /// - Parameter countingPlainBullets: whether `PlainBulletList`'s display-only signal counts.
    ///   True for the panes, which need the toggle. **False for the «Оформить» pass**, which
    ///   asks «is there structure a model could still add» — a flat mail with «•» bullets and
    ///   a collapsed table has a list to show and a table to recover, and the display heuristic
    ///   must not stop the recovery.
    public static func hasMarkup(_ text: String, countingPlainBullets: Bool = true) -> Bool {
        hasMarkup(text, inspecting: inspectionLimit, countingPlainBullets: countingPlainBullets)
    }

    /// The same question over a bounded prefix. The limit is a parameter so a test can pin the
    /// bound rather than restate the number.
    public static func hasMarkup(_ text: String, inspecting limit: Int,
                                 countingPlainBullets: Bool = true) -> Bool {
        // `utf8.count` and not `count`: the character count of a 2 MB string is itself a full
        // pass, which is the cost this bound exists to avoid. UTF-8 length is O(1) on a native
        // string and never smaller than the character count, so a document that passes this
        // test needs no truncating.
        let text = text.utf8.count > limit ? String(text.prefix(limit)) : text
        var paragraphs: [Range<String.Index>] = []
        for block in MarkdownBlockScanner.blocks(of: text) {
            guard case let .paragraph(range) = block else { return true }
            paragraphs.append(range)
        }
        for paragraph in paragraphs {
            // A display-only list still needs the toggle, or its raw form is unreachable.
            if countingPlainBullets, PlainBulletList.items(of: text[paragraph]) != nil { return true }
            for piece in LineScanner.pieces(String(text[paragraph])) {
                if !MarkupSkeleton.inlineCodeSpans(in: piece.content).isEmpty { return true }
                if hasPairedEmphasis(piece.content) { return true }
            }
        }
        return false
    }

    /// A run of `*` that can open, followed later on the same line by one that can close, with
    /// something between them. Deliberately not a parser: it answers «is there anything here
    /// worth rendering», and the renderer's own inline parse is Foundation's.
    static func hasPairedEmphasis(_ line: String) -> Bool {
        let characters = Array(line)
        var index = 0
        var sawOpener = false
        while index < characters.count {
            guard characters[index] == "*" else { index += 1; continue }
            var end = index
            while end < characters.count, characters[end] == "*" { end += 1 }
            let before = index > 0 ? characters[index - 1] : nil
            let after = end < characters.count ? characters[end] : nil
            let canOpen = after.map { !$0.isWhitespace } ?? false
            let canClose = before.map { !$0.isWhitespace } ?? false
            if sawOpener && canClose { return true }
            if canOpen { sawOpener = true }
            index = end
        }
        return false
    }
}
