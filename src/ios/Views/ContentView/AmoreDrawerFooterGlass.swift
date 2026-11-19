import Foundation

/// Paint policy only; the drawer's blue backing and existing buttons own layout.
enum AmoreDrawerFooterGlassPolicy {
    enum Surface: Equatable { case opaque, material, glass }

    static func surface(reduceTransparency: Bool, increaseContrast: Bool,
                        supportsLiquidGlass: Bool) -> Surface {
        if reduceTransparency || increaseContrast { return .opaque }
        return supportsLiquidGlass ? .glass : .material
    }
}

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Only a button background, never the footer/bar. Uses the same native
/// regular glass/material path as the production glass helpers, without tint
/// or interactive glass in the label (the original Button owns every touch).
struct AmoreDrawerFooterGlass<SurfaceShape: InsettableShape>: View {
    let shape: SurfaceShape
    var forceOpaque: Bool = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var surface: AmoreDrawerFooterGlassPolicy.Surface {
        var supportsLiquidGlass = false
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { supportsLiquidGlass = true }
        #endif
        return AmoreDrawerFooterGlassPolicy.surface(reduceTransparency: reduceTransparency || forceOpaque,
            increaseContrast: contrast == .increased, supportsLiquidGlass: supportsLiquidGlass)
    }

    var body: some View {
        paint
            .overlay {
                // A control outline, not a footer divider. Semantic separator
                // adapts to the system's light/dark and increased-contrast traits.
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var paint: some View {
        if surface == .opaque {
            // Accessibility only: an adaptive neutral system surface, not blue.
            shape.fill(Color(uiColor: .secondarySystemBackground))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
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
        // Real native backdrop sampling on iOS 18, not a colour approximation.
        shape.fill(.regularMaterial).clipShape(shape)
    }
}

/// Neutral system material needs semantic foreground (especially for the
/// opaque accessibility fallback), independently of the blue drawer's ink.
struct AmoreDrawerFooterGlassModifier<SurfaceShape: InsettableShape>: ViewModifier {
    let shape: SurfaceShape

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color(uiColor: .label))
            .background { AmoreDrawerFooterGlass(shape: shape) }
    }
}

extension View {
    func amoreDrawerFooterGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(AmoreDrawerFooterGlassModifier(shape: shape))
    }
}
#endif
