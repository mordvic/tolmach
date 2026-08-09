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

// MARK: - Registration

@MainActor
@Test func theRegistrationFollowsTheStoredCombinationWhenItChanges() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "hk"))
    settings.hotkey = combo(0x2B)
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }

    #expect(coordinator.start {})
    #expect(coordinator.registeredCombo == combo(0x2B))

    settings.hotkey = combo(0x2C)
    #expect(coordinator.refreshRegistration())
    #expect(coordinator.registeredCombo == combo(0x2C))
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
    let reader = ScriptedReader([nil])
    let (coordinator, _) = makeCoordinator(reader: reader, settings: settings)
    defer { coordinator.stop() }

    #expect(coordinator.start {})
    #expect(coordinator.registeredCombo == combo(0x2B))

    // Somebody else in this process is already holding what the user just chose.
    let rival = HotkeyManager()
    defer { rival.unregister() }
    #expect(rival.register(combo(0x2C)) {})

    settings.hotkey = combo(0x2C)
    #expect(coordinator.refreshRegistration() == false)
    #expect(coordinator.registeredCombo == combo(0x2B))
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
