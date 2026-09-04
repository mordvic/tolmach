import Testing
import Foundation
@testable import TranslationCore

// «Заменить» writes into the user's own document, so what this renderer decides per block is what
// lands in their Word file. Each choice is asserted rather than left to the doc comment, because
// each is a judgement: a marker kept, a marker dropped, or a character standing in for a form
// plain text does not have.

@Test func headingsKeepTheirWordsAndLoseTheirHashes() {
    #expect(MarkdownPlainText.render("# Отчёт") == "Отчёт")
    #expect(MarkdownPlainText.render("### Отчёт за квартал") == "Отчёт за квартал")
}

@Test func inlineMarkersAreRemovedAndTheWordsSurvive() {
    #expect(MarkdownPlainText.render("Совсем **жирный** и *курсивный* текст")
                == "Совсем жирный и курсивный текст")
    #expect(MarkdownPlainText.render("Вызовите `read()` первым") == "Вызовите read() первым")
}

@Test func aLinkKeepsItsTextAndLosesItsTarget() {
    // Stated as a loss rather than hidden: a plain write has nowhere to put a URL, and appending
    // it in parentheses would edit the user's sentence.
    #expect(MarkdownPlainText.render("см. [сайт](https://x.org)") == "см. сайт")
}

@Test func aListKeepsAMarkerButNotAMarkdownOne() {
    // A list whose markers are gone reads as glued prose, so a marker stays — «•» and not «-»,
    // because the destination is a rich document where a literal hyphen reads as syntax leaking.
    #expect(MarkdownPlainText.render("- раз\n- два") == "• раз\n• два")
    #expect(MarkdownPlainText.render("1. раз\n2. два") == "1. раз\n2. два")
    #expect(MarkdownPlainText.render("- снаружи\n  - внутри") == "• снаружи\n  • внутри")
    // No Markdown marker survives anywhere in the output — the property the whole type is for.
    #expect(!MarkdownPlainText.render("- **раз**\n- два").contains("*"))
}

@Test func aBlockquoteLosesItsMarkerAndKeepsItsWords() {
    #expect(MarkdownPlainText.render("> цитата") == "цитата")
    #expect(!MarkdownPlainText.render("> цитата").contains(">"))
}

@Test func aCodeBlockIsItsContentVerbatim() {
    // Its bytes are the one thing in a translation that must not be reformatted: no trimming, no
    // collapsing, the indentation kept, the fences gone.
    #expect(MarkdownPlainText.render("```swift\nif x {\n        return\n}\n```")
                == "if x {\n        return\n}")
}

@Test func aTableBecomesTabSeparatedCells() {
    // The plain-text spelling of a table everywhere: what a spreadsheet puts on the pasteboard,
    // and what Word's «преобразовать текст в таблицу» reads. Pipes would be syntax again.
    let markdown = """
        | Ключ | Значение |
        | --- | --- |
        | раз | 1 |
        | два | 2 |
        """
    #expect(MarkdownPlainText.render(markdown)
                == "Ключ\tЗначение\nраз\t1\nдва\t2")
    #expect(!MarkdownPlainText.render(markdown).contains("|"))
    #expect(!MarkdownPlainText.render(markdown).contains("---"))
}

@Test func aThematicBreakBecomesADividerAReaderCanSee() {
    // Reachable only from a model's own output — neither capture converter produces one.
    #expect(MarkdownPlainText.render("первый\n\n---\n\nвторой") == "первый\n\n———\n\nвторой")
}

@Test func aWholeDocumentComesOutWithItsBlocksStillApart() {
    let markdown = """
        ## Отчёт

        Первый **абзац** с `кодом`.

        - раз
        - два

        > цитата

        ```
        let x = 1
        ```

        | a | b |
        | --- | --- |
        | 1 | 2 |
        """
    #expect(MarkdownPlainText.render(markdown) == """
        Отчёт

        Первый абзац с кодом.

        • раз
        • два

        цитата

        let x = 1

        a\tb
        1\t2
        """)
    // The property «Заменить» depends on: nothing a reader would see as markup is left.
    let rendered = MarkdownPlainText.render(markdown)
    #expect(!rendered.contains("#"))
    #expect(!rendered.contains("**"))
    #expect(!rendered.contains("`"))
    #expect(!rendered.contains("|"))
}

@Test func plainProseComesBackUnchanged() {
    // The overwhelmingly common shape of a panel's reply, and the one this must not touch.
    let prose = "Первое предложение. Второе предложение.\n\nВторой абзац."
    #expect(MarkdownPlainText.render(prose) == prose)
}

@Test func proseThatMerelyContainsTheCharactersIsNotStripped() {
    // `MarkdownPresence`'s own probe string, from the other side: its `*` is followed by a space
    // and pairs with nothing, so the inline parse leaves every character where it was.
    let prose = "Цена 5 * 3 = 15, файл a_b_c.txt и #хэштег"
    #expect(MarkdownPlainText.render(prose) == prose)
}

// MARK: - The golden pin

/// Every block kind, and the joins between them, with the exact string `render` produced
/// **before** `plain(_:in:)` was factored out of it.
///
/// Written and frozen against the shipped outputs before the refactor, so that «`render` is
/// byte-identical afterwards» is something this file can fail on rather than a claim in a
/// commit message. Every expectation here is a captured output, not a hand-written guess: the
/// mutation it dies under is any change to a per-block spelling («•» to «-», the em-dash
/// count) or to the separator between two blocks (a list joined by a blank line, table rows
/// joined by two newlines).
private let goldenFixtures: [(name: String, markdown: String, plain: String)] = [
    ("atx heading", "# Отчёт за август", "Отчёт за август"),
    ("setext heading", "Отчёт за август\n===", "Отчёт за август"),
    ("paragraph with inline markers", "Совсем **жирный**, *курсивный* и `read()` текст.",
     "Совсем жирный, курсивный и read() текст."),
    ("paragraph over two lines", "Первая строка\nвторая строка.", "Первая строка\nвторая строка."),
    ("link", "см. [сайт](https://x.org) сегодня", "см. сайт сегодня"),
    ("bullet list", "- раз\n- два\n- три", "• раз\n• два\n• три"),
    ("nested bullet list", "- снаружи\n  - внутри\n    - глубже",
     "• снаружи\n  • внутри\n    • глубже"),
    ("ordered list", "1. раз\n2. два", "1. раз\n2. два"),
    ("blockquote", "> цитата в одну строку", "цитата в одну строку"),
    ("fenced code", "```swift\nif x {\n        return\n}\n```", "if x {\n        return\n}"),
    ("unterminated fence", "```\nlet x = 1", "let x = 1"),
    ("table", "| Ключ | Значение |\n| --- | --- |\n| раз | 1 |\n| два | 2 |",
     "Ключ\tЗначение\nраз\t1\nдва\t2"),
    ("table without a delimiter row", "| раз | 1 |\n| два | 2 |", "раз\t1\nдва\t2"),
    ("thematic break", "первый\n\n---\n\nвторой", "первый\n\n———\n\nвторой"),
    ("list then paragraph", "- раз\n- два\n\nАбзац после списка.",
     "• раз\n• два\n\nАбзац после списка."),
    ("paragraph then list", "Абзац перед списком.\n\n- раз\n- два",
     "Абзац перед списком.\n\n• раз\n• два"),
    ("crlf document", "# Заголовок\r\n\r\nАбзац.\r\n\r\n- раз\r\n- два",
     "Заголовок\n\nАбзац.\n\n• раз\n• два"),
    ("plain prose", "Первое предложение. Второе предложение.\n\nВторой абзац.",
     "Первое предложение. Второе предложение.\n\nВторой абзац."),
    ("everything at once", """
        ## Отчёт

        Первый **абзац** с `кодом`.

        - раз
        - два

        > цитата

        ```
        let x = 1
        ```

        | a | b |
        | --- | --- |
        | 1 | 2 |

        ---

        Последний абзац.
        """,
     "Отчёт\n\nПервый абзац с кодом.\n\n• раз\n• два\n\nцитата\n\nlet x = 1\n\na\tb\n1\t2"
     + "\n\n———\n\nПоследний абзац."),
]

@Test func renderSpellsEveryBlockKindExactlyAsItDidBeforeThePerBlockRefactor() {
    for fixture in goldenFixtures {
        // Asserted one fixture at a time, with the name in the message: a single
        // `allSatisfy` over the array would report «false» and leave the reader to find
        // which of nineteen documents moved.
        #expect(MarkdownPlainText.render(fixture.markdown) == fixture.plain,
                "\(fixture.name)")
    }
}
