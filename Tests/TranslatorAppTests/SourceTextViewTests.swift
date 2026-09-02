import AppKit
import Testing
@testable import TranslatorApp

/// A pasteboard of its own for each test, never `.general`: the tests must not touch the
/// user's clipboard, and two tests on one named board would race each other.
@MainActor
private func board() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.paste.\(UUID().uuidString)"))
}

@MainActor
private func write(plain: String, html: String? = nil, rtf: Data? = nil,
                   to board: NSPasteboard) {
    board.clearContents()
    board.setString(plain, forType: .string)
    if let html { board.setData(Data(html.utf8), forType: .html) }
    if let rtf { board.setData(rtf, forType: .rtf) }
}

/// The reason the editor has a paste of its own: a table copied out of a browser arrives on
/// the pasteboard twice — flat in `.string`, whole in `.html` — and the plain flavour alone
/// is what every `TextEditor` pastes. The исходник pane reads the rich flavour through the
/// same gate the hotkey uses, so the two entry points cannot come to disagree about what a
/// selection «is».
@Test @MainActor func pastingAnHTMLTableLandsAsAMarkdownTable() {
    let view = SourceTextView.make()
    let pasteboard = board()
    write(plain: "Папка\nРепозиторий\n/nova\nprofile-nova",
          html: "<table><tr><th>Папка</th><th>Репозиторий</th></tr>"
              + "<tr><td>/nova</td><td>profile-nova</td></tr></table>",
          to: pasteboard)

    view.pasteRich(from: pasteboard)

    #expect(view.string == "| Папка | Репозиторий |\n| --- | --- |\n| /nova | profile-nova |")
}

/// The no-op half of the gate, seen from the editor: a user pasting their own Markdown gets
/// their own bytes, whatever HTML the source application put beside them.
@Test @MainActor func pastingMarkdownThatAlreadyHasTheStructureKeepsThePlainBytes() {
    let view = SourceTextView.make()
    let pasteboard = board()
    write(plain: "- раз\n- два\n- три", html: "<ul><li>раз</li><li>два</li><li>три</li></ul>",
          to: pasteboard)

    view.pasteRich(from: pasteboard)

    #expect(view.string == "- раз\n- два\n- три")
}

/// Emphasis alone never opens the gate — the models are measurably worst with it — so a
/// paste whose only rich gain is a bold run pastes plain.
@Test @MainActor func aPasteWhoseOnlyGainIsBoldPastesThePlainFlavour() {
    let view = SourceTextView.make()
    let pasteboard = board()
    write(plain: "Совсем жирный текст", html: "<p>Совсем <b>жирный</b> текст</p>",
          to: pasteboard)

    view.pasteRich(from: pasteboard)

    #expect(view.string == "Совсем жирный текст")
}

/// A paste replaces the selection, as every paste does; the rich read must not turn it into
/// an append.
@Test @MainActor func aRichPasteReplacesTheSelectionLikeAnyPaste() {
    let view = SourceTextView.make()
    view.string = "Начало СТАРОЕ конец"
    view.setSelectedRange(NSRange(location: 7, length: 6))
    let pasteboard = board()
    write(plain: "Заголовок\nтекст", html: "<h1>Заголовок</h1><p>текст</p>", to: pasteboard)

    view.pasteRich(from: pasteboard)

    #expect(view.string == "Начало # Заголовок\n\nтекст конец")
}

/// A file dropped on the pane belongs to the pane's own drop destination — `DroppedDocument`
/// decides what is read out of it. A text view registers for file URLs by default and would
/// take the drop first, inserting the path as text.
@Test @MainActor func theEditorLeavesFileDropsToThePane() {
    let view = SourceTextView.make()
    #expect(!view.registeredDraggedTypes.contains(.fileURL))
    #expect(view.registeredDraggedTypes.contains(.string))
}
