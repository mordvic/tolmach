import Foundation
import Testing
import TranslationCore
@testable import TranslatorApp

private let dir = URL(fileURLWithPath: "/tmp/does-not-need-to-exist")

@Test func theTargetLanguageCodeIsInsertedBeforeTheExtension() {
    let out = OutputNaming.destination(for: dir.appendingPathComponent("techdoc-en.md"),
                                       target: .ru, exists: { _ in false })
    #expect(out.lastPathComponent == "techdoc-en.ru.md")
}

@Test func aFileWithNoExtensionGetsTheCodeAppended() {
    let out = OutputNaming.destination(for: dir.appendingPathComponent("README"),
                                       target: .de, exists: { _ in false })
    #expect(out.lastPathComponent == "README.de")
}

@Test func anOccupiedNameTakesTheNextFreeNumberRatherThanOverwriting() {
    let taken: Set<String> = ["techdoc-en.ru.md", "techdoc-en.ru 2.md"]
    let out = OutputNaming.destination(for: dir.appendingPathComponent("techdoc-en.md"),
                                       target: .ru,
                                       exists: { taken.contains($0.lastPathComponent) })
    #expect(out.lastPathComponent == "techdoc-en.ru 3.md")
}

@Test func theTranslationLandsBesideItsSourceAndNowhereElse() {
    let source = URL(fileURLWithPath: "/Users/someone/Documents/notes/article-en.markdown")
    let out = OutputNaming.destination(for: source, target: .en, exists: { _ in false })
    #expect(out.deletingLastPathComponent() == source.deletingLastPathComponent())
    #expect(out.lastPathComponent == "article-en.en.markdown")
}

@Test func aDottedStemKeepsEveryDotButTheLast() {
    // «v1.2.notes.md» is one file, not a stem with three extensions. Splitting on the
    // first dot would produce «v1.ru.2.notes.md», which is a different document's name.
    let out = OutputNaming.destination(for: dir.appendingPathComponent("v1.2.notes.md"),
                                       target: .ru, exists: { _ in false })
    #expect(out.lastPathComponent == "v1.2.notes.ru.md")
}
