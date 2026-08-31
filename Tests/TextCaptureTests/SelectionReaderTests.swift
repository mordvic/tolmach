import Testing
import Foundation
import AppKit
@testable import TextCapture

// `accessibilityText()` and `clipboardSelection()` are deliberately absent from this file. Neither
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
    // `clipboardSelection` or `PermissionsGate.isTrusted` would go unnoticed until then. Only
    // constructed, never read: calling `read()` here would post a real ⌘C.
    // The value of this test is entirely that the line below compiles; there is no assertion
    // to make about the result that could fail, and one written anyway would read as coverage
    // it does not provide.
    _ = SelectionReader()
}

// MARK: - The rich flavours

/// The Accessibility tier is plain **by construction, not by omission**:
/// `kAXSelectedTextAttribute` is a string attribute. The tier that would carry more —
/// `kAXAttributedStringForRangeParameterizedAttribute` — is deliberately absent, gated on a
/// measurement of what real applications answer it with (design §11.1), so this test is what
/// «plain only» looks like from here, and the flavours on the fallback's answer are what it is
/// *not* allowed to reach for.
@Test func theAccessibilityPathCarriesNoFlavoursAtAll() {
    let reader = SelectionReader(accessibility: { "из Accessibility" },
                                 clipboard: { CapturedSelection(plain: "не понадобится",
                                                                html: Data("<h1>Х</h1>".utf8)) },
                                 isTrusted: { true })
    guard case let .text(captured) = reader.read() else {
        Issue.record("the Accessibility path did not answer")
        return
    }
    #expect(captured.plain == "из Accessibility")
    #expect(captured.html == nil)
    #expect(captured.rtf == nil)
    #expect(!captured.hasRichFlavours)
}

@Test func theClipboardPathCarriesWhicheverFlavoursLanded() {
    let html = Data("<h1>Заголовок</h1>".utf8)
    let rtf = Data(#"{\rtf1}"#.utf8)
    let reader = SelectionReader(
        accessibility: { nil },
        clipboard: { CapturedSelection(plain: "Заголовок", html: html, rtf: rtf) },
        isTrusted: { true })
    guard case let .text(captured) = reader.read() else {
        Issue.record("the clipboard path did not answer")
        return
    }
    #expect(captured.plain == "Заголовок")
    #expect(captured.html == html)
    #expect(captured.rtf == rtf)
    #expect(captured.hasRichFlavours)
}

@Test func aRichCaptureWithNothingWorthTranslatingIsStillEmpty() {
    // The emptiness rule is about the characters and the flavours do not change it: a board
    // carrying `public.html` beside a whitespace-only string has no selection on it, and the
    // panel must still say «выделите текст» rather than translate an empty document with markup.
    let reader = SelectionReader(
        accessibility: { nil },
        clipboard: { CapturedSelection(plain: "  \n ", html: Data("<h1>Х</h1>".utf8)) },
        isTrusted: { true })
    #expect(reader.read() == .empty)
}

/// The flavours are read off the board in the same pass as the `.string` that satisfied the poll,
/// inside the same held `GeneralPasteboard` lock. **That placement cannot be observed from a test
/// process** — the function it lives in posts a synthetic ⌘C, which per
/// `docs/reference/TESTING.md` goes nowhere here and lands in the developer's frontmost
/// application when it goes anywhere. So what is pinned is the read itself, on a board of this
/// test's own; the single pass stays structural, by `CapturedSelection.capture(from:plain:)`
/// having exactly one caller.
@Test func everyFlavourThisAppCarriesIsTakenFromOneBoardInOneRead() {
    let board = NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.rich.\(UUID().uuidString)"))
    let html = Data("<h1>Заголовок</h1>".utf8)
    let rtf = Data(#"{\rtf1\ansi Заголовок}"#.utf8)
    board.clearContents()
    board.setData(html, forType: .html)
    board.setData(rtf, forType: .rtf)
    board.setString("Заголовок", forType: .string)

    let captured = CapturedSelection.capture(from: board, plain: "Заголовок")
    #expect(captured.plain == "Заголовок")
    #expect(captured.html == html)
    #expect(captured.rtf == rtf)

    // A board with only a string on it: two nils. The plain text comes from the poll rather than
    // from a second read of the board, which is the other half of «one pass».
    board.clearContents()
    board.setString("только текст", forType: .string)
    let plainOnly = CapturedSelection.capture(from: board, plain: "только текст")
    #expect(plainOnly.plain == "только текст")
    #expect(!plainOnly.hasRichFlavours)
}

@Test func aFlavourDeclaredWithNoBytesIsNoFlavour() {
    // An application may declare a type and hand back nothing; `data(forType:)` then answers an
    // empty `Data`. Carrying that as «there is HTML here» spends a conversion and a gate check
    // to arrive at the empty string.
    let board = NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.rich.\(UUID().uuidString)"))
    board.clearContents()
    board.setData(Data(), forType: .html)
    board.setString("текст", forType: .string)
    #expect(!CapturedSelection.capture(from: board, plain: "текст").hasRichFlavours)
}

@Test func aBareStringIsAPlainOnlyCapture() {
    // What `ExpressibleByStringLiteral` on `CapturedSelection` claims, asserted rather than
    // assumed: every call site that hands over a literal means «just these characters».
    let literal: CapturedSelection = "текст"
    #expect(literal == CapturedSelection(plain: "текст"))
    #expect(!literal.hasRichFlavours)
}

// MARK: - Universal Clipboard is not this app's selection

/// The ⌘C poll accepts *any* pasteboard change it sees, because `NSPasteboard` has no owner and
/// nothing here can ask who wrote. So the one third-party write that identifies itself is
/// excluded by name: content handed over from another device carries
/// `com.apple.is-remote-clipboard`, and without this check it was sent to the model and shown in
/// the panel as the user's selection.
///
/// The general case remains — any other process writing inside the ≤0.5 s window is still
/// mistaken for the selection — and ADR 0005 records that rather than this pretending otherwise.
@Test func aBoardDeliveredFromAnotherDeviceIsRecognised() {
    let board = NSPasteboard(name: NSPasteboard.Name("ru.tolmach.test.remote.\(UUID().uuidString)"))
    board.clearContents()
    board.setString("обычная копия", forType: .string)
    #expect(!SelectionReader.isRemoteClipboard(board))

    board.clearContents()
    board.setString("с айфона", forType: .string)
    board.setData(Data(), forType: SelectionReader.remoteClipboardType)
    #expect(SelectionReader.isRemoteClipboard(board))
}
