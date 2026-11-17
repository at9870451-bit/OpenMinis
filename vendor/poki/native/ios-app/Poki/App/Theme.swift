import SwiftUI
import UIKit

/// Sizing for custom icon controls that share space with scrolling content.
struct CompactControlMetrics: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    var base: CGFloat = 48
    var maximum: CGFloat = 56

    var side: CGFloat { min(maximum, max(44, base * scale)) }
}

/// The app's own colours (ESP-326 prototype, theme.ts), each one a light and a dark value. Blue belongs
/// to Poki: the bear, the task card while it has the phone, the links to what it can do. Amber is your
/// turn, green is done, red is a problem. Surfaces, text and separators are the system's own semantic
/// colours, so they follow Increase Contrast and elevated sheets as the system's apps do.
enum Tint {
    /// Poki's blue, the bear images' own background: the same in light and dark, never the system blue.
    static let blue = Color(hex: 0x0177FD)
    /// The asleep image's background.
    static let night = Color(hex: 0x0F2172)
    static let blueSoft = Color(light: 0xE6F1FF, dark: 0x0C2748)
    /// Blue words on the page: the brand blue in light, a lighter one in dark, for contrast.
    static let blueText = Color(light: 0x0177FD, dark: 0x4C9DFF)
    static let blueLine = Color(light: 0xB9D8FF, dark: 0x1D4F8F)

    static let amber = Color(hex: 0xFFB020)
    static let amberSoft = Color(light: 0xFFF4DC, dark: 0x33270A)
    static let amberInk = Color(light: 0x7A4B00, dark: 0xFFD280)
    static let amberLine = Color(light: 0xF6DFAE, dark: 0x5C4410)

    static let green = Color(hex: 0x1FB86A)
    static let greenSoft = Color(light: 0xE4F6EC, dark: 0x0D2E1D)
    static let greenInk = Color(light: 0x0E6B3C, dark: 0x74E3A8)

    static let red = Color(light: 0xE5484D, dark: 0xF2555A)
    static let redSoft = Color(light: 0xFDECEC, dark: 0x3A1517)
    static let redInk = Color(light: 0x8C1D22, dark: 0xFFA3A6)

    /// Your own solid buttons (Hold to Allow, Done): ink in light, white in dark.
    static let solid = Color(.label)
    static let onSolid = Color(.systemBackground)
    /// Your bubble and the quiet fills: grey, never blue.
    static let fill = Color(.secondarySystemBackground)
    /// A hairline around a blue block in dark, where a shadow would read as a glow; nothing in light.
    static let ring = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.18) : .clear })
    /// The soft shadow under a blue block in light (the prototype's 0 6 18, blue at 22 %); none in dark.
    static let blueShadow = Color(UIColor { $0.userInterfaceStyle == .dark ? .clear : UIColor(hex: 0x0177FD).withAlphaComponent(0.22) })
    /// The conversation's page (ESP-376): a cool paper white in light, a blue-black in dark.
    static let page = Color(light: 0xF5F8FC, dark: 0x05070D)
    /// The conversations drawer, in the home light's own colours and still: a pale blue white in light,
    /// the deep blue of the home page's dark middle in dark.
    static let sidebar = Color(light: 0xEFF4FC, dark: 0x081329)
    /// The drawer's selected row, a breath of Poki's blue.
    static let sidebarSelected = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x3A8CFE).withAlphaComponent(0.18) : UIColor(hex: 0x0177FD).withAlphaComponent(0.08) })
    /// The drawer's faint day headings, a blue grey.
    static let sidebarHeading = Color(light: 0x7D8BA6, dark: 0x6F82AA)
    /// The Settings gear in the drawer: a deep navy in light, a pale blue in dark.
    static let sidebarInk = Color(light: 0x1B2F57, dark: 0xC9D7F2)
    /// The round ground of Poki's picture in the top bar.
    static let portrait = Color(light: 0xE3EEFF, dark: 0x0C2748)
    /// The shadow under Poki's white bubble (0 2 12, ink at 5 %); none in dark.
    static let bubbleShadow = Color(UIColor { $0.userInterfaceStyle == .dark ? .clear : UIColor(hex: 0x11191C).withAlphaComponent(0.05) })
    /// Words on the home page's gradient, each measured there for contrast (ESP-376's table, 5.3 to 7.8
    /// against the least favourable pixels): the line under the title, the message field's
    /// placeholder, and the line under the bear when it rests.
    static let homeSecondary = Color(light: 0x5F676C, dark: 0x8E959A)
    static let homePlaceholder = Color(light: 0x3D4549, dark: 0xC7CCD6)
    static let homeNote = Color(light: 0x444C51, dark: 0xC7CCD6)
    /// The hairline around a card and around a picture on it: the prototype's line (#EEEEF0, #25282D),
    /// which is the system's lightest grey but one.
    static let line = Color(.systemGray5)
}

extension Color {
    /// One colour with a light and a dark value.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
