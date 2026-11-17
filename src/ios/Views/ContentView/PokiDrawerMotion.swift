import SwiftUI

/// ChatGPT/Poki-style exposed conversation geometry; the sidebar itself stays
/// solid and only the exposed conversation card uses material.
enum PokiDrawerMetrics {
    static func travel(for width: CGFloat) -> CGFloat {
        let visibleChat = max(72, (width * 0.22).rounded())
        return max(1, min(width - visibleChat, 420))
    }

    static func cornerRadius(progress: CGFloat, safeAreaInsets: EdgeInsets) -> CGFloat {
        let phase = min(1, max(0, progress))
        let resting = min(60, max(34, max(safeAreaInsets.top, safeAreaInsets.bottom)))
        return min(1, phase / 0.15) * resting
    }
}

struct PokiDrawerPanelBounds {
    let size: CGSize
    let centerOffset: CGSize

    init(containerSize: CGSize, safeAreaInsets: EdgeInsets) {
        size = CGSize(width: containerSize.width + safeAreaInsets.leading + safeAreaInsets.trailing,
                      height: containerSize.height + safeAreaInsets.top + safeAreaInsets.bottom)
        centerOffset = CGSize(width: (safeAreaInsets.trailing - safeAreaInsets.leading) / 2,
                              height: (safeAreaInsets.bottom - safeAreaInsets.top) / 2)
    }
}

struct PokiConversationPanel: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: min(max(0, radius), min(rect.width, rect.height) / 2),
                         style: .continuous).path(in: rect)
    }
}

/// Keeps the live chat mounted for streaming continuity. At a fully open drawer
/// only the independent material cover is visible; no chat pixels leak through.
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
        let radius = PokiDrawerMetrics.cornerRadius(progress: phase, safeAreaInsets: safeAreaInsets)
        ZStack {
            chat
                .frame(width: containerSize.width, height: containerSize.height)
                .offset(x: -bounds.centerOffset.width, y: -bounds.centerOffset.height)
                .opacity(Double(1 - phase))
                .allowsHitTesting(phase <= 0.001)
                .accessibilityHidden(phase > 0.001)
            if phase > 0.001 || presentationActive {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(Double(phase))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .allowsHitTesting(phase > 0.001)
                    .accessibilityHidden(phase <= 0.001)
                    .accessibilityLabel(Text(AppLocalized("Close conversations")))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onClose() }
            }
        }
        .frame(width: bounds.size.width, height: bounds.size.height)
        .clipShape(PokiConversationPanel(radius: reduceMotion ? 0 : radius))
        .offset(x: bounds.centerOffset.width + (reduceMotion ? drawerWidth : drawerWidth * phase),
                y: bounds.centerOffset.height)
        .frame(width: containerSize.width, height: containerSize.height)
    }
}
