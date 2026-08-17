# A shortcut of its own for правка — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second system-wide shortcut that captures the selection and proofreads it, with степень and стиль adjustable in the panel.

**Architecture:** One `HotkeyCoordinator` holding one `HotkeyManager` per `TextOperation`; the pressed shortcut's operation is carried into `handlePress(operation:)`, which assigns it to the panel model where a hard-coded `.translate` stood. `TextCapture` is not touched — its Carbon callback already distinguishes registrations by `signature` + `hotKeyID`. The panel's new степень/стиль row writes `AppSettings`, not per-run overrides.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Carbon.HIToolbox, Observation, Swift Testing.

**Spec:** `docs/design/specs/2026-08-15-proofread-hotkey-design.md`. Where this plan and the spec disagree, the spec is the authority on *why* and this plan is wrong — stop and ask.

## Global Constraints

- Swift 6 tools, `.swiftLanguageMode(.v6)` on every target, platform floor macOS 14.
- `swift build --build-tests` must stay at **zero warnings**. This is enforced by CI.
- **No external dependencies.** Foundation, NaturalLanguage, SwiftUI, AppKit, Observation, ApplicationServices, CoreGraphics, CoreText, ImageIO, Carbon, os, UniformTypeIdentifiers, Swift Testing only.
- All user-facing strings are Russian, with «guillemets» and «ё». No backticks inside a string rendered by `Text(String)` — that initialiser does not parse Markdown and they show as grave accents.
- Russian labels for domain enums live in `RussianCopy.swift`, exhaustive with no `default:`.
- Tests use **Swift Testing** (`@Test`, `#expect`), never XCTest. Test names are sentences describing the behaviour pinned. `UserDefaults`-backed tests use `InMemoryDefaults`, never a real suite.
- Comments carry *why* and the measurement behind it, not what the code does. «Measured» and «load-bearing» are a contract: changing the code under such a comment means re-measuring or recording why the measurement no longer applies.
- Nothing derived from the user's text may be logged. Error descriptions are logged `.public` deliberately.
- Commit messages: conventional, scoped — `feat(app):`, `fix(app):`, `test(app):`, `docs(app):`.
- Run the whole suite with `swift test`. It is offline and reads ~2.1 s; a much larger figure means the machine, not the code.

---

### Task 1: Probe whether ⌥⌘R is free

Spec §8.3. A Carbon hot key takes its combination from every application on the machine, so a factory value must be checked before it reaches the code. This task produces a measurement and, if it comes back bad, changes the constant Task 2 introduces.

**Files:**
- Create: `Scripts/hotkey-availability.swift`
- Modify: `docs/reference/MEASUREMENTS.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a decision — the key code Task 2 writes into `HotkeyCombo.proofreadDefault`. Default assumption: `kVK_ANSI_R` (15).

- [ ] **Step 1: Write the probe**

```swift
// Scripts/hotkey-availability.swift
//
// Whether a combination is free to take as a factory shortcut. Two questions, because they
// fail differently:
//
//   1. Does Carbon accept the registration? A refusal (-9878, eventHotKeyExistsErr) means
//      something in *this process* already holds it — which for a throwaway probe means
//      nothing does, so this half only ever catches a mistake in the probe itself.
//   2. Does macOS itself already use it? System shortcuts live in
//      com.apple.symbolichotkeys, and a hot key registered over one of those is simply never
//      delivered — RegisterEventHotKey returns noErr and the app looks broken.
//
//     swiftc -O -o /tmp/hka Scripts/hotkey-availability.swift && /tmp/hka
//     KEY=15 MODS=cmd,opt /tmp/hka     # the pair being checked; defaults to ⌥⌘R
//
// The modifier numbers in symbolichotkeys are NSEvent's raw values, not Carbon's:
// ⌘ 1048576, ⌥ 524288, ⌃ 262144, ⇧ 131072. That is why this reads them rather than
// converting — a table of Carbon constants compared against a plist of Cocoa ones is how a
// probe comes back green on a combination the system owns.
import AppKit
import Carbon.HIToolbox

let keyCode = UInt16(ProcessInfo.processInfo.environment["KEY"].flatMap { UInt16($0) } ?? 15)
let names = (ProcessInfo.processInfo.environment["MODS"] ?? "cmd,opt")
    .split(separator: ",").map(String.init)
let cocoaModifiers: UInt = names.reduce(into: 0) { total, name in
    switch name {
    case "cmd": total |= NSEvent.ModifierFlags.command.rawValue
    case "opt": total |= NSEvent.ModifierFlags.option.rawValue
    case "ctrl": total |= NSEvent.ModifierFlags.control.rawValue
    case "shift": total |= NSEvent.ModifierFlags.shift.rawValue
    default: FileHandle.standardError.write(Data("unknown modifier \(name)\n".utf8))
    }
}
var carbonModifiers: UInt32 = 0
let flags = NSEvent.ModifierFlags(rawValue: cocoaModifiers)
if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

print("checking keyCode \(keyCode) with \(names.joined(separator: "+")) "
      + "(cocoa \(cocoaModifiers), carbon \(carbonModifiers))")

// 1. Carbon
var ref: EventHotKeyRef?
let id = EventHotKeyID(signature: OSType(0x50524F42), id: 1)   // 'PROB'
let status = RegisterEventHotKey(UInt32(keyCode), carbonModifiers, id,
                                 GetEventDispatcherTarget(), 0, &ref)
print("RegisterEventHotKey → \(status)\(status == noErr ? " (accepted)" : " (REFUSED)")")
if let ref { UnregisterEventHotKey(ref) }

// 2. The system's own table
var collisions = 0
if let table = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
    .dictionary(forKey: "AppleSymbolicHotKeys") {
    for (which, raw) in table {
        guard let entry = raw as? [String: Any],
              entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int],
              parameters.count >= 3 else { continue }
        // parameters are [ASCII character, key code, modifier mask].
        guard parameters[1] == Int(keyCode) else { continue }
        let mods = UInt(bitPattern: parameters[2])
        print("  symbolichotkeys #\(which): same key, modifiers \(mods)"
              + (mods == cocoaModifiers ? "  ← COLLISION" : ""))
        if mods == cocoaModifiers { collisions += 1 }
    }
} else {
    print("  (no AppleSymbolicHotKeys table readable — treat this half as unmeasured)")
}
print(collisions == 0 ? "no system collision found" : "COLLIDES with \(collisions) system shortcut(s)")
```

- [ ] **Step 2: Run it**

Run: `swiftc -O -o /tmp/hka Scripts/hotkey-availability.swift && /tmp/hka`
Expected: `RegisterEventHotKey → 0 (accepted)` and `no system collision found`.

If it reports a collision, run it again for candidates in this order and take the first clean one: `KEY=14 /tmp/hka` (E), `KEY=17 MODS=cmd,opt,shift /tmp/hka` (⇧⌥⌘T). Whatever comes back clean is the constant Task 2 writes — record which one and why.

- [ ] **Step 3: Record the measurement**

Add to `docs/reference/MEASUREMENTS.md`, in the shape its neighbours use (what was measured, when, with what, and the number):

```markdown
### The правка shortcut's factory combination (2026-08-15)

`Scripts/hotkey-availability.swift`, on this machine: ⌥⌘R (key code 15, Cocoa modifiers
1572864) is accepted by `RegisterEventHotKey` (status 0) and collides with no enabled entry
in `com.apple.symbolichotkeys`. Both halves matter — a system shortcut is registered
successfully and then never delivered, so the Carbon status alone proves nothing.
```

Replace the combination and the numbers with what the probe actually printed. **Do not write a number the run did not produce.**

- [ ] **Step 4: Commit**

```bash
git add Scripts/hotkey-availability.swift docs/reference/MEASUREMENTS.md
git commit -m "test(app): probe whether the правка shortcut's combination is free"
```

---

### Task 2: The setting

Spec §3. A second `HotkeyCombo` in `AppSettings`, and a factory constant beside `HotkeyCombo.default`.

**Files:**
- Modify: `Sources/TextCapture/HotkeyCombo.swift` (after `static let default`, ~line 45)
- Modify: `Sources/TranslatorApp/AppSettings.swift` (after `var hotkey`, ~line 339)
- Test: `Tests/TranslatorAppTests/AppSettingsTests.swift`

**Interfaces:**
- Consumes: `HotkeyCombo`, `AppSettings`, `InMemoryDefaults`.
- Produces: `HotkeyCombo.proofreadDefault: HotkeyCombo` and `AppSettings.proofreadHotkey: HotkeyCombo` (get/set), stored under the key `"proofreadHotkey"`. Tasks 3, 4 and 5 read both.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslatorAppTests/AppSettingsTests.swift`. `freshDefaults()` already exists in that file.

```swift
@Test func theProofreadHotkeyDefaultsToOptionCommandRAndSurvivesARelaunch() {
    let defaults = freshDefaults()
    #expect(AppSettings(defaults: defaults).proofreadHotkey == HotkeyCombo.proofreadDefault)
    // The two factory shortcuts must differ, or the app ships a collision it then refuses
    // to let the user record.
    #expect(HotkeyCombo.proofreadDefault != HotkeyCombo.default)

    let custom = HotkeyCombo(keyCode: 0x23,
                             modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    AppSettings(defaults: defaults).proofreadHotkey = custom
    // A second instance over the same suite is what a relaunch looks like from here.
    #expect(AppSettings(defaults: defaults).proofreadHotkey == custom)
    // …and the перевод shortcut is untouched by it, which is the whole point of a second key.
    #expect(AppSettings(defaults: defaults).hotkey == HotkeyCombo.default)
}

@Test func aCorruptStoredProofreadHotkeyFallsBackToItsOwnDefault() {
    // Same threat as `hotkey`'s: the value is JSON in a single user-writable key. The
    // consequence differs — правка losing its shortcut leaves перевод's working — but a
    // setting whose stored state and behaviour disagree is the defect either way.
    let defaults = freshDefaults()
    defaults.set(Data("{ not json".utf8), forKey: "proofreadHotkey")
    #expect(defaults.data(forKey: "proofreadHotkey") != nil)
    #expect(AppSettings(defaults: defaults).proofreadHotkey == HotkeyCombo.proofreadDefault)

    // A value that decodes cleanly and is still unusable — a bare letter — is the quieter
    // half, and it is the one that would reach `HotkeyManager.register` and be refused.
    let bareLetter = HotkeyCombo(keyCode: 0x0F, modifiers: 0)
    #expect(!bareLetter.isValid)   // the premise, not the claim
    defaults.set(try? JSONEncoder().encode(bareLetter), forKey: "proofreadHotkey")
    #expect(AppSettings(defaults: defaults).proofreadHotkey == HotkeyCombo.proofreadDefault)
}

@Test func changingTheProofreadHotkeyNotifiesObservers() {
    // Neither test above can see a missing `access(keyPath:)` / `withMutation(keyPath:_:)`
    // — a round trip through `UserDefaults` succeeds just as well without them, and this
    // class has shipped that defect once already.
    let settings = AppSettings(defaults: freshDefaults())
    let fired = FiredFlag()
    withObservationTracking {
        _ = settings.proofreadHotkey
    } onChange: {
        fired.value = true
    }
    settings.proofreadHotkey = HotkeyCombo(keyCode: 0x23,
                                           modifiers: NSEvent.ModifierFlags.control.rawValue)
    #expect(fired.value)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter theProofreadHotkeyDefaultsToOptionCommandRAndSurvivesARelaunch`
Expected: compile error — `proofreadDefault` and `proofreadHotkey` do not exist.

- [ ] **Step 3: Add the factory constant**

In `Sources/TextCapture/HotkeyCombo.swift`, directly under `static let default`:

```swift
    /// The правка shortcut's default.
    ///
    /// A constant of its own rather than «`default` plus ⇧» computed at the call site: the
    /// two settings are independent, so a derived value would stop being the factory one the
    /// instant the user changed the first — and the factory value is what an unreadable
    /// stored value falls back to.
    ///
    /// ⌥⌘R because a Carbon hot key takes its combination from every application on the
    /// machine, and this one was measured free: `Scripts/hotkey-availability.swift` reports
    /// `RegisterEventHotKey` accepting it and no enabled entry in
    /// `com.apple.symbolichotkeys` holding it (2026-08-15, docs/reference/MEASUREMENTS.md).
    public static let proofreadDefault = HotkeyCombo(
        keyCode: UInt16(kVK_ANSI_R),
        modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)
```

If Task 1 chose a different key, change the key code **and** the sentence naming ⌥⌘R.

- [ ] **Step 4: Add the setting**

In `Sources/TranslatorApp/AppSettings.swift`, directly after the `hotkey` property:

```swift
    /// The правка shortcut, stored exactly as `hotkey` is: one JSON value under one key,
    /// `isValid` re-checked on the way out because a plist is user-writable and a value that
    /// decodes cleanly can still be unusable.
    ///
    /// **One piece of `hotkey`'s reasoning does not transfer, and the difference is worth
    /// stating.** That property falls back to its default rather than to «no hotkey» because
    /// the shortcut is the only way in to the panel, so an unset value would be an
    /// unrecoverable state reached by a typo. That door stays open here whatever this
    /// property holds. The fallback is kept anyway, for the weaker but still sufficient
    /// reason: a setting whose stored state and behaviour disagree is a setting the user
    /// cannot reason about.
    var proofreadHotkey: HotkeyCombo {
        get {
            access(keyPath: \.proofreadHotkey)
            guard let data = defaults.data(forKey: "proofreadHotkey"),
                  let decoded = try? JSONDecoder().decode(HotkeyCombo.self, from: data),
                  decoded.isValid
            else { return .proofreadDefault }
            return decoded
        }
        set {
            withMutation(keyPath: \.proofreadHotkey) {
                guard let encoded = try? JSONEncoder().encode(newValue) else {
                    Log.settings.error("""
                        could not encode the правка combination; it was not stored and the \
                        default remains in force \
                        (combination: \(newValue.displayString, privacy: .public))
                        """)
                    defaults.removeObject(forKey: "proofreadHotkey")
                    return
                }
                defaults.set(encoded, forKey: "proofreadHotkey")
            }
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ProofreadHotkey` then `swift test`
Expected: the three new tests pass, and the whole suite stays green.

- [ ] **Step 6: Commit**

```bash
git add Sources/TextCapture/HotkeyCombo.swift Sources/TranslatorApp/AppSettings.swift \
        Tests/TranslatorAppTests/AppSettingsTests.swift
git commit -m "feat(app): a second stored combination, for правка"
```

---

### Task 3: Two registrations, one coordinator

Spec §4 and §5. This is the task that makes the feature work; everything before it is storage and everything after is polish.

**Files:**
- Modify: `Sources/TranslatorApp/HotkeyCoordinator.swift`
- Modify: `Sources/TranslatorApp/TranslatorApp.swift:348-366` (`launch()`'s registration) and `:449-458` (`observeHotkeyChanges()`)
- Test: `Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AppSettings.hotkey`, `AppSettings.proofreadHotkey` (Task 2), `TextOperation`.
- Produces:
  - `HotkeyCoordinator.init(settings:glossary:translator:selectionReader:managers:pasteboard:)` — the `manager:` parameter becomes `managers: [TextOperation: HotkeyManager]? = nil`.
  - `func start(onPress: @escaping @MainActor (TextOperation) -> Void) -> Bool`
  - `func registeredCombo(for: TextOperation) -> HotkeyCombo?` — replaces the `registeredCombo` property.
  - `func pressAction(for: TextOperation) -> @MainActor () -> Void`
  - `func handlePress(operation: TextOperation = .translate, willCapture:afterCapture:) async`

- [ ] **Step 1: Write the failing tests**

Two existing tests call the old API and must be updated in the same edit — `theRegistrationFollowsTheStoredCombinationWhenItChanges` and `aRefusedReRegistrationPutsThePreviousCombinationBack`. In both, change `coordinator.start {}` to `coordinator.start { _ in }`, change `coordinator.registeredCombo` to `coordinator.registeredCombo(for: .translate)`, and add `settings.proofreadHotkey = combo(0x2D)` next to the existing `settings.hotkey = combo(0x2B)` — otherwise `start` registers the real ⌥⌘R and takes it from the developer for the length of the run.

Then append:

```swift
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
    // The rule the spec's §8 stated as «every press starts with перевод» becomes «every
    // press starts with its own operation». Both directions, because inheritance in either
    // one is a press doing something the user did not ask for.
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
    // `isCapturing` is per coordinator, and this is what that buys: two shortcuts cannot
    // put two synthetic ⌘C fallbacks into the user's application over one pasteboard.
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
    // The one that did not change is still live. A `refreshRegistration()` that
    // re-registered both would look identical from the setting's side and would drop the
    // other shortcut for the length of a Carbon round trip.
    #expect(coordinator.registeredCombo(for: .translate) == combo(0x2B))
}

@MainActor
@Test func aRefusedProofreadRegistrationLeavesTheTranslationShortcutAlone() {
    // The refusal path, from the side that matters now that there are two: правка failing
    // to register must not cost перевод its shortcut, since перевод is the only door to the
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
    // coordinator that built both actions from the same operation — the obvious slip when
    // one closure becomes two — passes every other test in this file.
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter HotkeyCoordinatorTests`
Expected: compile errors — `handlePress(operation:)`, `registeredCombo(for:)` and `pressAction(for:)` do not exist.

- [ ] **Step 3: Rewrite the registration half of the coordinator**

In `Sources/TranslatorApp/HotkeyCoordinator.swift`, replace the `manager` property, the `onPress` property, the `manager` init parameter, and the whole `// MARK: - Registration` section with:

```swift
    /// One manager per operation. **Two managers rather than one holding two registrations,
    /// and that is not an arbitrary split.** `HotkeyManager`'s own event handler already
    /// distinguishes registrations by `signature` and `hotKeyID`, and its comment records —
    /// measured — that a second manager in this process installs a second handler on the same
    /// dispatcher target and that every handler there is offered every hot-key event. Teaching
    /// one manager to hold several would edit the file where Carbon, `nonisolated(unsafe)` and
    /// a C callback live, to buy what that file was already written for.
    private let managers: [TextOperation: HotkeyManager]

    /// Kept so a re-registration after a settings change can reinstall the same action.
    /// Takes the operation, so one closure serves both registrations and the app does not
    /// have to keep two of them in step.
    @ObservationIgnored private var onPress: (@MainActor (TextOperation) -> Void)?
```

The init parameter becomes:

```swift
         managers: [TextOperation: HotkeyManager]? = nil,
```

and its assignment, with the existing comment about default arguments and main-actor isolation kept and extended:

```swift
        // Optional rather than a default argument for the reason that comment gave — a
        // default argument is evaluated in a nonisolated context and `HotkeyManager` is
        // `@MainActor` — and built from `allCases` so a third operation cannot arrive with
        // no shortcut and no compiler complaint.
        self.managers = managers ?? Dictionary(
            uniqueKeysWithValues: TextOperation.allCases.map { ($0, HotkeyManager()) })
```

Then the registration section:

```swift
    // MARK: - Registration

    /// What is registered right now for this operation, which is not always what the
    /// settings say — see `refreshRegistration()`.
    func registeredCombo(for operation: TextOperation) -> HotkeyCombo? {
        managers[operation]?.registered
    }

    /// Which stored combination belongs to which operation. Exhaustive with no `default:`,
    /// so a third operation fails to compile here rather than silently sharing перевод's key.
    private func combo(for operation: TextOperation) -> HotkeyCombo {
        switch operation {
        case .translate: settings.hotkey
        case .proofread: settings.proofreadHotkey
        }
    }

    /// What a press of this operation's shortcut does. Internal rather than private so a
    /// test can pin the wiring: nothing in a test process can press a Carbon hot key, and a
    /// coordinator that handed both registrations the same operation would otherwise pass
    /// every test in the suite.
    func pressAction(for operation: TextOperation) -> @MainActor () -> Void {
        { [weak self] in self?.onPress?(operation) }
    }

    /// Registers both stored combinations. Returns false when **either** was refused, which
    /// the caller surfaces rather than swallows.
    ///
    /// `reduce` and not `allSatisfy`: `allSatisfy` short-circuits, so a перевод refusal
    /// would leave правка unregistered as a side effect of how the check was written.
    @discardableResult
    func start(onPress: @escaping @MainActor (TextOperation) -> Void) -> Bool {
        self.onPress = onPress
        return TextOperation.allCases.reduce(true) { ok, operation in
            apply(combo(for: operation), for: operation) && ok
        }
    }

    /// Re-registers whichever shortcut the user changed. A no-op for one that did not move,
    /// so it is cheap to call from an observation callback that fires for any reason — and
    /// so a change to one shortcut does not drop the other for the length of a Carbon round
    /// trip.
    @discardableResult
    func refreshRegistration() -> Bool {
        TextOperation.allCases.reduce(true) { ok, operation in
            let wanted = combo(for: operation)
            guard wanted != managers[operation]?.registered else { return ok }
            return apply(wanted, for: operation) && ok
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
    /// already held anywhere in this process.
    ///
    /// The failure is logged **here** rather than at the call site, because here is where
    /// both paths meet: `refreshRegistration()` had no logging at all before this, and it is
    /// the path a user actually reaches, by choosing a combination another program holds.
    @discardableResult
    private func apply(_ combo: HotkeyCombo, for operation: TextOperation) -> Bool {
        // `onPress != nil` rather than binding it: the action registered is
        // `pressAction(for:)`, which reads the stored property at press time — binding a copy
        // here would freeze whichever action was installed at registration and quietly
        // survive a later `start(onPress:)`.
        guard onPress != nil, let manager = managers[operation] else { return false }
        let press = pressAction(for: operation)
        // Read before the call, not after: `register` clears `registered` on its way in.
        let previous = manager.registered
        if manager.register(combo, onPress: press) { return true }
        if let previous { manager.register(previous, onPress: press) }
        switch operation {
        case .translate:
            // `.fault` and not `.error`: перевод refused leaves the user with no shortcut
            // and no way into the panel, and the app still looks healthy — which is exactly
            // what makes it hard to diagnose.
            Log.hotkey.fault("""
                hotkey registration refused; the app has no shortcut and no way into the panel \
                (combination: \(combo.displayString, privacy: .public))
                """)
        case .proofread:
            // `.error` and not `.fault`, deliberately: правка refused costs the user a
            // shortcut, not the application. Copying перевод's level would make the log lie
            // about severity in the one place a severity is read.
            Log.hotkey.error("""
                правка shortcut registration refused; правка stays reachable from the panel's \
                switch (combination: \(combo.displayString, privacy: .public))
                """)
        }
        return false
    }
```

Remove the stray `_ = onPress` line if the compiler is satisfied without it — it is there only to make the `guard let onPress` binding used; if `pressAction(for:)` already reads the stored property (it does), delete both the binding and that line and guard on `managers[operation]` alone.

- [ ] **Step 4: Carry the operation into the press**

In the same file, change the signature and the assignment. The rest of `handlePress` — every comment, both hooks, the ordering — stays exactly as it is.

```swift
    func handlePress(operation: TextOperation = .translate,
                     willCapture: @MainActor () -> Void = {},
                     afterCapture: @MainActor () -> Void = {}) async {
```

and, where `panelModel.operation = .translate` stood:

```swift
        // The operation belongs to the shortcut that was pressed, and only to it: a press
        // never inherits what the previous presentation's switch was left on. That is the
        // предсказуемость the правка design's §8 asked for, restated now that there is more
        // than one shortcut — the design that supersedes it is
        // docs/design/specs/2026-08-15-proofread-hotkey-design.md.
        panelModel.operation = operation
```

Update the doc comment above `handlePress` to mention the new parameter in the shape the other two are documented.

- [ ] **Step 5: Wire the app**

In `Sources/TranslatorApp/TranslatorApp.swift`, `launch()`:

```swift
        if !coordinator.start(onPress: { operation in
            // The pointer is sampled *here*, at the press, and used after the capture. The
            // read can take up to three quarters of a second and the user's hand is still on
            // the mouse; the panel belongs where they were looking when they pressed.
            let cursor = NSEvent.mouseLocation
            // Hidden before the capture and shown after it, never before. The brief said
            // before; doing that breaks the capture outright, because the panel becomes the
            // key window and the system-wide accessibility focus follows it — see the
            // comment in `HotkeyCoordinator.handlePress`, which carries the measurement.
            Task {
                await coordinator.handlePress(operation: operation,
                                              willCapture: { panel.hide() },
                                              afterCapture: { panel.show(at: cursor) })
            }
        }) {
            // The message moved into `HotkeyCoordinator.apply`, which is where both
            // registration paths meet and where the two operations' severities differ.
            // Nothing is raised on screen, and that part is unchanged: a user-visible
            // message needs UI that does not exist yet.
        }
```

An empty `if` body is a warning risk. If the build complains, spell it as:

```swift
        coordinator.start(onPress: { operation in ... })
```

relying on `@discardableResult`, and delete the `if` — the logging is no longer here to condition on.

And `observeHotkeyChanges()`:

```swift
    /// Re-registers when the user changes either shortcut.
    ///
    /// Observation rather than a comparison on each panel show, for the reason that comment
    /// gave: after a change the *old* combination is still the registered one, so the user
    /// presses the new one, nothing happens, and the comparison that would have fixed it
    /// never runs.
    ///
    /// Both properties are read inside one tracking block, so one callback re-arms for both.
    /// `withObservationTracking` is one-shot and its `onChange` fires *before* the new value
    /// is stored, which is why the re-read happens on a later turn of the main actor.
    private func observeHotkeyChanges() {
        withObservationTracking {
            _ = settings.hotkey
            _ = settings.proofreadHotkey
        } onChange: {
            Task { @MainActor in
                coordinator.refreshRegistration()
                observeHotkeyChanges()
            }
        }
    }
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter HotkeyCoordinatorTests` then `swift build --build-tests 2>&1 | grep -c warning` then `swift test`
Expected: all coordinator tests pass; the warning count is `0`; the whole suite is green.

- [ ] **Step 7: Commit**

```bash
git add Sources/TranslatorApp/HotkeyCoordinator.swift Sources/TranslatorApp/TranslatorApp.swift \
        Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift
git commit -m "feat(app): a press carries its own operation, and two shortcuts register"
```

---

### Task 4: Recording the second shortcut

Spec §3 and §7's first row. The recorder must refuse a combination the other shortcut already holds, because Carbon would refuse it afterwards and `apply()` would silently restore the previous one — leaving the pane showing a combination that does not work.

**Files:**
- Modify: `Sources/TranslatorApp/HotkeyRecorder.swift`
- Modify: `Sources/TranslatorApp/SettingsGeneralView.swift:62-68`
- Test: `Tests/TranslatorAppTests/HotkeyRecorderTests.swift`

**Interfaces:**
- Consumes: `AppSettings.hotkey`, `AppSettings.proofreadHotkey`.
- Produces: `HotkeyRecorder(combo:reserved:)` where `reserved: [HotkeyCombo] = []`, and `HotkeyRecorder.RecorderView.reserved: [HotkeyCombo]`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/TranslatorAppTests/HotkeyRecorderTests.swift`:

```swift
/// A combination the other shortcut already holds is refused here, and the recorder stays
/// armed — the same shape, and the same reason, as the no-modifier refusal above.
///
/// The reason is sharper for this one. Accepting it would store a value the app cannot
/// register: Carbon refuses a combination already held in this process (-9878), and
/// `HotkeyCoordinator.apply` answers a refusal by putting the previous combination back. The
/// pane would then show one shortcut and the app would answer to another, with nothing on
/// screen to say so.
@MainActor @Test func aCombinationTheOtherShortcutHoldsIsRefusedAndTheRecorderStaysArmed() {
    let view = makeRecorder()
    var recorded: HotkeyCombo?
    view.onRecord = { recorded = $0 }
    let taken = HotkeyCombo(keyCode: 0x23,
                            modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)
    view.reserved = [taken]
    click(view)

    press(view, 0x23, [.option, .command])
    #expect(recorded == nil)
    #expect(view.combo == HotkeyCombo.default)   // nothing was written down

    // Still listening: the next combination that is not taken is recorded without a second
    // click. A recorder that disarmed on a refusal would make every attempt cost a click.
    press(view, 0x23, [.control, .option])
    #expect(recorded == HotkeyCombo(keyCode: 0x23,
                                    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue))
}

/// The refusal compares the *masked* candidate, not the raw event. A recorder that compared
/// `event.modifierFlags` against a stored combination would let ⌥⌘R-with-caps-lock through as
/// a different combination, store it masked, and produce the collision it just refused.
@MainActor @Test func theCollisionCheckComparesTheMaskedCombination() {
    let view = makeRecorder()
    var recorded: HotkeyCombo?
    view.onRecord = { recorded = $0 }
    view.reserved = [HotkeyCombo(keyCode: 0x23,
                                 modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)]
    click(view)

    press(view, 0x23, [.option, .command, .capsLock, .numericPad])
    #expect(recorded == nil)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter aCombinationTheOtherShortcutHoldsIsRefusedAndTheRecorderStaysArmed`
Expected: compile error — `reserved` does not exist on `RecorderView`.

- [ ] **Step 3: Add the refusal**

In `Sources/TranslatorApp/HotkeyRecorder.swift`:

```swift
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var combo: HotkeyCombo
    /// Combinations this recorder must refuse because something else in this app already
    /// holds them. An array rather than a `Set`, so `HotkeyCombo` does not have to gain
    /// `Hashable` for a list that is one element long.
    var reserved: [HotkeyCombo] = []
```

In `updateNSView`, beside the two assignments already there:

```swift
        view.reserved = reserved
```

On `RecorderView`, beside `combo`:

```swift
        /// See the property of the same name above. No `didSet`: this changes only when the
        /// *other* shortcut changes, and the drawing does not show it.
        var reserved: [HotkeyCombo] = []
```

And in `keyDown(with:)`, directly after the `isValid` guard:

```swift
            // Refused for the same reason and in the same way as an invalid combination:
            // Carbon would refuse this one too (-9878 for a combination already held in this
            // process) and `HotkeyCoordinator.apply` would put the previous one back, so
            // accepting it here would show the user a shortcut the app does not answer to.
            guard !reserved.contains(candidate) else { NSSound.beep(); return }
```

- [ ] **Step 4: Add the second recorder to the pane**

In `Sources/TranslatorApp/SettingsGeneralView.swift`, replace the «Сочетание клавиш» section:

```swift
            Section("Сочетание клавиш") {
                // Two rows, labelled by what they do rather than by «первое» и «второе»:
                // each shortcut opens the panel already performing its own operation, and
                // that is the only difference between them.
                LabeledContent("Перевод") {
                    HotkeyRecorder(combo: $settings.hotkey,
                                   reserved: [settings.proofreadHotkey])
                }
                LabeledContent("Правка") {
                    HotkeyRecorder(combo: $settings.proofreadHotkey,
                                   reserved: [settings.hotkey])
                }
                Text("Нажмите на поле и наберите новое сочетание. Нужен хотя бы один из "
                     + "модификаторов ⌃, ⌥ или ⌘ — иначе сочетание отняло бы обычную клавишу "
                     + "у всех остальных программ. Сочетания должны различаться: одно и то же "
                     + "система не отдаст дважды.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

`.fixedSize(horizontal: false, vertical: true)` is added because the caption is now three sentences: a `Text` given less width than it wants truncates rather than wrapping, and the clause that would go is the one explaining the refusal.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter HotkeyRecorderTests` then `swift test`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranslatorApp/HotkeyRecorder.swift Sources/TranslatorApp/SettingsGeneralView.swift \
        Tests/TranslatorAppTests/HotkeyRecorderTests.swift
git commit -m "feat(app): record the правка shortcut, and refuse a combination already taken"
```

---

### Task 5: Степень and стиль in the panel

Spec §6. The row, the coordinator methods behind it, and the wiring that keeps the panel a readout.

**Files:**
- Modify: `Sources/TranslatorApp/PanelView.swift` (the `header` region, ~line 305, and `translation`, ~line 382)
- Modify: `Sources/TranslatorApp/HotkeyCoordinator.swift` (after `switchOperation(to:)`)
- Modify: `Sources/TranslatorApp/TranslatorApp.swift` (`PanelHost` and `configurePanel()`)
- Test: `Tests/TranslatorAppTests/PanelViewTests.swift`, `Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AppSettings.defaultProofreadingLevel`, `AppSettings.defaultRewriteStyle`, `ProofreadingLevel.allowsRewriteStyle`, `HotkeyCoordinator.runTranslation()`.
- Produces:
  - `PanelView.showsProofreadingControls(operation:selection:) -> Bool` (`nonisolated static`)
  - `PanelView.init` gains `proofreadingLevel:`, `rewriteStyle:`, `onProofreadingLevelChange:`, `onRewriteStyleChange:`
  - `HotkeyCoordinator.setProofreadingLevel(_:) async`, `HotkeyCoordinator.setRewriteStyle(_:) async`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranslatorAppTests/PanelViewTests.swift`:

```swift
/// Which controls appear is a decision, and a decision inside a `ViewBuilder` can only be
/// read by rebuilding the view — the same reasoning that makes `status(for:)` a value.
@Test func theDegreeAndStyleControlsBelongOnlyToProofreadOverACapturedSelection() {
    #expect(PanelView.showsProofreadingControls(operation: .proofread,
                                                selection: .text("что-то")))
    // Перевод has no степень, so the row would be two controls governing nothing.
    #expect(!PanelView.showsProofreadingControls(operation: .translate,
                                                 selection: .text("что-то")))
    // And with nothing captured there is nothing to re-run: the panel is showing «выделите
    // текст» or the permission prompt, where an inert control is worse than no control.
    #expect(!PanelView.showsProofreadingControls(operation: .proofread, selection: .empty))
    #expect(!PanelView.showsProofreadingControls(operation: .proofread,
                                                 selection: .notPermitted))
}
```

Append to `Tests/TranslatorAppTests/HotkeyCoordinatorTests.swift`:

```swift
@MainActor
@Test func thePanelsDegreePickerWritesTheSettingAndRerunsTheCapturedSelection() async {
    // The panel's controls *are* the settings (design §6): a user who always proofreads with
    // style sets it once, where they use it. A per-run override would be forgotten by the
    // next press and send them to Settings anyway.
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
    // And the model was actually told, which is what the setting is for.
    let system = client.receivedMessages.last!.first!.content
    #expect(system.contains("smooth awkward phrasing"))
}

@MainActor
@Test func aDegreeChangeWithNothingCapturedNeitherWritesNorRuns() async {
    // The guards are `switchOperation(to:)`'s, and this is the one that would do damage: a
    // setting written from a panel showing «выделите текст» changes what the *next* press
    // does, for a click the user made on a control that should not have been there.
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
    // pinned because the failure is silent and expensive: without the operation guard, a
    // stray call would re-run a *translation* the user did not ask to repeat and would
    // change a правка setting to do it.
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter showsProofreadingControls` and `swift test --filter thePanelsDegreePickerWritesTheSetting`
Expected: compile errors — none of the three new members exist.

- [ ] **Step 3: Add the coordinator methods**

In `Sources/TranslatorApp/HotkeyCoordinator.swift`, after `switchOperation(to:)`:

```swift
    /// The panel's «степень» picker.
    ///
    /// Writes the **setting**, not a per-run override: the panel's controls are the settings
    /// (design §6), so a choice made where the operation is used survives the panel closing.
    /// `panelModel.proofreadingLevelOverride` stays nil on this model and keeps its single
    /// meaning — «the window's toolbar was used for this run».
    ///
    /// Guards are `switchOperation(to:)`'s, plus the operation itself: a stray call under
    /// перевод would re-run a translation the user did not ask to repeat.
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
```

- [ ] **Step 4: Add the row to the panel**

In `Sources/TranslatorApp/PanelView.swift`, add four stored properties beside the existing callbacks (`onSwitchOperation`, `onAnotherVariant`):

```swift
    /// The степень and стиль the next правка will use. Passed in rather than read from
    /// `AppSettings` here, because this view is a readout: `HotkeyCoordinator` owns every
    /// decision a press makes, and writing a setting is one.
    let proofreadingLevel: ProofreadingLevel
    let rewriteStyle: RewriteStyle
    let onProofreadingLevelChange: (ProofreadingLevel) -> Void
    let onRewriteStyleChange: (RewriteStyle) -> Void
```

Add the decision as a value, beside `announcement(for:)` and `status(for:)`:

```swift
    /// Whether the степень/стиль row belongs on screen.
    ///
    /// A value rather than a condition written inside the `ViewBuilder`, for `status(for:)`'s
    /// reason: which controls appear is a decision, and a decision inside a view body can
    /// only be read by rebuilding the view.
    ///
    /// The selection half is not redundant with the operation half: `header` is drawn by the
    /// permission prompt and the empty hint too, and a control with nothing captured to
    /// re-run is the inert chrome the operation switch is already gated against.
    nonisolated static func showsProofreadingControls(operation: TextOperation,
                                                      selection: SelectionResult) -> Bool {
        guard case .text = selection else { return false }
        return operation == .proofread
    }
```

Add the row itself:

```swift
    /// Степень and стиль, drawn only for правка.
    ///
    /// **Pinned, beside the header rather than inside `scrollingMiddle`**, for the reason the
    /// header is pinned: the middle region is where the reply and the warnings grow, and a
    /// control that scrolls away with them is one the user cannot reach at the moment they
    /// want it.
    ///
    /// Both pickers are `.menu`: a segmented степень would carry «только ошибки» and «ошибки
    /// и стиль» side by side, and the panel's width floor is 300 pt with 14 pt of padding
    /// each side — 272 pt for everything in the row. `Scripts/panel-proofread-row.swift`
    /// carries the measurement.
    @ViewBuilder private var proofreadingControls: some View {
        if Self.showsProofreadingControls(operation: model.operation, selection: selection) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { proofreadingLevel },
                                              set: { onProofreadingLevelChange($0) })) {
                    ForEach(ProofreadingLevel.allCases, id: \.self) {
                        Text($0.russianName).tag($0)
                    }
                }
                .fixedSize()
                .accessibilityLabel("Степень правки")
                Picker("", selection: Binding(get: { rewriteStyle },
                                              set: { onRewriteStyleChange($0) })) {
                    ForEach(RewriteStyle.allCases, id: \.self) {
                        Text($0.russianName).tag($0)
                    }
                }
                .fixedSize()
                // One rule, read from the type. The window's toolbar and the settings pane
                // read the same property; a restated comparison is how two surfaces come to
                // disagree about what is available (spec §7 of the правка design).
                .disabled(!proofreadingLevel.allowsRewriteStyle)
                .accessibilityLabel("Стиль правки")
                Spacer(minLength: 0)
            }
            .pickerStyle(.menu)
            .controlSize(.mini)
            .labelsHidden()
            // The same condition the operation switch carries: a control that restarts the
            // run must not be live while a run is in flight.
            .disabled(model.state == .running || awaitingRun)
        }
    }
```

And draw it in `translation`, directly under `header`:

```swift
            header
            proofreadingControls
```

- [ ] **Step 5: Wire the panel host**

In `Sources/TranslatorApp/TranslatorApp.swift`, `PanelHost` gains:

```swift
    /// Read **inside `body`**, not passed in already resolved, for the reason `selection` is
    /// read here: `PanelController` builds its hosting view once and keeps it, so a value
    /// resolved at the call site would freeze at whatever it was when the panel was built.
    /// Read here, it registers observation on `@Observable` `AppSettings` and the row
    /// redraws when the setting changes.
    let settings: AppSettings
```

passed to `PanelView`:

```swift
                  proofreadingLevel: settings.defaultProofreadingLevel,
                  rewriteStyle: settings.defaultRewriteStyle,
                  onProofreadingLevelChange: onProofreadingLevelChange,
                  onRewriteStyleChange: onRewriteStyleChange,
```

with two more stored closures on `PanelHost` beside `onSwitchOperation`:

```swift
    /// The степень and стиль pickers, threaded like every other callback here — see
    /// `HotkeyCoordinator.setProofreadingLevel(_:)`.
    let onProofreadingLevelChange: (ProofreadingLevel) -> Void
    let onRewriteStyleChange: (RewriteStyle) -> Void
```

and in `configurePanel()`, inside the `PanelHost(...)` call:

```swift
                settings: settings,
                onProofreadingLevelChange: { level in
                    Task { await coordinator.setProofreadingLevel(level) }
                },
                onRewriteStyleChange: { style in
                    Task { await coordinator.setRewriteStyle(style) }
                },
```

- [ ] **Step 6: Fix the other construction sites**

`PanelView` is also constructed in `Tests/TranslatorAppTests/TranslationPanelTests.swift` and possibly `PanelSizerTests.swift`. Run `grep -rn "PanelView(" Sources Tests` and give every call the four new arguments. For tests that do not care, `proofreadingLevel: .errorsOnly, rewriteStyle: .original, onProofreadingLevelChange: { _ in }, onRewriteStyleChange: { _ in }` is the neutral filling.

- [ ] **Step 7: Run the tests**

Run: `swift test` then `swift build --build-tests 2>&1 | grep -c warning`
Expected: green suite, warning count `0`.

- [ ] **Step 8: Commit**

```bash
git add Sources/TranslatorApp/PanelView.swift Sources/TranslatorApp/HotkeyCoordinator.swift \
        Sources/TranslatorApp/TranslatorApp.swift Tests/TranslatorAppTests
git commit -m "feat(app): степень and стиль where правка is used"
```

---

### Task 6: Measure the row against the panel's floor

Spec §8.1. The panel's width is clamped to 300–560 pt and **frozen for a whole presentation**, so a row that does not fit at 300 widens every правка panel. This measures it rather than assuming.

**Files:**
- Create: `Scripts/panel-proofread-row.swift`
- Modify: `docs/reference/MEASUREMENTS.md`, and `Sources/TranslatorApp/PanelView.swift` only if the row does not fit

**Interfaces:**
- Consumes: the row built in Task 5.
- Produces: a number, and either a confirmation or a shape change.

- [ ] **Step 1: Write the probe**

```swift
// Scripts/panel-proofread-row.swift
//
// Whether the panel's степень/стиль row fits at the panel's narrowest. `PanelSizer` clamps
// the width to 300–560 pt and freezes it for a whole presentation, and `PanelView` pads by 14
// on each side — so the row has 272 pt, and a row that wants more widens every правка panel
// for its whole life rather than wrapping.
//
//     swiftc -O -o /tmp/pr Scripts/panel-proofread-row.swift && /tmp/pr
//
// Measured with a detached `NSHostingController` and `fittingSize`, which is how
// `PanelController.measure` takes the panel's own ideal width — never the installed view,
// which measures what it is showing rather than what the content wants.
import SwiftUI
import AppKit

let levels = ["только ошибки", "ошибки и стиль"]
let styles = ["как в оригинале", "дружеский", "деловой", "профессиональный", "простой и ясный"]

struct Row: View {
    @State private var level = "ошибки и стиль"          // the longer of the two
    @State private var style = "профессиональный"        // the longest of the five
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $level) {
                ForEach(levels, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            Picker("", selection: $style) {
                ForEach(styles, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .pickerStyle(.menu)
        .controlSize(.mini)
        .labelsHidden()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = NSHostingController(rootView: Row())
host.view.layoutSubtreeIfNeeded()
let width = host.view.fittingSize.width
print(String(format: "row wants %.1f pt; the floor gives 272 pt (300 − 2 × 14)", width))
print(width <= 272 ? "FITS" : "DOES NOT FIT — change the row's shape, not the panel's floor")
```

- [ ] **Step 2: Run it**

Run: `swiftc -O -o /tmp/pr Scripts/panel-proofread-row.swift && /tmp/pr`
Expected: a number and a verdict.

- [ ] **Step 3: Act on the verdict**

If it **fits**: nothing to change in the code. Go to Step 4.

If it does **not** fit, apply the first of these that brings it under 272 and re-run the probe after each. They are ordered by what they cost the user, cheapest first.

1. **Stack the two pickers.** Wrap them in a `VStack(alignment: .leading, spacing: 4)` instead of the `HStack`, keeping everything else. Costs one row of panel height (~20 pt) on every правка and keeps both current values visible.

```swift
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: Binding(get: { proofreadingLevel },
                                              set: { onProofreadingLevelChange($0) })) {
                    ForEach(ProofreadingLevel.allCases, id: \.self) {
                        Text($0.russianName).tag($0)
                    }
                }
                .fixedSize()
                .accessibilityLabel("Степень правки")
                Picker("", selection: Binding(get: { rewriteStyle },
                                              set: { onRewriteStyleChange($0) })) {
                    ForEach(RewriteStyle.allCases, id: \.self) {
                        Text($0.russianName).tag($0)
                    }
                }
                .fixedSize()
                .disabled(!proofreadingLevel.allowsRewriteStyle)
                .accessibilityLabel("Стиль правки")
            }
```

2. **Give the style a fixed title instead of showing its value**, keeping the row on one line:

```swift
                Menu("Стиль") {
                    ForEach(RewriteStyle.allCases, id: \.self) { style in
                        Button(style.russianName) { onRewriteStyleChange(style) }
                    }
                }
                .fixedSize()
                .disabled(!proofreadingLevel.allowsRewriteStyle)
                .accessibilityLabel("Стиль правки")
                .accessibilityValue(rewriteStyle.russianName)
```

The chosen style is then invisible until the menu is opened, which is a real loss for a value that now persists between presses — say so in the measurement note rather than letting the next reader discover it.

Do **not** raise `PanelSizer`'s 300 pt floor. That number is measured (`docs/reference/OPEN-ITEMS.md` carries what it buys) and this row is not a reason to move it.

- [ ] **Step 4: Record the measurement**

Add to `docs/reference/MEASUREMENTS.md`:

```markdown
### The panel's степень/стиль row at the width floor (2026-08-15)

`Scripts/panel-proofread-row.swift`, longest label in each picker («ошибки и стиль»,
«профессиональный»), `.menu` style at `.controlSize(.mini)`: the row wants N pt against the
272 pt the panel's 300 pt floor leaves after its 14 pt padding. [Fits / does not fit, and
what was changed.]
```

Replace `N` with what the probe printed.

- [ ] **Step 5: Commit**

```bash
git add Scripts/panel-proofread-row.swift docs/reference/MEASUREMENTS.md Sources/TranslatorApp/PanelView.swift
git commit -m "test(app): measure the правка row against the panel's width floor"
```

---

### Task 7: Copy, documentation, and the manual checks

Spec §5's label change and §11's list. Nothing here changes behaviour; all of it keeps the documents true, which in this repository is a contract rather than housekeeping.

**Files:**
- Modify: `Sources/TranslatorApp/SettingsGeneralView.swift:156`
- Modify: `CLAUDE.md`, `CONTEXT.md`, `docs/reference/OPEN-ITEMS.md`, `docs/design/specs/2026-08-10-proofreading-design.md`

- [ ] **Step 1: Fix the autoCopy label**

In `SettingsGeneralView.swift`, in the «Поведение» section:

```swift
                // «результат» and no longer «перевод»: this setting is read in exactly one
                // place — `HotkeyCoordinator.runTranslation` — which now serves both
                // operations, so the label promised one of the two things it governs.
                Toggle("Копировать результат по сочетанию клавиш", isOn: $settings.autoCopy)
```

Keep the existing comment above it about `autoCopy` being panel-only; it is still true and still load-bearing.

- [ ] **Step 2: Update CLAUDE.md**

In the app-layer section, the `HotkeyCoordinator` bullet, replace the sentence describing one shortcut with:

```markdown
- `HotkeyCoordinator` owns every decision of a press; `PanelView` is a readout. **There are
  two shortcuts and one coordinator**: a `HotkeyManager` per `TextOperation`, and
  `handlePress(operation:)` assigns the pressed shortcut's operation to the panel model. Two
  managers rather than one holding two registrations, because `HotkeyManager`'s handler
  already distinguishes registrations by `signature` + `hotKeyID` and its comment records the
  measurement; two coordinators are forbidden for the reason the three models are — that
  would be a second panel and a second `TranslationViewModel`. Ordering inside a press is
  measured, not preferred: hide the old panel → read the selection off the main actor → show
  the panel → translate. Showing the panel first breaks the capture, because a
  `.nonactivatingPanel` still becomes *key* and system-wide accessibility focus follows the
  key window.
```

Add to the settings bullet: the two stored combinations are `"hotkey"` and `"proofreadHotkey"`, and the panel's степень/стиль pickers write `defaultProofreadingLevel` / `defaultRewriteStyle` directly rather than per-run overrides.

- [ ] **Step 3: Add the correction note to the правка spec**

At the top of §8 of `docs/design/specs/2026-08-10-proofreading-design.md`:

```markdown
> **Corrected 2026-08-15.** The first bullet below — «A press of ⌥⌘T behaves exactly as
> today: capture → перевод» — no longer describes the code. There are two shortcuts now, each
> carrying its own operation, and the panel has the степень/стиль controls this section
> predicted as «the expected first ask». See
> `docs/design/specs/2026-08-15-proofread-hotkey-design.md`. Everything else in this
> section still holds.
```

- [ ] **Step 4: Add the manual checks to docs/reference/OPEN-ITEMS.md**

In the table of checks owed to a human:

```markdown
| **A press of the правка shortcut** | Select a sentence with a mistake in another app and press ⌥⌘R. The panel must open already saying «правка · …», with the segment on «Правка» and the степень/стиль row under it. Nothing in a test process can press a Carbon hot key, so the wiring between a registration and its operation is pinned at `pressAction(for:)` and this is the only check of the whole path | `HotkeyCoordinator.apply`, `TranslatorApp.launch()` |
| **A pop-up menu inside the panel** | Open either picker in the row. The panel is a `.nonactivatingPanel` — key while the application stays inactive — and no measurement in this project covers `NSMenu` in that state. If it does not open, the fallbacks are in the design's §8.2 | `PanelView.proofreadingControls` |
| **The row at the panel's narrowest** | Drag the panel to its 300 pt floor with правка showing. The row must not clip and must not push the ⨯ off the header | `PanelSizer`, `PanelView.proofreadingControls` |
```

- [ ] **Step 5: Update CONTEXT.md**

Add to the vocabulary: «сочетание клавиш для перевода» and «сочетание клавиш для правки» as the names of the two settings, so the pane and the documents cannot drift.

- [ ] **Step 6: Verify and commit**

Run: `swift build --build-tests 2>&1 | grep -c warning` then `swift test`
Expected: `0` and a green suite.

```bash
git add Sources/TranslatorApp/SettingsGeneralView.swift CLAUDE.md CONTEXT.md \
        docs/reference/OPEN-ITEMS.md docs/design/specs/2026-08-10-proofreading-design.md
git commit -m "docs(app): record the second shortcut and what only a human can check"
```

---

## Final verification

- [ ] `swift build --build-tests 2>&1 | grep -c warning` → `0`
- [ ] `swift test` → green
- [ ] `./Scripts/make-app-bundle.sh` → builds, and the three manual checks in Task 7 Step 4 are performed against the bundle before the work is called done. GUI automation is unavailable here: **never describe UI behaviour that was not actually observed.**
