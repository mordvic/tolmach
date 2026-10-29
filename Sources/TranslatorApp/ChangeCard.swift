// Sources/TranslatorApp/ChangeCard.swift
import AppKit
import MarkupKit
import SwiftUI
import TranslationCore

/// «было → стало» for one change, as a value — the popover's content and nothing about how it
/// is shown.
///
/// The three shapes a `TextChange` can be are read here once, so the popover cannot draw a
/// fourth: a pure removal shows only «было», a pure insertion shows only «стало», and a
/// substitution shows both, each under its label. Empty is `nil`, not `""` — `TextChange`
/// already spells «nothing on this side» that way (its own doc comment), and a card that drew
/// an empty line where a whole half is missing would look like a rendering defect rather than
/// the shape it is.
struct ChangeCard: Equatable {
    let removed: String?
    let inserted: String?

    static func of(_ change: TextChange) -> ChangeCard {
        ChangeCard(removed: change.removed.isEmpty ? nil : change.removed,
                  inserted: change.inserted.isEmpty ? nil : change.inserted)
    }
}

/// The popover's content view: `ChangeCard`, «Вернуть», and nothing else — a readout with one
/// action, the same shape `PanelView`'s status row is.
///
/// **Chrome keeps the system size; only the user's text takes «Шрифт текста»'s family.**
/// `docs/adr/0008` draws the line at four surfaces and this is not one of them: the words are the
/// system's body size in the content font's *family*, the labels its caption size — so a change
/// read at 32 pt still opens a card sized for the system's own type, not for the pane's scale.
/// Body and not caption since 2026-10-29: the words are what the card exists to show, and at
/// 10 pt in `secondaryLabelColor` with a strike through them they were the least legible text
/// in the feature (3.9:1 on the card's own ground).
///
/// **The same marks as the text**: the removed words in `ChangeMarks.removedColour`, struck; the
/// inserted ones with the dotted mark — so the card reads as the change it was opened from. The
/// labels say which half is which, so no arrow stands between them.
struct ChangeCardView: View {
    let card: ChangeCard
    var typeface: ContentTypeface = .system
    /// The system's Increase Contrast, for the marks' colours — the view's own state.
    var increasedContrast = false
    /// Nil hides the button under its own reason rather than merely disabling it with none —
    /// `docs/design/specs/2026-09-04-change-marks-spec.md`'s «Вернуть» step: a change the
    /// aligner cannot place is refused, not guessed.
    var revertUnavailableReason: String?
    var onRevert: () -> Void = {}

    /// The widest the text column grows before it wraps. **Measured, 2026-10-29**: with no bound
    /// (`.fixedSize()` on both axes) a 128-character change laid out on one line, 733 pt wide, and
    /// a rewritten paragraph would be wider than the screen.
    static let textWidth: CGFloat = 320
    static let padding: CGFloat = 12

    private var textFont: Font { .system(.body, design: typeface.design) }

    var body: some View {
        CappedWidth(maxWidth: Self.textWidth) {
            VStack(alignment: .leading, spacing: 4) {
                if let removed = card.removed {
                    Text("Было").font(.caption).foregroundStyle(.secondary)
                    Text(removed).font(textFont)
                        .foregroundStyle(Color(nsColor: removedColour))
                        .strikethrough(true, color: Color(nsColor: removedColour))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let inserted = card.inserted {
                    Text("Стало").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, card.removed == nil ? 0 : 6)
                    Text(inserted).font(textFont)
                        .underline(true, pattern: .dot,
                                   color: Color(nsColor: ChangeMarks.markColour(
                                       increasedContrast: increasedContrast)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().padding(.vertical, 4)
                Button("Вернуть", action: onRevert)
                    .disabled(revertUnavailableReason != nil)
                    .help(revertUnavailableReason ?? "Восстановить исходный текст для этого изменения")
            }
        }
        .padding(Self.padding)
        .frame(minWidth: 160, alignment: .leading)
        .fixedSize()
    }

    private var removedColour: NSColor { ChangeMarks.removedColour(increasedContrast: increasedContrast) }
}

/// Proposes its content its own ideal width, capped — what `.frame(maxWidth:)` does not do.
///
/// Under an unspecified proposal (`.fixedSize()`, a popover's fitting size) a flexible frame
/// reports the cap as its width but has measured its child at the child's ideal — one line — so
/// the wrapped text is taller than the frame said. This measures the child again at the width it
/// will actually get, so the card's height is the wrapped text's.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified).width
        let width = min(ideal, maxWidth, proposal.width ?? .infinity)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        subviews.first?.place(at: bounds.origin,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
