// Tests/TranslatorAppTests/PanelChangeMarksTests.swift
//
// The panel's half of the change marks (spec #81, step 4): when the reply becomes a document,
// what «Вид» offers and points at, what the marked rendering costs in height, what the panel
// copies, and the floor a hand-drag may not go below now that a finished правка pins a summary
// row and three menus.
import Testing
import AppKit
import Foundation
import SwiftUI
@testable import MarkupKit
@testable import TranslatorApp
@testable import TranslationCore
@testable import TextCapture

// MARK: - «Вид», as a value

/// The six (flag, flag, set) combinations the menu can be in, and the three it may point at.
///
/// A table rather than three lookups, so it fails in both directions — an item that stops being
/// reachable and one that becomes reachable when it should not. Mutations watched: `current`
/// ignoring `showsOriginal` (rows 3 and 6 fail), ignoring `hasChanges` (row 2), and
/// `items(hasChanges:)` answering `allCases` unconditionally (the count assertion).
@Test func theViewMenuOffersAndPointsAtWhatTheTwoFlagsDescribe() {
    #expect(PanelReplyView.current(showsOriginal: false, showsChangeDetail: false,
                                   hasChanges: true) == .result)
    // A `true` left over from an earlier правка must not point the menu at an item it does not
    // draw — the same rule that takes the item away below.
    #expect(PanelReplyView.current(showsOriginal: false, showsChangeDetail: true,
                                   hasChanges: false) == .result)
    #expect(PanelReplyView.current(showsOriginal: false, showsChangeDetail: true,
                                   hasChanges: true) == .changes)
    #expect(PanelReplyView.current(showsOriginal: true, showsChangeDetail: false,
                                   hasChanges: true) == .original)
    #expect(PanelReplyView.current(showsOriginal: true, showsChangeDetail: true,
                                   hasChanges: true) == .original)
    #expect(PanelReplyView.current(showsOriginal: true, showsChangeDetail: false,
                                   hasChanges: false) == .original)

    // «изменения» draws the same document «результат» does when nothing changed, so the item is
    // dropped rather than left to snap back the moment it is chosen.
    #expect(PanelReplyView.items(hasChanges: true) == [.result, .changes, .original])
    #expect(PanelReplyView.items(hasChanges: false) == [.result, .original])
    // Every item the menu offers must be one `current` can answer, or the picker has a
    // selection outside its own list.
    for item in PanelReplyView.items(hasChanges: true) {
        let writes = item.writes
        #expect(PanelReplyView.current(showsOriginal: writes.showsOriginal,
                                       showsChangeDetail: writes.showsChangeDetail ?? true,
                                       hasChanges: true) == item)
    }
}

/// «оригинал» is the one item that leaves a setting alone, and the whole point is that a reader
/// comes back to the view they left. Mutation: `.original` writing `false` fails the last line.
@Test func onlyTheOriginalLeavesTheDetailSettingWhereItWas() {
    #expect(PanelReplyView.result.writes.showsChangeDetail == false)
    #expect(PanelReplyView.changes.writes.showsChangeDetail == true)
    #expect(PanelReplyView.original.writes.showsChangeDetail == nil)
    #expect(PanelReplyView.original.writes.showsOriginal)
    #expect(PanelReplyView.result.writes.showsOriginal == false)
    #expect(PanelReplyView.changes.writes.showsOriginal == false)
}

/// The three labels, and the one that carries the reason the type exists: «оригинал» and never
/// «исходник», which already names the raw form of a pane one control away in the window.
@Test func theViewMenusLabelsAreRussianAndDoNotSayIskhodnik() {
    #expect(PanelReplyView.result.russianName == "результат")
    #expect(PanelReplyView.changes.russianName == "изменения")
    #expect(PanelReplyView.original.russianName == "оригинал")
    #expect(!PanelReplyView.allCases.contains { $0.russianName.lowercased().contains("исходник") })
}

// MARK: - The panel's summary sentence

/// The panel's row stands alone, so it is capitalised; the window's sits after «Готово за N мс ·
/// », so it is not. Both count through `changeCount`, which is why the declension is asserted
/// here against the window's own function rather than against three more literals.
///
/// Mutations watched: `proofreadSummary` prefixing «Исправлено: » unconditionally (the clean and
/// bounded lines fail), and `capitalised` written as `.capitalized` (the bounded line comes back
/// «Изменения Не Отмечены — Текст Слишком Длинный»).
@Test func theSummarySentenceCapitalisesTheWindowsOwnFragment() {
    func set(_ count: Int, notCompared: ChangeSet.NotComparedReason? = nil) -> ChangeSet {
        ChangeSet(changes: (0..<count).map {
            TextChange(scope: .words, block: 0, insertedTokens: $0..<($0 + 1),
                       removed: "было", inserted: "стало")
        }, blocks: [], notCompared: notCompared)
    }

    #expect(RussianCopy.proofreadSummary(set(1)) == "Исправлено: 1 изменение")
    #expect(RussianCopy.proofreadSummary(set(2)) == "Исправлено: 2 изменения")
    #expect(RussianCopy.proofreadSummary(set(6)) == "Исправлено: 6 изменений")
    // Zero is the whole answer to a clean «только ошибки» run, and «Исправлено: изменений нет»
    // would claim work that was not done.
    #expect(RussianCopy.proofreadSummary(set(0)) == "Изменений нет")
    #expect(RussianCopy.proofreadSummary(set(0, notCompared: .tooLong(tokens: 71_204)))
            == "Изменения не отмечены — текст слишком длинный")
    // And the window's own fragment is untouched — one builder, two capitalisations.
    #expect(RussianCopy.changeSummary(set(6)) == "6 изменений")
}

// MARK: - When the panel renders

/// A правка's marks are attributes, and a `Text` carries none of them — so the two settings that
/// decide *how* the reply is drawn may not decide *whether* the changes are visible.
///
/// Each line dies under a different mutation: dropping the `hasChanges` clause fails the first
/// two, hoisting it above the `awaitingRun`/`.running` guard fails the last two, and leaving the
/// `showsRenderedMarkup` guard in front of it fails the second.
@Test func aFinishedProofreadIsADocumentWhateverTheMarkupSettingsSay() {
    let prose = "Обычная проза, где 5 * 3 = 15 и файл a_b_c.txt ничего не размечают."

    // Prose, with no `**` anywhere in it: rendered because the underlines need a text view.
    #expect(PanelView.rendersFinalReply(state: .finished, awaitingRun: false, text: prose,
                                        showsRenderedMarkup: true, hasChanges: true))
    // …and «Исходник» does not take the marks away either. That setting says how the text is
    // drawn, not whether the правка is described.
    #expect(PanelView.rendersFinalReply(state: .finished, awaitingRun: false, text: prose,
                                        showsRenderedMarkup: false, hasChanges: true))
    // The two gates that still outrank it. A stream is plain characters — the marks are located
    // against a settled document and the panel is measured against a moving one — and
    // `awaitingRun` is the window in which the panel is sized against the invisible reservation.
    #expect(PanelView.rendersFinalReply(state: .running, awaitingRun: false, text: prose,
                                        showsRenderedMarkup: true, hasChanges: true) == false)
    #expect(PanelView.rendersFinalReply(state: .finished, awaitingRun: true, text: prose,
                                        showsRenderedMarkup: true, hasChanges: true) == false)
    // Without a set the rule is what it always was, byte for byte: prose stays a `Text`.
    #expect(PanelView.rendersFinalReply(state: .finished, awaitingRun: false, text: prose,
                                        showsRenderedMarkup: true) == false)
}

// MARK: - What the marked rendering costs

/// A real change set over a real source and result, through the shipped `TextDiff` — nothing
/// hand-built, so the fixture cannot drift away from what the engine produces.
private let markSource = """
    Превет мир. Как дила?

    Второй абзац написан с ошибкай, которую правка исправляет, и он нарочно длинный: \
    на панели в триста пунктов он переносится на несколько строк, так что вычеркнутые \
    слова обязаны стоить высоты, а не помещаться в тот же ряд.

    Третий абзац здесь совершенно иной.
    """
private let markResult = """
    Привет, мир. Как дела?

    Второй абзац написан с ошибкой, которую правка исправляет, и он нарочно длинный: \
    на панели в триста пунктов он переносится на несколько строк, так что вычеркнутые \
    слова обязаны стоить высоты, а не помещаться в тот же ряд.

    Его переписали другими словами, целиком и от начала до конца.
    """

/// A one-line правка — the fixture the floor is measured against, because the figures in
/// `PanelSizer`'s tables are what the panel *pins* and a longer reply would fold its own
/// wrapping into them.
private let floorSource = "Превет мир. Как дила?"
private let floorResult = "Привет, мир. Как дела?"

/// «Изменения» is a different *document*, not a differently-coloured one: the removed words are
/// characters spliced into the storage. So it can never be shorter than «Результат» at the same
/// width, and the panel — whose height comes from `sizeThatFits` on this very rendering — has to
/// be measured against the one it is showing.
///
/// Mutation: `RenderedReplyView.rendering(_:)` ignoring `detail` (the two heights become equal
/// and the strict `>` fails) or ignoring `changes` (the marked string equals the clean one).
@MainActor
@Test func theChangesViewIsNeverShorterThanTheResultViewAtTheSameWidth() {
    let changes = TextDiff.changes(source: markSource, result: markResult)
    #expect(changes.count > 0, "the fixture must actually change something")
    let config = MarkdownFontConfig(baseSize: 13)

    // Through the coordinator the view actually asks, rather than through `ChangeMarks.apply`
    // beside it: the memo the panel is measured from is keyed on the whole tuple, and a key that
    // dropped `detail` would answer the «Изменения» fit with the «Результат» rendering — the
    // shape `docs/reference/TESTING.md` calls testing the builder while claiming the wiring.
    // One coordinator for both calls, so a stale memo would show up here.
    let coordinator = RenderedReplyView.Coordinator()
    let clean = MarkdownToAttributed.plainRendering(of: markResult, config: config)
    let result = coordinator.rendering(of: markResult, config: config, rendersMarkup: false,
                                       changes: changes, detail: .result)
    let detail = coordinator.rendering(of: markResult, config: config, rendersMarkup: false,
                                       changes: changes, detail: .changes)

    // The underlines cost no characters; the deletions do.
    #expect(result.attributed.string == clean.attributed.string)
    #expect(detail.attributed.length > result.attributed.length)

    for width in [CGFloat(300), 430, 560] {
        let resultHeight = RenderedReplyView.measuredSize(of: result.attributed, width: width).height
        let detailHeight = RenderedReplyView.measuredSize(of: detail.attributed, width: width).height
        #expect(detailHeight >= resultHeight,
                "at \(width) pt «изменения» measured \(detailHeight) against «результат» \(resultHeight)")
    }
    // Strictly taller at the narrowest width, which is the half `>=` alone would not catch —
    // and it is the fixture's **third** paragraph that buys it: rewritten past the density
    // threshold, it is one `.block` change, and a block removal is spliced in as a paragraph of
    // its own. Word-level changes alone tie here, measured: the first two paragraphs on their
    // own come out 64 pt with the deletions and 64 without at 300 pt, because eight extra
    // characters do not always push a wrap. That is why the fixture carries all three shapes.
    #expect(RenderedReplyView.measuredSize(of: detail.attributed, width: 300).height
            > RenderedReplyView.measuredSize(of: result.attributed, width: 300).height)
}

/// The marks reach a **plain** reply, which is the case the panel gains at this step: prose with
/// no markup used to be drawn as characters and now goes through `plainRendering` so the
/// underlines have a storage to live in.
///
/// Mutation: `Coordinator.rendering` calling `rendering(of:)` unconditionally — the raw text is
/// then parsed as Markdown and the block ranges no longer match the projection, so the alignment
/// refuses and no `changeKey` run survives.
@MainActor
@Test func aProseReplyCarriesItsMarksThroughThePlainRenderingPath() {
    let changes = TextDiff.changes(source: markSource, result: markResult)
    let config = MarkdownFontConfig(baseSize: 13)
    // `rendersMarkup: false` is what `PanelView` passes for prose, and the coordinator is where
    // the two lines that answer it live.
    let marked = RenderedReplyView.Coordinator()
        .rendering(of: markResult, config: config, rendersMarkup: false,
                   changes: changes, detail: .result)
    var marks = 0
    marked.attributed.enumerateAttribute(ChangeMarks.changeKey,
                                         in: NSRange(location: 0, length: marked.attributed.length)) {
        value, _, _ in if value != nil { marks += 1 }
    }
    #expect(marks > 0, "a prose правка's changes have to be locatable in the plain rendering")
}

/// «оригинал» draws the source and is **never** marked, whichever detail the setting is on.
///
/// The mark set names blocks and tokens of the *result*; over the source those indices point at
/// whatever words happen to sit at the same offsets, so a mark drawn there would be a claim
/// about the wrong text. The view drops the set itself rather than trusting the caller to,
/// which is what this pins — `PanelView` hands one over unconditionally.
///
/// Mutation: `marks` written as `changes` fails the third line; `shown` written as `text` fails
/// the second.
@MainActor
@Test func theOriginalViewDrawsTheSourceAndCarriesNoMarks() {
    let changes = TextDiff.changes(source: markSource, result: markResult)
    let marked = RenderedReplyView(text: markResult, font: .default, changes: changes,
                                   showsChangeDetail: true)
    #expect(marked.shown == markResult)
    #expect(marked.marks == changes)
    #expect(marked.detail == .changes)

    let original = RenderedReplyView(text: markResult, font: .default, changes: changes,
                                     showsChangeDetail: true, original: markSource)
    #expect(original.shown == markSource)
    #expect(original.marks == nil)
}

/// …and the panel decides *when* «оригинал» is what the reply area shows, which is not the same
/// question as which item the menu points at.
///
/// A run in flight is the case the flag alone gets wrong: «Вид» is disabled during one, but the
/// choice survives a «Повторить», which re-runs the same selection without clearing it. The
/// arriving reply has to be what streams, or the panel shows the old source while the new answer
/// lands invisibly behind it. Mutation: dropping `!awaitingReply` fails the last two lines.
@Test func theOriginalIsShownOnlyWhileNoRunIsInFlight() {
    #expect(PanelView.shownOriginal(view: .original, awaitingReply: false, source: "исходник")
            == "исходник")
    #expect(PanelView.shownOriginal(view: .result, awaitingReply: false, source: "исходник") == nil)
    #expect(PanelView.shownOriginal(view: .changes, awaitingReply: false, source: "исходник") == nil)
    #expect(PanelView.shownOriginal(view: .original, awaitingReply: true, source: "исходник") == nil)
    #expect(PanelView.shownOriginal(view: .result, awaitingReply: true, source: "исходник") == nil)
}

// MARK: - What «Скопировать» carries

/// Story 10: a правка never arrives in Word wearing review marks — and by construction rather
/// than by a condition someone has to remember. `PanelView.richFlavour` takes no change set at
/// all; it goes to `PaneRendering`, which builds the clean document.
///
/// Asserted as byte equality against the same text with no правка in sight, because «no
/// underlines» is not something an RTF blob can be asked directly. Mutation: threading a set
/// into `richFlavour` and marking the rendering makes the two differ.
@Test func theRichFlavourIsTheCleanDocumentWhateverAProofreadFound() {
    let markup = "## Заголовок\n\n**жирный** абзац с ошибкой."
    let changes = TextDiff.changes(source: "## Заголовок\n\n**жирный** абзац с ошибкай.",
                                   result: markup)
    #expect(changes.count > 0)

    let flavour = PanelView.richFlavour(text: markup, rendersFinalReply: true,
                                        showsRenderedMarkup: true, font: .default)
    #expect(flavour != nil)
    // The same call is the only one there is: no overload takes a change set, so this is the
    // byte sequence a marked panel copies too.
    #expect(flavour == PanelView.richFlavour(text: markup, rendersFinalReply: true,
                                             showsRenderedMarkup: true, font: .default))
    if let flavour {
        let rtf = String(decoding: flavour, as: UTF8.self)
        #expect(!rtf.contains("\\strike"), "a struck-through deletion must never reach the pasteboard")
    }
}

// MARK: - The floor, through the real view

/// A client that is never asked for anything — `TranslationPanelTests`' stand-in, for the same
/// reason: what is measured here is geometry.
private final class SilentPanelClient: LLMClient, @unchecked Sendable {
    func chat(messages: [ChatMessage],
              options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// A finished правка, run for real through `QueueClient` so its outcome carries the change set
/// `TextDiff` actually produces. `.errorsAndStyle` because that is the степень under which
/// «Ещё вариант» appears, and the button row is the widest thing in this state.
@MainActor
private func finishedProofreadModel() async -> TranslationViewModel {
    let model = TranslationViewModel(
        translator: Translator(client: QueueClient(replies: [floorResult])),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "panel-marks")),
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-marks-\(UUID().uuidString).json")),
        pasteboard: NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.marks.\(UUID().uuidString)")))
    model.sourceText = floorSource
    model.operation = .proofread
    model.proofreadingLevelOverride = .errorsAndStyle
    await model.run()
    return model
}

/// The two questions `PanelController.measure` asks, of the real `PanelView` in the `.measured`
/// variant — the same shape the sizing tests in `TranslationPanelTests` drive through the
/// controller, taken directly here because the numbers wanted are the ones *below* the floors
/// the controller would apply.
@MainActor
private func measured(_ view: some View, at width: CGFloat) -> (ideal: CGFloat, height: CGFloat) {
    let host = NSHostingController(rootView: AnyView(view))
    // Load-bearing, and for the reason `PanelController.measure` records: a host that has not
    // been laid out answers with whatever it was last asked, and this content reaches it through
    // observation on an `@Observable` model.
    host.view.layoutSubtreeIfNeeded()
    return (host.view.fittingSize.width,
            host.sizeThatFits(in: CGSize(width: width,
                                         height: CGFloat.greatestFiniteMagnitude)).height)
}

/// Measurement item 5: what a finished правка pins, now that it carries a summary row and three
/// menus, and whether a hand-drag can put it off the frame.
///
/// The figures are asserted rather than bounded — `PanelSizer`'s tables are what this replaces,
/// and a bound would let the row silently double. ±2 pt for the reason
/// `theRenderedReplyMeasuresTheHeightsTheProbeTookAtEachPanelWidth` gives: these are sums of
/// system-font metrics and a font revision may move a line height by a fraction, while anything
/// larger is a real change and should fail.
///
/// Mutation: dropping the summary row from `status(for:)` takes 145 to 121 and 179 to 155, and
/// both assertions fail — which is the point, since 179 is the number `dragMinHeight` is now.
@MainActor
@Test func aFinishedProofreadPinsWhatTheDragFloorPromisesToKeepOnScreen() async {
    let model = await finishedProofreadModel()
    #expect(model.state == .finished)
    #expect(model.changes != nil, "the fixture must produce the set the summary row reports")

    let plain = measured(PanelView(model: model, selection: .text(CapturedSelection(plain: floorSource)),
                                   adoptionRefusal: nil, fillsPanel: false), at: 300)
    #expect(abs(plain.height - 145) <= 2, "finished правка at 300 pt measured \(plain.height)")
    #expect(plain.height <= PanelSizer.dragMinHeight)

    // The state the floor is set from: the main window already translating when the shortcut is
    // pressed adds one pinned caption under the button row, and nothing there scrolls.
    let busy = measured(PanelView(model: model, selection: .text(CapturedSelection(plain: floorSource)),
                                  adoptionRefusal: .targetBusy, fillsPanel: false), at: 300)
    #expect(abs(busy.height - 179) <= 2, "finished правка + «окно занято» measured \(busy.height)")
    #expect(busy.height <= PanelSizer.dragMinHeight)
    #expect(PanelSizer.dragMinHeight == 179)

    // Measurement item 4's other half: the степень/стиль/вид row is 331 + 28 = 359 pt wide, and
    // the panel in this state asks for more than that on its own — so the third menu widens
    // nothing. `Scripts/panel-proofread-row.swift` carries the row's own figure.
    #expect(plain.ideal >= 359,
            "the правка panel wants \(plain.ideal) pt, against the row's 359")
}

/// …and the перевод states the same two constants were originally measured against, re-taken in
/// the same call so the tables in `PanelSizer` are one measurement rather than two vintages.
///
/// This is the half that says the +6 recorded there is drift and not a cost of the marks:
/// nothing on this path draws a summary row, a «Вид» menu or a mark.
@MainActor
@Test func theTranslationStatesTheFloorsWereMeasuredAgainstStillMeasureWhatTheTablesSay() {
    let model = TranslationViewModel(
        translator: Translator(client: SilentPanelClient()),
        settings: AppSettings(defaults: InMemoryDefaults(prefix: "panel-floor")),
        glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-floor-\(UUID().uuidString).json")))
    let selection = SelectionResult.text("исходный текст")

    #expect(abs(measured(PanelView(model: model, selection: selection, adoptionRefusal: nil,
                                   fillsPanel: false), at: 300).height - 98) <= 2)

    model.state = .finished
    model.translatedText = "Готово."
    let finished = measured(PanelView(model: model, selection: selection, adoptionRefusal: nil,
                                      fillsPanel: false), at: 300)
    #expect(abs(finished.height - 100) <= 2, "finished перевод measured \(finished.height)")
    // Still below `minHeight`, which is the whole reason that floor is not raised to clear the
    // правка rows: it is only consulted when the content is smaller than it.
    #expect(finished.height < PanelSizer.minHeight)

    model.state = .failed("Ollama не запущена. Запустите её командой «ollama serve».")
    let failed = measured(PanelView(model: model, selection: selection,
                                    adoptionRefusal: .targetBusy, fillsPanel: false), at: 300)
    #expect(abs(failed.height - 170) <= 2, "failed + «окно занято» measured \(failed.height)")
}
