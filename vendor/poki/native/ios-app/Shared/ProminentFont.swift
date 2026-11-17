import SwiftUI
import UIKit

/// Geist, the website's typeface, for prominent text only (page titles, session names, the Live
/// Activity's status word and main line); body text and controls keep the system font. Geist has no
/// Chinese, and laid Chinese lines out narrower than they drew (cut off on the Live Activity), so
/// Chinese uses the system font throughout.
enum Prominent {
    static var usesGeist: Bool { AppLocalization.language.hasPrefix("en") }

    private static func name(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "Geist-Bold"
        case .semibold: "Geist-SemiBold"
        case .medium: "Geist-Medium"
        default: "Geist-Regular"
        }
    }

    /// A text style's size at the default text size. The preferred font's own size is already scaled
    /// for the text size in use; scaling from it grew prominent text twice at the larger sizes and
    /// took it past a view's Dynamic Type limit.
    private static func baseSize(_ style: UIFont.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    }

    /// Geist at a text style's size, scaling with Dynamic Type.
    static func font(_ style: Font.TextStyle, _ weight: Font.Weight = .semibold) -> Font {
        guard usesGeist else { return .system(style, weight: weight) }
        return .custom(name(weight), size: baseSize(style.uiKit), relativeTo: style)
    }

    /// Geist at a size of its own, for a page's one large line, growing with `style` under Dynamic Type.
    static func font(size: CGFloat, relativeTo style: Font.TextStyle, _ weight: Font.Weight = .bold) -> Font {
        guard usesGeist else { return .system(style, weight: weight) }
        return .custom(name(weight), size: size, relativeTo: style)
    }

    static func uiFont(_ style: UIFont.TextStyle, _ weight: Font.Weight, compatibleWith traits: UITraitCollection? = nil) -> UIFont? {
        guard usesGeist, let base = UIFont(name: name(weight), size: baseSize(style)) else { return nil }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traits)
    }
}

private extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
