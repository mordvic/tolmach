// Sources/TextCapture/CapturedSelection.swift
import Foundation
import AppKit

/// What one capture actually got: the characters, plus whatever richer flavours came with them.
///
/// **This type converts nothing and this module never will.** `TextCapture` is «every fragile
/// macOS API, isolated on purpose» and knows nothing about Markdown, `TranslationCore` or
/// AppKit's text system; the flavours travel as the bytes the copying application wrote, and
/// `MarkupKit` — called from `HotkeyCoordinator` — is what turns them into anything. Two
/// consequences worth stating rather than rediscovering: this module keeps its
/// no-`TranslationCore` independence (`Package.swift`), and a conversion that turns out to be
/// wrong can be changed without touching the code that posts synthetic keystrokes.
///
/// `html` and `rtf` are nil far more often than not, and each nil has one of three causes,
/// which are worth telling apart:
///
/// - **The Accessibility path answered.** It asks for `kAXSelectedTextAttribute`, which is a
///   string; there is no flavour to have. That path is tried first because it «touches
///   nothing» — see `SelectionReader.accessibilityText()` — and richer capture is *not* a
///   reason to reorder the two tiers. Lifting rich capture onto this path is tier 1 of the
///   design (`kAXAttributedStringForRangeParameterizedAttribute`), and it is **deliberately
///   absent**: it is gated on a measurement of what real applications answer it with, which
///   nobody has taken yet (design §11.1). The absence is a decision, not an oversight.
/// - **The application wrote no such flavour.** A plain-text editor's ⌘C is plain text.
/// - **The flavour was declared and empty.** Normalised to nil here (`nonEmpty`), because an
///   empty `public.html` is not markup and would send the converter off to find structure in
///   nothing.
///
/// The honest consequence of tier 1 being absent: rich capture improves exactly the
/// applications where the Accessibility read *fails* and the ⌘C fallback runs — per
/// `SelectionReader`'s own measurements that includes Safari (focused `AXGroup`, `kAXErrorNoValue`),
/// Xcode and Telegram (`kAXErrorAttributeUnsupported`), which are several of the rich-text
/// applications this feature is for; and it does nothing at all for an application that answers
/// the Accessibility attribute.
public struct CapturedSelection: Equatable, Sendable {
    /// The characters, exactly as `SelectionResult.text` used to carry them — the flavour every
    /// consumer can read and the only one that is never nil.
    public let plain: String
    /// `public.html`, as the application wrote it. Not decoded, not validated, not parsed.
    public let html: Data?
    /// `public.rtf`, same terms.
    public let rtf: Data?

    public init(plain: String, html: Data? = nil, rtf: Data? = nil) {
        self.plain = plain
        self.html = Self.nonEmpty(html)
        self.rtf = Self.nonEmpty(rtf)
    }

    /// Whether there is anything for a converter to look at. Read by the app so a press with
    /// nothing rich about it costs no conversion at all — the overwhelmingly common case, since
    /// the Accessibility path never carries a flavour.
    public var hasRichFlavours: Bool { html != nil || rtf != nil }

    /// An application may declare a type and hand back zero bytes; `data(forType:)` then answers
    /// an empty `Data` rather than nil. Treating that as «there is HTML here» would cost a
    /// conversion and a gate check to arrive at the empty string.
    private static func nonEmpty(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    /// Everything on `pasteboard` that this app knows how to carry, given the plain text the
    /// ⌘C poll already accepted.
    ///
    /// **Called at exactly one point** — inside `SelectionReader.clipboardTextLocked()`, in the
    /// same pass and under the same held `GeneralPasteboard` lock as the `string(forType:)` read
    /// that satisfied the poll. That placement is the whole design of the tier: no second ⌘C, no
    /// second poll, no second snapshot, and nothing about the fallback's invasiveness changes —
    /// the copy has already happened and these are two more reads off a board this app is
    /// already holding. Reading them later, outside the lock, would race the restore that the
    /// same lock is protecting (`PasteboardSnapshot`, `docs/adr/0005`).
    ///
    /// `plain` is passed in rather than re-read for the same reason: the poll has already decided
    /// which bytes are the selection, and asking the board a second time could answer differently.
    static func capture(from pasteboard: NSPasteboard, plain: String) -> CapturedSelection {
        CapturedSelection(plain: plain,
                          html: pasteboard.data(forType: .html),
                          rtf: pasteboard.data(forType: .rtf))
    }
}

/// A bare string *is* a plain-only capture, and that is what this conformance says.
///
/// It exists so that «this selection, just these characters» keeps its old spelling everywhere it
/// was already written — `SelectionResult.text("Привет")`, a fake reader answering a literal —
/// which is exactly what the Accessibility tier and every test that does not care about flavours
/// mean. Without it, adding two optional fields to a capture rewrote lines in four test files
/// that have nothing to do with rich text, and each of those rewrites is a place a reader would
/// have to check whether the meaning had changed. It had not.
///
/// Deliberately no `ExpressibleByStringInterpolation`: the literal form is for a fixed string in
/// a test or a default, not for building a selection out of pieces.
extension CapturedSelection: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(plain: value)
    }
}
