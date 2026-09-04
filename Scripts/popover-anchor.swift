// Scripts/popover-anchor.swift
//
// Phase 2's gate (issue #89, measurement protocol item 6, before any UI): does an `NSPopover`
// anchored to `layoutManager.boundingRect(forGlyphRange:in:)` of a TextKit 1 `NSTextView` land
// on the glyphs, survive the pane scrolling, and survive the panel's own trap — a detached
// `NSHostingController` reassigning `rootView` on every fit (`PanelController.measure`), and
// the *installed* host doing the same on `setRendersFinalReply`/`setScrolling`?
//
//     swiftc -O -o /tmp/pa Scripts/popover-anchor.swift && /tmp/pa
//
// Compiled rather than interpreted, for `window-title.swift`'s reason: the interpreter cannot
// JIT the availability check SwiftUI emits. No package objects linked in — unlike
// `panel-rendered-measure.swift`, nothing here asks what `MarkdownToAttributed` draws; the
// question is purely AppKit's own behaviour under a hand-built TextKit 1 triple, so a
// stand-in document is the right one to ask it of.
//
// Three questions, each answered with a real, on-screen `NSWindow` — a popover's window has to
// exist somewhere, and a detached `NSHostingController` (`panel-rendered-measure.swift`'s own
// approach) never gets one:
//
//  (a) Anchor accuracy: `popover.show(relativeTo:of:preferredEdge:)` against the glyph rect of
//      a marked word inside a plain `NSScrollView`-hosted text view. Read back the popover's own
//      window frame and compare it to the anchor rect converted to screen coordinates.
//  (b) Scrolling: scroll the text view (`scrollToVisible`), and read `popover.isShown` and the
//      window frame before and after.
//  (c) The panel's own trap: reassign the *hosting* `NSHostingView`'s `rootView` — a fresh
//      `AnyView` wrapping a **new** `NSViewRepresentable` value over the **same** text view
//      instance SwiftUI is expected to keep (structural identity: same position in the view
//      tree) — and see whether the popover survives. Tried under both `.transient` and
//      `.semitransient` behaviour, because the task names both as live questions.
import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func pump(_ seconds: TimeInterval = 0.05) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

// ── the text view: a hand-built TextKit 1 triple, the same construction
//    `CodeBlockTextView.init(textKit1Inset:lineFragmentPadding:)` uses ────────────────────────
func makeTextView() -> NSTextView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400),
                          textContainer: container)
    view.isEditable = false
    view.isSelectable = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.minSize = NSSize.zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    let text = (0..<40).map { "строка номер \($0) со словом ИЗМЕНЕНО в середине текста" }
        .joined(separator: "\n")
    let attributed = NSMutableAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
    ])
    // The marked word — the one the popover anchors to, on line 20 of 40, well below the fold.
    let markedWord = "ИЗМЕНЕНО"
    let markedRange = (text as NSString).range(of: markedWord)
    attributed.addAttribute(.underlineStyle, value: 1, range: markedRange)
    storage.setAttributedString(attributed)
    view.textContainer?.size = CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    return view
}

func glyphRect(of textView: NSTextView, range: NSRange) -> NSRect {
    guard let layoutManager = textView.layoutManager, let container = textView.textContainer
    else { return .zero }
    let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    rect.origin.x += textView.textContainerOrigin.x
    rect.origin.y += textView.textContainerOrigin.y
    return rect
}

func markedRange(of textView: NSTextView) -> NSRange {
    guard let storage = textView.textStorage else { return NSRange(location: 0, length: 0) }
    var found = NSRange(location: 0, length: 0)
    storage.enumerateAttribute(.underlineStyle,
                               in: NSRange(location: 0, length: storage.length)) { value, range, stop in
        guard value != nil else { return }
        found = range
        stop.pointee = true
    }
    return found
}

func popoverWindowFrame(_ popover: NSPopover) -> NSRect? {
    popover.contentViewController?.view.window?.frame
}

func screenRect(of rect: NSRect, in view: NSView) -> NSRect? {
    guard let window = view.window else { return nil }
    let windowRect = view.convert(rect, to: nil)
    return window.convertToScreen(windowRect)
}

// ── (a) anchor accuracy, inside a scroll view, inside a real window ─────────────────────────
print("== (a) anchor accuracy ==")
let textView = makeTextView()
let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
scroll.hasVerticalScroller = true
scroll.documentView = textView
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = scroll
window.makeKeyAndOrderFront(nil)
pump()

let range = markedRange(of: textView)
print("marked range \(range), text \"\((textView.string as NSString).substring(with: range))\"")
let rect = glyphRect(of: textView, range: range)
print("glyph rect (view coords) \(rect)")
// Scroll it into view first — the marked word is on line 20 of 40, well past the 200 pt
// viewport, so a click on it could not have happened without this already being true, and a
// popover shown against an off-screen rect is not the case the click handler will ever hit.
textView.scrollRangeToVisible(range)
pump()
let visibleRectAfterScroll = textView.visibleRect
print("visibleRect after scrollRangeToVisible: \(visibleRectAfterScroll), "
      + "contains glyph rect = \(visibleRectAfterScroll.intersects(rect))")

let popover = NSPopover()
popover.behavior = .transient
let content = NSViewController()
let label = NSTextField(labelWithString: "было → стало")
label.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
content.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
content.view.addSubview(label)
popover.contentViewController = content
let anchorScreenRect = screenRect(of: rect, in: textView)
popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
pump()
print("popover.isShown \(popover.isShown)")
print("anchor rect in screen coords   \(anchorScreenRect.map { "\($0)" } ?? "nil")")
print("popover window frame           \(popoverWindowFrame(popover).map { "\($0)" } ?? "nil")")
if let anchorScreenRect, let popoverFrame = popoverWindowFrame(popover) {
    // «On the glyphs» read narrowly: the popover's window horizontally overlaps the anchor
    // rect's x-span (it points *at* the word, not at the whole line), and sits vertically
    // adjacent to it — touching or within a few points, the arrow's own size.
    let horizontallyOverlaps = popoverFrame.minX < anchorScreenRect.maxX
        && popoverFrame.maxX > anchorScreenRect.minX
    let verticalGap = popoverFrame.minY - anchorScreenRect.maxY
    print("horizontally overlaps anchor = \(horizontallyOverlaps), "
          + "vertical gap above anchor = \(verticalGap)")
}

// ── (b) survives scrolling ───────────────────────────────────────────────────────────────────
print("\n== (b) survives scrolling ==")
let frameBeforeScroll = popoverWindowFrame(popover)
print("isShown before scroll \(popover.isShown), frame \(frameBeforeScroll.map { "\($0)" } ?? "nil")")
// Scroll the opposite direction — back toward the top, away from the anchored word.
textView.scroll(NSPoint(x: 0, y: 0))
pump()
let frameAfterScroll = popoverWindowFrame(popover)
print("isShown after scroll  \(popover.isShown), frame \(frameAfterScroll.map { "\($0)" } ?? "nil")")
print("frame moved = \(frameBeforeScroll != frameAfterScroll)")
popover.close()
pump()

// ── (c) survives the hosting view's rootView being reassigned ───────────────────────────────
// The panel's actual shape: an `NSHostingView<AnyView>` is the window's content view, and
// `PanelController` reassigns its `rootView` on `setScrolling` / `setRendersFinalReply` — a
// fresh `AnyView` built from the *same* builder closure, at the *same* position in the view
// tree, which is what SwiftUI's structural identity is supposed to preserve the underlying
// `NSView` instance across. This reproduces exactly that: one `NSViewRepresentable` whose
// `makeNSView` is called once and remembered, so a second `updateNSView` — driven by a second
// `rootView` assignment — proves whether the popover's positioning view is still alive and
// still in a window, not merely whether the Swift value survived.
final class Box { var view: NSTextView? }
let box = Box()

struct Hosted: NSViewRepresentable {
    let box: Box
    let tick: Int // forces SwiftUI to see this as new content each time, exactly as a real
                  // content change would
    func makeNSView(context: Context) -> NSScrollView {
        let tv = makeTextView()
        box.view = tv
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        sv.hasVerticalScroller = true
        sv.documentView = tv
        return sv
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

for behaviorName in ["transient", "semitransient"] {
    print("\n== (c) rootView reassignment, popover.behavior = .\(behaviorName) ==")
    let hosting = NSHostingView(rootView: AnyView(Hosted(box: box, tick: 0)))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    let win2 = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable],
                        backing: .buffered, defer: false)
    win2.contentView = hosting
    win2.makeKeyAndOrderFront(nil)
    pump()
    guard let tv = box.view else { print("no text view captured"); continue }
    let r = markedRange(of: tv)
    let gr = glyphRect(of: tv, range: r)
    let pop2 = NSPopover()
    pop2.behavior = behaviorName == "transient" ? .transient : .semitransient
    let vc2 = NSViewController()
    vc2.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    pop2.contentViewController = vc2
    pop2.show(relativeTo: gr, of: tv, preferredEdge: .maxY)
    pump()
    print("shown before reassignment: \(pop2.isShown), "
          + "positioningView.window != nil: \(tv.window != nil)")
    // Reassign rootView — a brand-new `AnyView`/`Hosted` value, same builder, same tick-free
    // identity path a real fit-driven rebuild takes.
    hosting.rootView = AnyView(Hosted(box: box, tick: 1))
    hosting.layoutSubtreeIfNeeded()
    pump()
    print("same NSTextView instance kept: \(box.view === tv)")
    print("shown after reassignment:  \(pop2.isShown), "
          + "positioningView.window != nil: \(tv.window != nil)")
    if pop2.isShown {
        print("frame after reassignment:  \(popoverWindowFrame(pop2).map { "\($0)" } ?? "nil")")
    }
    pop2.close()
    win2.close()
}

print("\ndone")

// ── (d) does a real scroll-wheel NSEvent dismiss a `.transient` popover on its own? ─────────
// (b) above scrolled programmatically (`textView.scroll(_:)`), which proved the popover does
// not *reposition* itself — it says nothing about whether AppKit's own dismissal machinery
// (a local event monitor `.transient` installs) treats a scroll gesture as "an interaction
// outside the popover" the way a click or Esc is documented to be. That is worth measuring
// rather than assuming, because the answer decides whether the app needs to close the popover
// on scroll itself or can lean on `.transient`.
print("\n== (d) a real scrollWheel NSEvent against a .transient popover ==")
let textView3 = makeTextView()
let scroll3 = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
scroll3.hasVerticalScroller = true
scroll3.documentView = textView3
let window3 = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                       styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window3.contentView = scroll3
window3.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
pump()

let r3 = markedRange(of: textView3)
textView3.scrollRangeToVisible(r3)
pump()
let rect3 = glyphRect(of: textView3, range: r3)
let pop3 = NSPopover()
pop3.behavior = .transient
let vc3 = NSViewController()
vc3.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
pop3.contentViewController = vc3
pop3.show(relativeTo: rect3, of: textView3, preferredEdge: .maxY)
pump()
print("shown before synthetic scroll: \(pop3.isShown)")

if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: -20, wheel2: 0, wheel3: 0),
   let nsEvent = NSEvent(cgEvent: cgEvent) {
    // Posted at the window, over the scroll view, i.e. squarely "outside the popover" by any
    // reading of that phrase.
    app.postEvent(nsEvent, atStart: false)
    app.sendEvent(nsEvent)
} else {
    print("could not build a synthetic scrollWheel CGEvent")
}
pump(0.2)
print("shown after synthetic scroll:  \(pop3.isShown)")
pop3.close()

print("\ndone")
