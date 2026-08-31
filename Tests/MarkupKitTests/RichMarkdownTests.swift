import Testing
import AppKit
import Foundation
@testable import MarkupKit
@testable import TranslationCore

// The gate is the whole safety argument of rich capture: everything it accepts is translated
// instead of the plain flavour, so every marker it lets through rides into every chunk's prompt.
// «Улучшение или ничего» — a block form the plain flavour lacks, or the plain flavour.

@Test func aConversionThatRecoversABlockFormIsAccepted() {
    // The case the whole feature exists for: the plain flavour of a heading is a line of prose,
    // and the HTML flavour still says it is a heading.
    let plain = "Отчёт\nПервый абзац."
    let html = Data("<h1>Отчёт</h1><p>Первый абзац.</p>".utf8)
    #expect(RichMarkdown.markdown(html: html, rtf: nil, improvingOn: plain)
                == "# Отчёт\n\nПервый абзац.")
}

@Test func aConversionThatRecoversNothingIsRefusedAndThePlainFlavourIsUsed() {
    // Two paragraphs of prose have no block form to recover. The conversion is *correct* and
    // still refused: it would replace the user's own bytes with a re-serialisation for nothing.
    let plain = "Первый абзац.\n\nВторой абзац."
    let html = Data("<p>Первый абзац.</p><p>Второй абзац.</p>".utf8)
    #expect(RichMarkdown.markdown(html: html, rtf: nil, improvingOn: plain) == nil)
}

@Test func aConversionWhoseOnlyGainIsInlineMarkersIsRefused() {
    // Emphasis is the form the models are measurably worst with (design §2 series B: bold
    // degraded to italic 5/5 on translategemma:12b, emphasis invented 2/3 on aya-expanse:32b),
    // and a bold run recovered from a font weight is the guess most likely to be wrong. So a
    // conversion that gained nothing but `**` does not open the gate.
    let plain = "Совсем жирный текст"
    let html = Data("<p>Совсем <b>жирный</b> текст</p>".utf8)
    #expect(RichMarkdown.markdown(html: html, rtf: nil, improvingOn: plain) == nil)
    // Inline code and a link are the same answer, for the same reason.
    #expect(RichMarkdown.markdown(html: Data("<p>Вызовите <code>read()</code></p>".utf8),
                                  rtf: nil, improvingOn: "Вызовите read()") == nil)
    #expect(RichMarkdown.markdown(
        html: Data(#"<p>см. <a href="https://x.org">сайт</a></p>"#.utf8),
        rtf: nil, improvingOn: "см. сайт") == nil)
}

@Test func aPlainFlavourThatAlreadyCarriesTheStructureIsKept() {
    // The no-op half of the name: a bulleted list copied out of an editor is still `- раз` in
    // plain text, so the conversion adds no block form and the user's own bytes win.
    let plain = "- раз\n- два"
    let html = Data("<ul><li>раз</li><li>два</li></ul>".utf8)
    #expect(RichMarkdown.markdown(html: html, rtf: nil, improvingOn: plain) == nil)
}

@Test func aConversionThatAddsMoreOfAFormThePlainFlavourHasIsAccepted() {
    // «At least one block token the plain flavour lacks» is counted, not merely present: a
    // document whose plain text kept one of its three list items is still missing two.
    let plain = "- раз\nдва\nтри"
    let html = Data("<ul><li>раз</li><li>два</li><li>три</li></ul>".utf8)
    #expect(RichMarkdown.markdown(html: html, rtf: nil, improvingOn: plain) == "- раз\n- два\n- три")
}

@Test func everyBlockFormOpensTheGateAndNoInlineFormDoes() {
    // The gate's classification, form by form, so a new `MarkupToken` cannot be added to the
    // wrong side of it silently.
    #expect(RichMarkdown.isImprovement("# Заголовок", over: "Заголовок"))
    #expect(RichMarkdown.isImprovement("- элемент", over: "элемент"))
    #expect(RichMarkdown.isImprovement("> цитата", over: "цитата"))
    #expect(RichMarkdown.isImprovement("```\nкод\n```", over: "код"))
    #expect(RichMarkdown.isImprovement("| a | b |", over: "a b"))

    #expect(!RichMarkdown.isImprovement("**жирный**", over: "жирный"))
    #expect(!RichMarkdown.isImprovement("`код`", over: "код"))
    #expect(!RichMarkdown.isImprovement("[текст](https://x.org)", over: "текст"))
    #expect(!RichMarkdown.isImprovement("первый\n\nвторой", over: "первый второй"))
    #expect(!RichMarkdown.isImprovement("строка  \nдругая", over: "строка другая"))
}

@Test func anEmptyConversionIsNeverAnImprovement() {
    // An HTML flavour whose content is all `<style>` converts to nothing, and «nothing» must not
    // become the text that gets translated.
    #expect(!RichMarkdown.isImprovement("", over: "текст"))
    #expect(!RichMarkdown.isImprovement("   \n ", over: "текст"))
    #expect(RichMarkdown.markdown(html: Data("<style>p{}</style>".utf8), rtf: nil,
                                  improvingOn: "текст") == nil)
}

// MARK: - Which flavour is read

@Test func theHtmlFlavourIsPreferredOverTheRtfOne() {
    // Semantics over visuals: `<h2>` says «heading, level two» where RTF says «18 pt bold», and
    // `AttributedToMarkdown` lists what it has to guess for want of that.
    let html = Data("<h2>Из HTML</h2>".utf8)
    let rtf = rtfHeading(text: "Из RTF")
    #expect(RichMarkdown.markdown(html: html, rtf: rtf, improvingOn: "Из HTML")
                == "## Из HTML")
}

@Test func theRtfFlavourIsReadWhenThereIsNoHtmlOne() {
    let rtf = rtfHeading(text: "Report")
    let markdown = RichMarkdown.markdown(html: nil, rtf: rtf,
                                         improvingOn: "Plain body paragraph, long enough to set "
                                             + "the body size of this document.\nReport")
    #expect(markdown?.contains("## Report") == true)
}

@Test func theRtfFlavourIsReadWhenTheHtmlOneCannotBeUsed() {
    // Two ways the HTML half can fail — bytes that are not UTF-8, and a conversion the gate
    // refuses — and in both the RTF flavour still gets its turn. Without the fallthrough, an
    // application that writes both would lose its structure to whichever flavour was worse.
    let rtf = rtfHeading(text: "Report")
    let plain = "Plain body paragraph, long enough to set the body size of this document.\nReport"
    let notUTF8 = "<h1>Überschrift</h1>".data(using: .isoLatin1)!
    #expect(RichMarkdown.markdown(html: notUTF8, rtf: rtf, improvingOn: plain)?
        .contains("## Report") == true)
    let noGain = Data("<p>Plain body paragraph.</p>".utf8)
    #expect(RichMarkdown.markdown(html: noGain, rtf: rtf, improvingOn: plain)?
        .contains("## Report") == true)
}

@Test func noFlavoursAtAllIsNil() {
    #expect(RichMarkdown.markdown(html: nil, rtf: nil, improvingOn: "текст") == nil)
}

/// A small RTF document whose second paragraph is 18 pt against a 12 pt body — ×1.5, an h2 on
/// `AttributedToMarkdown`'s ladder. ASCII on purpose: an `\ansi` document escapes everything else,
/// and the encoding is not what these tests are about.
private func rtfHeading(text: String) -> Data {
    Data(#"""
        {\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Helvetica;}}
        \f0\fs24 Plain body paragraph, long enough to set the body size of this document.\par
        \b\fs36 \#(text)\b0\fs24\par
        }
        """#.utf8)
}
