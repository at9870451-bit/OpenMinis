import SwiftUI

/// One material layer only. This modifier is used by the real Amore composer
/// and simulator snapshots; it adds no padding or frame to the editor.
struct PokiComposerMaterial: ViewModifier {
    var radius: CGFloat = PokiTheme.Radius.composer
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape).clipShape(shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.bar, in: shape)
            .overlay(shape.strokeBorder(PokiTheme.fieldEdge, lineWidth: 0.5))
            .clipShape(shape)
    }
}
