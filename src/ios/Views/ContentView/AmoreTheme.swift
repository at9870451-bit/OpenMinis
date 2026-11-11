//
//  AmoreTheme.swift
//  Amore - Apple Native White design tokens
//
//  Single source of truth for the ChatGPT-style light system:
//  flat whites, one grey family, one accent, no gradients.
//

import SwiftUI

enum AmoreTheme {
    /// Adaptive: the system palette in light, the same roles inverted in dark,
    /// so nothing hard-codes a scheme the user did not choose.
    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }

    // MARK: Surfaces
    static let background = adaptive(light: .white, dark: Color(red: 0.07, green: 0.07, blue: 0.08))                       // #FFFFFF
    static let secondaryBackground = Color(red: 0.961, green: 0.961, blue: 0.969) // #F5F5F7
    static let groupedBackground = Color(red: 0.949, green: 0.949, blue: 0.969)   // #F2F2F7
    static let card = Color.white

    // MARK: Text
    static let textPrimary = adaptive(light: Color(red: 0.110, green: 0.110, blue: 0.118), dark: .white)
    static let textSecondary = adaptive(light: Color(red: 0.557, green: 0.557, blue: 0.576), dark: Color(white: 0.62))
    static let textDisabled = Color(red: 0.780, green: 0.780, blue: 0.800)  // #C7C7CC

    // MARK: Lines & accent
    static let separator = adaptive(light: Color(red: 0.898, green: 0.898, blue: 0.918), dark: Color(white: 0.28))
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)            // #007AFF
    static let success = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let warning = Color(red: 1.0, green: 0.584, blue: 0.0)
    static let danger = Color(red: 1.0, green: 0.231, blue: 0.188)

    // MARK: Radii
    enum Radius {
        static let chip: CGFloat = 12
        static let row: CGFloat = 12
        static let card: CGFloat = 20
        static let panel: CGFloat = 24
        static let screen: CGFloat = 28
    }

    // MARK: Glass
    /// White glass fill used by floating surfaces (drawer, composer, bars).
    static func glassFill(_ opacity: Double = 0.80) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.10, alpha: opacity * 0.9)
            : UIColor.white.withAlphaComponent(opacity) })
    }
}
