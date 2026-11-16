import SwiftUI

/// Independently implemented drawer geometry, following Poki's exposed-chat
/// proportions without copying its drawing or brand assets.
enum PokiDrawerMetrics {
    static func travel(for width: CGFloat) -> CGFloat {
        let visibleChat = max(72, (width * 0.22).rounded())
        return max(1, min(width - visibleChat, 420))
    }
}

/// Paints just the outer corner cutouts. Unlike clipping a live collection
/// view, this does not re-rasterise its text for each drag frame.
struct PokiConversationCorners: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        return path
    }
}

/// Glass belongs to the exposed conversation while the drawer is open, never
/// to the sidebar itself. It is removed entirely in the resting chat state.
struct PokiConversationCover: View {
    let progress: CGFloat
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                Rectangle().fill(.ultraThinMaterial).opacity(Double(progress) * 0.28)
            }
            Color.black.opacity(Double(progress) * (scheme == .dark ? 0.30 : 0.06))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityElement()
        .accessibilityLabel(Text(AppLocalized("Close conversations")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onClose() }
    }
}
