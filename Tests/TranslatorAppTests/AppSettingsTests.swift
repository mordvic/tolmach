import Testing
import Foundation
import Observation
@testable import TranslatorApp
@testable import TranslationCore

private func freshDefaults() -> UserDefaults {
    let suite = "test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

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
