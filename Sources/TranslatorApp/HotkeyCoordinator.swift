// Sources/TranslatorApp/HotkeyCoordinator.swift
import Foundation
import Observation
import AppKit
import TranslationCore
import TextCapture

/// Everything that happens between the user pressing the shortcut and the panel having
/// something to show. The panel view stays a readout; every decision is here.
@Observable
@MainActor
final class HotkeyCoordinator {
    private let settings: AppSettings
    private let selectionReader: SelectionReader
    private let manager: HotkeyManager
    /// Injected so the tests can write to a board of their own. The user's clipboard is not
    /// the suite's to spend, and `NSPasteboard` is only safe concurrently across *distinct*
    /// names — see `SelectionReader.clipboardLock`.
    private let pasteboard: NSPasteboard

    /// Kept so a re-registration after a settings change can reinstall the same action.
    /// Without it, `refreshRegistration()` would have nothing to hand `HotkeyManager` and the
    /// new combination would register a hotkey that did nothing.
    @ObservationIgnored private var onPress: (@MainActor () -> Void)?

    /// True from the instant a press is accepted until its translation has settled.
    ///
    /// Not the same guard as `panelModel.state != .running`, and neither subsumes the other.
    /// Reading the selection is asynchronous and slow — up to 0.25 s of Accessibility
    /// messaging plus 0.5 s of clipboard polling — so for most of a press the view model is
    /// still `.idle`, and a second press landing in that window would post a second synthetic
    /// ⌘C into the user's application while the first is still in flight, with two
    /// whole-pasteboard destroy-and-restore cycles racing over one board. Set before the
    /// first `await`, on the main actor, so the window between the check and the set does not
    /// exist.
    @ObservationIgnored private var isCapturing = false

    /// The panel's own view model, deliberately not the window's. A hotkey translation must
    /// not overwrite what the user has on screen in the window — and Plan 2's re-entrancy
    /// guard is per-instance, so sharing one would make a hotkey press during a window
    /// translation silently do nothing at all.
    let panelModel: TranslationViewModel
    private(set) var selection: SelectionResult = .empty

    init(settings: AppSettings,
         glossary: GlossaryStore,
         translator: Translator,
         selectionReader: SelectionReader = SelectionReader(),
         manager: HotkeyManager? = nil,
         pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.selectionReader = selectionReader
        // Optional rather than `= HotkeyManager()` as a default argument: a default argument
        // is evaluated in a nonisolated context, and `HotkeyManager` is `@MainActor`, so the
        // obvious spelling does not compile («call to main actor-isolated initializer in a
        // synchronous nonisolated context»). Built here instead, where the isolation holds.
        self.manager = manager ?? HotkeyManager()
        self.pasteboard = pasteboard
        self.panelModel = TranslationViewModel(translator: translator,
                                               settings: settings, glossary: glossary)
    }

    // MARK: - Registration

    /// What is registered right now, which is not always what `settings.hotkey` says — see
    /// `refreshRegistration()`.
    var registeredCombo: HotkeyCombo? { manager.registered }

    /// Registers the stored combination. Returns false when it is refused, which the caller
    /// surfaces rather than swallows: the hotkey is the only way into the panel.
    @discardableResult
    func start(onPress: @escaping @MainActor () -> Void) -> Bool {
        self.onPress = onPress
        return apply(settings.hotkey)
    }

    /// Re-registers after the user changes the shortcut. A no-op when nothing changed, so it
    /// is cheap to call from an observation callback that fires for any reason.
    ///
    /// Returns false only when the new combination was refused — in which case the *previous*
    /// one is still live, because `apply` puts it back.
    @discardableResult
    func refreshRegistration() -> Bool {
        let wanted = settings.hotkey
        guard wanted != manager.registered else { return true }
        return apply(wanted)
    }

    func stop() {
        manager.unregister()
        onPress = nil
    }

    /// The restore is the whole point of this function existing.
    ///
    /// `HotkeyManager.register` tears the live registration down *before* it finds out
    /// whether the new combination is acceptable — `guard status == noErr else {
    /// unregister(); return false }` — so a refusal does not leave the old shortcut alone, it
    /// leaves the user with no shortcut at all. Carbon refuses with -9878 any combination
    /// already held anywhere in this process, and the hotkey is the only door to the panel,
    /// so a failed change must not be able to lock it.
    @discardableResult
    private func apply(_ combo: HotkeyCombo) -> Bool {
        guard let onPress else { return false }
        // Read before the call, not after: `register` clears `registered` on its way in.
        let previous = manager.registered
        if manager.register(combo, onPress: onPress) { return true }
        if let previous { manager.register(previous, onPress: onPress) }
        return false
    }

    // MARK: - A press

    /// Read the selection, then translate it. Everything the panel shows is decided here so
    /// the view stays a readout.
    ///
    /// - Parameters:
    ///   - willCapture: run once the press has been accepted and before anything is read.
    ///     This is where a panel left over from the previous press is taken off screen.
    ///   - afterCapture: run once the selection is known and `selection` has been assigned,
    ///     and before the model is asked anything. This is where the panel is put on screen.
    ///
    /// Both hooks exist for the same reason, and it is a measured one rather than a
    /// preference — see the comment on the `afterCapture()` call below.
    func handlePress(willCapture: @MainActor () -> Void = {},
                     afterCapture: @MainActor () -> Void = {}) async {
        // Two conditions, because they cover different windows. `isCapturing` covers the
        // whole of a press including the read; `state != .running` covers a translation
        // started by something that is not a press — «Повторить» on the panel — which would
        // otherwise have its source swapped out from under it and leave the panel showing
        // one text's translation above another's.
        guard !isCapturing, panelModel.state != .running else { return }
        isCapturing = true
        defer { isCapturing = false }
        // Inside the guard, so a press that is dropped does not take the panel away from a
        // translation already on screen.
        willCapture()

        // Off the main actor, deliberately. `SelectionReader.read()` is `nonisolated` and
        // blocks: up to 0.25 s on the Accessibility path against an application that is not
        // answering, plus 0.5 s of clipboard polling on the fallback path. On the main actor
        // that is three quarters of a second with the run loop stopped — the panel the app
        // has just shown could not draw, its spinner could not turn, and Esc could not be
        // delivered. `Task.detached` and not a bare `Task {}`: a `Task {}` created here
        // inherits this actor and would run the read on it, which is the bug this avoids.
        // `SelectionReader` is `Sendable` and `SelectionResult` is too, so the value crosses
        // back cleanly.
        let reader = selectionReader
        let captured = await Task.detached(priority: .userInitiated) { reader.read() }.value

        selection = captured
        // Only now may the panel appear, and this is measured rather than preferred.
        //
        // Showing it first — which is what Task 10's brief specifies, and what reads as the
        // responsive choice — breaks the capture. Observed against TextEdit holding a
        // selection this app had just read back through `AXSelectedText`: the press produced
        // «выделите текст», with the user's clipboard untouched, on every attempt.
        //
        // The half of that which is *measured* rather than inferred is the Accessibility
        // path, and it is measured directly. A standalone probe asking
        // `AXUIElementCreateSystemWide()` for `kAXFocusedUIElement` answers «Толмач», role
        // `AXWindow`, `kAXSelectedTextAttribute` → -25205, while the panel is on screen; with
        // this application not running at all, the identical query answers TextEdit's
        // `AXTextArea` and the selected sentence. `makeKeyAndOrderFront` on a
        // `.nonactivatingPanel` leaves the application inactive but still makes the panel
        // key, and system-wide accessibility focus follows the key window, not the active
        // application — key and active are different things, as `TranslationPanel`'s own
        // comment says, and this is the direction that catches people out.
        //
        // Why the clipboard fallback came back empty in the same runs was *not* isolated;
        // the obvious candidate is the synthetic ⌘C landing on the panel rather than on
        // TextEdit, and it is written here as a suspicion, not a finding.
        //
        // The cost is that nothing appears on screen until the read returns. On the
        // Accessibility path that was 22 ms when Task 5 measured it, which is invisible; on
        // the clipboard fallback it is up to half a second, which is not — and is the price
        // of the panel not being the thing that eats the selection.
        //
        // `willCapture` above is the same defect approached from the other side: the panel
        // from the *previous* press is still on screen and still key, so on the second press
        // it would eat the selection just as surely. Measured with the probe: with the panel
        // up, the system-wide focused element is «Толмач», role `AXWindow`, and
        // `kAXSelectedTextAttribute` answers -25205; with it gone, the same query returns
        // TextEdit's `AXTextArea` and the selected sentence.
        afterCapture()
        guard case .text(let text) = captured else { return }
        panelModel.sourceText = text
        await runTranslation()
    }

    /// The «Повторить» the panel offers on a failure. Translates the selection already
    /// captured rather than reading a new one — the user's selection may well be gone by
    /// then, and a retry that silently translated something else would be worse than a
    /// button that did nothing.
    func retry() async {
        guard case .text = selection, panelModel.state != .running else { return }
        await runTranslation()
    }

    private func runTranslation() async {
        await panelModel.translate()
        // Spec 6 is emphatic that capturing a selection must leave the clipboard as the user
        // left it, so this is the *only* path in the app that writes to it without the user
        // asking — and it is behind a setting that is off by default.
        if settings.autoCopy, panelModel.state == .finished { await copyResult() }
    }

    /// Enter on the panel, and the «Скопировать» button.
    func copyResult() async {
        // An empty result is not copied. `clearContents()` alone would destroy whatever the
        // user has, in exchange for putting nothing there — the exact failure spec 6 is about.
        guard !panelModel.translatedText.isEmpty else { return }
        // The text is read here, on the main actor; the write happens off it, through the
        // same serialisation `SelectionReader.clipboardText()` uses.
        //
        // Serialised because two threads touching one pasteboard name abort the process —
        // measured 10 times out of 10 for one name, 0 out of 10 for distinct names — and
        // `NSPasteboard.general` is one name. Today this and the ⌘C fallback cannot overlap,
        // because the panel that offers «Скопировать» is hidden for the duration of a
        // capture; but that is a fact about the current UI rather than about this code, and
        // the failure mode is a hard abort rather than a wrong value.
        //
        // Off the main actor because the lock's other holder keeps it for the whole of its
        // poll — up to half a second whenever the target application ignores the ⌘C — and
        // blocking the main thread for that long stops drawing and event delivery outright.
        // `async` rather than fire-and-forget so callers that need the write to have landed,
        // and the test that checks it, can await it; the suspension does not block the actor.
        let text = panelModel.translatedText
        let board = pasteboard
        await Task.detached(priority: .userInitiated) {
            GeneralPasteboard.withExclusiveAccess {
                board.clearContents()
                board.setString(text, forType: .string)
            }
        }.value
    }

}
