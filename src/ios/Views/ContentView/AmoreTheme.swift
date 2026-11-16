import SwiftUI
import UIKit

/// Single adaptive palette for SwiftUI and UIKit. Providers resolve directly
/// from traitCollection; no conversion through a pre-resolved SwiftUI Color.
enum PokiTheme {
    private static func rgba(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    private static func pair(_ light: UInt32, _ dark: UInt32,
                             lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? rgba(dark, alpha: darkAlpha) : rgba(light, alpha: lightAlpha)
        }
    }

    static let uiBackground = pair(0xFAFAF9, 0x0C0C0D)
    static let uiPrimaryText = pair(0x111110, 0xF4F4F1)
    static let uiSecondaryText = pair(0x6F6F69, 0x8D8D87)
    static let uiSurface = pair(0xEFEFEC, 0x1C1C1E)
    static let uiDivider = pair(0x000000, 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.14)
    static let uiAIAccent = pair(0xC4CEFB, 0x3A4270)
    static let uiTagBackground = pair(0xDEE3FD, 0x2A3052)
    static let uiTagText = pair(0x262D63, 0xD5DAFB)
    static let uiPrimaryButton = pair(0x111110, 0xF4F4F1)
    static let uiPrimaryButtonText = pair(0xFAFAF9, 0x0C0C0D)
    static let uiDanger = pair(0xB3261E, 0xF2B8B5)
    static let uiSelection = pair(0xDEE3FD, 0x2A3052)

    static let background = Color(uiBackground)
    static let primaryText = Color(uiPrimaryText)
    static let secondaryText = Color(uiSecondaryText)
    static let surface = Color(uiSurface)
    static let divider = Color(uiDivider)
    static let aiAccent = Color(uiAIAccent)
    static let tagBackground = Color(uiTagBackground)
    static let tagText = Color(uiTagText)
    static let primaryButton = Color(uiPrimaryButton)
    static let primaryButtonText = Color(uiPrimaryButtonText)
    static let selection = Color(uiSelection)
    static let danger = Color(uiDanger)
    /// Legacy name maps to the specified accessible lavender foreground.
    static let aiAccentStrong = tagText
    static let floatingSurface = Color(pair(0xFAFAF9, 0x1C1C1E, lightAlpha: 0.86, darkAlpha: 0.86))
    static let shadowSoft = Color.black.opacity(0.04)
    static let shadowFloating = Color.black.opacity(0.06)

    enum Radius {
        static let chip: CGFloat = 12
        static let row: CGFloat = 12
        static let card: CGFloat = 20
        static let composer: CGFloat = 24
        static let panel: CGFloat = 24
        static let screen: CGFloat = 28
    }

    static func adaptive(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// Install before the first window, not in ContentView.onAppear (too late
    /// for bars and existing table cells to inherit UIAppearance).
    @MainActor static func applyGlobalAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiBackground
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: uiPrimaryText]
        nav.largeTitleTextAttributes = [.foregroundColor: uiPrimaryText]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().compactScrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = uiPrimaryButton
        let bar = UIToolbarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = uiBackground
        bar.shadowColor = .clear
        UIToolbar.appearance().standardAppearance = bar
        UIToolbar.appearance().scrollEdgeAppearance = bar
        UIToolbar.appearance().tintColor = uiPrimaryButton
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = uiBackground
        tab.shadowColor = uiDivider
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = uiPrimaryButton
        UITabBar.appearance().unselectedItemTintColor = uiSecondaryText
        UITableView.appearance().backgroundColor = uiBackground
        UITableView.appearance().separatorColor = uiDivider
        UITableViewCell.appearance().backgroundColor = uiSurface
        UICollectionView.appearance().backgroundColor = uiBackground
        UISwitch.appearance().onTintColor = uiTagText
        UISegmentedControl.appearance().selectedSegmentTintColor = uiSurface
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: uiPrimaryText], for: .normal)
        UITextField.appearance().tintColor = uiTagText
        UITextView.appearance().tintColor = uiTagText
        UISearchBar.appearance().tintColor = uiPrimaryButton
        UIProgressView.appearance().progressTintColor = uiTagText
        UIPageControl.appearance().currentPageIndicatorTintColor = uiTagText
    }
}

/// Explicit screen styling is required for SwiftUI List/Form; UIAppearance
/// alone cannot override scrollContentBackground or a view's own hardcodes.
private struct PokiScreenModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(PokiTheme.background.ignoresSafeArea())
            .foregroundStyle(PokiTheme.primaryText)
            .tint(PokiTheme.primaryButton)
            .toolbarBackground(PokiTheme.background, for: .navigationBar)
    }
}
extension View {
    func pokiScreen() -> some View { modifier(PokiScreenModifier()) }
    func pokiCard() -> some View {
        background(PokiTheme.surface, in: RoundedRectangle(cornerRadius: PokiTheme.Radius.card, style: .continuous))
    }
}

/// Source-compatible aliases; direct rendering call sites are migrated too.
enum AmoreTheme {
    static let background = PokiTheme.background
    static let secondaryBackground = PokiTheme.surface
    static let groupedBackground = PokiTheme.background
    static let card = PokiTheme.surface
    static let textPrimary = PokiTheme.primaryText
    static let textSecondary = PokiTheme.secondaryText
    static let textDisabled = PokiTheme.secondaryText.opacity(0.6)
    static let separator = PokiTheme.divider
    static let accent = PokiTheme.tagText
    static let success = PokiTheme.tagText
    static let warning = PokiTheme.secondaryText
    static let danger = PokiTheme.danger
    enum Radius {
        static let chip = PokiTheme.Radius.chip
        static let row = PokiTheme.Radius.row
        static let card = PokiTheme.Radius.card
        static let panel = PokiTheme.Radius.panel
        static let screen = PokiTheme.Radius.screen
    }
    static func glassFill(_ opacity: Double = 0.80) -> Color {
        PokiTheme.background.opacity(opacity)
    }
}
