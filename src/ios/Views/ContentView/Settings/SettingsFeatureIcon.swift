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

    /// Restrained coloured INK, not the old saturated solid tile. Each colour
    /// has dark light-mode ink and a soft light dark-mode ink for contrast.
    var lightHex: UInt32 {
        switch self {
        case .red: 0x884650
        case .orange: 0x80552F
        case .yellow: 0x705D23
        case .green: 0x3B6550
        case .cyan: 0x316472
        case .blue: 0x425D85
        case .purple: 0x645178
        }
    }

    var darkHex: UInt32 {
        switch self {
        case .red: 0xD4A7AD
        case .orange: 0xD8B18C
        case .yellow: 0xD7C58F
        case .green: 0xA4C8B1
        case .cyan: 0x9DC7D0
        case .blue: 0xADC3E3
        case .purple: 0xC4B2DC
        }
    }

    // Compatibility for isolated older palette consumers. The redesigned
    // icon below uses the adaptive coloured ink, never white-on-yellow.
    var foregroundHex: UInt32 { self == .yellow ? 0x1C1C1E : 0xFFFFFF }
}

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

struct SettingsFeatureIcon: View {
    let symbol: String
    let feature: SettingsFeature
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    // Decorative bounds, not a new hit target. Native List still owns its
    // >=44pt row; cap growth so accessibility text retains horizontal space.
    private var size: CGFloat { min(max(side, 32), 44) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
    }

    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
    private var ink: Color {
        color(scheme == .dark ? feature.iconColor.darkHex : feature.iconColor.lightHex)
    }

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.51, weight: .medium))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background {
                plate
                    .overlay { shape.fill(ink.opacity(scheme == .dark ? 0.08 : 0.04)) }
                    .overlay { shape.strokeBorder(ink.opacity(0.22), lineWidth: 0.65) }
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }

    // Self-contained so the existing isolated icon host also compiles. No
    // copied logo, image asset, interactive glass or per-icon shadow.
    @ViewBuilder private var plate: some View {
        if reduceTransparency || contrast == .increased {
            shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape).clipShape(shape)
            } else {
                shape.fill(.regularMaterial)
            }
            #else
            shape.fill(.regularMaterial)
            #endif
        }
    }
}
#endif
