// Sources/MarkupKit/RichMarkdown.swift
import Foundation
import TranslationCore

/// The one place a captured selection's rich flavours are turned into the text that gets
/// translated — and the one place that decides whether they are used at all.
///
/// Two decisions, both here so neither can be restated somewhere else:
///
/// **HTML before RTF.** Semantics over visuals: `<h2>` says «heading, level two» where RTF says
/// «18 pt bold». `AttributedToMarkdown`'s own doc comment lists what it has to guess for want of
/// that. The RTF flavour is read only when there is no HTML flavour, or when the HTML flavour's
/// conversion is refused by the gate below.
///
/// **The improvement-or-no-op gate.** A conversion is accepted only if
/// `MarkupSkeleton.tokens(of:)` finds at least one *block* token in it — a heading, a list item,
/// a blockquote, a code block, a table row — that the plain flavour's own scan does not have. Any
/// other outcome uses the plain flavour, unchanged, exactly as before this existed.
///
/// The asymmetry is deliberate and measured. **A conversion that fabricates markup is worse than
/// one that loses it**: every marker in the accepted text rides into every chunk's prompt, and the
/// design's §2 series B measured what these models do with markers they were not given cleanly —
/// bold degraded to italic in 5 of 5 runs on translategemma:12b, emphasis invented in 2 of 3 on
/// aya-expanse:32b. Losing a heading costs a rendering; inventing one costs a translation.
///
/// Two consequences of counting only *block* tokens, both intended:
///
/// - A conversion whose only gain is inline (`**`, `` ` ``, a link) is **refused**. Emphasis is
///   the form these models are measurably worst with, and a bold run recovered from a font weight
///   is the guess most likely to be wrong.
/// - A plain flavour that already carries the structure — a bulleted list whose plain text is
///   still `- раз`, a Markdown document copied out of an editor — is **kept**, because the
///   conversion adds no block form it lacks. That is the no-op half of the name.
public enum RichMarkdown {
    /// The text to translate, or nil to translate the plain flavour.
    ///
    /// Nil is the answer in every uninteresting case — no flavours, a flavour that would not
    /// decode, a conversion the gate refused — and the caller's response to all of them is the
    /// same: use `plain`. That is why they are one nil rather than an error type.
    public static func markdown(html: Data?, rtf: Data?, improvingOn plain: String) -> String? {
        if let html, let converted = HTMLToMarkdown.markdown(from: html),
           isImprovement(converted, over: plain) {
            return converted
        }
        if let rtf, let converted = AttributedToMarkdown.markdown(fromRTF: rtf),
           isImprovement(converted, over: plain) {
            return converted
        }
        return nil
    }

    /// The gate itself. One function, so «улучшение или ничего» is a single readable rule.
    static func isImprovement(_ converted: String, over plain: String) -> Bool {
        guard !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let gained = blockCounts(of: converted)
        let had = blockCounts(of: plain)
        return gained.contains { kind, count in count > (had[kind] ?? 0) }
    }

    /// The block forms the gate counts, with their payloads dropped.
    ///
    /// Payloads go because the question is «is there a block form here that the plain flavour
    /// lacks», and a heading's level, a list item's depth and a code block's content hash are
    /// properties of the *text* rather than of the form. Keeping them would make an h2 recovered
    /// from an h1's plain text read as a gain, and — worse — would make every code block a gain
    /// automatically, since the fence's content hash cannot match a plain flavour that has no
    /// fence at all.
    ///
    /// `.inlineCode`, `.url`, `.paragraphBreak` and `.hardLineBreak` are deliberately not here:
    /// see the type's doc comment for why inline gains do not open this gate.
    enum BlockKind: Hashable { case heading, listItem, blockquote, codeBlock, tableRow }

    static func blockCounts(of text: String) -> [BlockKind: Int] {
        var counts: [BlockKind: Int] = [:]
        for token in MarkupSkeleton.tokens(of: text) {
            // Exhaustive with no `default:`, so a new `MarkupToken` — the design's §9 adds
            // `.emphasis` and `.tableCells` — has to be classified here rather than silently
            // counting as nothing.
            switch token {
            case .heading: counts[.heading, default: 0] += 1
            case .listItem: counts[.listItem, default: 0] += 1
            case .blockquote: counts[.blockquote, default: 0] += 1
            case .codeBlock: counts[.codeBlock, default: 0] += 1
            case .tableRow: counts[.tableRow, default: 0] += 1
            // `.emphasis` is inline — exactly what this gate exists to refuse as a gain.
            // `.tableCells` always travels beside the `.tableRow` counted above; counting
            // the pair would double one signal without changing any decision.
            case .inlineCode, .url, .paragraphBreak, .hardLineBreak, .emphasis, .tableCells:
                break
            }
        }
        return counts
    }
}
