import SwiftUI

/// A paint-only policy. Default translucency never fills the pane with blue.
/// Respect the user's system accessibility request for an opaque surface.
enum AmoreDrawerSurfacePolicy {
    static func opaque(reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        reduceTransparency || increasedContrast
    }
    static let materialOpacity = 0.30
}

struct AmoreDrawerBackdrop: View {
    var forceOpaque = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if forceOpaque || AmoreDrawerSurfacePolicy.opaque(
                reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased) {
                Color(uiColor: .systemBackground)
            } else {
                // Partial native material, NOT an opaque colour with a glass label.
                // The one live conversation remains visible through this surface.
                Rectangle().fill(.ultraThinMaterial)
                    .opacity(AmoreDrawerSurfacePolicy.materialOpacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The actual chat/navigation tree appears exactly once. Sliding the sidebar
/// OVER it (rather than moving chat out from behind it) makes translucency real.
/// No snapshot, second AIChatView, cloned VM, store read or per-frame mutation.
struct AmoreTransparentDrawer<Chat: View, Sidebar: View>: View {
    let size: CGSize
    let drawerWidth: CGFloat
    let progress: CGFloat
    let presentationActive: Bool
    let reduceMotion: Bool
    let onClose: () -> Void
    private let chat: Chat
    private let sidebar: Sidebar

    init(size: CGSize, drawerWidth: CGFloat, progress: CGFloat,
         presentationActive: Bool, reduceMotion: Bool, onClose: @escaping () -> Void,
         @ViewBuilder chat: () -> Chat, @ViewBuilder sidebar: () -> Sidebar) {
        self.size = size; self.drawerWidth = drawerWidth; self.progress = progress
        self.presentationActive = presentationActive; self.reduceMotion = reduceMotion
        self.onClose = onClose; self.chat = chat(); self.sidebar = sidebar()
    }

    var body: some View {
        let phase = AmoreDrawerPresentation.phase(progress)
        ZStack(alignment: .leading) {
            chat
                .environment(\.amoreDrawerProgress, phase)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(phase < 0.001 && !presentationActive)
                .accessibilityHidden(phase >= 0.001 || presentationActive)

            if phase > 0.001 || presentationActive {
                // Transparent dismiss target above chat and below the sidebar.
                // Sidebar controls consume their own touches; the exposed right
                // strip dismisses without pressing the transcript underneath.
                Color.clear
                    .frame(width: max(0, size.width - drawerWidth * phase), height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .offset(x: drawerWidth * phase)
                    .allowsHitTesting(phase > 0.001 || presentationActive)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("amore.drawer.dismiss")
            }

            sidebar
                .frame(width: drawerWidth, height: size.height, alignment: .leading)
                .background { AmoreDrawerBackdrop().ignoresSafeArea(.container, edges: .vertical) }
                .contentShape(Rectangle())
                .offset(x: reduceMotion ? 0 : -drawerWidth * (1 - phase))
                .opacity(reduceMotion ? phase : 1)
                .allowsHitTesting(phase >= 0.999)
                .accessibilityHidden(phase < 0.999)
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .contentShape(Rectangle())
    }
}
