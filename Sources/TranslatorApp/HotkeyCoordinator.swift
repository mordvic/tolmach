// Sources/TranslatorApp/HotkeyCoordinator.swift
import Foundation
import Observation
import AppKit
import TranslationCore
import TextCapture

/// Why a registration was refused, and how loudly to say so.
///
/// A type rather than a pair of `Log` calls, so the claim each message makes can be asserted —
/// see `HotkeyCoordinator.failure(for:restored:combination:)`, whose doc comment carries the
/// false claim this exists to prevent.
struct RegistrationFailure: Equatable {
    enum Severity: Equatable { case fault, error }
    let severity: Severity
    let message: String
}

/// Everything that happens between the user pressing the shortcut and the panel having
/// something to show. The panel view stays a readout; every decision is here.
@Observable
@MainActor
final class HotkeyCoordinator {
    private let settings: AppSettings
    private let selectionReader: SelectionReader
    /// One manager per operation. **Two managers rather than one holding two registrations,
    /// and that is not an arbitrary split.** `HotkeyManager`'s own event handler already
    /// distinguishes registrations by `signature` and `hotKeyID`, and its comment records —
    /// measured — that a second manager in this process installs a second handler on the same
    /// dispatcher target and that every handler there is offered every hot-key event.
    /// Teaching one manager to hold several would edit the file where Carbon,
    /// `nonisolated(unsafe)` and a C callback live, to buy what that file was already
    /// written for.
    private let managers: [TextOperation: HotkeyManager]
    /// Injected so the tests can write to a board of their own. The user's clipboard is not
    /// the suite's to spend, and `NSPasteboard` is only safe concurrently across *distinct*
    /// names — see the lock inside `GeneralPasteboard`, which is where that serialisation
    /// lives; it is not on `SelectionReader`, which an earlier version of this line said.
    private let pasteboard: NSPasteboard
    /// «Заменить» — issue #27. Injected for the same reason `pasteboard` is: a test needs to
    /// assert the write → trigger → restore sequence without a real synthesized ⌘V landing
    /// wherever the test process's focus happens to be.
    private let selectionWriter: SelectionWriter

    /// Kept so a re-registration after a settings change can reinstall the same action.
    /// Without it, `refreshRegistration()` would have nothing to hand `HotkeyManager` and the
    /// new combination would register a hotkey that did nothing.
    ///
    /// Takes the operation, so one closure serves both registrations and the app does not
    /// have to keep two of them in step.
    @ObservationIgnored private var onPress: (@MainActor (TextOperation) -> Void)?

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

    /// True from the instant «Заменить» is accepted until its write has settled. A second
    /// call arriving while one is in flight — a double click, or ⌘⇧↩ landing during the brief
    /// window between the paste trigger and the pasteboard restore — is ignored rather than
    /// queued: interleaving two snapshot/restore cycles over one board is exactly the class of
    /// race `isCapturing` above already exists to prevent on the read side. Set before the
    /// first `await`, on the main actor, for the same reason `isCapturing` is.
    @ObservationIgnored private var isReplacing = false

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
         managers: [TextOperation: HotkeyManager]? = nil,
         pasteboard: NSPasteboard = .general,
         selectionWriter: SelectionWriter = SelectionWriter()) {
        self.settings = settings
        self.selectionReader = selectionReader
        self.selectionWriter = selectionWriter
        // Optional rather than a default argument: a default argument is evaluated in a
        // nonisolated context, and `HotkeyManager` is `@MainActor`, so the obvious spelling
        // does not compile («call to main actor-isolated initializer in a synchronous
        // nonisolated context»). Built here instead, where the isolation holds — and built
        // from `allCases`, so a third operation cannot arrive with no shortcut and no
        // complaint from the compiler.
        self.managers = managers ?? Dictionary(
            uniqueKeysWithValues: TextOperation.allCases.map { ($0, HotkeyManager()) })
        self.pasteboard = pasteboard
        self.panelModel = TranslationViewModel(translator: translator,
                                               settings: settings, glossary: glossary)
    }

    // MARK: - Registration

    /// What is registered right now for this operation, which is not always what the settings
    /// say — see `refreshRegistration()`.
    func registeredCombo(for operation: TextOperation) -> HotkeyCombo? {
        managers[operation]?.registered
    }

    /// Which stored combination belongs to which operation. Exhaustive with no `default:`, so
    /// a third operation fails to compile here rather than silently sharing перевод's key.
    private func combo(for operation: TextOperation) -> HotkeyCombo {
        switch operation {
        case .translate: settings.hotkey
        case .proofread: settings.proofreadHotkey
        }
    }

    /// What a press of this operation's shortcut does.
    ///
    /// Not `private`, so a test can pin the wiring: nothing in a test process can press a
    /// Carbon hot key, and a coordinator that handed both registrations the same operation
    /// would otherwise pass every test in the suite.
    func pressAction(for operation: TextOperation) -> @MainActor () -> Void {
        { [weak self] in self?.onPress?(operation) }
    }

    /// Registers both stored combinations. Returns false when **either** was refused, which
    /// the caller surfaces rather than swallows: перевод's is the only way into the panel.
    @discardableResult
    func start(onPress: @escaping @MainActor (TextOperation) -> Void) -> Bool {
        self.onPress = onPress
        return bringRegistrationsInLine()
    }

    /// Re-registers whichever shortcut the user changed. A no-op for one that is already as it
    /// should be, so it is cheap to call from an observation callback that fires for any
    /// reason — and so a change to one shortcut does not drop the other for the length of a
    /// Carbon round trip.
    ///
    /// Returns false only when a new combination was refused — in which case that one's
    /// *previous* value is still live, because `apply` puts it back.
    @discardableResult
    func refreshRegistration() -> Bool { bringRegistrationsInLine() }

    /// Whether this operation's shortcut may be registered at all.
    ///
    /// **The collision is not something the user can type.** `HotkeyRecorder` refuses a
    /// duplicate at the keystroke; what reaches here is the upgrade case — `proofreadHotkey`
    /// answers its factory ⌥⌘R until the key is set, so a user who had already put перевод on
    /// ⌥⌘R gets two identical settings without doing anything. Carbon would refuse the second
    /// registration with -9878 and there would be nothing to restore, so the outcome is the
    /// same either way; declining outright is what keeps it from being *reported* as a system
    /// refusal, which it is not. `AppSettings.shortcutsCollide` is the one place that rule is
    /// written, and «Основные» draws the warning from it.
    ///
    /// Перевод wins, because it is the only door to the panel.
    private func shouldRegister(_ operation: TextOperation) -> Bool {
        operation == .translate || !settings.shortcutsCollide
    }

    /// Makes the live registrations match the settings — the whole job, for both operations,
    /// in the one place. `start` and `refreshRegistration` differ only in that the first also
    /// stores the action.
    ///
    /// **Two passes, and the order is load-bearing — a test found this, not a review.** Carbon
    /// refuses (-9878) a combination already held anywhere in this process, so a shortcut
    /// moving *onto* the one the other currently holds cannot be registered until that other
    /// one has let go. Measured with a single pass in `allCases` order: with перевод on ⌃⌥⌘,
    /// key 0x2B and правка on 0x2C, changing перевод to 0x2C left перевод still on **0x2B** —
    /// its own restore-on-refusal — and правка unregistered a moment later. The user's choice
    /// was discarded silently, and both settings then disagreed with what was registered.
    ///
    /// `reduce` and not `allSatisfy` in the second pass: `allSatisfy` short-circuits, so a
    /// перевод refusal would leave правка unregistered as a side effect of how the check was
    /// written.
    @discardableResult
    private func bringRegistrationsInLine() -> Bool {
        // What each operation should end up holding. Absent means «nothing» — the shortcut
        // that loses a collision.
        let wanted = TextOperation.allCases.reduce(into: [TextOperation: HotkeyCombo]()) {
            if shouldRegister($1) { $0[$1] = combo(for: $1) }
        }
        // Pass 1: let go of every registration that stands in the way — either because it must
        // not exist at all, or because the *other* operation is about to ask Carbon for exactly
        // the combination this one is still holding.
        //
        // **«In the way» and not «out of date», and the difference is the whole care here.**
        // A manager can hold a combination its own setting no longer names: `apply` restores
        // the previous one on refusal, which is the guarantee that a rejected change never
        // leaves the user with no shortcut. Releasing every such registration up front would
        // throw that guarantee away — there would be nothing left to restore to — so only the
        // ones actually blocking someone else are released. Found by review, reproduced by
        // `aStaleRegistrationIsReleasedBeforeTheOtherShortcutAsksForItsCombination`: перевод's
        // move onto a combination правка was *stale* on came back -9878, and перевод kept its
        // old shortcut while the pane showed the new one.
        //
        // What is released is **remembered**, and pass 2 hands it to `apply` as the thing to
        // fall back to. Without that the release destroys the very guarantee this method
        // protects, and not in theory: measured by
        // `resolvingAnInheritedCollisionNeverLeavesTranslationWithoutAShortcut`, resolving an
        // inherited collision by moving перевод onto a combination another component holds
        // ended with перевод registered to **nothing** — pass 1 let go of its live shortcut
        // because правка's setting still named it, and `apply` found `manager.registered` nil
        // and had nothing to put back. Правка then took the combination the user had been
        // pressing for перевод.
        var released: [TextOperation: HotkeyCombo] = [:]
        for operation in TextOperation.allCases {
            guard let held = managers[operation]?.registered else { continue }
            let mustNotExist = wanted[operation] == nil
            let blocksTheOther = wanted.contains { $0.key != operation && $0.value == held }
            guard mustNotExist || blocksTheOther else { continue }
            released[operation] = held
            managers[operation]?.unregister()
        }
        // Pass 2: register what should be, skipping whatever already is.
        return TextOperation.allCases.reduce(true) { ok, operation in
            guard let combination = wanted[operation],
                  combination != managers[operation]?.registered else { return ok }
            return apply(combination, for: operation, fallback: released[operation]) && ok
        }
    }

    func stop() {
        for manager in managers.values { manager.unregister() }
        onPress = nil
    }

    /// The restore is the whole point of this function existing.
    ///
    /// `HotkeyManager.register` tears the live registration down *before* it finds out
    /// whether the new combination is acceptable — `guard status == noErr else {
    /// unregister(); return false }` — so a refusal does not leave the old shortcut alone, it
    /// leaves the user with no shortcut at all. Carbon refuses with -9878 any combination
    /// already held anywhere in this process, and перевод's hotkey is the only door to the
    /// panel, so a failed change must not be able to lock it.
    ///
    /// The failure is logged **here** rather than at the call site, because here is where both
    /// registration paths meet. `refreshRegistration()` had no logging at all before this, and
    /// it is the path a user actually reaches — by choosing a combination another program
    /// holds.
    /// - Parameter fallback: what to restore to when this manager's own registration was
    ///   already released by `bringRegistrationsInLine`'s first pass. Without it a release
    ///   makes the restore above impossible — `manager.registered` is nil by then — and a
    ///   refused change leaves the user with nothing, which is the one outcome this function
    ///   exists to prevent.
    @discardableResult
    private func apply(_ combo: HotkeyCombo, for operation: TextOperation,
                       fallback: HotkeyCombo? = nil) -> Bool {
        // `onPress != nil` rather than binding it: the action registered is
        // `pressAction(for:)`, which reads the stored property at press time. Binding a copy
        // here would freeze whichever action was installed at registration and quietly
        // survive a later `start(onPress:)`.
        guard onPress != nil, let manager = managers[operation] else { return false }
        let press = pressAction(for: operation)
        // Read before the call, not after: `register` clears `registered` on its way in.
        let previous = manager.registered ?? fallback
        if manager.register(combo, onPress: press) { return true }
        // Whether the restore actually happened is what the message below turns on, so it is
        // read rather than assumed. On `refreshRegistration()` there is a working shortcut to
        // fall back to; on `start()` there is not, and the two situations are not equally bad.
        let restored = previous.map { manager.register($0, onPress: press) } ?? false
        let failure = Self.failure(for: operation, restored: restored,
                                   combination: combo.displayString)
        switch failure.severity {
        case .fault: Log.hotkey.fault("\(failure.message, privacy: .public)")
        case .error: Log.hotkey.error("\(failure.message, privacy: .public)")
        }
        return false
    }

    /// What a refused registration means, as a value.
    ///
    /// A value rather than two `Log` calls written inline, and the reason is a defect this
    /// replaces rather than a preference. The message used to be `.fault` and «the app has no
    /// shortcut and no way into the panel» for перевод unconditionally — which was true where
    /// it was born, in `launch()`, where nothing has been registered yet, and **false** on the
    /// path it was moved to: `apply` restores the previous combination two lines up, so a
    /// refused *change* leaves the old shortcut working. A log entry is a claim about the
    /// app's state, and the highest severity there is was making the wrong one.
    ///
    /// `combination` is a `String` rather than a `HotkeyCombo` because `displayString` reads
    /// the current keyboard layout through Text Input Sources, which must happen on the main
    /// actor — see `HotkeyCombo.inputSourceLock`. Taking it already rendered keeps this
    /// `nonisolated` and testable.
    nonisolated static func failure(for operation: TextOperation, restored: Bool,
                                    combination: String) -> RegistrationFailure {
        switch (operation, restored) {
        case (.translate, false):
            // The only genuinely `.fault`-worthy case: no shortcut at all, and the app still
            // looks healthy — which is precisely what makes it hard to diagnose.
            RegistrationFailure(severity: .fault, message: """
                hotkey registration refused; the app has no shortcut and no way into the panel \
                (combination: \(combination))
                """)
        case (.translate, true):
            RegistrationFailure(severity: .error, message: """
                hotkey change refused; the previous combination is still registered, so the \
                panel is still reachable (refused combination: \(combination))
                """)
        case (.proofread, false):
            // `.error` and not `.fault`, deliberately: правка refused costs the user a
            // shortcut, not the application — the panel's own switch still reaches правка.
            // Copying перевод's level would make the log lie about severity in the one place
            // a severity is read.
            RegistrationFailure(severity: .error, message: """
                правка shortcut registration refused; правка stays reachable from the panel's \
                switch (combination: \(combination))
                """)
        case (.proofread, true):
            RegistrationFailure(severity: .error, message: """
                правка shortcut change refused; the previous combination is still registered \
                (refused combination: \(combination))
                """)
        }
    }

    // MARK: - A press

    /// A press has captured its text and the panel is being shown, but `translate()` has not
    /// been reached yet — the one window in which nothing about the model says what is about
    /// to happen.
    ///
    /// It exists because `PanelController.show(at:)` measures the panel inside
    /// `afterCapture()`, before `translate()` runs. Read only by `PanelView`, for the room it
    /// reserves and the status row it shows; `state == .running` covers the rest of the run,
    /// so this is true for a handful of milliseconds and false for everything else.
    private(set) var isStartingRun = false

    /// Read the selection, then translate it. Everything the panel shows is decided here so
    /// the view stays a readout.
    ///
    /// - Parameters:
    ///   - operation: which of the two shortcuts was pressed. It governs the whole run — see
    ///     the assignment below — and defaults to `.translate` so a caller that has only ever
    ///     known one shortcut still means what it always meant.
    ///   - willCapture: run once the press has been accepted and before anything is read.
    ///     This is where a panel left over from the previous press is taken off screen.
    ///   - afterCapture: run once the selection is known and `selection` has been assigned,
    ///     and before the model is asked anything. This is where the panel is put on screen.
    ///
    /// Both hooks exist for the same reason, and it is a measured one rather than a
    /// preference — see the comment on the `afterCapture()` call below.
    func handlePress(operation: TextOperation = .translate,
                     willCapture: @MainActor () -> Void = {},
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
        // «A run for this selection is about to start», said in the one way that changes
        // nothing else.
        //
        // This was `panelModel.translatedText = ""; outcome = nil; state = .idle` and both
        // halves were wrong. Writing `state` is a *state change*, and `PanelHost` answers
        // every one of them with `onContentChange(new != .running)` — so `.finished → .idle`
        // was delivered as a **settle**, at the start of a press, and `applyFit(settling:)`
        // froze `frozenWidth` at the opening width for the whole presentation. The growth rule
        // that `PanelSizer` spends thirty lines justifying was dead: a selection of short lines
        // opened at ~330 pt and the reply was wrapped into that column for the entire run. It
        // also fired an Ollama round trip at the start of every press instead of at the settle.
        //
        // Clearing the text was the other half. `translate()` keeps the previous reply until
        // the new run's first real token precisely so a failed run does not clobber it — spec
        // 8 — and clearing ahead of the run threw that away: press again while Ollama is down
        // and the pane is blank with «Скопировать» disabled, the earlier translation gone for
        // good.
        //
        // A flag on this coordinator touches neither. `PanelView` reads it for the two things
        // that must know — the room it reserves and the row that says «Перевожу…» — and the
        // model is left exactly as `translate()` expects to find it.
        // The operation belongs to the shortcut that was pressed, and only to it: a press never
        // inherits what the previous presentation's switch was left on. That is the
        // predictability the правка design's §8 asked for, restated now that there is more than
        // one shortcut — see docs/superpowers/specs/2026-08-15-proofread-hotkey-design.md,
        // which supersedes that paragraph and nothing else in it.
        //
        // **Assigned before `afterCapture()`, and that placement is the point.** The panel is measured
        // inside that call — `PanelController.show(at:)` → `measure` — and the степень/стиль
        // row is drawn from this property, so assigning it afterwards measured the panel with
        // the *previous* press's operation: a перевод press following a правка one was
        // measured with the row present and kept the space, because the height is monotonic
        // within a presentation, and a правка press following a перевод one opened without the
        // row and then grew. That growth is «кнопки прыгают», the defect the reservation below
        // exists to remove.
        //
        // Neither of the two defects the comment above records applies to it: this is not
        // `state`, so `PanelHost` reads no settle from it, and it is not `translatedText`, so
        // nothing a failed run would need is cleared. It is assigned outside the `.text` guard
        // for the same reason — an empty or unpermitted capture draws neither the row nor the
        // switch, so there is nothing for a stale value to be right or wrong about.
        panelModel.operation = operation
        isStartingRun = true
        afterCapture()
        // Cleared **here**, not after the run. `afterCapture()` is the whole of what the flag
        // is for — `PanelController.show(at:)` takes its measurement inside it — and nothing
        // between this line and `state = .running` can observe the gap: there is no suspension
        // point, so no layout pass runs in it.
        //
        // Held to the end of the run instead, it outlived its purpose and did damage.
        // `runTranslation()` awaits `copyResult()` when «копировать автоматически» is on, and
        // the main actor renders during that suspension — so the settle was measured with the
        // flag still true, froze the panel at the *source's* size, and `PanelSizer` is
        // monotonic outside the settle, so nothing ever gave the space back. The doc comment
        // promising «a handful of milliseconds» is now true of the code as well.
        isStartingRun = false
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

    /// The panel's «Перевод | Правка» switch. Re-runs the **already captured** selection
    /// under the other operation — it never reads a new one: the user's selection may be
    /// long gone, and silently operating on something else would be worse than a control
    /// that does nothing (retry()'s reasoning, verbatim; spec §8).
    func switchOperation(to operation: TextOperation) async {
        guard case .text = selection, panelModel.state != .running,
              panelModel.operation != operation else { return }
        panelModel.operation = operation
        await runTranslation()
    }

    /// The panel's «степень» picker.
    ///
    /// Writes the **setting**, not a per-run override, and that is the design's choice rather
    /// than an accident of what was easiest: the panel's controls *are* the settings
    /// (2026-08-15 design §6), so a степень chosen where правка is actually used survives the
    /// panel closing. `panelModel.proofreadingLevelOverride` stays nil on this model and keeps
    /// its single meaning — «the window's toolbar was used for this run».
    ///
    /// The guards are `switchOperation(to:)`'s, plus the operation itself: a call arriving
    /// under перевод would re-run a translation nobody asked to repeat, and would change a
    /// правка setting to do it.
    func setProofreadingLevel(_ level: ProofreadingLevel) async {
        guard case .text = selection, panelModel.state != .running,
              panelModel.operation == .proofread,
              settings.defaultProofreadingLevel != level else { return }
        settings.defaultProofreadingLevel = level
        await runTranslation()
    }

    /// The panel's «стиль» picker — `setProofreadingLevel(_:)`'s reasoning, verbatim.
    func setRewriteStyle(_ style: RewriteStyle) async {
        guard case .text = selection, panelModel.state != .running,
              panelModel.operation == .proofread,
              settings.defaultRewriteStyle != style else { return }
        settings.defaultRewriteStyle = style
        await runTranslation()
    }

    /// «Ещё вариант» — the same re-run under the same operation; temperature is what
    /// varies the rendering. Offered by the view only for a finished «ошибки и стиль»
    /// правка (`offersAnotherVariant`).
    func anotherVariant() async {
        guard case .text = selection, panelModel.state != .running else { return }
        await runTranslation()
    }

    private func runTranslation() async {
        await panelModel.run()
        // Spec 6 is emphatic that capturing a selection must leave the clipboard as the user
        // left it, so this is the *only* path in the app that writes to it without the user
        // asking — and it is behind a setting that is off by default.
        if settings.autoCopy, panelModel.state == .finished { await copyResult() }
    }

    /// Enter on the panel, and the «Скопировать» button.
    ///
    /// Delegates to `GeneralPasteboard.write`, which is where the empty-guard, the
    /// serialisation and the off-actor write actually live now — shared with the window's
    /// own «Скопировать», so the two cannot diverge in how they touch the pasteboard. This
    /// method exists only because it knows which board and which text belong to *this*
    /// press: today the write and the ⌘C fallback cannot overlap, because the panel that
    /// offers «Скопировать» is hidden for the duration of a capture; but that is a fact
    /// about the current UI rather than about this code, which is exactly why the actual
    /// serialisation lives in `GeneralPasteboard` and not here.
    func copyResult() async {
        await GeneralPasteboard.write(panelModel.translatedText, to: pasteboard)
    }

    /// «Заменить» — issue #27. Writes the panel's finished result back into whatever
    /// application currently has focus, replacing the selection this press originally
    /// captured, and closes the panel — the caller (`TranslatorApp.configurePanel()`) hides it
    /// the same way it does for «⏎ copies and closes».
    ///
    /// Gated on `.finished` rather than merely non-empty text: the button that calls this is
    /// disabled until the run has fully settled (spec: never replace with a half-streamed
    /// answer), and this is the same gate enforced again here so a call reaching this method by
    /// any other path — a future shortcut, a test — cannot bypass it either.
    func replaceInSource() async {
        guard !isReplacing, panelModel.state == .finished else { return }
        isReplacing = true
        defer { isReplacing = false }
        await selectionWriter.replace(panelModel.translatedText, on: pasteboard)
    }
}
