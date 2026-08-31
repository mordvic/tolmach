import Testing
import Foundation
@testable import MarkupKit
@testable import TranslationCore

// The `public.html` flavour of a real capture is written by an application nobody here controls,
// so every test below is either a form the converter promises to read or a shape exported HTML
// is known to contain. The exact spacing of the output is asserted, not merely «contains a #»:
// what the pipeline does with these bytes is decided by `MarkupSkeleton` and
// `MarkdownBlockScanner`, and both read line prefixes.

// MARK: - The forms on the list

@Test func headingsCarryTheirLevelAcrossAsHashes() {
    for level in 1...6 {
        let hashes = String(repeating: "#", count: level)
        #expect(HTMLToMarkdown.markdown(html: "<h\(level)>Заголовок</h\(level)>")
                    == "\(hashes) Заголовок")
    }
}

@Test func boldAndItalicBecomeTheirMarkers() {
    #expect(HTMLToMarkdown.markdown(html: "<p>Совсем <strong>жирный</strong> текст</p>")
                == "Совсем **жирный** текст")
    #expect(HTMLToMarkdown.markdown(html: "<p>Совсем <b>жирный</b> текст</p>")
                == "Совсем **жирный** текст")
    #expect(HTMLToMarkdown.markdown(html: "<p>Совсем <em>курсивный</em> текст</p>")
                == "Совсем *курсивный* текст")
    #expect(HTMLToMarkdown.markdown(html: "<p>Совсем <i>курсивный</i> текст</p>")
                == "Совсем *курсивный* текст")
}

@Test func inlineCodeBecomesBackticks() {
    #expect(HTMLToMarkdown.markdown(html: "<p>Вызовите <code>read()</code> первым</p>")
                == "Вызовите `read()` первым")
}

@Test func aPreBlockBecomesAFenceHoldingItsBytes() {
    let html = "<pre>let x = 1\n  let y = 2</pre>"
    #expect(HTMLToMarkdown.markdown(html: html) == "```\nlet x = 1\n  let y = 2\n```")
}

@Test func aPreCodePairIsOneFenceAndNotAFenceFullOfBackticks() {
    // `<pre><code>` is how every code-highlighting exporter writes a block, and the inner
    // `code` must contribute no inline markers: `` ```\n`let x = 1`\n``` `` would send the
    // model a fence whose first line is a broken inline span.
    let html = "<pre><code>let x = 1\nlet y = 2</code></pre>"
    #expect(HTMLToMarkdown.markdown(html: html) == "```\nlet x = 1\nlet y = 2\n```")
}

@Test func whitespaceInsideAPreIsNotCollapsed() {
    // The one place HTML's whitespace rule does not apply, and the reason `pre` has its own
    // buffer: indentation is the content of a code block.
    let html = "<pre>if x {\n        return\n}</pre>"
    #expect(HTMLToMarkdown.markdown(html: html) == "```\nif x {\n        return\n}\n```")
}

@Test func codeContainingAFenceKeepsItsBytesAndSplitsIntoMoreThanOneBlock() {
    // The honest limit, pinned so it is not rediscovered as a defect: this pipeline's fence rule
    // is a *prefix* one (`LineScanner.isFenceMarker`), so no fence spelling can contain a ```
    // line — a longer ```` fence is closed by the inner ``` just the same. The characters all
    // survive; the block structure around them does not.
    let html = "<pre>```\nвложенный\n```</pre>"
    let markdown = HTMLToMarkdown.markdown(html: html)
    #expect(markdown == "```\n```\nвложенный\n```\n```")
    #expect(markdown.contains("вложенный"))
    #expect(MarkdownBlockScanner.blocks(of: markdown).count > 1)
}

@Test func listsBecomeMarkersAndNestingBecomesIndentation() {
    let html = "<ul><li>первый</li><li>второй<ul><li>вложенный</li></ul></li></ul>"
    #expect(HTMLToMarkdown.markdown(html: html)
                == "- первый\n- второй\n  - вложенный")
}

@Test func anOrderedListNumbersItsOwnItems() {
    let html = "<ol><li>раз</li><li>два</li><li>три</li></ol>"
    #expect(HTMLToMarkdown.markdown(html: html) == "1. раз\n2. два\n3. три")
    // The counter belongs to its own list: a nested ordered list restarts, and the outer one
    // carries on where it left off.
    let nested = "<ol><li>раз<ol><li>вложенный</li></ol></li><li>два</li></ol>"
    #expect(HTMLToMarkdown.markdown(html: nested)
                == "1. раз\n  1. вложенный\n2. два")
}

@Test func aListItemWrittenAsAParagraphKeepsItsMarker() {
    // Exported HTML wraps each item's content in a `<p>`; an empty flush at that `<p>` must not
    // take the item's bullet with it, or every item comes out as a paragraph and the acceptance
    // gate — rightly — refuses the whole conversion.
    let html = "<ul><li><p>первый</p></li><li><p>второй</p></li></ul>"
    #expect(HTMLToMarkdown.markdown(html: html) == "- первый\n- второй")
}

@Test func aBlockquoteBecomesQuoteMarkersAtEveryDepth() {
    #expect(HTMLToMarkdown.markdown(html: "<blockquote><p>цитата</p></blockquote>")
                == "> цитата")
    #expect(HTMLToMarkdown.markdown(
        html: "<blockquote><p>снаружи</p><blockquote><p>внутри</p></blockquote></blockquote>")
                == "> снаружи\n\n> > внутри")
}

@Test func aTableBecomesPipeRowsAndOnlyAHeaderRowGetsADelimiter() {
    let html = """
        <table><tr><th>Ключ</th><th>Значение</th></tr>\
        <tr><td>раз</td><td>1</td></tr><tr><td>два</td><td>2</td></tr></table>
        """
    #expect(HTMLToMarkdown.markdown(html: html) == """
        | Ключ | Значение |
        | --- | --- |
        | раз | 1 |
        | два | 2 |
        """)
}

@Test func aTableWithNoHeaderCellsGetsNoDelimiterRow() {
    // `MarkdownBlockScanner`'s rule, from the other side: without a delimiter row there is no
    // header, and inventing one renders a row of data in semibold.
    let html = "<table><tr><td>раз</td><td>1</td></tr><tr><td>два</td><td>2</td></tr></table>"
    #expect(HTMLToMarkdown.markdown(html: html) == "| раз | 1 |\n| два | 2 |")
    guard case let .table(header, rows, _)? = MarkdownBlockScanner
        .blocks(of: HTMLToMarkdown.markdown(html: html)).first else {
        Issue.record("the rows did not parse back as a table")
        return
    }
    #expect(header.isEmpty)
    #expect(rows.count == 2)
}

@Test func aCellsOwnPipeIsEscapedAndItsLineBreakIsFlattened() {
    // Either one would end the row early, and a row that ends early loses its later cells.
    let html = "<table><tr><td>a|b</td><td>две<br>строки</td></tr></table>"
    #expect(HTMLToMarkdown.markdown(html: html) == "| a\\|b | две строки |")
}

@Test func aCellWrittenAsAParagraphKeepsItsText() {
    // `<td><p class=MsoNormal>…</p></td>` is how Word writes every cell. Treating the `</p>` as
    // a block flush emptied every one of them.
    let html = "<table><tr><td><p>раз</p></td><td><p>два</p></td></tr></table>"
    #expect(HTMLToMarkdown.markdown(html: html) == "| раз | два |")
}

@Test func aLinkWithAURLTargetBecomesAMarkdownLinkAndAnAnchorDoesNot() {
    #expect(HTMLToMarkdown.markdown(html: #"<p>см. <a href="https://x.org">сайт</a></p>"#)
                == "см. [сайт](https://x.org)")
    // Word's internal anchors are links in a document that no longer exists once the text is
    // Markdown; `MarkupSkeleton.targetIsURL` is the one place that question is answered.
    #expect(HTMLToMarkdown.markdown(html: ##"<p>см. <a href="#_Toc42">раздел</a></p>"##)
                == "см. раздел")
    #expect(HTMLToMarkdown.markdown(html: #"<p>см. <a href="./file.md">файл</a></p>"#)
                == "см. файл")
    // An autolinked address: the text already is the URL, so `[url](url)` says it twice.
    #expect(HTMLToMarkdown.markdown(
        html: #"<p><a href="https://x.org">https://x.org</a></p>"#) == "https://x.org")
}

@Test func aBrBecomesAMarkdownHardBreak() {
    let markdown = HTMLToMarkdown.markdown(html: "<p>первая<br>вторая</p>")
    #expect(markdown == "первая  \nвторая")
    #expect(MarkupSkeleton.tokens(of: markdown).contains(.hardLineBreak))
}

@Test func paragraphsAndDivsAreBlockBoundaries() {
    #expect(HTMLToMarkdown.markdown(html: "<p>первый</p><p>второй</p>")
                == "первый\n\nвторой")
    // `div` is this converter's one addition to the design's tag list: a browser selection is
    // div-structured, and treating a div as inline glues two blocks into one paragraph.
    #expect(HTMLToMarkdown.markdown(html: "<div>первый</div><div>второй</div>")
                == "первый\n\nвторой")
}

// MARK: - Everything not on the list

@Test func anUnknownTagContributesItsTextAndNothingElse() {
    #expect(HTMLToMarkdown.markdown(html: "<p>это <span>обычный</span> текст</p>")
                == "это обычный текст")
    #expect(HTMLToMarkdown.markdown(html: "<section><article>текст</article></section>")
                == "текст")
    // An `img` has no text to contribute, and its alt attribute is not the user's prose.
    #expect(HTMLToMarkdown.markdown(html: #"<p>до<img src="x.png" alt="рисунок">после</p>"#)
                == "допосле")
}

@Test func wordsMsoAttributesCannotReachTheOutput() {
    // The measured shape of Word's flavour: inline `mso-*` styles, `class=MsoNormal`,
    // `<span class=SpellE>`, a conditional comment, and a `<style>` block full of the same. None
    // of it is on the tag list, so none of it can change the structure — that is what «closed
    // list» buys.
    let html = """
        <html xmlns:o="urn:schemas-microsoft-com:office:office"><head>\
        <style><!-- p.MsoNormal {mso-style-parent:""; font-family:"Calibri",sans-serif;} --></style>\
        <title>Документ1</title></head><body lang=RU style='tab-interval:35.4pt'>\
        <!--[if gte mso 9]><xml><o:DocumentProperties/></xml><![endif]-->\
        <p class=MsoNormal style='mso-margin-top-alt:auto'><span class=SpellE>\
        <b style='mso-bidi-font-weight:normal'>Отчёт</b></span> за квартал</p></body></html>
        """
    #expect(HTMLToMarkdown.markdown(html: html) == "**Отчёт** за квартал")
}

@Test func theContentOfStyleAndScriptIsDropped() {
    // Not «its tags are ignored» — its *text* must not arrive. A `<style>` block's CSS reaching
    // the model as prose is the failure this prevents, and it is several kilobytes of it in a
    // Word export.
    #expect(HTMLToMarkdown.markdown(
        html: "<style>p { color: red; }</style><p>текст</p>") == "текст")
    #expect(HTMLToMarkdown.markdown(
        html: "<script>var x = 1;</script><p>текст</p>") == "текст")
    // Nested elements of the same kind must not end the drop early.
    #expect(HTMLToMarkdown.markdown(
        html: "<head><style>a{}</style><title>Документ</title></head><p>текст</p>") == "текст")
}

@Test func aCommentAndADoctypeContributeNothing() {
    #expect(HTMLToMarkdown.markdown(
        html: "<!DOCTYPE html><!-- заметка --><p>текст</p>") == "текст")
    // An unterminated comment swallows the rest rather than spilling its text: the alternative
    // is emitting markup as prose.
    #expect(HTMLToMarkdown.markdown(html: "<p>текст</p><!-- дальше") == "текст")
}

@Test func aBareLessThanSignInProseStaysText() {
    #expect(HTMLToMarkdown.markdown(html: "<p>если a < b, то</p>") == "если a < b, то")
}

// MARK: - Entities

@Test func namedAndNumericEntitiesAreDecoded() {
    #expect(HTMLToMarkdown.markdown(html: "<p>&amp; &lt; &gt; &quot; &apos;</p>")
                == "& < > \" '")
    #expect(HTMLToMarkdown.markdown(html: "<p>&#1055;&#1088;&#1080;&#1074;&#1077;&#1090;</p>")
                == "Привет")
    #expect(HTMLToMarkdown.markdown(html: "<p>&#x41F;&#x440;&#x438;</p>") == "При")
    // An unrecognised reference is left exactly as it stands — the user's characters, unchanged.
    #expect(HTMLToMarkdown.markdown(html: "<p>&mdash; тире</p>") == "&mdash; тире")
    // A bare ampersand in prose is an ampersand.
    #expect(HTMLToMarkdown.markdown(html: "<p>Кофе & сигареты</p>") == "Кофе & сигареты")
}

@Test func aNonBreakingSpaceSurvivesAsItselfAndAnEmptyParagraphOfThemIsDropped() {
    // U+00A0 is the character the document has, and collapsing it would edit «10 км». A
    // paragraph made only of them is Word's vertical spacing and is not a paragraph.
    #expect(HTMLToMarkdown.markdown(html: "<p>10&nbsp;км</p>") == "10\u{00A0}км")
    #expect(HTMLToMarkdown.markdown(html: "<p>первый</p><p>&nbsp;</p><p>второй</p>")
                == "первый\n\nвторой")
}

// MARK: - Not fabricating markers

@Test func emphasisAroundNothingProducesNoMarkers() {
    // `<b> </b>` is ordinary in exported HTML, and `** **` is not emphasis in any parser —
    // `MarkdownInline`'s first refusal, seen from here.
    #expect(HTMLToMarkdown.markdown(html: "<p>до<b> </b>после</p>") == "до после")
    #expect(HTMLToMarkdown.markdown(html: "<p>до<b></b>после</p>") == "допосле")
}

@Test func spaceAgainstAMarkerIsMovedOutsideThePair() {
    // CommonMark's flanking rules: `**жирный **` does not close, so the space goes outside the
    // markers and every character the user selected is still there.
    #expect(HTMLToMarkdown.markdown(html: "<p>до <b>жирный </b>после</p>")
                == "до **жирный** после")
}

@Test func nestedEmphasisOfTheSameKindDoesNotDoubleItsMarkers() {
    // What Word writes around a partially re-styled run. Wrapping twice yields `**a**c****` —
    // four literal asterisks in the text handed to the model.
    #expect(HTMLToMarkdown.markdown(html: "<p><b>раз<b>два</b></b></p>") == "**раздва**")
}

@Test func aCrossedPairLosesItsEmphasisRatherThanGainingAMarker() {
    // `<b>раз<i>два</b>три</i>` — the closes arrive in the wrong order, which no stack can
    // honour without inventing a marker for text it cannot describe. The bold is dropped, the
    // italic closes where its own tag does — over «дватри», further than the source drew it —
    // and nothing unpaired reaches the output. Getting the span right would need a document
    // model; getting the markers balanced is what actually matters downstream.
    let markdown = HTMLToMarkdown.markdown(html: "<p><b>раз<i>два</b>три</i></p>")
    #expect(markdown == "раз*дватри*")
    // The property that matters: an odd number of `*` runs would ride into the prompt as a
    // literal, and §2 series B measured what these models then do with one.
    #expect(markdown.filter { $0 == "*" }.count % 2 == 0)
}

@Test func emphasisWholeContentIsWrappedOnceEvenAcrossInnerTags() {
    #expect(HTMLToMarkdown.markdown(html: "<p><b>раз <span>два</span> три</b></p>")
                == "**раз два три**")
}

// MARK: - The Data face

@Test func theDataFaceRefusesAnythingThatIsNotUTF8() {
    // UTF-8 or nothing, exactly `DroppedDocument`'s rule and for a stronger reason: a guessed
    // encoding does not fail, it succeeds with mojibake — and mojibake carrying a heading passes
    // the acceptance gate and reaches the model as the user's text.
    let utf8 = Data("<h1>Заголовок</h1>".utf8)
    #expect(HTMLToMarkdown.markdown(from: utf8) == "# Заголовок")

    let latin1 = "<h1>Überschrift</h1>".data(using: .isoLatin1)!
    #expect(HTMLToMarkdown.markdown(from: latin1) == nil)
}

@Test func aWholeDocumentComesBackAsEveryFormAtOnce() {
    // One capture carrying every form the list covers, asserted whole: the conversion is used as
    // one string by the pipeline, so the block *separation* is as load-bearing as the blocks.
    let html = """
        <h2>Отчёт</h2><p>Первый <b>абзац</b> с <code>кодом</code>.</p>\
        <ul><li>раз</li><li>два</li></ul><blockquote><p>цитата</p></blockquote>\
        <pre>let x = 1</pre><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>
        """
    #expect(HTMLToMarkdown.markdown(html: html) == """
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
        """)
}
