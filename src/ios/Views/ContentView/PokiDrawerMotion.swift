import SwiftUI

/// Solid ChatGPT-style drawer geometry. Keep the established metrics API for
/// EdgeSwipeCatcher so its left-edge progress matches the conversation travel.
enum PokiDrawerMetrics {
    static func travel(for width: CGFloat) -> CGFloat {
        let visibleChat = max(72, (width * 0.22).rounded())
        return max(1, min(width - visibleChat, 420))
    }

    static func cornerRadius(progress: CGFloat, safeAreaInsets: EdgeInsets) -> CGFloat {
        let phase = min(1, max(0, progress))
        return 16 * phase
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

/// A small rounded viewport shared by the live conversation and its tap cover.
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

/// Translates a permanently mounted live chat; only a flat dimming cover is
/// added while presenting the drawer. There are no snapshots or materials.
/// The inner chat keeps its original safe-area layout and keyboard avoidance.
/// Reduce Motion leaves the chat stationary and cross-fades the sidebar above.
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
        let radius = reduceMotion ? 0 : PokiDrawerMetrics.cornerRadius(progress: phase, safeAreaInsets: safeAreaInsets)

        ZStack {
            chat
                .frame(width: containerSize.width, height: containerSize.height)
                .offset(x: -bounds.centerOffset.width, y: -bounds.centerOffset.height)
                .allowsHitTesting(phase <= 0.001)
                .accessibilityHidden(phase > 0.001)

            // Kept mounted: adding/removing the cover never replaces the chat.
            PokiConversationCover(progress: phase, onClose: onClose)
        }
        .frame(width: bounds.size.width, height: bounds.size.height)
        .clipShape(PokiConversationPanel(radius: radius))
        .offset(x: bounds.centerOffset.width + (reduceMotion ? 0 : drawerWidth * phase),
                y: bounds.centerOffset.height)
        .frame(width: containerSize.width, height: containerSize.height)
    }
}

/// A cheap scrim over the actual conversation; the exposed right strip closes
/// on tap and exposes the same close action to VoiceOver.
struct PokiConversationCover: View {
    let progress: CGFloat
    let onClose: () -> Void

    private var visibleProgress: CGFloat { min(1, max(0, progress)) }

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.16 * Double(visibleProgress)))
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
            .allowsHitTesting(visibleProgress > 0.001)
            .accessibilityElement()
            .accessibilityHidden(visibleProgress <= 0.001)
            .accessibilityLabel(Text(AppLocalized("Close conversations")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onClose() }
    }
}
