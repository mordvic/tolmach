import Testing
import Foundation
import AppKit
import Observation
@testable import TranslatorApp
@testable import TranslationCore
import TextCapture

/// An empty, isolated defaults store per test. In-memory rather than a real
/// `UserDefaults` suite, because a suite that gets written to leaves a plist in
/// ~/Library/Preferences that nothing can reliably remove — see `InMemoryDefaults`.
private func freshDefaults() -> InMemoryDefaults { InMemoryDefaults(prefix: "test") }

@Test func factoryValuesMatchTheSpec() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(settings.primaryLanguage == .ru)
    #expect(settings.workingLanguage == .en)
    #expect(settings.defaultTone == .neutral)
    #expect(settings.keepAlive == "30m")
    #expect(settings.chunkSize == 900)
    #expect(settings.temperature == 0.2)
    #expect(settings.autoCopy == false)
    #expect(settings.warmUpOnLaunch == true)
    #expect(settings.interactiveModel == ModelPolicy.defaultModel(for: .interactive))
    // Off, both of them, until the measurement spec #72 names has been taken: the pass is a
    // second model call on every run, and the panel's own switch is off because that surface
    // promises a first token in under a second.
    #expect(settings.reconstructsStructure == false)
    #expect(settings.reconstructsStructureInPanel == false)
}

@Test func valuesSurviveAReload() {
    let defaults = freshDefaults()
    let first = AppSettings(defaults: defaults)
    first.chunkSize = 1200
    first.defaultTone = .technical
    let second = AppSettings(defaults: defaults)
    #expect(second.chunkSize == 1200)
    #expect(second.defaultTone == .technical)
}

/// The hand-check the Settings task asked for — change the primary language, quit,
/// relaunch, see it stick — needs a GUI this environment does not have. Its actual claim
/// does not: `AppSettings` caches nothing in memory, so a second instance over the same
/// store sees precisely what a relaunched app would read back. These five are the
/// properties the General tab binds. `valuesSurviveAReload` above happens to cover two of
/// them; this covers the tab's whole set on purpose, so adding a control to that tab
/// without a working setter behind it fails here.
///
/// What this pins is that every General-tab setter writes through to the store and every
/// getter reads back from it, with nothing cached in between — the failure it is built to
/// catch is a setter that silently drops its write. The store is in-memory (see
/// `InMemoryDefaults`), so the round trip is no longer through a plist on disk; the values
/// involved are strings, ints, doubles and bools, which is not where a serialisation bug
/// would hide, and the alternative was leaking a preferences file on every single run.
@Test func everySettingTheGeneralTabBindsSurvivesARelaunch() {
    let defaults = freshDefaults()

    let beforeQuit = AppSettings(defaults: defaults)
    // Every value differs from the factory default, so a setter that quietly drops its
    // write leaves the factory value in place and is caught rather than matching by luck.
    beforeQuit.primaryLanguage = .de
    beforeQuit.workingLanguage = .fr
    beforeQuit.defaultTone = .formal
    beforeQuit.autoCopy = true
    beforeQuit.warmUpOnLaunch = false

    let afterRelaunch = AppSettings(defaults: defaults)
    #expect(afterRelaunch.primaryLanguage == .de)
    #expect(afterRelaunch.workingLanguage == .fr)
    #expect(afterRelaunch.defaultTone == .formal)
    #expect(afterRelaunch.autoCopy == true)
    #expect(afterRelaunch.warmUpOnLaunch == false)
}

/// Beyond the brief, and the whole contract of the first-launch prompt in one test.
/// `TranslatorApp.launch()` raises the system Accessibility dialog only while this reads
/// false, so a getter that defaulted to `true` would mean the dialog is never shown at all,
/// and a setter that dropped its write would mean it is shown on every single launch. Both
/// failures are silent in a build that otherwise works, and neither is visible in the two
/// existing round-trip tests, which cover only the properties the General tab binds — this
/// one is deliberately not bound to any control.
@Test func theAccessibilityPromptIsRaisedOnceAndThenLatched() {
    let defaults = freshDefaults()
    #expect(AppSettings(defaults: defaults).hasRequestedAccessibility == false)

    AppSettings(defaults: defaults).hasRequestedAccessibility = true
    // A second instance over the same store is what the next launch reads.
    #expect(AppSettings(defaults: defaults).hasRequestedAccessibility == true)
}

@Test func directionFollowsThePrimaryLanguageRule() {
    let settings = AppSettings(defaults: freshDefaults())   // ru primary, en working
    // Source is the primary language -> translate into the working one.
    #expect(settings.targetLanguage(forDetected: .ru) == .en)
    // Anything else -> translate into the primary one.
    #expect(settings.targetLanguage(forDetected: .de) == .ru)
    #expect(settings.targetLanguage(forDetected: .en) == .ru)
    // Undetected is not the primary language, so it goes to the primary one too.
    #expect(settings.targetLanguage(forDetected: nil) == .ru)
}

/// `onChange` is `@Sendable`, so a captured `var` can't be mutated inside it under
/// strict concurrency checking. A small reference box sidesteps that without
/// weakening what's actually being asserted.
private final class FiredFlag: @unchecked Sendable {
    var value = false
}

@Test func changingAValueNotifiesObservers() {
    let settings = AppSettings(defaults: freshDefaults())
    let fired = FiredFlag()
    withObservationTracking {
        _ = settings.chunkSize
    } onChange: {
        fired.value = true
    }
    settings.chunkSize = 1200
    #expect(fired.value)
}

@Test func theHotkeyDefaultsToOptionCommandTAndSurvivesARelaunch() {
    let defaults = freshDefaults()
    #expect(AppSettings(defaults: defaults).hotkey == HotkeyCombo.default)

    let custom = HotkeyCombo(keyCode: 0x23, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    AppSettings(defaults: defaults).hotkey = custom
    // A second instance over the same suite is what a relaunch looks like from here.
    #expect(AppSettings(defaults: defaults).hotkey == custom)
}

@Test func aCorruptStoredHotkeyFallsBackToTheDefaultRatherThanLeavingNoHotkeyAtAll() {
    // The value is JSON in a single key and the file is user-writable. A half-written or
    // hand-mangled value must not leave the app with nothing registered and no way to fix
    // it, since the settings pane is reachable from the menu but the hotkey is not.
    let defaults = freshDefaults()
    defaults.set(Data("{ not json".utf8), forKey: "hotkey")
    // Pinned so this cannot pass for the wrong reason. `InMemoryDefaults` overrides
    // `object(forKey:)` but not `data(forKey:)`; the two are only connected because
    // `NSUserDefaults` implements the latter on top of the former, which is an
    // implementation detail this suite depends on. Were that to stop holding, the getter
    // below would see no data at all, return `.default`, and this test would pass while
    // testing nothing. Measured today: it holds.
    #expect(defaults.data(forKey: "hotkey") != nil)
    #expect(AppSettings(defaults: defaults).hotkey == HotkeyCombo.default)
}

/// Beyond the brief. A stored value that decodes cleanly can still be one the app must not
/// use: `{"keyCode":17,"modifiers":0}` is valid JSON and a valid `HotkeyCombo`, and it is a
/// bare «T». The recorder refuses those, but the recorder is not the only writer — a
/// hand-edited plist is exactly the threat the corrupt-value case above is written for, and
/// this half of it is the worse half. Undecodable bytes cost the user their custom
/// shortcut; a decodable invalid one gets handed to `HotkeyManager.register`, which refuses
/// it and leaves the app with *no* hotkey — and the hotkey is the only way to the panel.
/// A bare letter that did somehow register would be worse still, taking «T» away from every
/// other program on the machine.
@Test func aStoredHotkeyWithNoUsableModifierFallsBackToTheDefault() {
    let defaults = freshDefaults()
    let bareLetter = HotkeyCombo(keyCode: 0x11, modifiers: 0)
    #expect(!bareLetter.isValid)   // the premise, not the claim
    defaults.set(try? JSONEncoder().encode(bareLetter), forKey: "hotkey")
    #expect(AppSettings(defaults: defaults).hotkey == HotkeyCombo.default)

    // Shift alone is the same hole through a narrower gap, and the one a plausible typo
    // reaches: ⇧T is how the whole world types a capital T.
    let shiftOnly = HotkeyCombo(keyCode: 0x11, modifiers: NSEvent.ModifierFlags.shift.rawValue)
    defaults.set(try? JSONEncoder().encode(shiftOnly), forKey: "hotkey")
    #expect(AppSettings(defaults: defaults).hotkey == HotkeyCombo.default)
}

/// Beyond the brief. `HotkeyCombo.init(from:)` is hand-written precisely so a stored value
/// gets masked on the way back in, and nothing at this layer pinned that the settings store
/// actually goes through it. Bytes in a plist are not necessarily bytes this build wrote:
/// caps lock, the numeric pad and the fn key all set bits that survive
/// `deviceIndependentFlagsMask`, and an unmasked `modifiers` compares unequal to the same
/// visible combination recorded fresh — so the settings pane would show ⌘T, the manager
/// would register ⌘T, and `settings.hotkey == recordedCombo` would be false anyway.
///
/// Written as raw JSON rather than by encoding a `HotkeyCombo`, because encoding one would
/// have masked the bits before they ever reached the store and the test would prove nothing.
@Test func aStoredHotkeyWithStrayModifierBitsReadsBackAsTheVisibleCombination() {
    let defaults = freshDefaults()
    let dirty = NSEvent.ModifierFlags([.command, .capsLock, .numericPad, .function]).rawValue
    defaults.set(Data(#"{"keyCode":17,"modifiers":\#(dirty)}"#.utf8), forKey: "hotkey")

    let expected = HotkeyCombo(keyCode: 0x11, modifiers: NSEvent.ModifierFlags.command.rawValue)
    // Distinct from `.default` (⌥⌘, same key code), so a decode that failed outright and
    // fell back would fail this rather than sail past it.
    #expect(expected != HotkeyCombo.default)
    #expect(AppSettings(defaults: defaults).hotkey == expected)
}

/// Beyond the brief. Neither of the brief's two tests can see a missing `access(keyPath:)`
/// or `withMutation(keyPath:_:)` — a round trip through `UserDefaults` succeeds just as
/// well without them. That is the exact defect Plan 2 shipped on this class, and adding a
/// property is when it comes back.
@Test func changingTheHotkeyNotifiesObservers() {
    let settings = AppSettings(defaults: freshDefaults())
    let fired = FiredFlag()
    withObservationTracking {
        _ = settings.hotkey
    } onChange: {
        fired.value = true
    }
    settings.hotkey = HotkeyCombo(keyCode: 0x23, modifiers: NSEvent.ModifierFlags.control.rawValue)
    #expect(fired.value)
}

@Test func anUnsetBatchModelFollowsTheInteractiveOne() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "batch-model-unset"))
    #expect(settings.batchModel == nil)
    #expect(settings.resolvedBatchModel == settings.interactiveModel)

    settings.interactiveModel = "some-other-model:7b"
    // Still following, not frozen at whatever the interactive model was when first read.
    #expect(settings.resolvedBatchModel == "some-other-model:7b")
}

@Test func aChosenBatchModelStopsFollowingTheInteractiveOne() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "batch-model-set"))
    settings.batchModel = "gpt-oss:20b"
    settings.interactiveModel = "aya-expanse:8b"
    #expect(settings.resolvedBatchModel == "gpt-oss:20b")
}

@Test func theBatchModelReadsTheKeyTheRemovedBackgroundModelWroteTo() {
    // AppSettings' own removal comment promises this: a value a user stored before the
    // property was deleted stays under "backgroundModel" and v2 finds it again.
    let defaults = InMemoryDefaults(prefix: "batch-model-legacy")
    defaults.set("gpt-oss:20b", forKey: "backgroundModel")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.batchModel == "gpt-oss:20b")
}

@Test func clearingTheBatchModelReturnsItToFollowingTheInteractiveOne() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "batch-model-cleared"))
    settings.batchModel = "gpt-oss:20b"
    settings.batchModel = nil
    #expect(settings.batchModel == nil)
    #expect(settings.resolvedBatchModel == settings.interactiveModel)
}

@Test func anUnsetProofreadModelFollowsTheInteractiveOne() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "proofread-model-unset"))
    #expect(settings.proofreadModel == nil)
    #expect(settings.resolvedProofreadModel == settings.interactiveModel)
    #expect(!settings.proofreadModelDiffersFromInteractive)
    settings.interactiveModel = "translategemma:12b"
    // Following, not frozen at whatever the interactive model was when first read.
    #expect(settings.resolvedProofreadModel == "translategemma:12b")
}

@Test func aChosenProofreadModelStopsFollowingTheInteractiveOneAndAnEmptyChoiceClearsIt() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "proofread-model-set"))
    settings.proofreadModel = "gemma4:26b"
    settings.interactiveModel = "translategemma:12b"
    #expect(settings.resolvedProofreadModel == "gemma4:26b")
    #expect(settings.proofreadModelDiffersFromInteractive)
    // The same model chosen explicitly is not «different» — the pane's note must not draw.
    settings.proofreadModel = "translategemma:12b"
    #expect(!settings.proofreadModelDiffersFromInteractive)
    // Empty string stores as nil, like `batchModel`: «» is not a model.
    settings.proofreadModel = ""
    #expect(settings.proofreadModel == nil)
    #expect(settings.resolvedProofreadModel == settings.interactiveModel)
}

@Test func theGptOssDepthControlAlsoAppearsWhenOnlyTheProofreadModelIsGptOss() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "proofread-gpt-oss"))
    settings.interactiveModel = "aya-expanse:8b"
    #expect(!settings.usesGptOss)
    settings.proofreadModel = "gpt-oss:20b"
    #expect(settings.usesGptOss)
}

@Test func choosingABatchModelThatDiffersFromTheHotkeysIsWorthWarningAbout() {
    // Ollama holds one model: cold load ~2000 ms against ~155 ms warm. A batch model
    // that differs costs two of those on every hotkey press during a queue run, and the
    // pane has to say so rather than leaving the user to discover it.
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "batch-warning"))
    #expect(!settings.batchModelDiffersFromInteractive)

    settings.batchModel = "gpt-oss:20b"
    settings.interactiveModel = "aya-expanse:8b"
    #expect(settings.batchModelDiffersFromInteractive)

    settings.batchModel = "aya-expanse:8b"
    #expect(!settings.batchModelDiffersFromInteractive)
}

@Test func theQueueSavesBesideTheSourceUnlessToldOtherwise() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "queue-saving"))
    #expect(settings.saveNextToSource)
    settings.saveNextToSource = false
    #expect(!settings.saveNextToSource)
}

@Test func theQueueRunsToTheEndAndTheTermsGateIsOffUntilAskedFor() {
    let settings = AppSettings(defaults: InMemoryDefaults(prefix: "queue-defaults"))
    #expect(!settings.stopOnWarnings)
    // Ships off even though the design draws it on: the drawing assumed the gate lived
    // in the batch path only, and it reaches ⌥⌘T too.
    #expect(!settings.reviewDocumentTerms)
}

@Test func proofreadingDefaultsAreTheSafeOnes() {
    let settings = AppSettings(defaults: freshDefaults())
    // «Только ошибки» and «как в оригинале»: the tool touches someone's finished
    // text, and no surveyed product defaults to a tone (spec §3, §7).
    let level: ProofreadingLevel = .errorsOnly
    let style: RewriteStyle = .original
    #expect(settings.defaultProofreadingLevel == level)
    #expect(settings.defaultRewriteStyle == style)
}

@Test func proofreadingSettingsRoundTripAndSurviveGarbage() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    let styleValue: ProofreadingLevel = .errorsAndStyle
    let rewriteValue: RewriteStyle = .business
    settings.defaultProofreadingLevel = styleValue
    settings.defaultRewriteStyle = rewriteValue
    #expect(settings.defaultProofreadingLevel == styleValue)
    #expect(settings.defaultRewriteStyle == rewriteValue)
    // «Переписать» stores under the same key — no migration, and a downgrade to a build
    // without the case reads it as the unknown-value fallback below (issue #40).
    settings.defaultProofreadingLevel = .rewrite
    #expect(settings.defaultProofreadingLevel == .rewrite)
    // A plist is user-writable; an unreadable value falls back to the default
    // rather than to a crash or an absent control.
    defaults.set("nonsense", forKey: "proofreadingLevel")
    defaults.set("nonsense", forKey: "rewriteStyle")
    let defaultLevel: ProofreadingLevel = .errorsOnly
    let defaultStyle: RewriteStyle = .original
    #expect(settings.defaultProofreadingLevel == defaultLevel)
    #expect(settings.defaultRewriteStyle == defaultStyle)
}

@Test func thinkingIsQuietOnAFreshInstall() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(settings.quietThinking == true)
    #expect(settings.gptOssThinkingLevel == .low)
}

@Test func aStoredThinkingLevelSurvivesAReloadAndAnUnrecognisedOneReadsBackAsLow() {
    let defaults = freshDefaults()
    let first = AppSettings(defaults: defaults)
    first.gptOssThinkingLevel = .high
    #expect(AppSettings(defaults: defaults).gptOssThinkingLevel == .high)

    // Hand-edited or written by a future version: a raw value this build does not know must
    // not trap and must not silently mean «high».
    defaults.set("exhaustive", forKey: "gptOssThinkingLevel")
    #expect(AppSettings(defaults: defaults).gptOssThinkingLevel == .low)
}

@Test func chatOptionsCarryTheThinkDecisionForWhicheverModelIsAskedFor() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.interactiveModel = "qwen3:8b"
    settings.batchModel = "gpt-oss:20b"
    #expect(settings.chatOptions(model: settings.interactiveModel).think == .off)
    #expect(settings.chatOptions(model: settings.resolvedBatchModel).think == .level(.low))

    settings.quietThinking = false
    #expect(settings.chatOptions(model: settings.interactiveModel).think == nil)
    #expect(settings.chatOptions(model: settings.resolvedBatchModel).think == nil)
}

@Test func chatOptionsStillCarryTheTemperatureAndKeepAliveTheUserSet() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.temperature = 0.45
    settings.keepAlive = "5m"
    let options = settings.chatOptions(model: "aya-expanse:8b")
    #expect(options.model == "aya-expanse:8b")
    #expect(options.temperature == 0.45)
    #expect(options.keepAlive == "5m")
}

@Test func theDepthRowIsOfferedOnlyWhileAGptOssModelIsSelectedOnEitherPath() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.interactiveModel = "aya-expanse:8b"
    settings.batchModel = nil
    #expect(settings.usesGptOss == false)

    settings.batchModel = "gpt-oss:20b"
    #expect(settings.usesGptOss == true)

    settings.batchModel = nil
    settings.interactiveModel = "gpt-oss:20b"
    #expect(settings.usesGptOss == true)
}

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

@Test func theTwoShortcutsAreReportedAsCollidingWhenTheyHoldTheSameCombination() {
    // The factory pair must not collide, or every fresh install ships the warning.
    let settings = AppSettings(defaults: freshDefaults())
    #expect(!settings.shortcutsCollide)

    // The case that actually reaches this: перевод was already on ⌥⌘R before правка's setting
    // existed, so `proofreadHotkey` answers its factory value and the two match.
    settings.hotkey = HotkeyCombo.proofreadDefault
    #expect(settings.shortcutsCollide)

    settings.proofreadHotkey = HotkeyCombo(
        keyCode: 0x23, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)
    #expect(!settings.shortcutsCollide)
}

/// A fresh install renders exactly as the app did before «Шрифт текста» existed.
///
/// The factory value is not «a sensible default» — it is the one that reproduces `.body`, and
/// `ContentFontTests` pins that equivalence against the system. Here it is only pinned that
/// nothing in the settings layer moves it.
@Test func theContentFontStartsAtTheSizeTheAppAlwaysUsed() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(settings.contentFont == ContentFont.default)
    #expect(settings.contentTypeface == .system)
    #expect(settings.contentFontSize == ContentFont.defaultSize)
}

@Test func theContentFontSurvivesAReload() {
    let defaults = freshDefaults()
    let first = AppSettings(defaults: defaults)
    first.contentFont = ContentFont(typeface: .serif, size: 19)
    let second = AppSettings(defaults: defaults)
    #expect(second.contentFont == ContentFont(typeface: .serif, size: 19))
}

/// The two keys are read defensively, because this app is not their only writer.
///
/// `defaults write` and a hand-edited plist reach them just as the settings pane does — the
/// reasoning `hotkey` gives for re-checking `isValid` on the way *out* rather than trusting
/// what the setter stored. A face that no longer exists falls back to the system one; a size
/// from beyond the range is clamped rather than sizing a pane nobody can use.
@Test func nonsenseStoredByHandIsCorrectedOnTheWayOut() {
    let defaults = freshDefaults()
    defaults.set("copperplate", forKey: "contentTypeface")
    defaults.set(400.0, forKey: "contentFontSize")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.contentTypeface == .system)
    #expect(settings.contentFontSize == ContentFont.sizes.upperBound)

    defaults.set(0.0, forKey: "contentFontSize")
    #expect(AppSettings(defaults: defaults).contentFontSize == ContentFont.sizes.lowerBound)
}

/// Both halves notify, and this is the only kind of test that can see it: a round trip through
/// `UserDefaults` succeeds just as well with the hand-written `access(keyPath:)` /
/// `withMutation(keyPath:_:)` missing, and this class has shipped that defect once already.
///
/// It matters more here than for most settings: the panel re-measures itself from an
/// `.onChange` on this value, and the window's two panes redraw from reading it inside a body.
/// A missing `withMutation` would leave both surfaces on the old font until something else
/// happened to invalidate them.
@Test func changingTheContentFontNotifiesObservers() {
    for change in [ContentFont(typeface: .monospaced, size: ContentFont.defaultSize),
                   ContentFont(typeface: .system, size: 20)] {
        let settings = AppSettings(defaults: freshDefaults())
        let fired = FiredFlag()
        withObservationTracking {
            _ = settings.contentFont
        } onChange: {
            fired.value = true
        }
        settings.contentFont = change
        #expect(fired.value)
    }
}

// MARK: - The engine, and the settings that follow it

@Test func aFreshInstallTalksToOllamaSoNothingChangesForAnExistingUser() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(settings.engine == .ollama)
    #expect(settings.interactiveModel == ModelPolicy.defaultModel(for: .interactive))
    #expect(settings.enginePort == 11434)
}

@Test func eachEngineKeepsItsOwnChoiceOfModels() {
    // The whole reason these are per-engine: `translategemma:27b` does not exist in LM Studio
    // and `openai/gpt-oss-20b` does not exist in Ollama, so one shared field would leave the
    // first translation after a switch failing with «model not found».
    let settings = AppSettings(defaults: freshDefaults())
    settings.interactiveModel = "translategemma:27b"
    settings.batchModel = "gpt-oss:20b"
    settings.proofreadModel = "aya-expanse:32b"

    settings.engine = .lmStudio
    settings.interactiveModel = "qwen/qwen3.8-27b"
    settings.batchModel = "openai/gpt-oss-20b"
    settings.proofreadModel = "google/gemma-4-e4b"

    settings.engine = .ollama
    #expect(settings.interactiveModel == "translategemma:27b")
    #expect(settings.batchModel == "gpt-oss:20b")
    #expect(settings.proofreadModel == "aya-expanse:32b")

    settings.engine = .lmStudio
    #expect(settings.interactiveModel == "qwen/qwen3.8-27b")
    #expect(settings.batchModel == "openai/gpt-oss-20b")
    #expect(settings.proofreadModel == "google/gemma-4-e4b")
}

@Test func anUnchosenLMStudioModelReadsBackEmptyRatherThanAnOllamaDefault() {
    // `ModelPolicy.defaultModel(for:)` names Ollama tags, so there is no sensible default here.
    // Empty is what lets the window disable «Перевести» and say which setting to fill; an
    // Ollama tag would produce «model not found» from a server that never had it.
    let settings = AppSettings(defaults: freshDefaults())
    settings.engine = .lmStudio
    #expect(settings.interactiveModel.isEmpty)
    #expect(settings.hasNoTranslationModel)
    settings.interactiveModel = "qwen/qwen3.8-27b"
    #expect(settings.hasNoTranslationModel == false)
}

@Test func theResolvedModelsFollowTheEngineTheyWereChosenOn() {
    // `nil` still means «the same one перевод uses», per engine rather than across them.
    let settings = AppSettings(defaults: freshDefaults())
    settings.interactiveModel = "translategemma:27b"
    #expect(settings.resolvedBatchModel == "translategemma:27b")
    #expect(settings.resolvedProofreadModel == "translategemma:27b")

    settings.engine = .lmStudio
    settings.interactiveModel = "qwen/qwen3.8-27b"
    #expect(settings.resolvedBatchModel == "qwen/qwen3.8-27b")
    settings.batchModel = "openai/gpt-oss-20b"
    #expect(settings.resolvedBatchModel == "openai/gpt-oss-20b")
    settings.engine = .ollama
    #expect(settings.resolvedBatchModel == "translategemma:27b", "the LM Studio choice must not leak back")
}

@Test func eachEngineKeepsItsOwnPort() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.enginePort = 11435
    settings.engine = .lmStudio
    #expect(settings.enginePort == 1234)
    settings.enginePort = 4567
    settings.engine = .ollama
    #expect(settings.enginePort == 11435)
}

/// Switching the engine changes what every model property answers, and this is the only kind of
/// test that can see it: the hand-written `access(keyPath:)` calls are what make SwiftUI notice,
/// and a per-engine getter that registered only its *own* key would leave a picker showing the
/// other engine's model until something unrelated invalidated the view.
@Test func switchingTheEngineNotifiesWhoeverIsReadingAModelName() {
    let settings = AppSettings(defaults: freshDefaults())
    let fired = FiredFlag()
    withObservationTracking {
        _ = settings.interactiveModel
    } onChange: {
        fired.value = true
    }
    settings.engine = .lmStudio
    #expect(fired.value)
}

@Test func theThinkDecisionIsMadePerEngineBecauseTheTwoServersAnswerOppositeQuestions() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.gptOssThinkingLevel = .medium

    // Ollama: blind, so `ModelPolicy`'s tables decide. A plain model is asked to stop.
    settings.interactiveModel = "aya-expanse:8b"
    #expect(settings.chatOptions(model: "aya-expanse:8b").think == .off)
    // …and the one family that ignores being switched off is graded instead.
    #expect(settings.chatOptions(model: "gpt-oss:20b").think == .level(.medium))

    // LM Studio: the intent travels and the transport resolves it against what the model says
    // it accepts. Passing `ModelPolicy`'s answer would be quietly wrong — its prefixes match no
    // publisher-qualified name, so «Длина рассуждения» would be read by nobody.
    settings.engine = .lmStudio
    #expect(settings.chatOptions(model: "openai/gpt-oss-20b").think == .level(.medium))
    #expect(settings.chatOptions(model: "qwen/qwen3.8-27b").think == .level(.medium))
}

@Test func askingForNoQuietSendsNothingOnEitherEngine() {
    // The user wants the model's own behaviour: no key on the wire, whichever server it is.
    let settings = AppSettings(defaults: freshDefaults())
    settings.quietThinking = false
    #expect(settings.chatOptions(model: "gpt-oss:20b").think == nil)
    settings.engine = .lmStudio
    #expect(settings.chatOptions(model: "openai/gpt-oss-20b").think == nil)
}

// MARK: - What gets warmed at launch

@Test func ollamaWarmsBothHotkeyModelsAndLMStudioWarmsOnlyTheOneThatTranslates() {
    // Not a transport difference — a memory one. Two Ollama models that fit stay resident
    // together (measured 2026-08-18); the LM Studio install here is all MLX with the 27B class
    // at 22.81 GB apiece against 48 GB, so warming two at *login* would either fail or swap.
    let settings = AppSettings(defaults: freshDefaults())
    settings.interactiveModel = "aya-expanse:8b"
    settings.proofreadModel = "gemma4:26b"
    #expect(WarmUpPlan.models(for: settings) == ["aya-expanse:8b", "gemma4:26b"])

    settings.engine = .lmStudio
    settings.interactiveModel = "qwen/qwen3.8-27b"
    settings.proofreadModel = "google/gemma-4-e4b"
    #expect(WarmUpPlan.models(for: settings) == ["qwen/qwen3.8-27b"])
}

@Test func nothingIsWarmedBeforeAModelHasBeenChosen() {
    // The state LM Studio starts in. Asking a server to load «» is a refusal with a confusing
    // message on it, at launch, about something the user never asked for.
    let settings = AppSettings(defaults: freshDefaults())
    settings.engine = .lmStudio
    #expect(WarmUpPlan.models(for: settings).isEmpty)
    settings.interactiveModel = "qwen/qwen3.8-27b"
    #expect(WarmUpPlan.models(for: settings) == ["qwen/qwen3.8-27b"])
}

@Test func warmingUpIsSkippedEntirelyWhenTheSettingIsOff() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.warmUpOnLaunch = false
    #expect(WarmUpPlan.models(for: settings).isEmpty)
}

@Test func onlyOneModelIsWarmedWhenBothRolesUseTheSameOne() {
    // The default state: `proofreadModel` is nil, so both roles resolve to the same name and
    // warming it twice would be two requests for one load.
    let settings = AppSettings(defaults: freshDefaults())
    settings.interactiveModel = "translategemma:27b"
    #expect(WarmUpPlan.models(for: settings) == ["translategemma:27b"])
}

// MARK: - The port is a port

/// The «Порт» field is a `TextField` over an `Int` with `.number` formatting, which parses a
/// negative happily — and `URL(string: "http://127.0.0.1:-1")` answers nil, which both call
/// sites force-unwrapped. `warmUpOnLaunch` is on by default and routes through the pool at every
/// start, so a stored `-1` was a crash at every launch that survived the crash.
@Test func aPortOutsideTheTCPRangeFallsBackToTheEnginesDefault() {
    let settings = AppSettings(defaults: freshDefaults())
    for refused in [-1, 0, 65536, 70000] {
        settings.enginePort = refused
        #expect(settings.enginePort == ModelEngine.ollama.defaultPort,
                "\(refused) is not a port and must not be stored as one")
    }
    // Both ends of the range itself are ports and must survive.
    settings.enginePort = 1
    #expect(settings.enginePort == 1)
    settings.enginePort = 65535
    #expect(settings.enginePort == 65535)
}

/// The setter is not the only writer — `defaults write com.mordvic.localtranslator enginePort
/// -int -1` is — so the clamp has to be on the way out as well as on the way in. Same reasoning
/// as `contentFontSize`, which this follows.
@Test func aPortPlantedPastTheSetterIsStillRefusedOnTheWayOut() {
    let defaults = freshDefaults()
    defaults.set(-1, forKey: "enginePort")
    #expect(AppSettings(defaults: defaults).enginePort == ModelEngine.ollama.defaultPort)
    // `EngineRouter` reads through the static reader rather than the instance, and it is the
    // one that actually builds the URL — so it needs the same guarantee, not a parallel one.
    #expect(AppSettings.enginePort(in: defaults) == ModelEngine.ollama.defaultPort)
}

/// The fallback is the *selected* engine's default, not a fixed number: the two servers listen
/// in different places and «not a port» has a different right answer for each.
@Test func theFallbackPortFollowsTheSelectedEngine() {
    let settings = AppSettings(defaults: freshDefaults())
    settings.engine = .lmStudio
    settings.enginePort = -1
    #expect(settings.enginePort == ModelEngine.lmStudio.defaultPort)
    #expect(settings.enginePort != ModelEngine.ollama.defaultPort)
}

// MARK: - One engine, one port, one decision

/// `EngineRouter` read the engine key to pick its branch and then called
/// `AppSettings.enginePort(in:)`, which read the same key *again* to know which port key to look
/// under. A «Движок» change landing between the two reads sent one engine's port into the other
/// engine's client. The overload taking an engine is what makes the pair one decision.
@Test func thePortReaderCanBeToldWhichEngineItIsAnsweringAbout() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.enginePort = 11500
    settings.engine = .lmStudio
    settings.enginePort = 1300

    #expect(AppSettings.enginePort(in: defaults, for: .ollama) == 11500)
    #expect(AppSettings.enginePort(in: defaults, for: .lmStudio) == 1300)
    // The engine-reading overload still agrees with the selected engine, so nothing above it
    // has to change.
    #expect(AppSettings.enginePort(in: defaults) == 1300)
}
