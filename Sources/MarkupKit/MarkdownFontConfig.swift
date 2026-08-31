// Sources/MarkupKit/MarkdownFontConfig.swift
import AppKit

/// Which family the rendered text is drawn in — the same three `ContentFont` offers, spelled
/// again here because `MarkupKit` must not import the app.
///
/// A mirror and not a shared type: `ContentTypeface` is a SwiftUI `Font.Design` in a
/// `@Observable` app layer, and this target is AppKit and `NSFontDescriptor.SystemDesign`. The
/// app maps one to the other at the one call site that knows both. `docs/adr/0008` is why the
/// mapping exists at all — only the user's own text follows the content font, so the converter
/// takes the font it must use rather than reading a preference it cannot see.
public enum MarkdownTypeface: Sendable, Equatable {
    case system, monospaced, serif

    var design: NSFontDescriptor.SystemDesign {
        switch self {
        case .system: .default
        case .monospaced: .monospaced
        case .serif: .serif
        }
    }
}

/// The whole of what the converter knows about how big and in what face to draw.
///
/// Headings and code are **multiples of `baseSize`**, never sizes of their own, because
/// `docs/adr/0008` promises that «Шрифт текста» governs every rendered run and nothing else
/// does. A heading that took a constant would stop scaling the moment someone changed the
/// setting, which is the failure that ADR exists to prevent — silently.
public struct MarkdownFontConfig: Sendable, Equatable {
    public let baseSize: CGFloat
    public let typeface: MarkdownTypeface

    public init(baseSize: CGFloat, typeface: MarkdownTypeface = .system) {
        self.baseSize = baseSize
        self.typeface = typeface
    }

    /// 13 pt системный — `ContentFont.default`'s pair, so a target with no font to hand
    /// renders what an untouched install renders. The number is duplicated rather than
    /// imported for the reason `MarkdownTypeface` is: this target cannot see `ContentFont`.
    public static let `default` = MarkdownFontConfig(baseSize: 13, typeface: .system)

    /// ×1.6 / 1.4 / 1.25 / 1.1 / 1.0 / 1.0 of `baseSize`, semibold — the design's own ladder.
    /// H5 and H6 do not grow: at 13 pt a 1.05 multiplier is under a point, and a heading that
    /// looks like body text with extra spacing is more honest than one that looks like a
    /// rounding error.
    static let headingScale: [CGFloat] = [1.6, 1.4, 1.25, 1.1, 1.0, 1.0]

    func headingSize(level: Int) -> CGFloat {
        let index = min(max(level, 1), Self.headingScale.count) - 1
        return (baseSize * Self.headingScale[index]).rounded()
    }
}
