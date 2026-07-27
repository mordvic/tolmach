import Testing
import Foundation
import Observation
@testable import TranslatorApp
@testable import TranslationCore

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
