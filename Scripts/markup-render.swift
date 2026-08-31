// Scripts/markup-render.swift
//
// Every measurement behind `docs/design/specs/2026-08-31-formatting-design.md`.
//
//     swiftc -O -o /tmp/mr Scripts/markup-render.swift && /tmp/mr
//
// Compiled rather than interpreted, for `content-font.swift`'s reason: the interpreter cannot
// JIT the availability check SwiftUI emits.
//
// Six questions, none of which should be answered from memory:
//
//  1. **What Foundation's own Markdown parser understands** under `interpretedSyntax: .full`.
//     The answer decides how much of a parser this project has to write, and it turned out to
//     be less than expected — GFM tables with per-column alignment included.
//  2. **Whether that parse is lossless.** It is not, and that single fact is why the design
//     keeps a Markdown string as the pipeline's only representation.
//  3. **What it does with an indent**, which is the one place its reading contradicts this
//     pipeline's own rule that indented text is prose.
//  4. **What half-arrived markup parses as** — the streaming rule's raw material.
//  5. **Which of these intents SwiftUI's `Text` actually renders.** Inline yes, block no; so
//     inline markup is free and the block layer is ours.
//  6. **Whether AppKit can carry the rich round trip** — HTML in, RTF/HTML out, and a table
//     that lays out rather than flattening.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let full = AttributedString.MarkdownParsingOptions(
    allowsExtendedAttributes: true, interpretedSyntax: .full,
    failurePolicy: .returnPartiallyParsedIfPossible)
let inlineOnly = AttributedString.MarkdownParsingOptions(
    allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace,
    failurePolicy: .returnPartiallyParsedIfPossible)

func kinds(_ text: String, _ options: AttributedString.MarkdownParsingOptions) -> [String] {
    guard let parsed = try? AttributedString(markdown: text, options: options) else { return ["ERROR"] }
    return parsed.runs.compactMap { run in
        run.presentationIntent?.components.first.map { "\($0.kind)" }
    }
}

// MARK: - 1. What `.full` understands

print("=== 1. what `.full` understands ===")
let sample = """
# Заголовок 1

Абзац с **жирным**, *курсивом* и `кодом`, ссылка [тут](https://x.org).

- пункт один
  - вложенный

1. первый

> цитата

| Колонка | Значение |
|:---|---:|
| a | 1 |

```swift
let x = 1
```

Конец  
после жёсткого переноса.
"""
if let parsed = try? AttributedString(markdown: sample, options: full) {
    for run in parsed.runs {
        let text = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\\n")
        var notes: [String] = []
        if let intent = run.presentationIntent {
            notes.append(intent.components.map { "\($0.kind)" }.joined(separator: " / "))
        }
        if let inline = run.inlinePresentationIntent { notes.append("inline \(inline.rawValue)") }
        if let link = run.link { notes.append("link \(link)") }
        print("  \(text.prefix(44).debugDescription.padding(toLength: 46, withPad: " ", startingAt: 0)) \(notes.joined(separator: "  "))")
    }
}

// MARK: - 2. Losslessness

print("=== 2. is the parse lossless? ===")
let soft = "Строка один\nСтрока два в том же абзаце\n\nВторой абзац"
for (name, options) in [("full", full), ("inlineOnlyPreservingWhitespace", inlineOnly)] {
    let out = (try? AttributedString(markdown: soft, options: options)).map { String($0.characters) } ?? "ERROR"
    print("  \(name.padding(toLength: 32, withPad: " ", startingAt: 0)) \(out.debugDescription)")
    print("  \(String(repeating: " ", count: 32)) lossless: \(out == soft)")
}

// MARK: - 3. Indentation

print("=== 3. an indent is prose in this pipeline — what does `.full` call it? ===")
for text in ["Абзац:\n\n    отступ на четыре пробела\n\nещё абзац",
             "Цитата письма:\n\n    > Здравствуйте, коллеги",
             "- пункт\n\n    продолжение пункта"] {
    print("  \(text.debugDescription.prefix(48))\n    -> \(kinds(text, full))")
}

// MARK: - 4. Half-arrived markup

print("=== 4. what a stream's tail parses as ===")
for text in ["Текст с **незакрытым жирным", "```swift\nlet x = 1", "| a | b |\n|---|",
             "Цена 5 * 3 = 15, файл a_b_c.txt и #хэштег"] {
    let out = (try? AttributedString(markdown: text, options: full)).map { String($0.characters) } ?? "ERROR"
    print("  \(text.debugDescription.prefix(34).padding(toLength: 36, withPad: " ", startingAt: 0)) \(kinds(text, full))  chars=\(out.debugDescription.prefix(46))")
}
print("  a fence handed to the inline parser (never done — a codeBlock is emitted from source bytes):")
print("    \(kinds("```swift\nlet x = 1\n```", inlineOnly)) inline-intents=\((try? AttributedString(markdown: "```swift\nlet x = 1\n```", options: inlineOnly))?.runs.compactMap { $0.inlinePresentationIntent?.rawValue } ?? [])")

// MARK: - 5. What SwiftUI renders

@MainActor func ideal<V: View>(_ view: V) -> CGSize {
    let host = NSHostingController(rootView: view)
    host.view.layoutSubtreeIfNeeded()
    return host.view.fittingSize
}

@MainActor func rendered<V: View>(_ view: V) -> [UInt8] {
    let renderer = ImageRenderer(content: view.frame(width: 200, height: 30))
    renderer.scale = 2
    guard let image = renderer.cgImage, let data = image.dataProvider?.data as Data? else { return [] }
    return Array(data)
}

@MainActor func swiftUIIntents() {
    print("=== 5. which intents does SwiftUI's `Text` render? ===")
    let word = "слово слово слово"
    let plain = try! AttributedString(markdown: word, options: full)
    let cases: [(String, AttributedString)] = [
        ("plain", plain),
        ("**bold**", try! AttributedString(markdown: "**\(word)**", options: full)),
        ("*italic*", try! AttributedString(markdown: "*\(word)*", options: full)),
        ("`code`", try! AttributedString(markdown: "`\(word)`", options: full)),
        ("# heading (block)", try! AttributedString(markdown: "# \(word)", options: full)),
    ]
    let plainPixels = rendered(Text(plain).font(.system(size: 13)))
    for (name, value) in cases {
        let size = ideal(Text(value).font(.system(size: 13)))
        let differs = rendered(Text(value).font(.system(size: 13))) != plainPixels
        print("  \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(size)  differs from plain: \(differs)")
    }
    print("  -> inline intents are honoured; the block intent renders identically to plain,")
    print("     so headings, lists, quotes, tables and code blocks are ours to lay out.")
}
MainActor.assumeIsolated { swiftUIIntents() }

// MARK: - 6. The rich round trip

print("=== 6. AppKit's rich round trip ===")
let html = """
<meta charset="utf-8"><h2>Заголовок</h2><p>Абзац с <b>жирным</b> и <i>курсивом</i>, а также <code>кодом</code>.</p>
<ul><li>пункт один</li><li>пункт два</li></ul>
<table><tr><th>Колонка</th><th>Значение</th></tr><tr><td>a</td><td>1</td></tr></table>
<pre><code>let x = 1</code></pre>
"""
if let data = html.data(using: .utf8) {
    let started = Date()
    let imported = try? NSAttributedString(
        data: data,
        options: [.documentType: NSAttributedString.DocumentType.html,
                  .characterEncoding: String.Encoding.utf8.rawValue],
        documentAttributes: nil)
    if let imported {
        print("  html -> NSAttributedString in \(Int(Date().timeIntervalSince(started) * 1000)) ms (first call; warm is ~4× faster)")
        print("  the semantics AppKit keeps — none of them a heading *level*:")
        imported.enumerateAttributes(in: NSRange(location: 0, length: imported.length)) { attrs, range, _ in
            var notes: [String] = []
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                notes.append("\(Int(font.pointSize))pt \(font.familyName ?? "?")"
                    + (traits.contains(.boldFontMask) ? " bold" : "")
                    + (traits.contains(.italicFontMask) ? " italic" : ""))
            }
            if let style = attrs[.paragraphStyle] as? NSParagraphStyle {
                if !style.textLists.isEmpty { notes.append("textList ×\(style.textLists.count)") }
                if let block = style.textBlocks.first as? NSTextTableBlock {
                    notes.append("table r\(block.startingRow)c\(block.startingColumn)")
                }
            }
            let text = (imported.string as NSString).substring(with: range)
            print("    \(text.debugDescription.prefix(24).padding(toLength: 26, withPad: " ", startingAt: 0)) \(notes.joined(separator: ", "))")
        }
        let whole = NSRange(location: 0, length: imported.length)
        print("  out: rtf \(imported.rtf(from: whole, documentAttributes: [:])?.count ?? -1) bytes, "
            + "html \((try? imported.data(from: whole, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]))?.count ?? -1) bytes")
    }
}

// A hand-built table, the shape `MarkupKit.MarkdownToAttributed` will produce.
let table = NSTextTable()
table.numberOfColumns = 2
let document = NSMutableAttributedString()
for (rowIndex, row) in [["Колонка", "Значение"], ["a", "1"]].enumerated() {
    for (columnIndex, cell) in row.enumerated() {
        let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                     startingColumn: columnIndex, columnSpan: 1)
        block.setBorderColor(.separatorColor)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(4, type: .absoluteValueType, for: .padding)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        document.append(NSAttributedString(string: cell + "\n",
                                           attributes: [.paragraphStyle: style,
                                                        .font: NSFont.systemFont(ofSize: 13)]))
    }
}
let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
view.isEditable = false
view.textStorage?.setAttributedString(document)
// Touching `layoutManager` is what puts the view in TextKit 1 compatibility mode — which is
// where `NSTextTable` lives. A TextKit 2 text view has no table support to measure.
view.layoutManager?.ensureLayout(for: view.textContainer!)
print("  a 2×2 NSTextTable lays out at \(view.layoutManager?.usedRect(for: view.textContainer!) ?? .zero)")
print("  and copies as \(document.rtf(from: NSRange(location: 0, length: document.length), documentAttributes: [:])?.count ?? -1) bytes of rtf")

// MARK: - Cost

print("=== cost of a whole-document parse (the streaming rule's reason) ===")
let big = String(repeating: "## Заголовок\n\nАбзац с **жирным** и `кодом`.\n\n- пункт\n- пункт\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n",
                 count: 700)
print("  \(big.utf8.count) bytes:")
for _ in 0..<3 {
    let started = Date()
    let parsed = try? AttributedString(markdown: big, options: full)
    print("    \(parsed?.runs.count ?? -1) runs in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
}
