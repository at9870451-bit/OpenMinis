import SwiftUI

/// Independently implemented drawer geometry, following Poki's exposed-chat
/// proportions without copying its drawing or brand assets.
enum PokiDrawerMetrics {
    static func travel(for width: CGFloat) -> CGFloat {
        let visibleChat = max(72, (width * 0.22).rounded())
        return max(1, min(width - visibleChat, 420))
    }

    static func cornerRadius(progress: CGFloat, safeAreaInsets: EdgeInsets) -> CGFloat {
        let phase = min(1, max(0, progress))
        let restingRadius = min(60, max(34, max(safeAreaInsets.top, safeAreaInsets.bottom)))
        return min(1, phase / 0.15) * restingRadius
    }
}

/// Full-window panel bounds reconstructed from a safe-area-sized container.
/// The chat keeps its safe-area layout; only its clipping host uses these bounds.
struct PokiDrawerPanelBounds {
    let size: CGSize
    let centerOffset: CGSize

    init(containerSize: CGSize, safeAreaInsets: EdgeInsets) {
        size = CGSize(
            width: containerSize.width + safeAreaInsets.leading + safeAreaInsets.trailing,
            height: containerSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
        centerOffset = CGSize(
            width: (safeAreaInsets.trailing - safeAreaInsets.leading) / 2,
            height: (safeAreaInsets.bottom - safeAreaInsets.top) / 2
        )
    }
}

/// The actual rounded viewport shared by the live chat and its glass cover.
struct PokiConversationPanel: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clampedRadius = min(max(0, radius), max(0, min(rect.width, rect.height) / 2))
        return RoundedRectangle(cornerRadius: clampedRadius, style: .continuous).path(in: rect)
    }
}

/// Keeps the live navigation/chat tree mounted, but fades all of its pixels
/// out as the drawer opens. At progress 1 only an independent material remains.
///
/// `containerSize` and `safeAreaInsets` must come from the SAME GeometryReader
/// before any ignoresSafeArea modifier. The inner chat retains that reader's
/// safe-area size and origin, including keyboard avoidance. Its full-bounds host
/// clips navigation/collection-view overflow as well as the glass in one place.
/// There is no drawingGroup, snapshot, or per-frame walk of the chat view tree.
struct PokiDrawerConversationPanel<Chat: View>: View {
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let drawerWidth: CGFloat
    let progress: CGFloat
    let presentationActive: Bool
    let reduceMotion: Bool
    let onClose: () -> Void
    private let chat: Chat

    init(containerSize: CGSize, safeAreaInsets: EdgeInsets, drawerWidth: CGFloat,
         progress: CGFloat, presentationActive: Bool, reduceMotion: Bool,
         onClose: @escaping () -> Void, @ViewBuilder chat: () -> Chat) {
        self.containerSize = containerSize
        self.safeAreaInsets = safeAreaInsets
        self.drawerWidth = drawerWidth
        self.progress = progress
        self.presentationActive = presentationActive
        self.reduceMotion = reduceMotion
        self.onClose = onClose
        self.chat = chat()
    }

    var body: some View {
        let phase = min(1, max(0, progress))
        let bounds = PokiDrawerPanelBounds(containerSize: containerSize, safeAreaInsets: safeAreaInsets)
        let openRadius = PokiDrawerMetrics.cornerRadius(progress: 1, safeAreaInsets: safeAreaInsets)
        let radius = PokiDrawerMetrics.cornerRadius(progress: phase, safeAreaInsets: safeAreaInsets)
        let isPresenting = presentationActive || phase > 0

        ZStack {
            chat
                .frame(width: containerSize.width, height: containerSize.height)
                .offset(x: -bounds.centerOffset.width, y: -bounds.centerOffset.height)
                .opacity(Double(1 - phase))
                .allowsHitTesting(phase <= 0.001)
                .accessibilityHidden(phase > 0.001)

            if isPresenting {
                PokiConversationCover(progress: phase, onClose: onClose)
                    // Reduced motion cross-fades in place. The glass starts at
                    // its final position, so its open-state geometry is identical.
                    .clipShape(PokiConversationPanel(radius: reduceMotion ? openRadius : 0))
                    .offset(x: reduceMotion ? drawerWidth : 0)
            }
        }
        .frame(width: bounds.size.width, height: bounds.size.height)
        .clipShape(PokiConversationPanel(radius: reduceMotion ? 0 : radius))
        .offset(x: bounds.centerOffset.width + (reduceMotion ? 0 : drawerWidth * phase),
                y: bounds.centerOffset.height)
        .frame(width: containerSize.width, height: containerSize.height)
    }
}

/// A single glass layer over the exposed conversation; the sidebar stays solid.
/// Reduce Motion changes positioning above, never whether this material exists.
struct PokiConversationCover: View {
    let progress: CGFloat
    let onClose: () -> Void

    private var visibleProgress: CGFloat { min(1, max(0, progress)) }

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(Double(visibleProgress))
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
            .allowsHitTesting(visibleProgress > 0)
            .accessibilityElement()
            .accessibilityHidden(visibleProgress <= 0)
            .accessibilityLabel(Text(AppLocalized("Close conversations")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onClose() }
    }
}
