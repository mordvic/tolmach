// Sources/TranslatorApp/PaneSplit.swift
import AppKit
import SwiftUI

/// The window's two panes as sheets on a tinted frame — the measurements every surface inside a
/// sheet reads, kept in one place so the header, the editor and the rendered view cannot start
/// their text at three different edges.
///
/// **Why sheets** (2026-10-29, the framed-sheet direction chosen from three rendered variants):
/// the languages moved out of the toolbar onto the panes they describe — «Английский» over the
/// text that is English, «Русский» over the text that is Russian, ⇄ between them — which is
/// how DeepL and Google Translate lay out the same two texts. A header that names its pane's
/// language needs the pane to read as one object, and a bordered sheet on a frame one tone off
/// it is what makes it one. `docs/adr/0014` is the decision.
enum PaneSheet {
    static let cornerRadius: CGFloat = 10
    /// Where a sheet's content starts, from its edge: the header's controls, and — through
    /// `textInset` — the first character of its text.
    static let contentInset: CGFloat = 14
    /// A hosted text view's `textContainerInset.width`: `contentInset` less the container's
    /// `lineFragmentPadding`, which is 5 (measured — `SourceEditor`'s placeholder carries it).
    static let textInset: CGFloat = contentInset - 5
    /// The frame around and between the sheets.
    static let gap: CGFloat = 8
    /// Both sheets' headers, pinned to one height so their rows line up across the gap and ⇄
    /// can sit on the line between them. 40, the chosen design's own figure (the framed-sheet
    /// variant, 2026-10-29); with `textTopInset` below it puts a sheet's first line where that
    /// picture put it. It was 36 for a day, which set the text 2 pt higher than the design.
    static let headerHeight: CGFloat = 40
    /// From the header to the first line of text, in every view a sheet hosts — the editor, the
    /// rendered view and the plain-prose `Text` — so the two sheets' first lines stand level.
    /// 6, the design's figure; it was 8 under the old 28 pt header band, which carried no room
    /// of its own below its controls.
    static let textTopInset: CGFloat = 6

    /// The leading sheet's width for a split, clamped so neither sheet goes under its floor.
    /// A function so a test can pin the clamp without laying out a view. When the two floors do
    /// not both fit — never, at the window's 700 pt minimum — the leading one wins.
    static func leadingWidth(total: CGFloat, fraction: CGFloat,
                             leadingMin: CGFloat, trailingMin: CGFloat) -> CGFloat {
        let available = max(total - gap, 0)
        let ceiling = max(available - trailingMin, leadingMin)
        return min(max((available * fraction).rounded(), leadingMin), ceiling)
    }

    /// The frame's ground: the window's own, a tone toward the ink. macOS 27 draws the light
    /// window white — the same white as the sheets — so the step has to be drawn rather than
    /// inherited; in the dark the sheets (`textBackgroundColor`) are already the darker of the two.
    static var frame: some View {
        Color(nsColor: .windowBackgroundColor).overlay(Color.primary.opacity(0.045))
    }
}

extension View {
    /// One sheet: the text ground, a hairline, rounded corners. The content is clipped to the
    /// shape, so a hosted text view's scroller cannot draw over a corner.
    func paneSheet() -> some View {
        let shape = RoundedRectangle(cornerRadius: PaneSheet.cornerRadius, style: .continuous)
        return self
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Two sheets side by side, the gap between them the handle that resizes them.
///
/// **Not `HSplitView`, which the window used until 2026-10-29.** Its divider is a hairline the
/// split view draws itself, in a colour SwiftUI does not expose — between two bordered sheets it
/// made three parallel lines four points apart. Here the gap *is* the divider: dragging it moves
/// the boundary, the pointer turns into the column-resize one over it, and VoiceOver can adjust
/// it. `bridge` is drawn over the gap at the headers' height — ⇄, which belongs between the two
/// languages it exchanges — and follows the boundary when it moves.
///
/// The fraction lives in `@State`, the lifetime `HSplitView`'s own position had: it survives
/// switching «Текст | Файлы», because the split's identity does not change with its leading
/// sheet, and resets when the window is closed.
struct PaneSplit<Leading: View, Trailing: View, Bridge: View>: View {
    let leadingMinWidth: CGFloat
    let trailingMinWidth: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var bridge: Bridge

    @State private var fraction: CGFloat = 0.5
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let width = PaneSheet.leadingWidth(total: total, fraction: fraction,
                                          leadingMin: leadingMinWidth, trailingMin: trailingMinWidth)
            HStack(spacing: 0) {
                leading.frame(width: width)
                handle(total: total, width: width)
                trailing.frame(maxWidth: .infinity)
            }
            .overlay(alignment: .topLeading) {
                bridge.position(x: width + PaneSheet.gap / 2, y: PaneSheet.headerHeight / 2)
            }
        }
    }

    private func handle(total: CGFloat, width: CGFloat) -> some View {
        let available = max(total - PaneSheet.gap, 1)
        return Color.clear
            .frame(width: PaneSheet.gap)
            .contentShape(Rectangle())
            .resizePointer()
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartWidth ?? width
                    dragStartWidth = start
                    // Stored as the clamped width's fraction, so dragging past a floor and back
                    // moves the boundary the moment the pointer turns round, not after it has
                    // travelled the overshoot back.
                    let clamped = PaneSheet.leadingWidth(total: total,
                                                    fraction: (start + value.translation.width) / available,
                                                    leadingMin: leadingMinWidth,
                                                    trailingMin: trailingMinWidth)
                    fraction = clamped / available
                }
                .onEnded { _ in dragStartWidth = nil })
            .accessibilityElement()
            .accessibilityLabel("Граница между исходником и переводом")
            .accessibilityValue("\(Int((fraction * 100).rounded())) %")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 0.05
                let wanted = fraction + (direction == .increment ? step : -step)
                let clamped = PaneSheet.leadingWidth(total: total, fraction: wanted,
                                                leadingMin: leadingMinWidth,
                                                trailingMin: trailingMinWidth)
                fraction = clamped / available
            }
    }
}

private extension View {
    /// The column-resize pointer over the handle. `pointerStyle` is macOS 15+; before it, the
    /// cursor stack, which is what that modifier replaces.
    @ViewBuilder func resizePointer() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.columnResize)
        } else {
            onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
    }
}
