// Sources/MarkupKit/HTMLToMarkdown.swift
import Foundation
import TranslationCore

/// The `public.html` flavour of a capture, turned into Markdown by reading its tags.
///
/// **A converter, not a browser.** No CSS, no scripting, no DOM, one linear pass, a closed list
/// of tags. Everything outside that list contributes its *text* and nothing else, which is the
/// property that makes exported HTML survivable: Word's flavour is mostly `mso-*` attributes,
/// `<span class=SpellE>` and conditional comments, and none of it can change the structure this
/// produces because none of it is on the list.
///
/// ### Why this exists rather than AppKit's own HTML import
///
/// Measured (design §10, `Scripts/markup-render.swift`): `NSAttributedString(data:, .html)`
/// keeps only *visuals* — `<h2>` arrives as 18 pt bold Times with the heading level gone,
/// `<code>` as Courier, `<ul>` as `textLists` plus literal `"\t•\t"` characters — and costs
/// 216–262 ms cold / ~60 ms warm on a path whose whole budget is «the panel answers in under a
/// second». Semantics still exist in the HTML; importing throws them away and charges for it.
/// So the tags are read directly. This is `docs/adr/0007`'s fifth hand-written dependency, and
/// the same trade that ADR records for the other four: a small parser this project understands
/// against a framework that answers a different question.
///
/// `AttributedToMarkdown` is the sibling for the `public.rtf` flavour, where visuals genuinely
/// are all there is. HTML is preferred wherever both are on the board — semantics over visuals.
///
/// ### The tag list, in full
///
/// `h1`…`h6`, `p`, `div`, `br`, `strong`, `b`, `em`, `i`, `code`, `pre`, `ul`, `ol`, `li`,
/// `blockquote`, `table`, `tr`, `th`, `td`, `a` (its `href` and nothing else), plus
/// `style`, `script`, `head` and `title`, whose **content is dropped**.
///
/// Two of those are additions to the design's list, both stated rather than slipped in:
///
/// - **`div`** — a browser's or an editor's selection is div-structured, and treating a div as
///   inline glues consecutive blocks into one paragraph. It can only ever *add* a paragraph
///   boundary where the source drew a visual one, and a paragraph is not one of the block tokens
///   the acceptance gate counts (`RichMarkdown`), so this cannot buy a conversion its acceptance.
/// - **`head`/`title` content** — a pasteboard HTML flavour is routinely a whole document rather
///   than a fragment, and a `<title>` is not part of what the user selected. `style` and `script`
///   are the design's own; `head` subsumes them wherever the export is well-formed and does no
///   harm where it is not.
///
/// **Attributes are ignored except `href`.** Not «mostly ignored»: the tokenizer keeps one and
/// discards the rest, so no styling attribute anywhere can influence the output.
///
/// ### What it does not do, on purpose
///
/// - No `hr`, no `img`, no `hN` inside a cell — an `hr` has no text and no `MarkupToken`, an
///   `img`'s alt text is not the user's prose.
/// - **Nested tables come out flattened**, the inner table's rows landing as their own rows
///   after the outer one's. Word writes them; handling them properly is a cell-spanning model
///   this converter has no use for. It garbles the order of a nested table and fabricates
///   nothing.
/// - A mismatched closing tag (`<b>…</i>`) is dropped rather than guessed at, so a malformed
///   document loses an emphasis instead of gaining a marker.
public enum HTMLToMarkdown {
    /// The flavour as the application wrote it. **UTF-8 or nothing**, exactly the rule
    /// `DroppedDocument` already applies to a dropped file, and for a stronger reason here: a
    /// mis-guessed encoding does not fail, it succeeds with mojibake, and mojibake carrying a
    /// heading passes the acceptance gate and reaches the model as the user's text. A `nil` costs
    /// the capture its markup and nothing else — the plain flavour is what gets translated.
    public static func markdown(from data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        return markdown(html: html)
    }

    /// The same conversion from a string, which is what the tests read.
    public static func markdown(html: String) -> String {
        var writer = Writer()
        for token in tokens(of: html) { writer.take(token) }
        return writer.finish()
    }

    // MARK: - Tokens

    enum Token: Equatable {
        /// Entity-decoded. Whitespace is *not* collapsed here — `pre` needs it verbatim, and
        /// only the writer knows whether it is inside one.
        case text(String)
        case open(String, href: String?)
        case close(String)
    }

    /// Void elements: `<br>` has no content and no closing tag, and treating one as an open
    /// element would leave the writer's span stack unbalanced for the rest of the document.
    static let voidTags: Set<String> = [
        "br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source",
        "track", "wbr", "param",
    ]

    static func tokens(of html: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var cursor = html.startIndex

        func flushText() {
            guard !text.isEmpty else { return }
            tokens.append(.text(decodeEntities(text)))
            text = ""
        }

        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                text.append(html[cursor])
                cursor = html.index(after: cursor)
                continue
            }
            let rest = html[cursor...]
            if rest.hasPrefix("<!--") {
                // Conditional comments (`<!--[if gte mso 9]>`) are comments and go the same way
                // as any other. Word's flavour is full of them.
                cursor = rest.range(of: "-->").map(\.upperBound) ?? html.endIndex
                continue
            }
            if rest.hasPrefix("<!") || rest.hasPrefix("<?") {
                cursor = rest.firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                continue
            }
            guard let tag = tag(in: html, from: cursor) else {
                // A bare `<` that opens no tag — «a < b» in prose. Literal text.
                text.append(html[cursor])
                cursor = html.index(after: cursor)
                continue
            }
            flushText()
            if tag.closing {
                tokens.append(.close(tag.name))
            } else {
                tokens.append(.open(tag.name, href: tag.href))
                // `<div/>` — legal XHTML, and its content is nothing, so it must close itself.
                if tag.selfClosing, !voidTags.contains(tag.name) {
                    tokens.append(.close(tag.name))
                }
            }
            cursor = tag.end
        }
        flushText()
        return tokens
    }

    struct Tag {
        let name: String
        let closing: Bool
        let selfClosing: Bool
        let href: String?
        let end: String.Index
    }

    /// One tag, from its `<` to just past its `>`.
    ///
    /// Quotes are honoured while looking for the `>`, because an attribute value may contain one
    /// — `<td style="width:1px; content:'>'">` is not two tags — and Word's inline styles are
    /// exactly where that turns up.
    static func tag(in html: String, from start: String.Index) -> Tag? {
        var cursor = html.index(after: start)
        guard cursor < html.endIndex else { return nil }
        var closing = false
        if html[cursor] == "/" {
            closing = true
            cursor = html.index(after: cursor)
        }
        guard cursor < html.endIndex, html[cursor].isLetter else { return nil }
        var body = ""
        var quote: Character?
        while cursor < html.endIndex {
            let character = html[cursor]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                break
            }
            body.append(character)
            cursor = html.index(after: cursor)
        }
        guard cursor < html.endIndex else { return nil }
        let end = html.index(after: cursor)
        var selfClosing = false
        if body.hasSuffix("/") {
            selfClosing = true
            body.removeLast()
        }
        let name = String(body.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
        guard !name.isEmpty else { return nil }
        let href = (name == "a" && !closing)
            ? attribute("href", in: body.dropFirst(name.count)) : nil
        return Tag(name: name, closing: closing, selfClosing: selfClosing, href: href, end: end)
    }

    /// One named attribute's value, quoted or bare. The only attribute anything here asks for.
    static func attribute(_ wanted: String, in body: Substring) -> String? {
        var cursor = body.startIndex
        while cursor < body.endIndex {
            // Termination is guaranteed at the bottom of the loop rather than argued about at
            // every branch: attribute syntax in the wild includes shapes this parser has no case
            // for, and a scanner over someone else's markup must not be able to stand still.
            let before = cursor
            while cursor < body.endIndex, body[cursor].isWhitespace {
                cursor = body.index(after: cursor)
            }
            var name = ""
            while cursor < body.endIndex, body[cursor] != "=", !body[cursor].isWhitespace {
                name.append(body[cursor])
                cursor = body.index(after: cursor)
            }
            var value: String?
            if cursor < body.endIndex, body[cursor] == "=" {
                cursor = body.index(after: cursor)
                if cursor < body.endIndex, body[cursor] == "\"" || body[cursor] == "'" {
                    let quote = body[cursor]
                    cursor = body.index(after: cursor)
                    var collected = ""
                    while cursor < body.endIndex, body[cursor] != quote {
                        collected.append(body[cursor])
                        cursor = body.index(after: cursor)
                    }
                    if cursor < body.endIndex { cursor = body.index(after: cursor) }
                    value = collected
                } else {
                    var collected = ""
                    while cursor < body.endIndex, !body[cursor].isWhitespace {
                        collected.append(body[cursor])
                        cursor = body.index(after: cursor)
                    }
                    value = collected
                }
            }
            if name.lowercased() == wanted, let value { return decodeEntities(value) }
            if cursor == before, cursor < body.endIndex { cursor = body.index(after: cursor) }
        }
        return nil
    }

    // MARK: - Entities

    /// The six named entities the design lists, plus every numeric one.
    ///
    /// A closed list and not a table of all 2231 HTML names: these are what real exports write,
    /// and an unrecognised `&…;` is left exactly as it stands rather than guessed at — the user's
    /// characters, unchanged, which is the same rule the unknown-tag case follows.
    ///
    /// `&nbsp;` decodes to U+00A0 and stays U+00A0: it is the character the document has, and the
    /// writer's whitespace collapsing deliberately does not touch it — collapsing it would edit
    /// «10 км» into a form the user did not write. A paragraph consisting of nothing *but*
    /// non-breaking spaces is still dropped, because `CharacterSet.whitespacesAndNewlines`
    /// contains U+00A0 and the writer trims blocks with it; Word writes such paragraphs for
    /// vertical spacing.
    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&" else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            // A reference is short; a `&` with no `;` nearby is an ampersand in prose.
            let horizon = text.index(cursor, offsetBy: 12, limitedBy: text.endIndex)
                ?? text.endIndex
            guard let semicolon = text[cursor..<horizon].firstIndex(of: ";") else {
                result.append("&")
                cursor = text.index(after: cursor)
                continue
            }
            let body = String(text[text.index(after: cursor)..<semicolon])
            if let decoded = decodeReference(body) {
                result.append(decoded)
                cursor = text.index(after: semicolon)
            } else {
                result.append("&")
                cursor = text.index(after: cursor)
            }
        }
        return result
    }

    static func decodeReference(_ body: String) -> String? {
        if let named = namedEntities[body.lowercased()] { return named }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let scalar: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            scalar = UInt32(digits.dropFirst(), radix: 16)
        } else {
            scalar = UInt32(digits, radix: 10)
        }
        guard let scalar, let unicode = Unicode.Scalar(scalar) else { return nil }
        return String(Character(unicode))
    }

    // MARK: - The writer

    /// Turns the token stream into Markdown blocks.
    ///
    /// One buffer (`pending`) holds the current block's inline text; a block is finished when a
    /// block-level tag opens or closes. Inline markers are applied on *closing* a span, over the
    /// text collected since it opened, so `MarkdownInline`'s refusals — whitespace against a
    /// marker, a line break inside it, the marker's own character — can be applied to the real
    /// content rather than guessed at when the span opens.
    struct Writer {
        /// The separator rule between two finished blocks is `MarkdownOutputBlock`'s, shared
        /// with the other converters here rather than restated: it was restated once and the
        /// restatement was wrong.
        private typealias Run = MarkdownOutputBlock.Run
        private typealias Block = MarkdownOutputBlock
        private struct Span { let marker: String; let href: String?; let offset: Int }
        private struct TableContext {
            var row: [String] = []
            var inRow = false
            var rowHasHeaderCell = false
            var wroteDelimiter = false
        }

        private var blocks: [Block] = []
        private var pending = ""
        private var pendingPrefix: String?
        private var pendingRun: Run = .other
        private var spans: [Span] = []
        private var lists: [(ordered: Bool, index: Int)] = []
        private var quoteDepth = 0
        /// Depth inside an element whose *content* is dropped, counted so a nested one of the
        /// same kind cannot end the drop early.
        private var skipDepth = 0
        private var preDepth = 0
        private var pre = ""
        private var tables: [TableContext] = []
        private var cellDepth = 0

        private var quoteMarkers: String { String(repeating: "> ", count: quoteDepth) }

        mutating func take(_ token: Token) {
            switch token {
            case let .text(text):
                guard skipDepth == 0 else { return }
                if preDepth > 0 { pre += text } else { append(text) }
            case let .open(name, href):
                open(name, href: href)
            case let .close(name):
                close(name)
            }
        }

        mutating func finish() -> String {
            if preDepth > 0 {
                // An unterminated `<pre>` — the same shape as a stream's half-arrived fence, and
                // the same answer: what arrived is code.
                preDepth = 0
                emitFence()
            }
            endRow()
            flush()
            return blocks.joinedAsMarkdown()
        }

        // MARK: Tags

        private mutating func open(_ name: String, href: String?) {
            if skipDepth > 0 {
                if Self.droppedContent.contains(name) { skipDepth += 1 }
                return
            }
            if preDepth > 0 {
                if name == "pre" { preDepth += 1 }
                // Inside a fence the only thing a tag can contribute is a line break.
                else if name == "br" || name == "p" || name == "div" || name == "tr" {
                    pre += "\n"
                }
                return
            }
            if Self.droppedContent.contains(name) { skipDepth = 1; return }
            switch name {
            case "pre":
                flush()
                preDepth = 1
                pre = ""
            case "br":
                // A hard break, in Markdown's own spelling. Inside a table cell it becomes a
                // space instead: a pipe row is one line by construction.
                if cellDepth > 0 { append(" ") } else { pending += "  \n" }
            case "p", "div":
                flush()
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                let level = Int(name.dropFirst()) ?? 1
                pendingPrefix = quoteMarkers + String(repeating: "#", count: level) + " "
            case "ul", "ol":
                flush()
                lists.append((ordered: name == "ol", index: 1))
            case "li":
                flush()
                let depth = max(0, lists.count - 1)
                var marker = "- "
                if let last = lists.last, last.ordered {
                    marker = "\(last.index). "
                    lists[lists.count - 1].index += 1
                }
                pendingPrefix = quoteMarkers + String(repeating: "  ", count: depth) + marker
                pendingRun = .listItem
            case "blockquote":
                flush()
                quoteDepth += 1
            case "table":
                closeCell()
                endRow()
                flush()
                tables.append(TableContext())
            case "tr":
                closeCell()
                endRow()
                flush()
                if tables.isEmpty { tables.append(TableContext()) }
                tables[tables.count - 1].row = []
                tables[tables.count - 1].inRow = true
                tables[tables.count - 1].rowHasHeaderCell = false
            case "th", "td":
                guard !tables.isEmpty else { flush(); return }
                if name == "th" { tables[tables.count - 1].rowHasHeaderCell = true }
                // Whitespace between `</td>` and `<td>` is not part of either cell.
                pending = ""
                spans = []
                cellDepth = 1
            case "strong", "b":
                push("**")
            case "em", "i":
                push("*")
            case "code":
                push("`")
            case "a":
                spans.append(Span(marker: "", href: href, offset: pending.count))
            default:
                // Unknown: its text arrives as text and its tags mean nothing. `<span
                // style='mso-bidi-font-weight:normal'>` lands here, which is the whole reason
                // the list is closed.
                break
            }
        }

        private mutating func close(_ name: String) {
            if skipDepth > 0 {
                if Self.droppedContent.contains(name) { skipDepth -= 1 }
                return
            }
            if preDepth > 0 {
                if name == "pre" {
                    preDepth -= 1
                    if preDepth == 0 { emitFence() }
                }
                return
            }
            switch name {
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li":
                flush()
            case "ul", "ol":
                flush()
                if !lists.isEmpty { lists.removeLast() }
            case "blockquote":
                flush()
                quoteDepth = max(0, quoteDepth - 1)
            case "th", "td":
                closeCell()
            case "tr":
                endRow()
            case "table":
                closeCell()
                endRow()
                flush()
                if !tables.isEmpty { tables.removeLast() }
            case "strong", "b":
                pop("**")
            case "em", "i":
                pop("*")
            case "code":
                pop("`")
            case "a":
                popLink()
            default:
                break
            }
        }

        /// `style`, `script`, `head`, `title` — see the type's doc comment for why `head` and
        /// `title` are here beside the design's two.
        private static let droppedContent: Set<String> = ["style", "script", "head", "title"]

        // MARK: Inline spans

        private mutating func push(_ marker: String) {
            // Emphasis already open with the same marker: the nested one contributes nothing.
            // `<b>a<b>c</b></b>` is what Word writes around a partially re-styled run, and
            // wrapping twice yields `**a**c****` — literal asterisks in the translation.
            let marker = spans.contains { $0.marker == marker } ? "" : marker
            spans.append(Span(marker: marker, href: nil, offset: pending.count))
        }

        private mutating func pop(_ marker: String) {
            // Only a matching top is popped: a crossed pair (`<b>…</i>`) drops its emphasis
            // rather than rewriting text it cannot describe.
            guard let span = spans.last, span.href == nil,
                  span.marker == marker || span.marker.isEmpty else { return }
            spans.removeLast()
            rewriteTail(from: span.offset) { MarkdownInline.wrapped($0, in: span.marker) }
        }

        private mutating func popLink() {
            guard let span = spans.last, span.marker.isEmpty, span.href != nil else { return }
            spans.removeLast()
            rewriteTail(from: span.offset) { MarkdownInline.link(text: $0, href: span.href) }
        }

        /// Replaces everything appended since `offset` with `transform`'s answer.
        ///
        /// Offsets rather than `String.Index`es because `pending` is appended to between a span
        /// opening and closing, and an index taken before an append is not guaranteed to survive
        /// it.
        private mutating func rewriteTail(from offset: Int,
                                          _ transform: (String) -> String) {
            guard offset <= pending.count else { return }
            let start = pending.index(pending.startIndex, offsetBy: offset)
            let content = String(pending[start...])
            pending = String(pending[..<start]) + transform(content)
        }

        // MARK: Text

        /// HTML's own whitespace rule: a run of spaces, tabs and line breaks is one space, and a
        /// leading one at the start of a block is nothing. U+00A0 is not in that set — see
        /// `namedEntities`.
        private mutating func append(_ text: String) {
            for character in text {
                if character == " " || character == "\t" || character == "\n"
                    || character == "\r" {
                    guard !pending.isEmpty, !pending.hasSuffix(" "), !pending.hasSuffix("\n")
                    else { continue }
                    pending.append(" ")
                } else {
                    pending.append(character)
                }
            }
        }

        // MARK: Blocks

        private mutating func flush() {
            // Inside a table cell a `<p>` boundary is a separator, not a block: the text belongs
            // to the cell. Word writes every cell as `<td><p class=MsoNormal>…</p></td>`, so
            // treating this as a block flush discarded every cell's content.
            if cellDepth > 0 {
                if !pending.isEmpty, !pending.hasSuffix(" ") { pending.append(" ") }
                return
            }
            let body = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = ""
            spans = []
            // **Nothing to say leaves the block open**, prefix and all. `<li><p>текст</p></li>`
            // is how exported HTML writes a list item, and clearing the prefix on the empty
            // flush at `<p>` cost every such item its bullet — the text came out as a paragraph.
            guard !body.isEmpty else { return }
            let prefix = pendingPrefix ?? quoteMarkers
            let run = pendingRun
            pendingPrefix = nil
            pendingRun = .other
            blocks.append(Block(text: prefix + continuationPrefixed(body), run: run))
        }

        /// A hard break inside a quote has to carry the quote markers onto the next line, or the
        /// scanner reads the continuation as a paragraph and the quote ends mid-sentence.
        private func continuationPrefixed(_ body: String) -> String {
            guard quoteDepth > 0, body.contains("\n") else { return body }
            return body.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + quoteMarkers)
        }

        private mutating func emitFence() {
            let code = pre.trimmingCharacters(in: .newlines)
            pre = ""
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Always exactly three backticks, and a longer fence would not help: this pipeline's
            // fence rule is a *prefix* one — `LineScanner.isFenceMarker` reads any line beginning
            // with ``` as a marker, indented or not — so a ```` fence would still be closed by
            // the first inner ``` line. A `<pre>` whose own content contains a fence line
            // therefore comes out as more than one block. That is a property of the shared line
            // discipline every layer here follows, not something a converter can spell around,
            // and the alternative — editing the user's code so it fences cleanly — is worse.
            blocks.append(Block(text: "```\n" + code + "\n```", run: .other))
        }

        // MARK: Tables

        private mutating func closeCell() {
            guard cellDepth > 0, !tables.isEmpty else { return }
            cellDepth = 0
            // One line, always: a newline or a bare `|` inside a cell would end the row early.
            let cell = pending
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
                .trimmingCharacters(in: .whitespaces)
            pending = ""
            spans = []
            tables[tables.count - 1].row.append(cell)
        }

        private mutating func endRow() {
            guard !tables.isEmpty, tables[tables.count - 1].inRow else { return }
            closeCell()
            let context = tables[tables.count - 1]
            tables[tables.count - 1].inRow = false
            tables[tables.count - 1].row = []
            guard !context.row.isEmpty else { return }
            blocks.append(Block(text: "| " + context.row.joined(separator: " | ") + " |",
                                run: .tableRow))
            // The delimiter row comes from `<th>` and from nothing else. HTML says which cells
            // are headers, so unlike RTF there is nothing to guess — and a table whose first row
            // is data gets no delimiter, exactly as `MarkdownBlockScanner` requires («inventing
            // one would render the first row of data in semibold»).
            guard context.rowHasHeaderCell, !context.wroteDelimiter else { return }
            tables[tables.count - 1].wroteDelimiter = true
            blocks.append(Block(text: "| " + context.row.map { _ in "---" }
                .joined(separator: " | ") + " |", run: .tableRow))
        }
    }
}
