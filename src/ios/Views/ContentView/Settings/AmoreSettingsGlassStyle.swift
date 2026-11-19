import Foundation

/// Kept UI-independent so the real accessibility/availability policy can be
/// exercised by an isolated host, without a chat store or device services.
enum AmoreSettingsGlassPolicy {
    enum Surface: Equatable { case opaque, material, glass }

    static func surface(reduceTransparency: Bool, increaseContrast: Bool = false,
                        supportsLiquidGlass: Bool) -> Surface {
        if reduceTransparency || increaseContrast { return .opaque }
        return supportsLiquidGlass ? .glass : .material
    }

    static func opaqueFillHex(dark: Bool) -> UInt32 { dark ? 0x1C1F27 : 0xFFFFFF }
}

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Paint-only surface: never adds layout, gestures, interaction or a shadow.
/// List/Form owns the row's grouped corners, separator and original hit area.
struct AmoreSettingsGlassSurface<SurfaceShape: InsettableShape>: View {
    let shape: SurfaceShape
    var forceOpaque: Bool = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var surface: AmoreSettingsGlassPolicy.Surface {
        var supportsLiquidGlass = false
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { supportsLiquidGlass = true }
        #endif
        return AmoreSettingsGlassPolicy.surface(reduceTransparency: reduceTransparency || forceOpaque,
            increaseContrast: contrast == .increased, supportsLiquidGlass: supportsLiquidGlass)
    }

    var body: some View {
        paint
            .overlay {
                shape.strokeBorder(Color(uiColor: .separator).opacity(0.24), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var paint: some View {
        if surface == .opaque {
            shape.fill(AmoreSettingsGlassPalette.opaqueFill(dark: scheme == .dark))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                // Non-interactive glass: the system row keeps every touch.
                Color.clear.glassEffect(.regular, in: shape).clipShape(shape)
            } else {
                material
            }
            #else
            material
            #endif
        }
    }

    private var material: some View {
        // Genuine native backdrop blur on iOS 18 (and the older deployment
        // floor), not a translucent colour pretending to be glass.
        shape.fill(.regularMaterial).clipShape(shape)
    }
}

enum AmoreSettingsGlassPalette {
    static let uiOpaqueFill = UIColor { traits in
        let hex = AmoreSettingsGlassPolicy.opaqueFillHex(dark: traits.userInterfaceStyle == .dark)
        return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                       green: CGFloat((hex >> 8) & 255) / 255,
                       blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let opaqueFill = Color(uiOpaqueFill)
    static func opaqueFill(dark: Bool) -> Color {
        let hex = AmoreSettingsGlassPolicy.opaqueFillHex(dark: dark)
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}

struct AmoreSettingsGlassRowBackground: View {
    var forceOpaque = false
    var body: some View { AmoreSettingsGlassSurface(shape: Rectangle(), forceOpaque: forceOpaque) }
}

/// Shared page paint for existing Lists, Forms and non-lazy parent stacks.
/// Uses AmoreAppearance's inherited colorScheme and the SAME home backdrop as
/// the chat. No second preference key, forced mode, .id or nested navigation.
struct AmoreSettingsGlassStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var barStyle: AnyShapeStyle {
        reduceTransparency || contrast == .increased
            ? AnyShapeStyle(AmoreSettingsGlassPalette.opaqueFill)
            : AnyShapeStyle(.regularMaterial)
    }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { AmoreChatBackdrop(home: true) }
            .foregroundStyle(PokiTheme.primaryText)
            .tint(PokiTheme.blueText)
            .toolbarBackground(barStyle, for: .navigationBar)
    }
}

extension View {
    func amoreSettingsGlass() -> some View { modifier(AmoreSettingsGlassStyle()) }

    /// Apply to row/Section/ForEach content INSIDE List/Form, never rely on a
    /// List-level background override to beat explicitly painted child rows.
    func amoreSettingsGlassRows() -> some View {
        listRowBackground(AmoreSettingsGlassRowBackground())
    }
}
#endif
