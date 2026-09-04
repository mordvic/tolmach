// Tests/TranslatorAppTests/ChangeMarksPaneTests.swift
//
// The window's half of the change marks (spec #81, step 3): the pane's text view carrying
// them, the cursor selecting them, the status bar's line and the setting behind the picker.
import AppKit
import Foundation
import MarkupKit
import Testing
@testable import TranslationCore
@testable import TranslatorApp

/// The same TextKit 1 triple `RenderedMarkupTests` builds by hand — `NSTextTable` lives only
/// there, and `scrollableTextView()` would come up in TextKit 2.
@MainActor
private func scratchTextView() -> CodeBlockTextView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: 400,
                                                 height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    return CodeBlockTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                             textContainer: container)
}

/// A finished правка over the diff that ships, never a hand-built set: the pane, the marks
/// and the diff are tested as they run together.
private func proofreadFixture() -> (source: String, result: String, changes: ChangeSet) {
    let source = "# Отчет\n\nВысылаю вам отчет за август, посмотрите пожалуйста до пятницы."
    let result = "# Отчёт\n\nВысылаю вам отчёт за август, посмотрите, пожалуйста, до пятницы."
    return (source, result, TextDiff.changes(source: source, result: result))
}

private func outcome(final: String, changes: ChangeSet?, totalMS: Double) -> TranslationOutcome {
    TranslationOutcome(final: final, chunks: [], translatedChunks: [final],
                       documentGlossary: [], detectedSource: .ru, checks: [],
                       markupDiffs: [], markupNotCompared: false, stats: [],
                       timeToFirstTokenMS: 10, totalMS: totalMS,
                       documentGlossaryFailure: nil,
                       documentGlossaryAttempted: changes == nil, modelChunkCount: 1,
                       changes: changes)
}

// MARK: - The pane's text view

@MainActor
@Test func aFinishedProofreadIsUnderlinedInTheStorageAndItsStringStaysClean() {
    let (_, result, changes) = proofreadFixture()
    #expect(changes.count >= 2, "the fixture must carry changes for the pane to mark")
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, showsChangeDetail: false, to: view)
    let storage = view.textStorage!
    // «Результат»: attributes and nothing else — the string is the clean rendering's.
    let clean = MarkdownToAttributed.rendering(of: result,
                                               config: ContentFont.default.markdownConfig)
    #expect(storage.string == clean.attributed.string)
    // Every change the locator placed can be found again by its index, and slices out the
    // words the diff inserted. Mutation: `changes` not handed to `ChangeMarks.apply` → no key
    // anywhere, `located == 0`.
    var located = 0
    for index in changes.changes.indices {
        if let range = RenderedTextView.Coordinator.range(ofChange: index, in: view) {
            located += 1
            #expect((storage.string as NSString).substring(with: range)
                    == changes.changes[index].inserted)
        }
    }
    #expect(located == changes.count)
}

@MainActor
@Test func aPlainProseProofreadTakesTheRenderedViewAndCarriesItsMarks() {
    // No markup at all — the pane hosts the text view for the marks alone, through
    // `plainRendering`. Mutation: the plain path built from `plain()` without block ranges
    // → `ChangeMarks.apply` returns the rendering unmarked and no key is found.
    let source = "Превет, мир."
    let result = "Привет, мир."
    let changes = TextDiff.changes(source: source, result: result)
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: result, font: .default, rendersMarkup: false, isStreaming: false,
                      changes: changes, showsChangeDetail: false, to: view)
    #expect(view.textStorage?.string == result)
    let range = RenderedTextView.Coordinator.range(ofChange: 0, in: view)
    #expect(range.map { (result as NSString).substring(with: $0) } == "Привет")
}

@MainActor
@Test func flippingToChangesRebuildsTheStorageWithTheRemovedWordsInIt() {
    let (_, result, changes) = proofreadFixture()
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, showsChangeDetail: false, to: view)
    let resultLength = view.textStorage!.length
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, showsChangeDetail: true, to: view)
    let detailed = view.textStorage!
    // «Изменения» is a different document: longer by the struck-through words, which are
    // present as characters. Mutation: `showsChangeDetail` left out of `Mode` → the guard
    // sees the same mode, nothing is rebuilt, and the length does not move.
    #expect(detailed.length > resultLength)
    #expect(detailed.string.contains("Отчет"))
    #expect(detailed.string.contains("Отчёт"))
    var struck = false
    detailed.enumerateAttribute(.strikethroughStyle,
                                in: NSRange(location: 0, length: detailed.length)) { value, _, _ in
        if let value = value as? Int, value != 0 { struck = true }
    }
    #expect(struck)
}

@MainActor
@Test func theCursorSelectsTheChangeItNamesAndOnlyWhenItMoves() {
    let (_, result, changes) = proofreadFixture()
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, showsChangeDetail: false, to: view)
    coordinator.select(change: 1, in: view)
    let second = RenderedTextView.Coordinator.range(ofChange: 1, in: view)
    #expect(second != nil)
    #expect(view.selectedRange() == second)
    // The reader moves the selection by hand; the same cursor arriving again from a `body`
    // re-evaluation must not snatch it back. Mutation: the `index != selectedChange` guard
    // removed → the selection is reset to the change and this fails.
    view.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.select(change: 1, in: view)
    #expect(view.selectedRange() == NSRange(location: 0, length: 0))
    coordinator.select(change: 0, in: view)
    #expect(view.selectedRange() == RenderedTextView.Coordinator.range(ofChange: 0, in: view))
}

@MainActor
@Test func aRebuiltStorageForgetsWhichChangeWasSelected() {
    // After a rebuild (a new set, a detail flip) the cursor must land again even if its index
    // is unchanged — the range it pointed at is gone with the old storage. Mutation:
    // `selectedChange = nil` dropped from `reset` → the second `select` returns early and the
    // selection stays at the storage's start.
    let (_, result, changes) = proofreadFixture()
    let view = scratchTextView()
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, showsChangeDetail: false, to: view)
    coordinator.select(change: 0, in: view)
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, showsChangeDetail: true, to: view)
    view.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.select(change: 0, in: view)
    #expect(view.selectedRange() == RenderedTextView.Coordinator.range(ofChange: 0, in: view))
    #expect(view.selectedRange().length > 0)
}

// MARK: - The pane's rules

@MainActor
@Test func aChangeSetIsNeverHandedToTheTextViewWhileTheTextStreams() {
    // The pane passes `isRunning ? nil : changes`; pinned as the pane's own values read through
    // the same expression, because the `assert` in `apply` is invisible to a release build.
    let pane = TranslationPane(title: "Правка", text: "Привет", isRunning: true, onCopy: {},
                               changes: TextDiff.changes(source: "Превет", result: "Привет"))
    #expect(pane.changes != nil)
    #expect((pane.isRunning ? nil : pane.changes) == nil)
    let settled = TranslationPane(title: "Правка", text: "Привет", isRunning: false, onCopy: {},
                                  changes: pane.changes)
    #expect((settled.isRunning ? nil : settled.changes) != nil)
}

@MainActor
@Test func thePickerIsOfferedForAProofreadWithoutMarkupAndNotForAPlainTranslation() {
    #expect(TranslationPane.offersPicker(translationHasMarkup: false, sourceHasMarkup: false,
                                         hasChanges: true))
    // Mutation: `|| hasChanges` dropped → false here.
    #expect(!TranslationPane.offersPicker(translationHasMarkup: false, sourceHasMarkup: false,
                                          hasChanges: false))
    // Unchanged for перевод: markup on either side still offers it.
    #expect(TranslationPane.offersPicker(translationHasMarkup: false, sourceHasMarkup: true,
                                         hasChanges: false))
    #expect(TranslationPane.offersPicker(translationHasMarkup: true, sourceHasMarkup: false,
                                         hasChanges: false))
}

// MARK: - The status bar's line

@MainActor
@Test func theStatusBarsFinishedLinePutsTheChangeCountBeforeTheWarnings() {
    let changes = TextDiff.changes(source: "Превет, мир.", result: "Привет, мир.")
    let proofread = outcome(final: "Привет, мир.", changes: changes, totalMS: 1812)
    #expect(RunStatusBar.finishedLine(outcome: proofread, summary: "2 предупреждения")
            == "Готово за 1812 мс · 1 изменение · 2 предупреждения")
    #expect(RunStatusBar.finishedLine(outcome: proofread, summary: nil)
            == "Готово за 1812 мс · 1 изменение")
    // A translation's line is exactly what it was. Mutation: appending the summary for
    // `changes == nil` too → «· изменений нет» under every translation.
    let translation = outcome(final: "Hello.", changes: nil, totalMS: 400)
    #expect(RunStatusBar.finishedLine(outcome: translation, summary: nil) == "Готово за 400 мс")
    #expect(RunStatusBar.finishedLine(outcome: translation, summary: "1 предупреждение")
            == "Готово за 400 мс · 1 предупреждение")
}

@MainActor
@Test func aCleanProofreadSaysThereAreNoChangesAndABoundedOneSaysItWasNotCompared() {
    let clean = outcome(final: "Привет.", changes: ChangeSet(changes: [], blocks: [],
                                                           notCompared: nil), totalMS: 5)
    #expect(RunStatusBar.finishedLine(outcome: clean, summary: nil)
            == "Готово за 5 мс · изменений нет")
    let bounded = outcome(final: "Привет.",
                          changes: ChangeSet(changes: [], blocks: [],
                                             notCompared: .tooLong(tokens: 70_000)), totalMS: 5)
    #expect(RunStatusBar.finishedLine(outcome: bounded, summary: nil)
            == "Готово за 5 мс · " + RussianCopy.changesNotCompared)
}

// MARK: - The setting

@Test func theChangeDetailSettingDefaultsToOffAndSurvivesAReload() {
    let defaults = InMemoryDefaults(prefix: "change-detail")
    #expect(AppSettings(defaults: defaults).showsChangeDetail == false)
    AppSettings(defaults: defaults).showsChangeDetail = true
    // A second instance over the same store: the *stored* value, not a remembered property.
    #expect(AppSettings(defaults: defaults).showsChangeDetail)
    #expect(defaults.object(forKey: "showsChangeDetail") as? Bool == true)
}

@Test func theChangeDetailSettingIsObservable() {
    // The hand-written `access`/`withMutation` pair: without it the picker writes the store
    // and redraws nothing.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "change-detail-obs"))
    final class Flag: @unchecked Sendable { var raised = false }
    let observed = Flag()
    withObservationTracking { _ = settings.showsChangeDetail } onChange: { observed.raised = true }
    settings.showsChangeDetail = true
    #expect(observed.raised)
}
