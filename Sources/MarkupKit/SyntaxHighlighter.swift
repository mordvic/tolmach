// Sources/MarkupKit/SyntaxHighlighter.swift
import Foundation

/// Which runs of a code block are worth a colour, per language — a lexer with a profile, not a
/// parser.
///
/// **Hand-written, because the dependency rule is a closed list** (`docs/adr/0007`): no
/// highlighting library is coming in for this. What a lexer can find without a grammar is
/// exactly the set most highlighters colour anyway — comments, strings, numbers, keywords, and
/// the keys of data formats — and that set is enough to make code read as code. Anything it
/// cannot tell apart is left in the label colour, which is the honest answer for an operator
/// or an identifier.
///
/// Two rules keep it from lying:
///
/// - **No profile, no colours.** A fence with no language, or one this file has no profile for,
///   yields nothing. A guess about comment syntax is how a URL turns green.
/// - **A token is closed by the syntax that opened it.** A `//` inside a string is characters; a
///   `"` inside a comment is a character; a `#` in shell is a comment only at a word boundary
///   (`$#` and `${#x}` are not). Each of those is a test.
///
/// Ranges are UTF-16, like everything `NSAttributedString` takes, so Cyrillic in a string never
/// shifts the tokens after it.
public enum SyntaxHighlighter {
    public enum Kind: Sendable, Equatable {
        case keyword, string, comment, number, key, type
    }

    public struct Token: Sendable, Equatable {
        public let range: NSRange
        public let kind: Kind
    }

    /// Every token of `code` under the profile `language` names, in document order and never
    /// overlapping. Empty for an unknown or absent language.
    public static func tokens(in code: String, language: String?) -> [Token] {
        guard let profile = Profile.named(language) else { return [] }
        var lexer = Lexer(code: code, profile: profile)
        return lexer.run()
    }

    // MARK: - Profiles

    struct Profile {
        var keywords: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: [Character] = ["\""]
        /// `"""`/`'''` strings that span lines (Python, Swift).
        var tripleQuotes = false
        /// SQL and Dockerfile spell keywords in either case.
        var caseInsensitiveKeywords = false
        /// An identifier followed by `:` (or `=` when `keysBeforeEquals`) is a key — data
        /// formats and CSS. Quoted strings before a `:` count too, for JSON.
        var keysBeforeColon = false
        var keysBeforeEquals = false
        /// `<name` and `</name` are keywords, strings only inside a tag, nothing else coloured.
        var markup = false
        /// A capitalised identifier is a type — the convention in Swift, Kotlin, Java, C#, Go,
        /// Rust and TypeScript, and a lie in Python or shell, where it is off.
        var capitalisedTypes = false
        /// `-` may continue an identifier (YAML and CSS keys, shell words).
        var hyphenInIdentifiers = false

        static func named(_ language: String?) -> Profile? {
            guard let language else { return nil }
            switch language.lowercased() {
            case "swift": return swift
            case "python", "py": return python
            case "javascript", "js", "jsx", "typescript", "ts", "tsx": return javascript
            case "bash", "sh", "zsh", "shell", "console", "fish": return shell
            case "json", "jsonc": return json
            case "yaml", "yml": return yaml
            case "toml": return toml
            case "sql", "postgresql", "mysql", "sqlite": return sql
            case "go", "golang": return go
            case "rust", "rs": return rust
            case "kotlin", "kt": return kotlin
            case "java": return java
            case "csharp", "cs", "c#": return csharp
            case "c", "cpp", "c++", "h", "hpp", "objc", "objective-c", "objectivec": return cFamily
            case "ruby", "rb": return ruby
            case "php": return php
            case "html", "xml", "svg", "xhtml", "plist": return html
            case "css", "scss": return css
            case "dockerfile", "docker": return dockerfile
            default: return nil
            }
        }

        static let swift = Profile(
            keywords: ["let", "var", "func", "class", "struct", "enum", "protocol", "extension",
                       "import", "return", "if", "else", "guard", "switch", "case", "default",
                       "for", "in", "while", "repeat", "do", "try", "catch", "throw", "throws",
                       "rethrows", "async", "await", "actor", "init", "deinit", "self", "Self",
                       "super", "static", "final", "private", "fileprivate", "public", "internal",
                       "open", "override", "mutating", "nonisolated", "where", "as", "is", "nil",
                       "true", "false", "some", "any", "typealias", "associatedtype", "inout",
                       "break", "continue", "fallthrough", "defer", "subscript", "operator",
                       "lazy", "weak", "unowned", "convenience", "required", "indirect", "get",
                       "set", "willSet", "didSet", "macro", "consuming", "borrowing"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], tripleQuotes: true,
            capitalisedTypes: true)

        static let python = Profile(
            keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not",
                       "and", "or", "is", "None", "True", "False", "import", "from", "as", "with",
                       "try", "except", "finally", "raise", "lambda", "pass", "break", "continue",
                       "yield", "global", "nonlocal", "assert", "del", "async", "await", "match",
                       "case", "self"],
            lineComments: ["#"], quotes: ["\"", "'"], tripleQuotes: true)

        static let javascript = Profile(
            keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while",
                       "do", "switch", "case", "default", "break", "continue", "new", "delete",
                       "typeof", "instanceof", "in", "of", "class", "extends", "super", "this",
                       "import", "export", "from", "as", "async", "await", "try", "catch",
                       "finally", "throw", "yield", "void", "null", "undefined", "true", "false",
                       "interface", "type", "enum", "implements", "public", "private",
                       "protected", "readonly", "static", "declare", "namespace", "keyof"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"],
            capitalisedTypes: true)

        static let shell = Profile(
            keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                       "case", "esac", "in", "function", "select", "time", "echo", "export",
                       "local", "return", "exit", "source", "alias", "unset", "set", "read", "cd",
                       "sudo", "printf", "test", "exec", "trap", "shift", "declare"],
            lineComments: ["#"], quotes: ["\"", "'", "`"], hyphenInIdentifiers: true)

        static let json = Profile(keywords: ["true", "false", "null"], quotes: ["\""],
                                  keysBeforeColon: true)

        static let yaml = Profile(keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                                  lineComments: ["#"], quotes: ["\"", "'"], keysBeforeColon: true,
                                  hyphenInIdentifiers: true)

        static let toml = Profile(keywords: ["true", "false"], lineComments: ["#"],
                                  quotes: ["\"", "'"], keysBeforeEquals: true,
                                  hyphenInIdentifiers: true)

        static let sql = Profile(
            keywords: ["select", "from", "where", "insert", "into", "values", "update", "set",
                       "delete", "create", "table", "drop", "alter", "add", "column", "index",
                       "view", "join", "inner", "left", "right", "outer", "cross", "on", "group",
                       "by", "order", "having", "limit", "offset", "union", "all", "distinct",
                       "as", "and", "or", "not", "null", "is", "in", "exists", "between", "like",
                       "case", "when", "then", "else", "end", "primary", "key", "foreign",
                       "references", "default", "begin", "commit", "rollback", "with", "asc",
                       "desc", "count", "sum", "avg", "min", "max", "if", "returning", "using"],
            lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'"],
            caseInsensitiveKeywords: true)

        static let go = Profile(
            keywords: ["package", "import", "func", "var", "const", "type", "struct", "interface",
                       "map", "chan", "go", "defer", "return", "if", "else", "for", "range",
                       "switch", "case", "default", "break", "continue", "fallthrough", "select",
                       "goto", "nil", "true", "false", "make", "new", "len", "append", "error"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"],
            capitalisedTypes: true)

        static let rust = Profile(
            keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait",
                       "pub", "use", "mod", "crate", "self", "Self", "super", "match", "if",
                       "else", "loop", "while", "for", "in", "return", "break", "continue", "as",
                       "where", "unsafe", "async", "await", "move", "ref", "dyn", "type", "true",
                       "false", "Some", "None", "Ok", "Err", "macro_rules"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], capitalisedTypes: true)

        static let kotlin = Profile(
            keywords: ["fun", "val", "var", "class", "object", "interface", "data", "sealed",
                       "enum", "return", "if", "else", "when", "for", "while", "do", "in", "is",
                       "as", "null", "true", "false", "import", "package", "override", "open",
                       "private", "public", "internal", "protected", "abstract", "companion",
                       "suspend", "try", "catch", "finally", "throw", "this", "super", "lateinit",
                       "by", "get", "set", "init", "constructor"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], tripleQuotes: true,
            capitalisedTypes: true)

        static let java = Profile(
            keywords: ["class", "interface", "enum", "record", "extends", "implements", "public",
                       "private", "protected", "static", "final", "abstract", "void", "int",
                       "long", "double", "float", "boolean", "char", "byte", "short", "return",
                       "if", "else", "for", "while", "do", "switch", "case", "default", "break",
                       "continue", "new", "this", "super", "import", "package", "try", "catch",
                       "finally", "throw", "throws", "null", "true", "false", "instanceof", "var",
                       "synchronized", "volatile", "transient"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"],
            capitalisedTypes: true)

        static let csharp = Profile(
            keywords: ["class", "interface", "struct", "enum", "record", "namespace", "using",
                       "public", "private", "protected", "internal", "static", "readonly", "const",
                       "void", "int", "long", "double", "float", "bool", "string", "char", "var",
                       "return", "if", "else", "for", "foreach", "while", "do", "switch", "case",
                       "default", "break", "continue", "new", "this", "base", "try", "catch",
                       "finally", "throw", "null", "true", "false", "is", "as", "in", "out", "ref",
                       "async", "await", "get", "set", "override", "virtual", "abstract", "sealed"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"],
            capitalisedTypes: true)

        static let cFamily = Profile(
            keywords: ["int", "char", "long", "short", "float", "double", "void", "bool",
                       "unsigned", "signed", "const", "static", "extern", "struct", "union",
                       "enum", "typedef", "return", "if", "else", "for", "while", "do", "switch",
                       "case", "default", "break", "continue", "goto", "sizeof", "class",
                       "public", "private", "protected", "virtual", "override", "template",
                       "typename", "namespace", "using", "new", "delete", "this", "nullptr",
                       "true", "false", "auto", "constexpr", "inline", "try", "catch", "throw",
                       "#include", "#define", "#if", "#ifdef", "#endif", "#pragma", "#import",
                       "@interface", "@implementation", "@end", "@property", "@selector", "self",
                       "nil", "YES", "NO", "id"],
            lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"],
            capitalisedTypes: true)

        static let ruby = Profile(
            keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "case",
                       "when", "while", "until", "for", "in", "do", "return", "yield", "begin",
                       "rescue", "ensure", "raise", "self", "nil", "true", "false", "and", "or",
                       "not", "require", "include", "attr_accessor", "puts", "lambda", "proc"],
            lineComments: ["#"], quotes: ["\"", "'"], capitalisedTypes: true)

        static let php = Profile(
            keywords: ["function", "class", "interface", "trait", "extends", "implements", "public",
                       "private", "protected", "static", "return", "if", "else", "elseif", "for",
                       "foreach", "while", "do", "switch", "case", "default", "break", "continue",
                       "new", "echo", "null", "true", "false", "use", "namespace", "try", "catch",
                       "finally", "throw", "as", "fn", "match", "array", "require", "include"],
            lineComments: ["//", "#"], blockComment: ("/*", "*/"), quotes: ["\"", "'"],
            capitalisedTypes: true)

        static let html = Profile(blockComment: ("<!--", "-->"), quotes: ["\"", "'"], markup: true,
                                  hyphenInIdentifiers: true)

        static let css = Profile(blockComment: ("/*", "*/"), quotes: ["\"", "'"],
                                 keysBeforeColon: true, hyphenInIdentifiers: true)

        static let dockerfile = Profile(
            keywords: ["from", "run", "cmd", "copy", "add", "env", "arg", "workdir", "expose",
                       "entrypoint", "volume", "user", "label", "shell", "healthcheck", "onbuild",
                       "stopsignal", "maintainer", "as"],
            lineComments: ["#"], quotes: ["\"", "'"], caseInsensitiveKeywords: true)
    }

    // MARK: - The lexer

    struct Lexer {
        let units: [UInt16]
        let profile: Profile
        var index = 0
        var tokens: [Token] = []
        /// Inside `<…>` of a markup tag: strings colour, nothing else does.
        var inTag = false

        init(code: String, profile: Profile) {
            units = Array(code.utf16)
            self.profile = profile
        }

        mutating func run() -> [Token] {
            while index < units.count {
                if profile.markup {
                    stepMarkup()
                } else {
                    step()
                }
            }
            return tokens
        }

        private mutating func step() {
            let unit = units[index]
            if let comment = profile.blockComment, matches(comment.open) {
                let start = index
                index += comment.open.utf16.count
                if let end = find(comment.close, from: index) {
                    index = end + comment.close.utf16.count
                } else {
                    index = units.count
                }
                emit(start, .comment)
                return
            }
            for marker in profile.lineComments where matches(marker) {
                // `#` is a comment only at a word boundary: `$#`, `${#x}` and `a#b` are not.
                if marker == "#", index > 0, !isSpace(units[index - 1]), units[index - 1] != 0x0A {
                    break
                }
                let start = index
                index = endOfLine(from: index)
                emit(start, .comment)
                return
            }
            if let quote = profile.quotes.first(where: { $0.utf16.first == unit }) {
                let start = index
                scanString(quote: quote.utf16.first!)
                var kind = Kind.string
                if profile.keysBeforeColon, nextNonSpace(from: index) == 0x3A { kind = .key }
                emit(start, kind)
                return
            }
            if isDigit(unit), index == 0 || !isIdentifierBody(units[index - 1]) {
                let start = index
                scanNumber()
                emit(start, .number)
                return
            }
            if isIdentifierStart(unit) || (unit == 0x23 /* # */ && profile.keywords.contains("#include"))
                || (unit == 0x40 /* @ */ && profile.keywords.contains("@interface")) {
                let start = index
                index += 1
                while index < units.count, isIdentifierBody(units[index]) { index += 1 }
                let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                let matchWord = profile.caseInsensitiveKeywords ? word.lowercased() : word
                if profile.keywords.contains(matchWord) {
                    emit(start, .keyword)
                } else if profile.keysBeforeColon, atLineStart(before: start),
                          nextNonSpace(from: index) == 0x3A {
                    emit(start, .key)
                } else if profile.keysBeforeEquals, atLineStart(before: start),
                          nextNonSpace(from: index) == 0x3D {
                    emit(start, .key)
                } else if profile.capitalisedTypes, let first = word.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first), word.count > 1 {
                    emit(start, .type)
                }
                return
            }
            index += 1
        }

        private mutating func stepMarkup() {
            let unit = units[index]
            if let comment = profile.blockComment, matches(comment.open) {
                let start = index
                index += comment.open.utf16.count
                index = find(comment.close, from: index).map { $0 + comment.close.utf16.count }
                    ?? units.count
                emit(start, .comment)
                return
            }
            if inTag {
                if unit == 0x3E /* > */ { inTag = false; index += 1; return }
                if let quote = profile.quotes.first(where: { $0.utf16.first == unit }) {
                    let start = index
                    scanString(quote: quote.utf16.first!)
                    emit(start, .string)
                    return
                }
                index += 1
                return
            }
            if unit == 0x3C /* < */ {
                var cursor = index + 1
                if cursor < units.count, units[cursor] == 0x2F /* / */ { cursor += 1 }
                if cursor < units.count, isIdentifierStart(units[cursor]) {
                    let start = cursor
                    while cursor < units.count, isIdentifierBody(units[cursor]) || units[cursor] == 0x3A {
                        cursor += 1
                    }
                    tokens.append(Token(range: NSRange(location: start, length: cursor - start),
                                        kind: .keyword))
                    index = cursor
                    inTag = true
                    return
                }
            }
            index += 1
        }

        // MARK: Scanners

        private mutating func scanString(quote: UInt16) {
            let triple = profile.tripleQuotes && matchesRun(quote, count: 3)
            if triple {
                index += 3
                while index < units.count {
                    if matchesRun(quote, count: 3) { index += 3; return }
                    if units[index] == 0x5C { index += 2; continue }
                    index += 1
                }
                return
            }
            index += 1
            while index < units.count {
                let unit = units[index]
                if unit == 0x5C /* \ */ { index += 2; continue }
                if unit == quote { index += 1; return }
                // A single-line string that never closes ends at the line, so one stray quote
                // cannot swallow the rest of the block. Backticks span lines by design.
                if unit == 0x0A, quote != 0x60 { return }
                index += 1
            }
        }

        private mutating func scanNumber() {
            if units[index] == 0x30, index + 1 < units.count,
               [0x78, 0x58, 0x62, 0x42, 0x6F, 0x4F].contains(units[index + 1]) {
                index += 2
                while index < units.count, isHexDigit(units[index]) || units[index] == 0x5F { index += 1 }
                return
            }
            while index < units.count, isDigit(units[index]) || units[index] == 0x5F { index += 1 }
            if index + 1 < units.count, units[index] == 0x2E, isDigit(units[index + 1]) {
                index += 1
                while index < units.count, isDigit(units[index]) || units[index] == 0x5F { index += 1 }
            }
            if index + 1 < units.count, units[index] == 0x65 || units[index] == 0x45 {
                var cursor = index + 1
                if cursor < units.count, units[cursor] == 0x2B || units[cursor] == 0x2D { cursor += 1 }
                if cursor < units.count, isDigit(units[cursor]) {
                    index = cursor
                    while index < units.count, isDigit(units[index]) { index += 1 }
                }
            }
        }

        // MARK: Helpers

        private mutating func emit(_ start: Int, _ kind: Kind) {
            tokens.append(Token(range: NSRange(location: start, length: index - start), kind: kind))
        }

        private func matches(_ text: String) -> Bool {
            let needle = Array(text.utf16)
            guard index + needle.count <= units.count else { return false }
            return Array(units[index..<index + needle.count]) == needle
        }

        private func matchesRun(_ unit: UInt16, count: Int) -> Bool {
            guard index + count <= units.count else { return false }
            return units[index..<index + count].allSatisfy { $0 == unit }
        }

        private func find(_ text: String, from: Int) -> Int? {
            let needle = Array(text.utf16)
            guard !needle.isEmpty, from + needle.count <= units.count else { return nil }
            for position in from...(units.count - needle.count)
            where Array(units[position..<position + needle.count]) == needle {
                return position
            }
            return nil
        }

        private func endOfLine(from: Int) -> Int {
            var cursor = from
            while cursor < units.count, units[cursor] != 0x0A, units[cursor] != 0x0D { cursor += 1 }
            return cursor
        }

        private func nextNonSpace(from: Int) -> UInt16? {
            var cursor = from
            while cursor < units.count, units[cursor] == 0x20 || units[cursor] == 0x09 { cursor += 1 }
            return cursor < units.count ? units[cursor] : nil
        }

        /// Only indentation, or a list dash, between the line's start and `position`.
        private func atLineStart(before position: Int) -> Bool {
            var cursor = position - 1
            while cursor >= 0 {
                let unit = units[cursor]
                if unit == 0x0A || unit == 0x0D { return true }
                if unit == 0x20 || unit == 0x09 || unit == 0x2D { cursor -= 1; continue }
                return false
            }
            return true
        }

        private func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0D }
        private func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
        private func isHexDigit(_ unit: UInt16) -> Bool {
            isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
        }
        private func isLetter(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit >= 0x80
        }
        private func isIdentifierStart(_ unit: UInt16) -> Bool { isLetter(unit) || unit == 0x5F }
        private func isIdentifierBody(_ unit: UInt16) -> Bool {
            isLetter(unit) || isDigit(unit) || unit == 0x5F
                || (profile.hyphenInIdentifiers && unit == 0x2D)
        }
    }
}
