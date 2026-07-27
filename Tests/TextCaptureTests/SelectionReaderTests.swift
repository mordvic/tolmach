import Testing
@testable import TextCapture

// `accessibilityText()` and `clipboardText()` are deliberately absent from this file. Neither
// can run meaningfully here: `AXUIElementCreateSystemWide()` answers
// `kAXFocusedUIElementAttribute` with `kAXErrorCannotComplete` in a process that has never
// touched `NSApplication` — measured, and measured to start succeeding the instant it does —
// and a synthetic ⌘C posted from a test would land in whatever application the developer
// happens to have in front, copying their selection and firing their menu commands. Task 10's
// hand-check is where both are exercised. Everything below is the decision *between* them,
// which is the part spec 6 actually pins.

@Test func theAccessibilityPathIsPreferredAndTheClipboardIsNotTouched() {
    // Spec 6: the Accessibility read does not disturb the clipboard, so when it works the
    // fallback must not run at all. A fallback that ran anyway would post a synthetic ⌘C
    // into the user's app on every single hotkey press.
    nonisolated(unsafe) var clipboardCalls = 0
    let reader = SelectionReader(accessibility: { "из Accessibility" },
                                 clipboard: { clipboardCalls += 1; return "из буфера" },
                                 isTrusted: { true })
    #expect(reader.read() == .text("из Accessibility"))
    #expect(clipboardCalls == 0)
}

@Test func anEmptyAccessibilityResultFallsThroughToTheClipboard() {
    // Some Electron apps and browsers answer the attribute with an empty string rather than
    // refusing it, so "empty" and "unsupported" have to be treated the same way. Measured in
    // the wild: Activity Monitor's focused search field answers `kAXSelectedTextAttribute`
    // with `.success` and a zero-length `CFString`, while Safari's focused `AXGroup` answers
    // `kAXErrorNoValue`. Both must reach the fallback.
    let reader = SelectionReader(accessibility: { "" }, clipboard: { "из буфера" }, isTrusted: { true })
    #expect(reader.read() == .text("из буфера"))

    let nilReader = SelectionReader(accessibility: { nil }, clipboard: { "из буфера" }, isTrusted: { true })
    #expect(nilReader.read() == .text("из буфера"))

    // The whitespace-only case has to fall through as well, not just resolve to `.empty`.
    // Without this the filter could be applied to the clipboard branch alone and every test
    // above would still pass.
    let blankReader = SelectionReader(accessibility: { " \n " }, clipboard: { "из буфера" },
                                      isTrusted: { true })
    #expect(blankReader.read() == .text("из буфера"))
}

@Test func whitespaceOnlySelectionsCountAsEmpty() {
    // Translating a run of spaces wastes a model call and shows the user an empty panel.
    let reader = SelectionReader(accessibility: { "   \n\t " }, clipboard: { "  " }, isTrusted: { true })
    #expect(reader.read() == .empty)

    // Whitespace decides *whether* there is a selection; it does not get stripped from one
    // that exists. A double-click in most applications includes the trailing space, and
    // trimming here would silently change the text handed to the model — and, on a round
    // trip, what the user gets back. Pinned so nobody folds the trim into the return value.
    let padded = SelectionReader(accessibility: { "  привет  " }, clipboard: { nil }, isTrusted: { true })
    #expect(padded.read() == .text("  привет  "))
}

@Test func bothPathsComingBackEmptyIsDistinctFromHavingNoPermission() {
    // These need different words in the panel: «выделите текст» versus the onboarding
    // prompt. Collapsing them sends a user with no selection to System Settings.
    let empty = SelectionReader(accessibility: { nil }, clipboard: { nil }, isTrusted: { true })
    #expect(empty.read() == .empty)

    let untrusted = SelectionReader(accessibility: { "неважно" }, clipboard: { "неважно" }, isTrusted: { false })
    #expect(untrusted.read() == .notPermitted)
}

@Test func thePermissionIsCheckedBeforeEitherPathRuns() {
    // Without the grant the Accessibility read fails and the synthetic ⌘C is silently
    // dropped by the window server — so running them first would burn the round trip and
    // still end up here, having flickered the user's clipboard for nothing.
    nonisolated(unsafe) var attempts = 0
    let reader = SelectionReader(accessibility: { attempts += 1; return nil },
                                 clipboard: { attempts += 1; return nil },
                                 isTrusted: { false })
    #expect(reader.read() == .notPermitted)
    #expect(attempts == 0)
}

@Test func neitherPathIsConsultedTwiceInOneRead() {
    // Every call to the clipboard reader is a real synthetic ⌘C into the user's application,
    // a whole-pasteboard snapshot, and a poll of up to half a second. The obvious wrong
    // spelling — `if clipboard() != nil { return .text(clipboard()!) }` — reads correctly,
    // returns the right answer, and passes every other test in this file while posting two
    // keystrokes and destroying the user's clipboard twice per press.
    nonisolated(unsafe) var trustChecks = 0
    nonisolated(unsafe) var accessibilityCalls = 0
    nonisolated(unsafe) var clipboardCalls = 0
    let reader = SelectionReader(accessibility: { accessibilityCalls += 1; return nil },
                                 clipboard: { clipboardCalls += 1; return "из буфера" },
                                 isTrusted: { trustChecks += 1; return true })
    #expect(reader.read() == .text("из буфера"))
    #expect(trustChecks == 1)
    #expect(accessibilityCalls == 1)
    #expect(clipboardCalls == 1)
}

@Test func theDefaultsWireUpTheRealReaders() {
    // Nothing constructs a `SelectionReader` with its defaults yet — the coordinator that
    // will is a later task — so without this the three default arguments are never
    // instantiated from outside the module and a signature drift in `accessibilityText`,
    // `clipboardText` or `PermissionsGate.isTrusted` would go unnoticed until then. Only
    // constructed, never read: calling `read()` here would post a real ⌘C.
    let reader = SelectionReader()
    #expect(type(of: reader) == SelectionReader.self)
}
