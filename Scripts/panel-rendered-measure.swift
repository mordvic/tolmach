// Scripts/panel-rendered-measure.swift
//
// Can `PanelController` measure a hosted `NSTextView`? — the probe
// `docs/design/specs/2026-08-31-formatting-design.md` §11.4 asks for before Phase 4.
//
//     swift build && swiftc -O -o /tmp/prm Scripts/panel-rendered-measure.swift \
//         -I .build/debug/Modules \
//         .build/debug/MarkupKit.build/*.o .build/debug/TranslationCore.build/*.o && /tmp/prm
//
// Linked against the package's own object files rather than re-implementing the renderer,
// because the number that matters is the one `MarkdownToAttributed` actually produces —
// a stand-in document would answer a different question. Compiled and not interpreted, for
// `window-title.swift`'s reason: the interpreter cannot JIT the availability check SwiftUI
// emits. `NSApplication.shared` at `.accessory`, like every other probe here, because a
// hosting controller with no `NSApp` does not lay out.
//
// The panel is sized from a **detached second** `NSHostingController` — `fittingSize` for the
// ideal width, then `sizeThatFits(in:)` for the height at that width (`PanelController.measure`,
// and `PLATFORM-TRAPS.md` «Windows and views» for why those two calls and not one). Everything
// in the panel today is native SwiftUI. Phase 4 puts an `NSViewRepresentable`-hosted
// `NSTextView` in there, and a representable answers a proposal with whatever its
// `sizeThatFits(_:nsView:context:)` says — or, with no implementation, with whatever the
// framework decides on its behalf about a view that has never been in a window. Either 0 or
// unbounded is a defect the panel cannot survive: 0 opens it at `PanelSizer.minHeight` with the
// reply clipped to nothing, and unbounded is read as a *real* measurement — `PanelSizer.measured`
// tests `isFinite && > 0` and `greatestFiniteMagnitude` passes both — so every panel comes out at
// 0.6 × the screen and scrolling, for a one-line reply as much as for a long one.
//
// Four questions:
//
//  1. **What a detached host answers for the representable with no `sizeThatFits`.**
//  2. **What it answers with one** — height from a throwaway
//     `NSTextStorage`/`NSLayoutManager`/`NSTextContainer` triple laid out at the proposed
//     width, `usedRect(for:)`. Sane numbers at 300, 430 and 560 pt (`PanelSizer.minWidth`, the
//     midpoint, `PanelSizer.maxWidth`) for a document carrying a table and a code block, or the
//     approach is wrong.
//  3. **Whether that throwaway triple agrees with what the live view lays out**, since a
//     measurement the view then contradicts is worse than no measurement.
//  4. **Whether the answer is stable** across consecutive measurements of the same content on
//     one reused host, and against a fresh one. `PanelController` measures more than once per
//     presentation — `show(at:)`, then every `contentDidChange` — and a size that moved between
//     identical measurements would make the panel twitch at the settle.
//
// ── FINDINGS, measured 2026-08-31, macOS Darwin 27.0.0 arm64, 2056 × 1290 pt visibleFrame ────
//
// **1. With no `sizeThatFits`, the hosted text view is BOTH failures at once — 0 wide and
// unbounded tall.** Not one or the other:
//
//     reply alone, no sizeThatFits    fittingSize 0.0 × 0.0
//                                     @300 / @430 / @560  all greatestFiniteMagnitude
//     panel-shaped stack              fittingSize 359.0 × 81.0   ← the caption and buttons alone
//                                     @300 / @430 / @560  all greatestFiniteMagnitude
//
// Read through `PanelController.measure`'s two passes that is: `fittingSize` contributes nothing
// for the reply (0 is «not measured yet», so the width falls to `minWidth`/`previous`), and the
// height pass answers the whole unbounded proposal, which clamps to the 0.6 ceiling — 774 pt on
// this display — with `scrolls == true`, for **any** reply. It is the exact shape
// `PanelContentVariant.scrolls` and `PanelView.fillsPanel` already carry measurements for, from a
// third direction: a view that hands the proposal back. So the failure is not «the panel opens
// collapsed» — it is «every rendered panel opens at 60% of the screen and scrolls», and nothing
// about it looks like a bug from the code.
//
// **2. With `sizeThatFits`, the numbers are sane and monotone in width.** The §11.4 document —
// H2, two paragraphs, a 4-row GFM table with alignments, a fenced Swift block, a three-item
// list; 539 source characters, 459 attributed runs, 13 pt system:
//
//     reply alone       @300  467.0    @430  371.0    @560  355.0    fittingSize 1171.0 × 547.0
//     panel-shaped      @300  548.0    @430  484.0    @560  452.0    fittingSize 1199.0 × 628.0
//
// Narrower is taller, by whole line heights. The stack's cost over the reply reads 81 / 113 / 97
// at the same widths, which is **not** a chrome that varies: the stack's 14 pt padding takes 28
// pt off the width the reply is proposed, and against the reply measured at `width − 28` the
// difference is exactly 81.0 at all three widths. The stack adds the reply's height rather than
// swallowing or re-deciding it, which is the property the panel needs.
//
// `fittingSize` answers **1171** wide, which is the document's longest unwrapped line (the code
// block's first line) and not a wrap width. That is the same shape a `Text` gives — 274 for a
// word, 6929 for a paragraph — and `PanelSizer` clamps it to `maxWidth` 560. Reporting the
// natural width for an unspecified proposal is therefore load-bearing rather than tidy: an
// implementation that answered a fixed number there (the first draft of this probe defaulted to
// 300) makes every rendered reply ask for `minWidth`, and a wide document would only reach 560
// through `previous.width` — i.e. only if the plain streamed text had already taken it there.
//
// **3. The throwaway triple agrees with the live view exactly.** Same document, same widths,
// against a real `NSTextView`'s own layout manager after its frame and container width were set:
//
//     @300  throwaway 467.0 / live 467.0    @430  371.0 / 371.0    @560  355.0 / 355.0
//
// Two details are load-bearing for that and are measured here rather than assumed: a
// programmatically built `NSTextContainer` comes up with `lineFragmentPadding` **5.0** — the same
// as the one a text view builds for itself, so the two agree by default and a copy of the live
// container's value is belt-and-braces rather than a fix — and the laid-out width must be
// `proposal − 2 × textContainerInset.width` (3 a side here, per `RenderedTextView`'s measured
// inset). Getting either wrong moves the answer by a line at the narrow widths.
//
// **4. Stable to the bit.** Ten consecutive reads on one reused host: spread **0.0000** at all
// three widths, and a fresh host answers the identical CGFloat. So a pinning test could assert
// equality; the one written asserts a tolerance anyway, for the reason its own comment gives —
// these are sums of font metrics, and a system font revision may move them by a fraction without
// anything in this repo changing.
//
// **What the implementation took from this:** `RenderedReplyView` implements
// `sizeThatFits(_:nsView:context:)` through a throwaway triple — the natural size for an
// unspecified, infinite or zero proposal, the height at `proposal.width − 2 × inset.width`
// otherwise — and hosts a **bare** `NSTextView` with no `NSScrollView`, because the panel's
// `scrollingMiddle` owns scrolling and a scroll view here would answer the proposal back and put
// the panel at the ceiling by the other route. → `Sources/TranslatorApp/RenderedReplyView.swift`,
// `docs/reference/PLATFORM-TRAPS.md`.
import AppKit
import MarkupKit
import SwiftUI
import TranslationCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// ── the document ─────────────────────────────────────────────────────────────────────────────
// §11.4 asks for «a document with a table and a code block» specifically, because those are the
// two forms whose height is not a count of wrapped lines: a table is `NSTextTable` blocks and a
// code block is a tinted paragraph with its own spacing.
let document = """
    ## Отчёт о совместимости

    Ниже — сводка по трём движкам и один пример вызова. Абзац нарочно длинный, чтобы на \
    узкой панели он переносился на несколько строк, а на широкой — на меньшее их число.

    | Движок | Порт | Потоковая выдача | Таблицы |
    |---|---:|:---:|---|
    | Ollama | 11434 | да | да |
    | LM Studio | 1234 | да | да |
    | MLX | — | нет | нет |

    ```swift
    let outcome = try await translator.translate(source: text, to: .russian)
    print(outcome.timeToFirstTokenMS ?? 0)
    ```

    - первый пункт списка
    - второй пункт списка
    - третий пункт списка
    """

let config = MarkdownFontConfig(baseSize: 13, typeface: .system)
let rendering = MarkdownToAttributed.rendering(of: document, config: config)

let widths: [CGFloat] = [300, 430, 560]
let inset = NSSize(width: 3, height: 8)

// ── the two representables ───────────────────────────────────────────────────────────────────
// Both build the same bare text view. The only difference is whether `sizeThatFits` is
// implemented, which is the whole question.

func makeTextView(_ attributed: NSAttributedString) -> NSTextView {
    let storage = NSTextStorage(attributedString: attributed)
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(
        size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)
    let view = NSTextView(frame: .zero, textContainer: container)
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.minSize = .zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                          height: CGFloat.greatestFiniteMagnitude)
    view.textContainerInset = inset
    return view
}

/// What the candidate implementation would report — measured through a throwaway triple, never
/// the live view's own, so measuring cannot disturb what is on screen.
///
/// `width` nil means «unspecified»: the natural, unwrapped size, which is what `fittingSize`
/// reads and what has to be a real number for the panel to choose a width at all.
func throwawaySize(_ attributed: NSAttributedString, width: CGFloat?,
                   padding: CGFloat) -> CGSize {
    let storage = NSTextStorage(attributedString: attributed)
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let containerWidth = width.map { max($0 - inset.width * 2, 1) }
        ?? CGFloat.greatestFiniteMagnitude
    let container = NSTextContainer(
        size: CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = padding
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container)
    return CGSize(width: (width ?? ceil(used.width)) + (width == nil ? inset.width * 2 : 0),
                  height: ceil(used.height) + inset.height * 2)
}

struct Reply: NSViewRepresentable {
    let attributed: NSAttributedString
    let sizes: Bool

    func makeNSView(context: Context) -> NSTextView { makeTextView(attributed) }
    func updateNSView(_ view: NSTextView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView,
                      context: Context) -> CGSize? {
        guard sizes else { return nil }
        let padding = nsView.textContainer?.lineFragmentPadding ?? 5
        // Unspecified, infinite and zero all mean «what is your natural size» here, and none of
        // them is a wrap width to lay out at.
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return throwawaySize(attributed, width: nil, padding: padding)
        }
        return throwawaySize(attributed, width: width, padding: padding)
    }
}

/// The panel's shape around the reply — a caption, the reply, a button row, 14 pt of padding.
/// Not `PanelView` itself (this probe cannot import the app), so the chrome figure is
/// indicative; what it is here to show is that the stack *adds* the reply's height rather than
/// swallowing it.
struct PanelShaped: View {
    let attributed: NSAttributedString
    let sizes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Русский → английский").font(.caption).foregroundStyle(.secondary)
            Reply(attributed: attributed, sizes: sizes)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Заменить") {}
                Button("Скопировать") {}
                Button("Открыть в окне") {}
            }
        }
        .padding(14)
    }
}

func measure<V: View>(_ view: V) -> (ideal: CGSize, heights: [CGFloat]) {
    let host = NSHostingController(rootView: view)
    host.view.layoutSubtreeIfNeeded()
    let ideal = host.view.fittingSize
    let heights = widths.map {
        host.sizeThatFits(in: CGSize(width: $0, height: CGFloat.greatestFiniteMagnitude)).height
    }
    return (ideal, heights)
}

func line(_ label: String, _ ideal: CGSize, _ heights: [CGFloat]) {
    let cells = zip(widths, heights)
        .map { String(format: "@%.0f %7.1f", $0.0, $0.1) }
        .joined(separator: "   ")
    print(String(format: "%-34@ fitting %7.1f × %7.1f   %@",
                 label as NSString, ideal.width, ideal.height, cells as NSString))
}

print("document \(document.count) chars, rendering \(rendering.attributed.length) runs, "
      + "\(rendering.codeRegions.count) code region(s)")
print("screen visibleFrame \(NSScreen.main?.visibleFrame.size ?? .zero), "
      + "0.6 × height = \((NSScreen.main?.visibleFrame.height ?? 0) * 0.6)")

print("\n== 1. no sizeThatFits ==")
let bareAlone = measure(Reply(attributed: rendering.attributed, sizes: false))
line("reply alone", bareAlone.ideal, bareAlone.heights)
let bareStack = measure(PanelShaped(attributed: rendering.attributed, sizes: false))
line("panel-shaped stack", bareStack.ideal, bareStack.heights)

print("\n== 2. with sizeThatFits ==")
let sizedAlone = measure(Reply(attributed: rendering.attributed, sizes: true))
line("reply alone", sizedAlone.ideal, sizedAlone.heights)
let sizedStack = measure(PanelShaped(attributed: rendering.attributed, sizes: true))
line("panel-shaped stack", sizedStack.ideal, sizedStack.heights)
let chrome = zip(sizedStack.heights, sizedAlone.heights).map { $0 - $1 }
print("stack − reply, same width      \(chrome.map { String(format: "%.1f", $0) }.joined(separator: "   "))")
// Not a constant, and the reason is arithmetic rather than mysterious: the stack's 14 pt of
// padding takes 28 pt off the width the reply is proposed. Compared against the reply measured
// at the *inner* width, the difference should be the chrome alone and the same at every width.
let innerChrome = zip(widths, sizedStack.heights).map { width, stack in
    stack - throwawaySize(rendering.attributed, width: width - 28, padding: 5).height
}
print("stack − reply at width − 28    \(innerChrome.map { String(format: "%.1f", $0) }.joined(separator: "   "))")

print("\n== 3. the throwaway triple against the live view ==")
let probeContainer = NSTextContainer(size: .zero)
print("programmatic NSTextContainer lineFragmentPadding \(probeContainer.lineFragmentPadding)")
let live = makeTextView(rendering.attributed)
print("its text view's own container's padding          "
      + "\(live.textContainer?.lineFragmentPadding ?? -1)")
for width in widths {
    let throwaway = throwawaySize(rendering.attributed, width: width,
                                    padding: live.textContainer?.lineFragmentPadding ?? 5).height
    live.frame = NSRect(x: 0, y: 0, width: width, height: 10)
    live.textContainer?.size = CGSize(width: width - inset.width * 2,
                                      height: CGFloat.greatestFiniteMagnitude)
    live.layoutManager?.ensureLayout(for: live.textContainer!)
    let measured = ceil(live.layoutManager!.usedRect(for: live.textContainer!).height)
        + inset.height * 2
    print(String(format: "@%.0f  throwaway %7.1f   live %7.1f   agree=%@",
                 width, throwaway, measured,
                 (abs(throwaway - measured) < 0.5 ? "yes" : "NO") as NSString))
}

print("\n== 4. stability ==")
let host = NSHostingController(rootView: PanelShaped(attributed: rendering.attributed,
                                                     sizes: true))
host.view.layoutSubtreeIfNeeded()
for width in widths {
    var seen: [CGFloat] = []
    for _ in 0..<10 {
        host.view.layoutSubtreeIfNeeded()
        seen.append(host.sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height)
    }
    let spread = (seen.max() ?? 0) - (seen.min() ?? 0)
    let fresh = measure(PanelShaped(attributed: rendering.attributed, sizes: true))
        .heights[widths.firstIndex(of: width)!]
    print(String(format: "@%.0f  ten reads %7.1f   spread %.4f   fresh host %7.1f   agree=%@",
                 width, seen[0], spread, fresh,
                 (abs(seen[0] - fresh) < 0.5 ? "yes" : "NO") as NSString))
}
