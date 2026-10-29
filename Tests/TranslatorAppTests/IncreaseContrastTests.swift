import AppKit
import Testing
import MarkupKit
import TranslationCore
@testable import TranslatorApp

// Increase Contrast reaches the change marks through `DisplayContrast` and the two views' keys.
// The system setting cannot be flipped from a test, so the reader is injected and the
// notification posted on a private centre; what is pinned is that a flip of the value re-keys
// both coordinators into a thick-lined storage.

private let source = "Отчет за август готов."
private let result = "Отчёт за август готов."

private func underline(at text: String, in storage: NSAttributedString) -> NSUnderlineStyle? {
    let range = (storage.string as NSString).range(of: text)
    guard range.location != NSNotFound,
          let raw = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int
    else { return nil }
    return NSUnderlineStyle(rawValue: raw)
}

/// The system setting a test can flip: a reference the injected reader closes over.
@MainActor private final class Setting { var on = false }

@MainActor
@Test func displayContrastFollowsTheSettingWhenTheSystemSaysItChanged() {
    let center = NotificationCenter()
    let setting = Setting()
    let contrast = DisplayContrast(center: center, read: { setting.on })
    #expect(contrast.isIncreased == false)
    setting.on = true
    // Nothing moves until the system says so: the value is read on the notification, not polled.
    #expect(contrast.isIncreased == false)
    center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    #expect(contrast.isIncreased == true)
}

@MainActor
@Test func thePanesStorageIsRebuiltThickWhenIncreaseContrastTurnsOn() {
    let changes = TextDiff.changes(source: source, result: result)
    let view = CodeBlockTextView(textKit1Inset: NSSize(width: 3, height: 8))
    let coordinator = RenderedTextView.Coordinator()
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, to: view)
    #expect(underline(at: "Отчёт", in: view.textStorage!) == [.single, .patternDot])
    // The same inputs with the flag flipped: the mode changes, so the storage is rebuilt rather
    // than kept — the weight is an attribute, and a redraw alone would leave it thin.
    coordinator.apply(text: result, font: .default, rendersMarkup: true, isStreaming: false,
                      changes: changes, increasedContrast: true, to: view)
    #expect(underline(at: "Отчёт", in: view.textStorage!) == [.thick, .patternDot])
}

@MainActor
@Test func thePanelsMemoIsKeyedOnIncreaseContrast() {
    let changes = TextDiff.changes(source: source, result: result)
    let coordinator = RenderedReplyView.Coordinator()
    let config = ContentFont.default.markdownConfig
    let normal = coordinator.rendering(of: result, config: config, rendersMarkup: true,
                                       changes: changes, detail: .result)
    let high = coordinator.rendering(of: result, config: config, rendersMarkup: true,
                                     changes: changes, detail: .result, increasedContrast: true)
    #expect(underline(at: "Отчёт", in: normal.attributed) == [.single, .patternDot])
    #expect(underline(at: "Отчёт", in: high.attributed) == [.thick, .patternDot])
}
