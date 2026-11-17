import SwiftUI

/// Only controls use material; the sidebar and message content stay solid.
/// Uses platform glass on current iOS and native material on earlier systems.
private struct PokiControlSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(), in: shape)
                    .contentShape(shape)
            } else {
                content.glassEffect(.regular.interactive(), in: shape)
                    .contentShape(shape)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }
    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.6)) }
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
            .contentShape(shape)
    }
}

extension View {
    func pokiControl<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(PokiControlSurface(shape: shape, tint: tint))
    }
}
