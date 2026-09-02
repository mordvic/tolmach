import Testing
import Foundation
@testable import MarkupKit

// The highlighter is a lexer with a per-language profile, not a parser: it finds comments,
// strings, numbers, keywords and keys, and colours nothing else. Every expected token below is
// a hand-written (text, kind) pair — what a reader would want coloured — never something
// computed the way the lexer computes it.

/// A token as a reader sees it: the characters and the kind. `Equatable` so whole lists compare.
private struct Found: Equatable, CustomStringConvertible {
    let text: String
    let kind: SyntaxHighlighter.Kind
    init(_ text: String, _ kind: SyntaxHighlighter.Kind) { self.text = text; self.kind = kind }
    var description: String { "\(text.debugDescription)→\(kind)" }
}

private func tokens(_ code: String, _ language: String?) -> [Found] {
    SyntaxHighlighter.tokens(in: code, language: language).map {
        Found((code as NSString).substring(with: $0.range), $0.kind)
    }
}

@Test func swiftKeywordsStringsCommentsAndNumbersAreFound() {
    let code = "let x = 42 // answer\nfunc f() -> String { return \"a \\\"b\\\" c\" }"
    #expect(tokens(code, "swift") == [
        Found("let", .keyword), Found("42", .number), Found("// answer", .comment),
        Found("func", .keyword), Found("String", .type), Found("return", .keyword), Found("\"a \\\"b\\\" c\"", .string),
    ])
}

/// A `//` inside a string is characters, not a comment; a `"` inside a comment is not a string.
@Test func delimitersInsideOtherTokensDoNotOpenNewOnes() {
    #expect(tokens("let u = \"http://x\" // \"quoted\"", "swift") == [
        Found("let", .keyword), Found("\"http://x\"", .string), Found("// \"quoted\"", .comment),
    ])
}

@Test func blockCommentsSpanLines() {
    #expect(tokens("a /* one\ntwo */ b", "javascript") == [Found("/* one\ntwo */", .comment)])
}

@Test func pythonUsesHashCommentsAndTripleQuotedStrings() {
    let code = "def f():\n    \"\"\"doc\n    string\"\"\"\n    return 1  # done"
    #expect(tokens(code, "python") == [
        Found("def", .keyword), Found("\"\"\"doc\n    string\"\"\"", .string), Found("return", .keyword),
        Found("1", .number), Found("# done", .comment),
    ])
}

/// `$#` and `${#x}` are shell syntax, not comments; a `#` after whitespace or at a line start is.
@Test func shellCommentsNeedAWordBoundaryAndKeywordsAreTheShellsOwn() {
    let code = "# build\nif [ $# -gt 0 ]; then\n  echo \"hi\"\nfi"
    #expect(tokens(code, "bash") == [
        Found("# build", .comment), Found("if", .keyword), Found("0", .number), Found("then", .keyword),
        Found("echo", .keyword), Found("\"hi\"", .string), Found("fi", .keyword),
    ])
}

@Test func jsonKeysAreKeysAndValuesAreStringsOrNumbersOrKeywords() {
    #expect(tokens("{\"name\": \"x\", \"n\": 12, \"ok\": true, \"none\": null}", "json") == [
        Found("\"name\"", .key), Found("\"x\"", .string), Found("\"n\"", .key), Found("12", .number),
        Found("\"ok\"", .key), Found("true", .keyword), Found("\"none\"", .key), Found("null", .keyword),
    ])
}

@Test func yamlKeysAreKeysAndCommentsAreHashes() {
    #expect(tokens("name: Толмач # app\nports:\n  - 11434\n", "yaml") == [
        Found("name", .key), Found("# app", .comment), Found("ports", .key), Found("11434", .number),
    ])
}

@Test func sqlKeywordsAreCaseInsensitiveAndUseDashDashComments() {
    #expect(tokens("select id from users where n > 10 -- top\nSELECT 1", "sql") == [
        Found("select", .keyword), Found("from", .keyword), Found("where", .keyword), Found("10", .number),
        Found("-- top", .comment), Found("SELECT", .keyword), Found("1", .number),
    ])
}

@Test func htmlTagNamesAreKeywordsAttributeValuesStringsAndCommentsComments() {
    #expect(tokens("<!-- c --><a href=\"x\">t</a>", "html") == [
        Found("<!-- c -->", .comment), Found("a", .keyword), Found("\"x\"", .string), Found("a", .keyword),
    ])
}

/// Identifiers that merely contain a keyword are identifiers: `letter` is not `let`.
@Test func keywordsMatchWholeWordsOnly() {
    #expect(tokens("letter = 1", "swift") == [Found("1", .number)])
    #expect(tokens("x.return_value", "python") == [])
}

@Test func numbersIncludeHexFloatsAndUnderscores() {
    #expect(tokens("0xFF 1_000 3.14 2e10 v2", "swift").map(\.text) == ["0xFF", "1_000", "3.14", "2e10"])
}

/// No language, or one this lexer has no profile for, colours nothing — a guess about comment
/// syntax is how a URL turns green.
@Test func anUnknownOrAbsentLanguageYieldsNoTokens() {
    #expect(tokens("let x = 1 // c", nil).isEmpty)
    #expect(tokens("let x = 1 // c", "brainfuck").isEmpty)
}

@Test func fenceAliasesResolveToOneProfile() {
    for alias in ["sh", "zsh", "shell", "console", "Bash"] {
        #expect(!tokens("echo 1", alias).isEmpty, "alias \(alias)")
    }
    for alias in ["js", "ts", "typescript", "jsx", "tsx"] {
        #expect(tokens("const a = 1", alias).first?.text == "const", "alias \(alias)")
    }
}

/// Ranges are UTF-16, like everything an `NSAttributedString` takes, and Cyrillic in a string or
/// a comment must not shift the tokens after it.
@Test func rangesStayCorrectAfterNonASCIIText() {
    let code = "let s = \"привет\" // комментарий\nlet n = 7"
    let found = tokens(code, "swift")
    #expect(found.last == Found("7", .number))
    #expect(found.contains { $0 == Found("\"привет\"", .string) })
}
