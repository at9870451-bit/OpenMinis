//
//  AmoreTheme.swift
//  Amore — Poki Design System
//
//  Warm Paper UI · Minimalist Monochrome · Soft Lavender AI
//
//  Single source of truth for colour. Every surface in the app resolves
//  through these tokens, and `applyGlobalAppearance()` pushes the same
//  palette into UIKit's appearance proxies so navigation bars, table
//  backgrounds and control tints match without touching every screen.
//

import SwiftUI
import UIKit

// MARK: - Palette (Poki)

enum PokiTheme {

    // MARK: Raw hex → Color

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: Double(alpha)
        )
    }

    /// Resolves to `light` in light mode and `dark` in dark mode, refreshing
    /// automatically when the system appearance changes.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    // MARK: Light / dark pairs

    static let background = adaptive(light: hex(0xFAFAF9), dark: hex(0x0C0C0D))
    static let primaryText = adaptive(light: hex(0x111110), dark: hex(0xF4F4F1))
    static let secondaryText = adaptive(light: hex(0x6F6F69), dark: hex(0x8D8D87))
    static let surface = adaptive(light: hex(0xEFEFEC), dark: hex(0x1C1C1E))
    static let aiAccent = adaptive(light: hex(0xC4CEFB), dark: hex(0x3A4270))
    static let tagBackground = adaptive(light: hex(0xDEE3FD), dark: hex(0x2A3052))
    static let tagText = adaptive(light: hex(0x262D63), dark: hex(0xD5DAFB))
    static let primaryButton = adaptive(light: hex(0x111110), dark: hex(0xF4F4F1))
    static let primaryButtonText = adaptive(light: hex(0xFAFAF9), dark: hex(0x0C0C0D))

    /// 13% black in light, 14% white in dark.
    static let divider = adaptive(
        light: hex(0x000000, alpha: 0.13),
        dark: hex(0xFFFFFF, alpha: 0.14)
    )

    // MARK: Semantics that are not in the spec table but are needed in practice

    /// Slightly deeper than `aiAccent`, for glyphs and icons that must stay legible.
    static let aiAccentStrong = adaptive(light: hex(0x8E9BE8), dark: hex(0xA9B4F0))
    /// Composer / floating surfaces.
    static let floatingSurface = adaptive(
        light: hex(0xFFFFFF, alpha: 0.72),
        dark: hex(0x1C1C1E, alpha: 0.72)
    )
    /// Pressed / selected row.
    static let selection = adaptive(light: hex(0x000000, alpha: 0.045), dark: hex(0xFFFFFF, alpha: 0.07))
    /// Destructive actions.
    static let danger = adaptive(light: hex(0xB3261E), dark: hex(0xF2B8B5))

    // MARK: Radii

    enum Radius {
        static let chip: CGFloat = 12
        static let row: CGFloat = 12
        static let card: CGFloat = 20
        static let composer: CGFloat = 24
        static let panel: CGFloat = 24
        static let screen: CGFloat = 28
    }

    // MARK: Shadows (deliberately restrained)

    static let shadowSoft = Color.black.opacity(0.06)
    static let shadowFloating = Color.black.opacity(0.08)

    // MARK: - Global UIKit appearance

    /// Pushes the palette into UIKit so screens that use `List`, `Form`,
    /// `NavigationStack` or plain `UITableView` inherit it without edits.
    /// Idempotent; call once when the root view appears.
    static func applyGlobalAppearance() {
        let bg = UIColor(background)
        let surface = UIColor(PokiTheme.surface)
        let primary = UIColor(primaryText)
        let secondary = UIColor(secondaryText)
        let divider = UIColor(PokiTheme.divider)
        let accent = UIColor(aiAccentStrong)

        // Navigation bars — flat paper, no blur band.
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bg
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: primary]
        nav.largeTitleTextAttributes = [.foregroundColor: primary]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = accent

        // Toolbars / tab bars.
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = bg
        tab.shadowColor = divider
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = accent
        UITabBar.appearance().unselectedItemTintColor = secondary

        // Lists and scroll views (Settings, Memory, Providers, …).
        UITableView.appearance().backgroundColor = bg
        UICollectionView.appearance().backgroundColor = .clear
        UIScrollView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear

        // Controls.
        UISwitch.appearance().onTintColor = accent
        UISegmentedControl.appearance().selectedSegmentTintColor = surface
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: primary], for: .normal)
        UISearchBar.appearance().tintColor = accent
        UITextField.appearance().tintColor = accent
        UITextView.appearance().tintColor = accent
    }
}

// MARK: - Legacy bridge

/// The rest of the app still refers to `AmoreTheme`. Rather than touching
/// ~170 view files, every legacy token is re-pointed at the Poki palette so
/// existing call sites render in the new system immediately.
enum AmoreTheme {
    static let background = PokiTheme.background
    static let secondaryBackground = PokiTheme.surface
    static let groupedBackground = PokiTheme.surface
    static let card = PokiTheme.surface

    static let textPrimary = PokiTheme.primaryText
    static let textSecondary = PokiTheme.secondaryText
    static let textDisabled = PokiTheme.secondaryText.opacity(0.6)

    static let separator = PokiTheme.divider
    static let accent = PokiTheme.aiAccentStrong
    static let success = PokiTheme.aiAccentStrong
    static let warning = PokiTheme.secondaryText
    static let danger = PokiTheme.danger

    enum Radius {
        static let chip = PokiTheme.Radius.chip
        static let row = PokiTheme.Radius.row
        static let card = PokiTheme.Radius.card
        static let panel = PokiTheme.Radius.panel
        static let screen = PokiTheme.Radius.screen
    }

    /// Translucent paper tint used by floating surfaces (drawer, composer, bars).
    /// Resolves to the Poki background hue at the requested alpha, so glass
    /// panels read as warm paper in light and deep charcoal in dark.
    static func glassFill(_ opacity: Double = 0.80) -> Color {
        PokiTheme.adaptive(
            light: Color(.sRGB, red: 0xFA / 255, green: 0xFA / 255, blue: 0xF9 / 255, opacity: opacity),
            dark: Color(.sRGB, red: 0x0C / 255, green: 0x0C / 255, blue: 0x0D / 255, opacity: opacity)
        )
    }
}
