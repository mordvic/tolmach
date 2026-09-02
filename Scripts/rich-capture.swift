// Scripts/rich-capture.swift
//
// What a real application actually offers when the user selects formatted text — the
// measurement `docs/design/specs/2026-08-31-formatting-design.md` §10.1 owes a human, and
// the gate on its Phase 3. **Nothing in that phase should be built from a guess about these
// five answers.**
//
//     swiftc -O -o /tmp/rc Scripts/rich-capture.swift && /tmp/rc
//
// It needs the Accessibility grant (System Settings → Privacy & Security → Accessibility) for
// the AX half; the pasteboard half works without it. Run it, then — while it counts down —
// select formatted text in the application under test and leave it selected. It prints, per
// application:
//
//  1. Whether `kAXSelectedTextAttribute` answers, and with a plain string or something else.
//  2. Whether `kAXAttributedStringForRangeParameterizedAttribute` answers at all, and which
//     attributes come with it — this is the only question that decides whether tier 1 of the
//     design's capture is worth writing.
//  3. What flavours the application's own ⌘C produces (the design reads `public.html` and
//     `public.rtf`; anything else it finds here is worth knowing about).
//
// It does NOT post a synthetic ⌘C — that is `SelectionReader`'s job and this probe must not
// disturb the pasteboard it is reading. Copy by hand when it asks.
//
// Fill the table in `docs/reference/OPEN-ITEMS.md` from what this prints, for at least:
// Safari, Chrome, Word, Pages, Notes, Mail, Slack, Telegram, VS Code.
import AppKit
import ApplicationServices

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func countdown(_ seconds: Int, _ message: String) {
    print(message)
    for remaining in stride(from: seconds, to: 0, by: -1) {
        print("  \(remaining)…", terminator: " ")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
    }
    print("")
}

// MARK: - The AX half

func axProbe() {
    print("=== Accessibility ===")
    guard AXIsProcessTrusted() else {
        print("  not trusted — grant this binary Accessibility and re-run for this half")
        return
    }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.5)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
    else { print("  no focused element (the frontmost app answered nothing)"); return }
    let target = element as! AXUIElement

    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role)
    print("  focused role: \(role as? String ?? "—")")
    print("  frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "—")")
    // The ancestry, for one question added 2026-09-02: does the selection live in **web
    // content**? Chromium and WebKit both expose it as an `AXWebArea` ancestor, and a
    // selection there is where a flat, block-separator-free `kAXSelectedText` was reported
    // (spec #72, Q3). If that role shows up here whenever the text arrives glued, the browser
    // rule can be «the focused element sits under an AXWebArea» rather than a bundle list.
    var roles: [String] = []
    var cursor: AXUIElement? = target
    for _ in 0..<12 {
        guard let current = cursor else { break }
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
              let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
        let element = next as! AXUIElement
        var parentRole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &parentRole)
        roles.append(parentRole as? String ?? "?")
        cursor = element
    }
    print("  ancestry: \(roles.joined(separator: " → "))")
    print("  under AXWebArea: \(roles.contains("AXWebArea"))")

    // 1. The plain attribute, the one `SelectionReader` reads today.
    var selected: CFTypeRef?
    let plainStatus = AXUIElementCopyAttributeValue(target, kAXSelectedTextAttribute as CFString, &selected)
    if plainStatus == .success {
        if let string = selected as? String {
            // Newline count beside the length: a multi-block selection that answers with none
            // is the glued shape — headings, paragraphs and table cells run together.
            let breaks = string.filter(\.isNewline).count
            print("  kAXSelectedText: plain string, \(string.count) chars, \(breaks) line breaks")
            print("  first 200: \(String(string.prefix(200)).debugDescription)")
        } else {
            print("  kAXSelectedText: answered with a non-string (\(CFCopyTypeIDDescription(CFGetTypeID(selected!)) as String? ?? "?")) "
                + "— today's code drops this to nil and falls through to the clipboard")
        }
    } else {
        print("  kAXSelectedText: error \(plainStatus.rawValue)")
    }

    // 2. The attributed attribute — the design's tier 1, and the reason this script exists.
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
    else { print("  kAXSelectedTextRange: unavailable — tier 1 cannot work here"); return }
    var range = CFRange()
    AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
    print("  kAXSelectedTextRange: location \(range.location), length \(range.length)")

    var attributed: CFTypeRef?
    let attributedStatus = AXUIElementCopyParameterizedAttributeValue(
        target, kAXAttributedStringForRangeParameterizedAttribute as CFString,
        rangeValue, &attributed)
    guard attributedStatus == .success, let string = attributed as? NSAttributedString else {
        print("  kAXAttributedStringForRange: error \(attributedStatus.rawValue) — tier 1 is dead code here")
        return
    }
    print("  kAXAttributedStringForRange: \(string.length) chars, attribute runs:")
    var runs = 0
    string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attrs, range, _ in
        runs += 1
        guard runs <= 12 else { return }
        var notes: [String] = []
        for (key, value) in attrs {
            switch value {
            case let font as NSFont:
                let traits = NSFontManager.shared.traits(of: font)
                notes.append("\(key.rawValue)=\(Int(font.pointSize))pt \(font.familyName ?? "?")"
                    + (traits.contains(.boldFontMask) ? " bold" : "")
                    + (traits.contains(.italicFontMask) ? " italic" : ""))
            case let style as NSParagraphStyle:
                notes.append("\(key.rawValue)=lists:\(style.textLists.count) blocks:\(style.textBlocks.count)")
            default:
                notes.append("\(key.rawValue)=\(String(describing: value).prefix(28))")
            }
        }
        let text = (string.string as NSString).substring(with: range)
        print("    \(text.debugDescription.prefix(22).padding(toLength: 24, withPad: " ", startingAt: 0)) \(notes.sorted().joined(separator: ", "))")
    }
    if runs > 12 { print("    … \(runs - 12) more runs") }
    print("  -> what matters is whether any of these carry SEMANTICS (a heading level, a list")
    print("     kind) or only VISUALS. Visuals only means tier 1 is no better than the RTF flavour.")
}

// MARK: - The pasteboard half

func pasteboardProbe() {
    print("=== the application's own ⌘C ===")
    let board = NSPasteboard.general
    print("  changeCount \(board.changeCount), types:")
    for type in board.types ?? [] {
        let bytes = board.data(forType: type)?.count ?? 0
        print("    \(type.rawValue.padding(toLength: 34, withPad: " ", startingAt: 0)) \(bytes) bytes")
    }
    if let plain = board.string(forType: .string) {
        // The same two numbers as the AX half, so the two tiers can be compared for one
        // selection: does the application's own ⌘C keep the line breaks the AX answer lost?
        print("  public.utf8-plain-text: \(plain.count) chars, \(plain.filter(\.isNewline).count) line breaks")
        print("  first 200: \(String(plain.prefix(200)).debugDescription)")
    }
    for type in [NSPasteboard.PasteboardType.html, .rtf] {
        guard let data = board.data(forType: type) else { continue }
        print("  --- \(type.rawValue), first 400 bytes ---")
        let text = String(data: data.prefix(400), encoding: .utf8)
            ?? String(decoding: data.prefix(400), as: UTF8.self)
        print("  \(text.replacingOccurrences(of: "\n", with: " ").prefix(400))")
    }
}

countdown(6, "Select formatted text in the application under test, and leave it selected:")
axProbe()
countdown(6, "Now press ⌘C in that application yourself (this probe posts no keystrokes):")
pasteboardProbe()
