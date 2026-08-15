import Testing
import Foundation
import AppKit
@testable import TranslatorApp
@testable import TranslationCore
@testable import TextCapture

// MARK: - Doubles

/// A `SelectionReader.Reader` with a script and a memory.
///
/// Stateful rather than a constant closure because the two claims that matter here are about
/// *how many times* the reader runs and *which* press got which text — a press that is
/// dropped must not read at all, since a real read costs a synthetic ⌘C into the user's
/// application and half a second of clipboard polling.
///
/// `delay` blocks the calling thread on purpose. `SelectionReader.read()` is synchronous and
/// blocking by design (up to 0.25 s of Accessibility messaging plus 0.5 s of polling), and the
/// coordinator is meant to keep that off the main actor; a reader that returned instantly
/// could not tell a coordinator that gets this right from one that does not.
private final class ScriptedReader: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]
    private var calls = 0
    private let delay: TimeInterval

    init(_ values: [String?], delay: TimeInterval = 0) {
        self.values = values
        self.delay = delay
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func next() -> String? {
        lock.lock()
        calls += 1
        let value = values.isEmpty ? nil : values.removeFirst()
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return value
    }
}

/// Never `.general`: `copyResult()` writes for real, and the user's clipboard is not the
/// suite's to spend. A uniquely named board is also the only shape `NSPasteboard` is safe in
/// concurrently — the serialisation lives inside `GeneralPasteboard`, not on
/// `SelectionReader`, which an earlier version of this line named.
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.hk.\(UUID().uuidString)"))
}

/// Obscure enough that a shortcut the developer actually uses is never taken for the length
/// of a test run.
private func combo(_ keyCode: UInt16) -> HotkeyCombo {
    HotkeyCombo(keyCode: keyCode,
                modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)
}

@MainActor
private func makeCoordinator(reader: ScriptedReader,
                             isTrusted: Bool = true,
                             replies: [String] = ["перевод"],
                             delayPerToken: Duration = .zero,
                             settings: AppSettings? = nil,
                             pasteboard: NSPasteboard? = nil)
    -> (HotkeyCoordinator, ScriptedClient) {
    let glossary = GlossaryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("hk-\(UUID().uuidString).json"))
    try? glossary.load()
    let client = ScriptedClient(responses: replies, delayPerToken: delayPerToken)
    let coordinator = HotkeyCoordinator(
        settings: settings ?? AppSettings(defaults: InMemoryDefaults(prefix: "hk")),
        glossary: glossary,
        translator: Translator(client: client),
        selectionReader: SelectionReader(accessibility: { reader.next() },
                                         clipboard: { nil },
                                         isTrusted: { isTrusted }),
        pasteboard: pasteboard ?? scratchPasteboard())
    return (coordinator, client)
}

/// Waits on the condition the test is about rather than on a duration, with a ceiling so a
/// regression fails instead of hanging the suite.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool,
                       limit: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + limit
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Capture and translate

@MainActor
@Test func aCapturedSelectionBecomesTheSourceAndIsTranslated() async {
    let reader = ScriptedReader(["Hello, world."])
    let (coordinator, _) = makeCoordinator(reader: reader, replies: ["Привет, мир."])
    await coordinator.handlePress()
    #expect(coordinator.selection == .text("Hello, world."))
    #expect(coordinator.panelModel.sourceText == "Hello, world.")
    #expect(coordinator.panelModel.translatedText == "Привет, мир.")
    #expect(coordinator.panelModel.state == .finished)
}

@MainActor
@Test func anEmptySelectionShowsTheHintAndDoesNotCallTheModel() async {
    // A model call on an empty selection costs the user a two-second pause to be told
    // nothing was selected — which the panel can say instantly. Asserted against the
    // client's own call count, not against `state`: a `TranslationViewModel` that refuses an
    // empty `sourceText` would leave `state` at `.idle` too, and then this test would pass
    // while the coordinator handed the model a blank prompt.
    let reader = ScriptedReader([nil])
    let (coordinator, client) = makeCoordinator(reader: reader)
    await coordinator.handlePress()
    #expect(coordinator.selection == .empty)
    #expect(coordinator.panelModel.state == .idle)
    #expect(coordinator.panelModel.translatedText.isEmpty)
    #expect(client.callCount == 0)
}

@MainActor
@Test func aPressWithNothingSelectedLeavesTheLastTranslationAloneRatherThanRepeatingIt() async {
    // The empty case with something already on the panel, which is the one that can go wrong
    // quietly: a coordinator that fell back to the source it still holds would spend a real
    // model call — and the user's wait — re-translating text they are no longer looking at.
    let reader = ScriptedReader(["Hello.", nil])
    let (coordinator, client) = makeCoordinator(reader: reader, replies: ["Привет.", "Ещё раз."])
    await coordinator.handlePress()
    #expect(client.callCount == 1)

    await coordinator.handlePress()
    #expect(coordinator.selection == .empty)
    #expect(client.callCount == 1)
    // Kept, not cleared: the panel shows the hint, and the translation is still there when
    // the user selects something and presses again.
    #expect(coordinator.panelModel.translatedText == "Привет.")
}

@MainActor
@Test func aMissingPermissionShowsTheOnboardingPromptAndDoesNotCallTheModel() async {
    let reader = ScriptedReader(["не должно быть прочитано"])
    let (coordinator, client) = makeCoordinator(reader: reader, isTrusted: false)
    await coordinator.handlePress()
    #expect(coordinator.selection == .notPermitted)
    #expect(coordinator.panelModel.state == .idle)
    #expect(client.callCount == 0)
    // Neither capture path runs either: `SelectionReader.read()` checks the grant first, so
    // an untrusted process never posts the synthetic ⌘C that the fallback would.
    #expect(reader.callCount == 0)
}

// MARK: - Two presses

@MainActor
@Test func aSecondPressWhileTranslatingIsIgnoredRatherThanInterleaved() async {
    // `TranslationViewModel.translate()` already guards itself, but the coordinator also
    // reads the selection and reassigns `sourceText` — which would swap the source out from
    // under a running translation and leave the panel showing one text's translation above
    // another's, and would spend a second synthetic ⌘C on the user's application to do it.
    let reader = ScriptedReader(["Первый", "Второй"])
    let (coordinator, _) = makeCoordinator(reader: reader,
                                           replies: ["Один", "Два"],
                                           delayPerToken: .milliseconds(20))
    let first = Task { await coordinator.handlePress() }
    await waitUntil { coordinator.panelModel.state == .running }

    await coordinator.handlePress()
    #expect(coordinator.selection == .text("Первый"))
    #expect(coordinator.panelModel.sourceText == "Первый")
    #expect(reader.callCount == 1)

    await first.value
    #expect(coordinator.panelModel.translatedText == "Один")
}

@MainActor
@Test func aPressArrivingWhileTheSelectionIsStillBeingReadIsDropped() async {
    // The window the view model's own guard cannot cover. `read()` blocks for up to
    // three quarters of a second, so between the first press and `state == .running` there
    // is a long stretch where the model is still `.idle` — and a second press landing there
    // would post a second ⌘C into the user's application while the first is still in flight,
    // with two whole-pasteboard destroy-and-restore cycles racing over one board.
    let reader = ScriptedReader(["Первый", "Второй"], delay: 0.2)
    let (coordinator, _) = makeCoordinator(reader: reader, replies: ["Один", "Два"])
    let first = Task { await coordinator.handlePress() }
    await waitUntil { reader.callCount == 1 }
    #expect(coordinator.panelModel.state == .idle)   // the read has not returned yet

    await coordinator.handlePress()
    #expect(reader.callCount == 1)

    await first.value
    #expect(coordinator.selection == .text("Первый"))
    #expect(coordinator.panelModel.translatedText == "Один")
}

@MainActor
@Test func aPressArrivingWhileAPanelRetryIsRunningIsDropped() async {
    // The window the capture guard cannot cover. «Повторить» is not a press, so a press
    // landing on top of a running retry finds nothing held — and would read a fresh
    // selection and reassign `sourceText` under a translation already in flight.
    let reader = ScriptedReader(["Первый", "Второй"])
    let (coordinator, _) = makeCoordinator(reader: reader,
                                           replies: ["Один", "Двадцать два"],
                                           delayPerToken: .milliseconds(20))
    await coordinator.handlePress()
    #expect(coordinator.panelModel.state == .finished)

    let retry = Task { await coordinator.retry() }
    await waitUntil { coordinator.panelModel.state == .running }

    await coordinator.handlePress()
    #expect(reader.callCount == 1)
    #expect(coordinator.panelModel.sourceText == "Первый")

    await retry.value
    #expect(coordinator.panelModel.translatedText == "Двадцать два")
}

@MainActor
@Test func theSelectionIsReadOffTheMainActorSoTheRunLoopKeepsTurning() async {
    // `SelectionReader.read()` is `nonisolated` and blocking, and nothing in it stops a
    // caller running it on the main thread. If the coordinator did, the panel it has just
    // shown could not draw and the whole UI would freeze for the length of every press.
    // Measured here as the property that follows: the main actor stays free to run other
    // work while the read is in flight.
    let reader = ScriptedReader(["Первый"], delay: 0.3)
    let (coordinator, _) = makeCoordinator(reader: reader, replies: ["Один"])
    let press = Task { await coordinator.handlePress() }
    await waitUntil { reader.callCount == 1 }

    var turns = 0
    while reader.callCount == 1, coordinator.panelModel.state == .idle, turns < 10_000 {
        turns += 1
        await Task.yield()
    }
    #expect(turns > 0, "the main actor was blocked for the whole of the read")
    await press.value
}

// MARK: - When the panel may be on screen

@MainActor
@Test func thePanelGoesUpOnlyAfterTheSelectionHasBeenRead() async {
    // The defect the first live run found, pinned. Showing the panel before the capture —
    // which is what Task 10's brief specified — makes it the key window, and the system-wide
    // accessibility focus follows the key window rather than the active application: the
    // capture then reads the panel, finds no selected text, and the fallback's synthetic ⌘C
    // is delivered to the panel too. Both paths come back empty over a live selection.
    // Measured with a standalone probe: panel up → focused element «Толмач», role `AXWindow`,
    // `kAXSelectedText` -25205; app not running → TextEdit's `AXTextArea` and the sentence.
    let reader = ScriptedReader(["Hello."], delay: 0.05)
    let (coordinator, client) = makeCoordinator(reader: reader, replies: ["Привет."])
    var readsWhenShown = -1
    var callsWhenShown = -1
    var selectionWhenShown: SelectionResult?
    var hidesBeforeRead = -1
    await coordinator.handlePress(
        willCapture: { hidesBeforeRead = reader.callCount },
        afterCapture: {
            readsWhenShown = reader.callCount
            callsWhenShown = client.callCount
            selectionWhenShown = coordinator.selection
        })
    // Taken off screen before anything is read…
    #expect(hidesBeforeRead == 0)
    // …put back only once the read has happened…
    #expect(readsWhenShown == 1)
    // …with the result already assigned, so the panel draws the right one of its three
    // faces rather than flashing the wrong one…
    #expect(selectionWhenShown == .text("Hello."))
    // …and before the model is asked, so the spinner is on screen for the whole wait.
    #expect(callsWhenShown == 0)
}

@MainActor
@Test func aDroppedPressDoesNotTakeThePanelAwayFromTheRunItInterrupted() async {
    // `willCapture` hides the panel, so it has to sit inside the re-entrancy guard. Outside
    // it, a stray second press would blank a translation that is still streaming.
    let reader = ScriptedReader(["Первый", "Второй"])
    let (coordinator, _) = makeCoordinator(reader: reader, replies: ["Один", "Два"],
                                           delayPerToken: .milliseconds(20))
    var hides = 0
    let first = Task { await coordinator.handlePress(willCapture: { hides += 1 }) }
    await waitUntil { coordinator.panelModel.state == .running }

    await coordinator.handlePress(willCapture: { hides += 1 })
    #expect(hides == 1)
    await first.value
}

// MARK: - Handing over to the window

// MARK: - The pasteboard

@MainActor
@Test func copyingPutsTheTranslationOnThePasteboardAndLeavesAnEmptyOneAlone() async {
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("буфер пользователя", forType: .string)

    let reader = ScriptedReader([nil, "Hello."])
    let (coordinator, _) = makeCoordinator(reader: reader, replies: ["Привет."],
                                           pasteboard: board)
    // Nothing translated yet: Enter on an empty panel must not clear what the user has.
    await coordinator.handlePress()
    await coordinator.copyResult()
    #expect(board.string(forType: .string) == "буфер пользователя")

    await coordinator.handlePress()
    await coordinator.copyResult()
    #expect(board.string(forType: .string) == "Привет.")
}

@MainActor
@Test func autoCopyIsWhatDecidesWhetherARunTouchesThePasteboardByItself() async {
    // Spec 6: capturing the selection must leave the user's clipboard exactly as they left
    // it. `autoCopy` is the one opt-in that changes that, and it is off by default — so a
    // coordinator that copied unconditionally would destroy the clipboard on every press.
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("буфер пользователя", forType: .string)

    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    #expect(settings.autoCopy == false)
    let reader = ScriptedReader(["Hello.", "Goodbye."])
    let (coordinator, _) = makeCoordinator(reader: reader, replies: ["Привет.", "Пока."],
                                           settings: settings, pasteboard: board)
    await coordinator.handlePress()
    #expect(coordinator.panelModel.state == .finished)
    #expect(board.string(forType: .string) == "буфер пользователя")

    settings.autoCopy = true
    await coordinator.handlePress()
    #expect(coordinator.panelModel.state == .finished)
    #expect(board.string(forType: .string) == "Пока.")
}

@MainActor
@Test func autoCopyAlsoFollowsARunStartedByTheOperationSwitch() async {
    // `switchOperation(to:)` calls the same `runTranslation()` `handlePress()` does, so
    // `autoCopy`'s guard has to cover it too — a coordinator that only wired the setting
    // into the press itself would leave the clipboard holding a stale правка after the
    // switch, right where the panel claims a fresh one just finished.
    let board = scratchPasteboard()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("буфер пользователя", forType: .string)

    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.autoCopy = true
    let reader = ScriptedReader(["Hello."])
    let (coordinator, _) = makeCoordinator(reader: reader, replies: ["Привет.", "Исправлено."],
                                           settings: settings, pasteboard: board)
    await coordinator.handlePress()
    #expect(coordinator.panelModel.state == .finished)
    #expect(board.string(forType: .string) == "Привет.")

    await coordinator.switchOperation(to: .proofread)
    #expect(coordinator.panelModel.state == .finished)
    #expect(board.string(forType: .string) == "Исправлено.")
}

// MARK: - Registration

@MainActor
@Test func theRegistrationFollowsTheStoredCombinationWhenItChanges() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.hotkey = combo(0x2B)
    // Set too, and obscurely: `start` registers both shortcuts, so leaving this at the
    // factory ⌥⌘R would take a real shortcut from the developer for the length of the run.
    settings.proofreadHotkey = combo(0x2D)
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }

    #expect(coordinator.start { _ in })
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))

    settings.hotkey = combo(0x2C)
    #expect(coordinator.refreshRegistration())
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2C))
}

@MainActor
@Test func aRefusedReRegistrationPutsThePreviousCombinationBack() {
    // `HotkeyManager.register` tears the live registration down *before* it finds out
    // whether the new combination is acceptable (`guard status == noErr else { unregister();
    // return false }`), so a refusal leaves the user with no working shortcut at all — and
    // the hotkey is the only way into the panel. Measured refusal: Carbon answers -9878 for a
    // combination already held anywhere in this process.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.hotkey = combo(0x2B)
    settings.proofreadHotkey = combo(0x2D)   // see the note in the test above
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }

    #expect(coordinator.start { _ in })
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))

    // Somebody else in this process is already holding what the user just chose.
    let rival = HotkeyManager()
    defer { rival.unregister() }
    #expect(rival.register(combo(0x2C)) {})

    settings.hotkey = combo(0x2C)
    #expect(coordinator.refreshRegistration() == false)
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))
}

/// A press must say «a run is starting» without touching anything the panel or the engine
/// reads for something else. Two defects came from saying it the other way.
///
/// **The state.** `PanelHost` answers every state change with
/// `onContentChange(new != .running)`, so writing `.idle` here delivered a *settle* at the
/// start of a press — `applyFit(settling:)` then froze `frozenWidth` at the panel's opening
/// width for the whole presentation, killing the growth rule `PanelSizer` spends thirty lines
/// justifying, and fired an Ollama round trip at every press instead of at every settle.
///
/// **The text.** `translate()` keeps the previous reply until the new run's first real token
/// precisely so a failed run cannot clobber it (spec 8). Clearing it here meant a press made
/// while Ollama was down left a blank pane with «Скопировать» disabled and the earlier
/// translation gone for good.
@MainActor
@Test func aPressAnnouncesItselfWithoutDisturbingTheModel() async {
    let reader = ScriptedReader(["Slicing is how one repeating element is split."])
    let (coordinator, _) = makeCoordinator(reader: reader)
    coordinator.panelModel.translatedText = "перевод прошлого нажатия"
    coordinator.panelModel.state = .finished

    var stateAtShow: TranslationState?
    var textAtShow: String?
    var flagAtShow: Bool?
    await coordinator.handlePress(afterCapture: {
        stateAtShow = coordinator.panelModel.state
        textAtShow = coordinator.panelModel.translatedText
        flagAtShow = coordinator.isStartingRun
    })

    // The panel is told, and it is told by the flag.
    #expect(flagAtShow == true)
    // Nothing else moved: no state change for `PanelHost` to read as a settle, and the
    // previous reply still on screen for a run that may be about to fail.
    #expect(stateAtShow == .finished)
    #expect(textAtShow == "перевод прошлого нажатия")
    // And the flag does not outlive the press.
    #expect(coordinator.isStartingRun == false)
}

// MARK: - «Перевод | Правка»

/// A coordinator with one press already run to completion — the fixture every switch test
/// starts from, since switching operates on a selection that is already captured rather than
/// on a fresh one. The reader is scripted with two selections rather than one: some tests
/// press a second time, and a press that reads `nil` would not exercise the reset this task
/// adds (`handlePress` only resets `operation` on the branch that assigns `sourceText`).
@MainActor
private struct PressHarness {
    let coordinator: HotkeyCoordinator
    let fake: ScriptedClient
    private let reader: ScriptedReader

    /// How many times the selection was actually read — the number a switch or «Ещё вариант»
    /// must not move, since both re-run the selection already captured by the press.
    var selectionReads: Int { reader.callCount }

    func press() async { await coordinator.handlePress() }

    init(reader: ScriptedReader, responses: [String]) async {
        self.reader = reader
        (coordinator, fake) = makeCoordinator(reader: reader, replies: responses)
        await coordinator.handlePress()
    }
}

@MainActor
private func makePressedCoordinator(responses: [String]) async -> PressHarness {
    await PressHarness(reader: ScriptedReader(["Hello, world.", "Hello, world."]), responses: responses)
}

@MainActor
@Test func switchingTheOperationRerunsTheCapturedSelectionWithoutReadingANewOne() async {
    // The fake queues one translate reply (consumed by the harness's own press) and one
    // proofread reply (consumed by the switch).
    let harness = await makePressedCoordinator(responses: ["перевод", "правка"])
    await harness.coordinator.switchOperation(to: .proofread)
    #expect(harness.coordinator.panelModel.operation == .proofread)
    // The re-run went to the model with the *captured* text — the reader was not asked
    // again (same reasoning as retry(): the selection may be long gone).
    #expect(harness.selectionReads == 1)
    let system = harness.fake.receivedMessages.last!.first!.content
    #expect(system.contains("copy editor"))
}

@MainActor
@Test func aNewPressResetsTheOperationToTranslate() async {
    let harness = await makePressedCoordinator(responses: ["перевод", "правка", "перевод снова"])
    await harness.coordinator.switchOperation(to: .proofread)
    await harness.press()
    // The hotkey is predictable: every press starts with перевод (spec §8).
    #expect(harness.coordinator.panelModel.operation == .translate)
}

@MainActor
@Test func switchingToTheOperationAlreadyShownDoesNothing() async {
    let harness = await makePressedCoordinator(responses: ["перевод"])
    let callsBefore = harness.fake.receivedMessages.count
    await harness.coordinator.switchOperation(to: .translate)
    #expect(harness.fake.receivedMessages.count == callsBefore)
}

// MARK: - Two shortcuts

@MainActor
@Test func aPressOfTheProofreadShortcutOpensThePanelAlreadyProofreading() async {
    // The whole feature in one assertion: the operation reaching the model is the one the
    // shortcut carried, not the hard-coded `.translate` every press used to start from.
    let reader = ScriptedReader(["Здесь ошибка."])
    let (coordinator, client) = makeCoordinator(reader: reader, replies: ["Здесь ошибки нет."])
    await coordinator.handlePress(operation: .proofread)
    #expect(coordinator.panelModel.operation == .proofread)
    #expect(coordinator.panelModel.sourceText == "Здесь ошибка.")
    #expect(coordinator.panelModel.translatedText == "Здесь ошибки нет.")
    // Asserted against the prompt the model actually received, not against the model's own
    // `operation`: the property could be set correctly and the run still go through
    // `translate()`, which is the failure this is for.
    let system = client.receivedMessages.last!.first!.content
    #expect(system.contains("copy editor"))
}

@MainActor
@Test func eachShortcutBringsItsOwnOperationRatherThanInheritingTheLastOne() async {
    // The rule the правка design's §8 stated as «every press starts with перевод» becomes
    // «every press starts with its own operation». Both directions, because inheritance in
    // either one is a press doing something the user did not ask for.
    let reader = ScriptedReader(["Раз.", "Два.", "Три."])
    let (coordinator, _) = makeCoordinator(
        reader: reader, replies: ["Правка.", "Перевод.", "Правка снова."])
    await coordinator.handlePress(operation: .proofread)
    #expect(coordinator.panelModel.operation == .proofread)
    await coordinator.handlePress()
    #expect(coordinator.panelModel.operation == .translate)
    await coordinator.handlePress(operation: .proofread)
    #expect(coordinator.panelModel.operation == .proofread)
}

@MainActor
@Test func aProofreadPressArrivingWhileATranslationIsCapturingIsDropped() async {
    // `isCapturing` is per coordinator, and this is what that buys: two shortcuts cannot put
    // two synthetic ⌘C fallbacks into the user's application over one pasteboard.
    let reader = ScriptedReader(["Первый", "Второй"], delay: 0.2)
    let (coordinator, _) = makeCoordinator(reader: reader, replies: ["Один", "Два"])
    let first = Task { await coordinator.handlePress() }
    await waitUntil { reader.callCount == 1 }
    #expect(coordinator.panelModel.state == .idle)   // the read has not returned yet

    await coordinator.handlePress(operation: .proofread)
    #expect(reader.callCount == 1)

    await first.value
    #expect(coordinator.selection == .text("Первый"))
    #expect(coordinator.panelModel.operation == .translate)
}

@MainActor
@Test func bothShortcutsRegisterAndChangingOneLeavesTheOtherAlone() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.hotkey = combo(0x2B)
    settings.proofreadHotkey = combo(0x2C)
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }

    #expect(coordinator.start { _ in })
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))
    #expect(coordinator.registeredCombo(for: .proofread) == combo(0x2C))

    settings.proofreadHotkey = combo(0x2D)
    #expect(coordinator.refreshRegistration())
    #expect(coordinator.registeredCombo(for: .proofread) == combo(0x2D))
    // The one that did not change is still live. A `refreshRegistration()` that re-registered
    // both would look identical from the setting's side and would drop the other shortcut for
    // the length of a Carbon round trip.
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))
}

@MainActor
@Test func aRefusedProofreadRegistrationLeavesTheTranslationShortcutAlone() {
    // The refusal path from the side that matters now that there are two: правка failing to
    // register must not cost перевод its shortcut, since перевод is the only door to the
    // panel. Carbon answers -9878 for a combination already held anywhere in this process.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.hotkey = combo(0x2B)
    settings.proofreadHotkey = combo(0x2C)
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }
    #expect(coordinator.start { _ in })

    let rival = HotkeyManager()
    defer { rival.unregister() }
    #expect(rival.register(combo(0x2D)) {})

    settings.proofreadHotkey = combo(0x2D)
    #expect(coordinator.refreshRegistration() == false)
    #expect(coordinator.registeredCombo(for: .proofread) == combo(0x2C))
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))
}

@MainActor
@Test func theActionRegisteredForAShortcutCarriesThatShortcutsOperation() {
    // Nothing in a test process can press a Carbon hot key, so the wiring between a
    // registration and its operation is pinned at the one place it is decided instead. A
    // coordinator that built both actions from the same operation — the obvious slip when one
    // closure becomes two — passes every other test in this file.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.hotkey = combo(0x2B)
    settings.proofreadHotkey = combo(0x2C)
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }

    var seen: [TextOperation] = []
    #expect(coordinator.start { seen.append($0) })
    coordinator.pressAction(for: .proofread)()
    coordinator.pressAction(for: .translate)()
    #expect(seen == [.proofread, .translate])
}

// MARK: - The panel's степень and стиль

@MainActor
@Test func thePanelsDegreePickerWritesTheSettingAndRerunsTheCapturedSelection() async {
    // The panel's controls *are* the settings (design §6): a user who always proofreads with
    // style sets it once, where they use it. A per-run override would be forgotten by the next
    // press and send them to Settings anyway.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    #expect(settings.defaultProofreadingLevel == .errorsOnly)   // the premise
    let reader = ScriptedReader(["Здесь ошибка."])
    let (coordinator, client) = makeCoordinator(
        reader: reader, replies: ["Правка.", "Правка со стилем."], settings: settings)
    await coordinator.handlePress(operation: .proofread)
    let callsBefore = client.receivedMessages.count

    await coordinator.setProofreadingLevel(.errorsAndStyle)
    #expect(settings.defaultProofreadingLevel == .errorsAndStyle)
    #expect(client.receivedMessages.count == callsBefore + 1)
    // The re-run used the captured text rather than reading a new selection — `retry()`'s
    // reasoning, verbatim: the user's selection may be long gone.
    #expect(reader.callCount == 1)
    // And the model was actually told, which is the whole point of the setting.
    let system = client.receivedMessages.last!.first!.content
    #expect(system.contains("smooth awkward phrasing"))
}

@MainActor
@Test func aDegreeChangeWithNothingCapturedNeitherWritesNorRuns() async {
    // The guards are `switchOperation(to:)`'s, and this is the one that would do damage: a
    // setting written from a panel showing «выделите текст» changes what the *next* press
    // does, for a click on a control that should not have been there.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    let reader = ScriptedReader([nil])
    let (coordinator, client) = makeCoordinator(reader: reader, settings: settings)
    await coordinator.handlePress(operation: .proofread)
    #expect(coordinator.selection == .empty)   // the premise

    await coordinator.setProofreadingLevel(.errorsAndStyle)
    #expect(settings.defaultProofreadingLevel == .errorsOnly)
    #expect(client.callCount == 0)
}

@MainActor
@Test func aStyleChangeUnderTranslationIsRefusedRatherThanRerunningATranslation() async {
    // The row is drawn only for правка, so this is unreachable through the UI — and it is
    // pinned because the failure would be silent and expensive: without the operation guard, a
    // stray call would re-run a *translation* the user did not ask to repeat, and would change
    // a правка setting in order to do it.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    let reader = ScriptedReader(["Hello."])
    let (coordinator, client) = makeCoordinator(
        reader: reader, replies: ["Привет."], settings: settings)
    await coordinator.handlePress()
    let callsBefore = client.receivedMessages.count

    await coordinator.setRewriteStyle(.business)
    #expect(settings.defaultRewriteStyle == .original)
    #expect(client.receivedMessages.count == callsBefore)
}

// MARK: - What a refusal says, and the collision nobody can type

/// The message is a claim about the app's state, and the claim depends on whether the restore
/// happened. It used to be unconditional — «the app has no shortcut and no way into the panel»
/// at `.fault` — which was true where it was written, in `launch()`, and false where it was
/// moved to: `apply` puts the previous combination back, so a refused *change* leaves the old
/// shortcut working.
@Test func aRefusalOnlyClaimsTheAppIsShortcutlessWhenItActuallyIs() {
    let lost = HotkeyCoordinator.failure(for: .translate, restored: false, combination: "⌥⌘T")
    #expect(lost.severity == .fault)
    #expect(lost.message.contains("no way into the panel"))

    let kept = HotkeyCoordinator.failure(for: .translate, restored: true, combination: "⌥⌘T")
    #expect(kept.severity == .error)
    #expect(!kept.message.contains("no way into the panel"))
    #expect(kept.message.contains("still registered"))

    // Правка is never a fault: the panel's own switch reaches правка whatever happens to its
    // shortcut, and copying перевод's level would make the log lie about severity.
    #expect(HotkeyCoordinator.failure(for: .proofread, restored: false,
                                      combination: "⌥⌘R").severity == .error)
    #expect(HotkeyCoordinator.failure(for: .proofread, restored: true,
                                      combination: "⌥⌘R").severity == .error)
}

@MainActor
@Test func twoIdenticalCombinationsLeaveПравкаUnregisteredRatherThanFightingCarbon() async {
    // Not something the user can type — `HotkeyRecorder` refuses a duplicate. It is the
    // upgrade case: `proofreadHotkey` answers its factory ⌥⌘R until the key is set, so a user
    // who had already put перевод on ⌥⌘R arrives with two identical settings.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.hotkey = combo(0x2B)
    settings.proofreadHotkey = combo(0x2B)
    #expect(settings.shortcutsCollide)   // the premise
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }

    // Перевод wins, because it is the only door to the panel — and `start` reports success:
    // this is a settings conflict the pane explains, not a refusal by the system.
    #expect(coordinator.start { _ in })
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))
    #expect(coordinator.registeredCombo(for: .proofread) == nil)

    // And it recovers the moment the user separates them.
    settings.proofreadHotkey = combo(0x2C)
    #expect(coordinator.refreshRegistration())
    #expect(coordinator.registeredCombo(for: .proofread) == combo(0x2C))
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))
}

@MainActor
@Test func aShortcutMovedOntoTheOtherOneTakesПравкаRegistrationOff() {
    // The direction that needs `refreshRegistration` to compare against what *should* be
    // registered rather than against the stored combination: правка's own setting does not
    // move here, перевод's moves onto it, and правка's live registration has to come off
    // anyway or the app answers to a shortcut the pane says is not in force.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.hotkey = combo(0x2B)
    settings.proofreadHotkey = combo(0x2C)
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }
    #expect(coordinator.start { _ in })
    #expect(coordinator.registeredCombo(for: .proofread) == combo(0x2C))

    settings.hotkey = combo(0x2C)
    #expect(coordinator.refreshRegistration())
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2C))
    #expect(coordinator.registeredCombo(for: .proofread) == nil)
}
