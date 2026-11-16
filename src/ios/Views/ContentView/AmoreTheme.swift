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

    // Palette verified against JosssphZhou/poki App/Theme.swift, commit
    // 77254611596335464927258f62c7641b95ef2d02. No brand artwork is copied.
    static let uiBackground = pair(0xF5F8FC, 0x05070D)
    static let uiPrimaryText = UIColor.label
    static let uiSecondaryText = UIColor.secondaryLabel
    static let uiSurface = UIColor.secondarySystemBackground
    static let uiDivider = UIColor.systemGray5
    static let uiBlue = pair(0x0177FD, 0x0177FD)
    static let uiBlueText = pair(0x0177FD, 0x4C9DFF)
    static let uiBlueSoft = pair(0xE6F1FF, 0x0C2748)
    static let uiBlueLine = pair(0xB9D8FF, 0x1D4F8F)
    static let uiSidebar = pair(0xEFF4FC, 0x081329)
    static let uiSidebarHeading = pair(0x7D8BA6, 0x6F82AA)
    static let uiSidebarInk = pair(0x1B2F57, 0xC9D7F2)
    static let uiSelection = pair(0x0177FD, 0x3A8CFE, lightAlpha: 0.08, darkAlpha: 0.18)
    static let uiPortrait = pair(0xE3EEFF, 0x0C2748)
    static let uiAmber = pair(0xFFB020, 0xFFB020)
    static let uiAmberSoft = pair(0xFFF4DC, 0x33270A)
    static let uiAmberInk = pair(0x7A4B00, 0xFFD280)
    static let uiGreen = pair(0x1FB86A, 0x1FB86A)
    static let uiGreenSoft = pair(0xE4F6EC, 0x0D2E1D)
    static let uiGreenInk = pair(0x0E6B3C, 0x74E3A8)
    static let uiDanger = pair(0xE5484D, 0xF2555A)
    static let uiRedSoft = pair(0xFDECEC, 0x3A1517)
    static let uiRedInk = pair(0x8C1D22, 0xFFA3A6)
    // Utility icon accents are independent of the blue primary-action colour.
    static let uiToolOrange = pair(0xB85C00, 0xFFB66B)
    static let uiAgentPurple = pair(0x7954D6, 0xB69CFF)
    static let uiSkillTeal = pair(0x087C6F, 0x5ED8C8)
    static let uiMemoryRose = pair(0xB94278, 0xF399C2)
    static let uiRootfsIndigo = pair(0x4D59BE, 0xA5ACFF)
    static let uiBotCyan = pair(0x087DA5, 0x70D5F3)
    // Compatibility tokens now keep real colour instead of flattening every
    // action/status into label black or label white.
    static let uiAIAccent = uiPortrait
    static let uiTagBackground = uiBlueSoft
    static let uiTagText = uiBlueText
    static let uiPrimaryButton = uiBlue
    static let uiPrimaryButtonText = UIColor.white

    static let background = Color(uiBackground)
    static let primaryText = Color(uiPrimaryText)
    static let secondaryText = Color(uiSecondaryText)
    static let surface = Color(uiSurface)
    static let divider = Color(uiDivider)
    static let blue = Color(uiBlue)
    static let blueText = Color(uiBlueText)
    static let blueSoft = Color(uiBlueSoft)
    static let blueLine = Color(uiBlueLine)
    static let sidebar = Color(uiSidebar)
    static let sidebarHeading = Color(uiSidebarHeading)
    static let sidebarInk = Color(uiSidebarInk)
    static let portrait = Color(uiPortrait)
    static let amber = Color(uiAmber)
    static let amberSoft = Color(uiAmberSoft)
    static let amberInk = Color(uiAmberInk)
    static let green = Color(uiGreen)
    static let greenSoft = Color(uiGreenSoft)
    static let greenInk = Color(uiGreenInk)
    static let danger = Color(uiDanger)
    static let redSoft = Color(uiRedSoft)
    static let redInk = Color(uiRedInk)
    static let toolOrange = Color(uiToolOrange)
    static let agentPurple = Color(uiAgentPurple)
    static let skillTeal = Color(uiSkillTeal)
    static let memoryRose = Color(uiMemoryRose)
    static let rootfsIndigo = Color(uiRootfsIndigo)
    static let botCyan = Color(uiBotCyan)
    static let solid = Color(uiPrimaryText)
    static let onSolid = Color(UIColor.systemBackground)
    static let aiAccent = portrait
    static let tagBackground = blueSoft
    static let tagText = blueText
    static let primaryButton = blue
    static let primaryButtonText = Color.white
    static let selection = Color(uiSelection)
    static let aiAccentStrong = blueText
    static let floatingSurface = Color(pair(0xFFFFFF, 0x101C30, lightAlpha: 0.78, darkAlpha: 0.76))
    static let shadowSoft = Color.black.opacity(0.04)
    static let shadowFloating = Color.black.opacity(0.07)

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
            .tint(PokiTheme.blueText)
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
    static let success = PokiTheme.green
    static let warning = PokiTheme.amber
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
