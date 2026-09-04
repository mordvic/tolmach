// Sources/TranslatorApp/ChangeCard.swift
import SwiftUI
import TranslationCore

/// «было → стало» for one change, as a value — the popover's content and nothing about how it
/// is shown.
///
/// The three shapes a `TextChange` can be are read here once, so the popover cannot draw a
/// fourth: a pure removal shows only «было», a pure insertion shows only «стало», and a
/// substitution shows both with the arrow between them. Empty is `nil`, not `""` — `TextChange`
/// already spells «nothing on this side» that way (its own doc comment), and a card that drew
/// an empty line where a whole half is missing would look like a rendering defect rather than
/// the shape it is.
struct ChangeCard: Equatable {
    let removed: String?
    let inserted: String?

    /// «→» belongs between two halves that both exist — never beside just one of them.
    var showsArrow: Bool { removed != nil && inserted != nil }

    static func of(_ change: TextChange) -> ChangeCard {
        ChangeCard(removed: change.removed.isEmpty ? nil : change.removed,
                  inserted: change.inserted.isEmpty ? nil : change.inserted)
    }
}

/// The popover's content view: `ChangeCard`, «Вернуть», and nothing else — a readout with one
/// action, the same shape `PanelView`'s status row is.
///
/// **Chrome keeps the system size; only the user's text takes «Шрифт текста».** `docs/adr/0008`
/// draws the line at four surfaces and this is not one of them — the «было»/«стало» eyebrows are
/// `.caption2` and the struck/plain lines are the system's own caption size, in `font`'s
/// *family* only, so a change read at 32 pt still opens a popover sized for a caption rather
/// than for the pane's own type scale.
struct ChangeCardView: View {
    let card: ChangeCard
    var typeface: ContentTypeface = .system
    /// Nil hides the button under its own reason rather than merely disabling it with none —
    /// `docs/design/specs/2026-09-04-change-marks-spec.md`'s «Вернуть» step: a change the
    /// aligner cannot place is refused, not guessed.
    var revertUnavailableReason: String?
    var onRevert: () -> Void = {}

    /// The system's own caption size, `font`'s family — `Scripts/content-font.swift` is where
    /// 10 pt was measured against `.caption1`, the same figure `ContentFont`'s own doc comment
    /// cites for why 10 is the floor and not 9.
    private var textFont: Font { .system(size: 10, design: typeface.design) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let removed = card.removed {
                Text("было").font(.caption2).foregroundStyle(.secondary)
                Text(removed).font(textFont).foregroundStyle(.secondary).strikethrough()
            }
            if card.showsArrow {
                Image(systemName: "arrow.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let inserted = card.inserted {
                Text("стало").font(.caption2).foregroundStyle(.secondary)
                Text(inserted).font(textFont)
            }
            Divider()
            Button("Вернуть", action: onRevert)
                .disabled(revertUnavailableReason != nil)
                .help(revertUnavailableReason ?? "Восстановить исходный текст для этого изменения")
        }
        .padding(10)
        .frame(minWidth: 160, alignment: .leading)
        .fixedSize()
    }
}
