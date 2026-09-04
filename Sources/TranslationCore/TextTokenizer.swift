// Sources/TranslationCore/TextTokenizer.swift
import Foundation

/// One token of a text: a word, or a single mark standing on its own.
///
/// `range` is into the string it was cut from — the whole reason the type exists rather than a
/// bare `[String]`. The diff needs the *bytes between two tokens* to quote a change back
/// («, пожалуйста,» and not «,пожалуйста,»), and the mark locator in `MarkupKit` needs to turn
/// a token index into a range in a text storage. A token that only carried its characters
/// could do neither.
public struct TextToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A maximal run of letters, digits and combining marks, with a single apostrophe or
        /// hyphen allowed inside it.
        case word
        /// Any other non-whitespace character, one token per character.
        case mark
    }

    public let kind: Kind
    public let text: String
    public let range: Range<String.Index>

    public init(kind: Kind, text: String, range: Range<String.Index>) {
        self.kind = kind
        self.text = text
        self.range = range
    }
}

/// The one tokenizer this project diffs and locates changes with.
///
/// The rules are chosen so that the count a user is shown says what they would say themselves,
/// and each of them is a decision rather than an accident:
///
/// - **A word is a maximal run of `alphanumerics ∪ nonBaseCharacters`.** The second set is
///   there for decomposed text: «й» written as и + U+0306 is one word, not a word and a mark.
/// - **A single `'`, `’` or `-` between two word characters joins them**, so «кто-нибудь» and
///   «don’t» are one token each. Only a single one: «кто--нибудь» is a word, two marks and a
///   word, because a run of dashes is punctuation and not spelling.
/// - **Every other non-whitespace character is its own token.** A comma inserted by правка is
///   a change; a comma is not part of the word before it.
/// - **Whitespace is a boundary and never a token.** This is what makes a collapsed double
///   space, a rewrapped line and a paragraph re-indented by the model *not* a change — the
///   model reflows whitespace constantly and a diff that counted it would report a correction
///   on every run.
/// - **Case-sensitive, and «е»/«ё» differ.** Both are corrections this app's users ask for by
///   name; folding either would make правка's most common single edit invisible.
public enum TextTokenizer {
    /// The three characters that may sit inside a word. `’` (U+2019) as well as `'` because
    /// every macOS text substitution produces the first and every keyboard the second, and a
    /// diff that called «don't» and «don’t» different words would fire on the keyboard rather
    /// than on the text.
    public static let joiners: Set<Character> = ["'", "\u{2019}", "-"]

    public static func tokens(of text: String) -> [TextToken] {
        var tokens: [TextToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isWhitespace(character) {
                index = text.index(after: index)
                continue
            }
            guard isWordCharacter(character) else {
                let end = text.index(after: index)
                tokens.append(TextToken(kind: .mark, text: String(text[index..<end]),
                                        range: index..<end))
                index = end
                continue
            }
            var end = text.index(after: index)
            while end < text.endIndex {
                let candidate = text[end]
                if isWordCharacter(candidate) {
                    end = text.index(after: end)
                    continue
                }
                // Reached only from inside a word run, so «the character before the joiner is
                // a word character» holds by construction and only the one after it has to be
                // looked at.
                if joiners.contains(candidate) {
                    let after = text.index(after: end)
                    if after < text.endIndex, isWordCharacter(text[after]) {
                        end = text.index(after: after)
                        continue
                    }
                }
                break
            }
            tokens.append(TextToken(kind: .word, text: String(text[index..<end]),
                                    range: index..<end))
            index = end
        }
        return tokens
    }

    /// Decided over the character's scalars rather than its first one: «é» decomposed is a
    /// letter and a combining mark and is a word character, while an emoji whose scalars are
    /// neither is not — and reading only the first scalar would call a flag a word.
    static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { wordScalars.contains($0) }
    }

    static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static let wordScalars = CharacterSet.alphanumerics.union(.nonBaseCharacters)
}
