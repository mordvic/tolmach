import Testing
import Foundation
@testable import TranslatorApp
@testable import TranslationCore

/// What a view *draws* needs a human. What it *decides* does not, and this file is the
/// second kind only: the status row's contents and the rule that governs the header line.
/// The layout, the fonts, the scroll caps and the three-way `selection` switch are checked
/// by hand — see the report.

// MARK: - The status row

/// Spec 8 gives «Повторить» to a failed request and to nothing else. Written as a count
/// over every state rather than as a table of five expected values, so that it fails both
/// ways: a state that loses the button and a state that grows one.
@Test func onlyAFailureOffersARetry() {
    let states: [TranslationState] = [.idle, .running, .finished, .interrupted,
                                      .failed("Ollama не запущена.")]
    let offering = states.filter { PanelView.status(for: $0)?.offersRetry == true }
    #expect(offering.count == 1)
    #expect(PanelView.status(for: .failed("что угодно"))?.offersRetry == true)
}

/// `TranslationViewModel.message(for:)` has already put the failure into Russian, and it is
/// the only part that says what to do about it. A panel that replaced it with a generic
/// «Ошибка» would throw away «Запустите её командой «ollama serve»» — the sentence that
/// turns a dead end into an instruction.
@Test func aFailureShowsTheViewModelsOwnSentenceRatherThanAGenericOne() {
    let message = "Ollama не запущена. Запустите её командой «ollama serve»."
    #expect(PanelView.status(for: .failed(message))?.message == message)
    #expect(PanelView.status(for: .failed(message))?.kind == .failure)
}

/// The two states with nothing to report say nothing. `.finished` is the one that matters:
/// a status row that still reads «Перевожу…» over a finished translation is a spinner that
/// never goes away.
@Test func aQuietStateProducesNoStatusRow() {
    #expect(PanelView.status(for: .idle) == nil)
    #expect(PanelView.status(for: .finished) == nil)
    #expect(PanelView.status(for: .running) != nil)
    #expect(PanelView.status(for: .interrupted) != nil)
}

// MARK: - The header line

private final class PacedClient: LLMClient, @unchecked Sendable {
    private var responses: [String]
    private let delayPerToken: Duration
    init(responses: [String], delayPerToken: Duration = .zero) {
        self.responses = responses; self.delayPerToken = delayPerToken
    }
    func chat(messages: [ChatMessage], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        let reply = responses.isEmpty ? "" : responses.removeFirst()
        let delay = delayPerToken
        return AsyncThrowingStream { continuation in
            Task {
                for piece in reply.map(String.init) {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    continuation.yield(.token(piece))
                }
                continuation.yield(.done(ChatStats(loadDurationMS: 0, promptEvalCount: 0,
                                                   promptEvalDurationMS: 0, evalCount: reply.count,
                                                   evalDurationMS: 1)))
                continuation.finish()
            }
        }
    }
}

@MainActor
private func makeModel(_ client: LLMClient) -> TranslationViewModel {
    TranslationViewModel(translator: Translator(client: client),
                         settings: AppSettings(defaults: InMemoryDefaults(prefix: "panel")),
                         glossary: GlossaryStore(url: FileManager.default.temporaryDirectory
                             .appendingPathComponent("panel-\(UUID().uuidString).json")))
}

private let english = "The profile server validates every incoming bundle against the published profile."
private let russian = "Сервер профилей проверяет каждый входящий пакет по опубликованному профилю."

/// A view model for tests that only need one to exist, not one that has run a translation.
/// Built the same way `theHeaderNamesTheDirectionTheRunActuallyResolved` builds its own —
/// through `makeModel` — rather than a second construction shape.
@MainActor
private func model() -> TranslationViewModel {
    makeModel(PacedClient(responses: []))
}

/// End to end through a real run, so that both halves are the ones the engine actually
/// resolved rather than values handed to a formatter. Two runs in opposite directions,
/// because a header built from a constant would satisfy either one alone.
@MainActor
@Test func theHeaderNamesTheDirectionTheRunActuallyResolved() async {
    let model = makeModel(PacedClient(responses: ["Перевод.", "A translation."]))

    model.sourceText = english
    await model.translate()
    #expect(model.state == .finished)
    #expect(PanelView.direction(outcome: model.outcome, target: model.resolvedTarget,
                                operation: .translate)
            == "английский → русский")

    model.sourceText = russian
    await model.translate()
    #expect(model.state == .finished)
    #expect(PanelView.direction(outcome: model.outcome, target: model.resolvedTarget,
                                operation: .translate)
            == "русский → английский")
}

/// The reason the header is built from `outcome` and `resolvedTarget` **together** rather
/// than from `resolvedTarget` alone, measured rather than argued.
///
/// `TranslationViewModel` publishes both only when a run completes, and then clears
/// `outcome` — but *not* `resolvedTarget` — at the instant the next run's first token
/// replaces the text in the pane. So mid-run the pair comes apart: `detectedSource` is gone
/// while `resolvedTarget` still holds the **previous** run's target. Reading them
/// independently, as the brief's version did, renders «язык не определён → русский» over a
/// translation that is on its way to English — a direction wrong in both halves, on screen
/// for the whole streaming phase, which is most of the panel's visible life.
///
/// Withholding it is the honest answer, and it is what the assertions below pin.
@MainActor
@Test func theHeaderIsWithheldWhileTheNextRunReplacesTheTextInThePane() async {
    let second = "Первая строка.\n" + String(repeating: "б", count: 400)
    let model = makeModel(PacedClient(responses: ["Перевод.", second],
                                      delayPerToken: .milliseconds(5)))

    model.sourceText = english
    await model.translate()
    #expect(model.state == .finished)
    #expect(model.resolvedTarget == .ru)

    model.sourceText = russian
    let run = Task { await model.translate() }
    // Waits for the state the assertions are about — the new run's output has replaced the
    // old text — rather than for a duration that could drift into or out of it.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, model.translatedText.isEmpty || model.translatedText == "Перевод." {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.state == .running)
    #expect(model.translatedText != "Перевод.")   // the new run is genuinely on screen

    // The measurement: the target is a whole run out of date while the source is unknown.
    #expect(model.resolvedTarget == .ru)          // stale — this run is heading for English
    #expect(model.outcome == nil)
    // Which is why nothing is shown. `RussianCopy.direction(from: nil, to: .ru)` would have
    // produced «язык не определён → русский» from exactly these two values.
    #expect(PanelView.direction(outcome: model.outcome, target: model.resolvedTarget,
                                operation: .translate) == nil)

    model.cancel()
    await run.value
    #expect(model.state == .interrupted)
    // Still withheld: an interrupted run leaves partial text and no outcome to describe it.
    #expect(PanelView.direction(outcome: model.outcome, target: model.resolvedTarget,
                                operation: .translate) == nil)
}

// MARK: - The close control

@MainActor
@Test func thePanelOffersACloseControlOfItsOwn() {
    // The titlebar goes away with `.titled` in Task 4, and its close button with it. A
    // panel a mouse cannot dismiss would leave Esc as the only way out, which is fine for
    // the keyboard and not fine for anyone else.
    //
    // Constructed, not rendered: this process has no GUI automation, so what is checked is
    // that the view takes the callback and that a default exists — not that a glyph appears.
    var closed = false
    let view = PanelView(model: model(), selection: .empty, onClose: { closed = true })
    view.onClose()
    #expect(closed)
}

// MARK: - Colour is not the only channel

/// Spec-independent, and an accessibility rule rather than a style one: the panel's status row
/// distinguished «прервано» from «ошибка» by hue alone — `.orange` against `.red` — which is
/// nothing at all to a user who does not separate those two, and nothing at all with
/// «Дифференциация без цвета» switched on. Every other status in this app already pairs its
/// colour with a glyph.
///
/// Written as a count over every kind rather than as two literal lookups, so it fails in both
/// directions: a kind that loses its symbol, and a kind that grows one it should not have.
///
/// Over `allCases` and not a hand-written array. It **was** a hand-written array, and a kind
/// added to the enum afterwards — `.awaitingUser` — never joined it, so «every kind» was three
/// of four and the newest case was the unchecked one. A literal list cannot keep that promise;
/// the compiler's own list can.
@MainActor @Test func everyStatusThatIsNotProgressCarriesAGlyphAsWellAsAColour() {
    let kinds = PanelStatus.Kind.allCases
    #expect(kinds.count == 4, "a new kind needs a glyph decision, not a bigger count here")
    #expect(kinds.filter { $0.symbol != nil }.count == 3)
    // `.progress` is the deliberate exception: that row already draws a `ProgressView`, so a
    // glyph beside the spinner beside the word would be three ways of saying one thing.
    #expect(PanelStatus.Kind.progress.symbol == nil)
}

/// The two glyphs must be the ones the settings panes already use, or the app teaches two
/// vocabularies for one idea — a warning that looks like one thing in «Основные» and another
/// in the panel. `SettingsNote` draws `xmark.octagon.fill` for an error and
/// `exclamationmark.triangle.fill` for a warning; `SettingsGeneralView` uses the latter for a
/// missing permission.
@MainActor @Test func thePanelBorrowsTheGlyphsTheSettingsPanesAlreadyUse() {
    #expect(PanelStatus.Kind.interrupted.symbol == "exclamationmark.triangle.fill")
    #expect(PanelStatus.Kind.failure.symbol == "xmark.octagon.fill")
}

// MARK: - What VoiceOver is told

/// The panel is summoned by a shortcut, never takes the app to the foreground, and appears
/// next to the pointer rather than where focus was — so a user who does not see it gets no
/// indication that anything happened. Which states speak, and which stay quiet, is therefore a
/// decision worth pinning rather than a modifier worth reading.
///
/// Written as a count over every state so it fails both ways: a settle that goes silent, and a
/// non-settle that starts talking.
@MainActor @Test func exactlyTheThreeSettledStatesAnnounceThemselves() {
    let states: [TranslationState] = [.idle, .running, .finished, .interrupted,
                                      .failed("Ollama не запущена.")]
    #expect(states.filter { PanelView.announcement(for: $0) != nil }.count == 3)
    // `.running` in particular: the user pressed the key themselves a moment ago, and the
    // panel is already on screen saying «Перевожу…».
    #expect(PanelView.announcement(for: .running) == nil)
    #expect(PanelView.announcement(for: .idle) == nil)
}

/// A failure announces the view model's own sentence rather than a generic «ошибка», for the
/// same reason the status row does: that sentence is the only instruction the user gets, and
/// «Запустите её командой «ollama serve»» is the half that turns a dead end into a next step.
@MainActor @Test func aFailureIsAnnouncedWithTheSentenceThatSaysWhatToDo() {
    let message = "Ollama не запущена. Запустите её командой «ollama serve»."
    #expect(PanelView.announcement(for: .failed(message)) == message)
}

@Test func aRunWaitingOnTheTermsSheetDoesNotClaimToBeTranslating() {
    // The escalation opens the sheet on the main window and leaves the panel on screen
    // behind it. With the panel still saying «Перевожу…» the user is shown two
    // contradictory things at once: a table asking for their attention, and a spinner
    // claiming the machine is busy. Nothing is being translated — the model is idle and
    // the app is waiting on a person.
    let waiting = PanelView.status(for: .running, awaitingTerms: true)
    #expect(waiting?.message == "Жду ваших правок…")
    #expect(waiting?.kind == .awaitingUser)
    #expect(waiting?.offersRetry == false)

    // And the ordinary case is untouched.
    let translating = PanelView.status(for: .running, awaitingTerms: false)
    #expect(translating?.message == "Перевожу…")
    #expect(translating?.kind == .progress)
}

@Test func onlyTheProgressRowCarriesASpinner() {
    // `.progress` is the one state where the machine is working. A spinner beside «Жду
    // ваших правок…» would say the opposite of the words next to it.
    #expect(PanelStatus.Kind.progress.showsSpinner)
    #expect(!PanelStatus.Kind.awaitingUser.showsSpinner)
    #expect(!PanelStatus.Kind.interrupted.showsSpinner)
    #expect(!PanelStatus.Kind.failure.showsSpinner)
}

@Test func waitingOnAPersonIsToldByAGlyphAndNotOnlyByWords() {
    // Every other status in this row pairs its message with a symbol, for the reader who
    // does not see colour. This one is no different.
    #expect(PanelStatus.Kind.awaitingUser.symbol != nil)
}

@Test func awaitingTermsOnlyChangesTheRunningRow() {
    // A finished or failed run is not waiting on anyone, whatever the flag says.
    #expect(PanelView.status(for: .finished, awaitingTerms: true) == nil)
    #expect(PanelView.status(for: .idle, awaitingTerms: true) == nil)
    #expect(PanelView.status(for: .failed("x"), awaitingTerms: true)?.kind == .failure)
    #expect(PanelView.status(for: .interrupted, awaitingTerms: true)?.kind == .interrupted)
}

@MainActor @Test func theStatusSummaryAndItsDisclosureAnswerFromOneRun() {
    // The label read the *previous* run's outcome while the body took a branch of its own:
    // «4 предупреждения» over a disclosure containing one row. TranslationViewModel drops
    // `outcome` only when the next run's first real token arrives, so during `.running` the
    // stale one is still there.
    //
    // Pinned through the static half of the rule, which is the part a test can reach: with
    // no finished outcome there is nothing to summarise at all. A refused glossary save no
    // longer answers here — it is drawn as its own always-visible row, in both modes, so a
    // summary of «1 предупреждение» would be a chevron over a sentence already on screen.
    #expect(RunStatusBar.summary(outcome: nil) == nil)
}

// MARK: - «Перевод | Правка»

/// A finished outcome, built directly rather than through a run — same shape as
/// `WarningsViewTests`'s `quietOutcome`, and for the same reason: only `detectedSource` is
/// what `direction(outcome:target:operation:)` reads, so a fixture that runs a whole
/// translation to produce one would be testing the engine to test a formatter.
private func makeFinishedOutcome(detected: Language?) -> TranslationOutcome {
    TranslationOutcome(final: "Готово.",
                       chunks: [],
                       translatedChunks: ["Готово."],
                       documentGlossary: [],
                       detectedSource: detected,
                       checks: [],
                       markupDiffs: [],
                       stats: [],
                       timeToFirstTokenMS: 12,
                       totalMS: 34,
                       documentGlossaryFailure: nil,
                       documentGlossaryAttempted: false,
                       modelChunkCount: 1)
}

@Test func theHeaderLineSaysПравкаForAProofreadOutcome() {
    // Build any finished outcome fixture the file already uses; only these three
    // parameters decide the line.
    let outcome = makeFinishedOutcome(detected: .ru)
    #expect(PanelView.direction(outcome: outcome, target: nil, operation: .proofread)
            == "правка · русский")
    #expect(PanelView.direction(outcome: outcome, target: .en, operation: .translate)
            == RussianCopy.direction(from: outcome.detectedSource, to: .en))
}

@Test func theProgressRowAndTheAnnouncementSpeakTheOperationsLanguage() {
    #expect(PanelView.status(for: .running, operation: .proofread)?.message == "Исправляю…")
    #expect(PanelView.status(for: .running, operation: .translate)?.message == "Перевожу…")
    #expect(PanelView.announcement(for: .finished, operation: .proofread) == "Правка готова")
    #expect(PanelView.announcement(for: .finished, operation: .translate) == "Перевод готов")
    // The interrupted case must vary the same way: «Перевод прерван…» over a stopped правка
    // would name the wrong operation, and translate's own strings must stay byte-identical.
    #expect(PanelView.status(for: .interrupted, operation: .proofread)?.message
            == "Правка прервана — показана та часть, что успела прийти")
    #expect(PanelView.status(for: .interrupted, operation: .translate)?.message
            == "Перевод прерван — показана та часть, что успела прийти")
    #expect(PanelView.announcement(for: .interrupted, operation: .proofread)
            == "Правка прервана, показана пришедшая часть")
    #expect(PanelView.announcement(for: .interrupted, operation: .translate)
            == "Перевод прерван, показана пришедшая часть")
}

// MARK: - «Заменить» — issue #27

/// Not a check that the rendered button actually carries this shortcut — this project has no
/// view-inspection dependency to ask a `Button` what its `.keyboardShortcut(...)` is, and
/// `docs/OPEN-ITEMS.md` owes that to a human. What this pins is the value itself: a change to
/// the combination (or a copy-paste onto the wrong `KeyEquivalent`) fails here rather than
/// only ever being caught by eye.
@MainActor @Test func theReplaceShortcutIsCommandShiftReturn() {
    #expect(PanelView.replaceShortcut.key == .return)
    #expect(PanelView.replaceShortcut.modifiers == [.command, .shift])
}

// MARK: - Степень and стиль

/// Which controls appear is a decision, and a decision inside a `ViewBuilder` can only be
/// read by rebuilding the view — the same reasoning that makes `status(for:)` a value.
@Test func theDegreeAndStyleControlsBelongOnlyToProofreadOverACapturedSelection() {
    #expect(PanelView.showsProofreadingControls(operation: .proofread,
                                                selection: .text("что-то")))
    // Перевод has no степень, so the row would be two controls governing nothing.
    #expect(!PanelView.showsProofreadingControls(operation: .translate,
                                                 selection: .text("что-то")))
    // And with nothing captured there is nothing to re-run: the panel is showing «выделите
    // текст» or the permission prompt, where an inert control is worse than no control. Both
    // cases, because `header` is drawn by both.
    #expect(!PanelView.showsProofreadingControls(operation: .proofread, selection: .empty))
    #expect(!PanelView.showsProofreadingControls(operation: .proofread,
                                                 selection: .notPermitted))
}
