// Sources/MarkupKit/MarkdownInline.swift
import Foundation
import TranslationCore

/// Putting inline markers around text without fabricating markers nobody can read back.
///
/// Shared by both capture converters (`HTMLToMarkdown`, `AttributedToMarkdown`) because both
/// face the same question from opposite directions — a `<strong>` element and a bold run are the
/// same problem once the text is in hand — and because the refusals below are the interesting
/// part: **a conversion that emits a marker the Markdown parsers do not pair is worse than one
/// that loses the emphasis.** The design's §2 series B measured what these models do with stray
/// or redistributed markers (bold degraded to italic 5/5 on translategemma:12b; emphasis
/// fabricated 2/3 on aya-expanse:32b), and a marker this code invents rides into every chunk's
/// prompt exactly the same way.
///
/// The four refusals, each for a reason a probe or the parsers themselves settle:
///
/// - **Empty or whitespace-only content.** `<b> </b>` is common in exported HTML; `** **` is not
///   emphasis in any parser and `****` is literal asterisks.
/// - **Whitespace against the markers.** CommonMark's flanking rules mean `**bold **` does not
///   close, so the spaces are moved *outside* the pair rather than dropped: the characters the
///   user selected are all still there, in the same order.
/// - **A line break inside the content.** `*` emphasis does not span a hard break in
///   `AttributedString`'s inline parse — the markers would survive as literal asterisks.
/// - **The marker's own character inside the content.** A backtick inside a `` ` `` span, or an
///   asterisk inside an emphasis, closes it early.
enum MarkdownInline {
    static func wrapped(_ content: String, in marker: String) -> String {
        guard !marker.isEmpty else { return content }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else {
            return content
        }
        // The marker's own first character: `*` for both emphasis markers, `` ` `` for code.
        // Checked on the character rather than on the whole marker so `**` refuses a single
        // stray `*` too, which is the case that turns a bold run into two literal asterisks
        // plus an italic one somewhere later in the line.
        if let sign = marker.first, trimmed.contains(sign) { return content }
        let leading = String(content.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(content.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        return leading + marker + trimmed + marker + trailing
    }

    /// `[text](href)`, or the text alone.
    ///
    /// **URL targets only**, the same question `MarkupSkeleton.targetIsURL` asks of a Markdown
    /// link's target and answered by the same function, so the two layers cannot come to
    /// disagree about what a URL is. That filter is what keeps Word's internal anchors
    /// (`href="#_Toc42"`) and a mail client's `cid:` attachments out of the translation: they are
    /// links in a document that no longer exists once the text is Markdown, and a `[текст](#_Toc42)`
    /// riding into the prompt is a marker with nothing behind it.
    ///
    /// The text alone, also, when it already *is* the href — an autolinked address, the shape
    /// most rich clients write — because `[https://x.org](https://x.org)` says nothing twice and
    /// `MarkupSkeleton` reads the bare form as a URL either way.
    static func link(text: String, href: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.isEmpty, !trimmed.isEmpty,
              MarkupSkeleton.targetIsURL(href),
              trimmed != href,
              // A `]` or a `)` in the text, or a `)` or whitespace in the target, is a link
              // Markdown cannot spell without an escaping pass this converter does not have.
              !trimmed.contains("]"), !trimmed.contains("\n"),
              !href.contains(")"), !href.contains(" ")
        else { return text }
        let leading = String(text.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        return leading + "[" + trimmed + "](" + href + ")" + trailing
    }
}
