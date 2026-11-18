import Foundation

/// Stable homepage order: red → orange → yellow → green → cyan → blue → purple.
/// Kept free of UI dependencies so order, coverage and contrast can be unit tested.
enum SettingsFeature: Int, CaseIterable {
    case providers, modelGroups, usage, developerConnection, homeShortcuts, appearance
    case tools, subAgents, skills, soul, rootfs, terminal, plugins, memory
    case contextCompression, mcp, environments, storage, sharedFolders, mountedFolders
    case iCloud, backup, permissions, biometric, logs, about, privacy, feedback

    var iconColor: SettingsIconColor { SettingsIconColor.at(index: rawValue) }
}

enum SettingsIconColor: Int, CaseIterable {
    case red, orange, yellow, green, cyan, blue, purple

    static func at(index: Int) -> Self {
        let count = allCases.count
        return allCases[((index % count) + count) % count]
    }

    var lightHex: UInt32 {
        switch self {
        case .red: 0xC62828
        case .orange: 0xB44C00
        case .yellow: 0xF3CC30
        case .green: 0x137843
        case .cyan: 0x007C91
        case .blue: 0x1B63C8
        case .purple: 0x7A43BD
        }
    }

    var darkHex: UInt32 {
        switch self {
        case .red: 0xD03542
        case .orange: 0xBF5605
        case .yellow: 0xE8BE26
        case .green: 0x19814A
        case .cyan: 0x008197
        case .blue: 0x2567D4
        case .purple: 0x8650C9
        }
    }

    /// Yellow needs dark ink; white on yellow fails in either appearance.
    var foregroundHex: UInt32 { self == .yellow ? 0x1C1C1E : 0xFFFFFF }
}

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

struct SettingsFeatureIcon: View {
    let symbol: String
    let feature: SettingsFeature
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

    private var size: CGFloat { min(side, 40) }

    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    var body: some View {
        let palette = feature.iconColor
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(Color(color(palette.foregroundHex)))
            .frame(width: size, height: size)
            .background(Color(UIColor { traits in
                color(traits.userInterfaceStyle == .dark ? palette.darkHex : palette.lightHex)
            }), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}
#endif
